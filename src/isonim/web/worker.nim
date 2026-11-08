## isonim/web/worker.nim
##
## The Web Worker build target (IsoNim.md § Web Worker Target): a module
## compiled to its own, separately loaded script that runs off the main
## thread, and a typed message bridge between the two.
##
## The worker side is a Nim module built with `-d:isonimWebWorker` (by
## `tools/isonim-bundle.mjs build --kind worker`, which also records the
## chunk for the bundle-size report) whose top level calls `serveWorker`:
##
##   # preview.worker.nim
##   import isonim/web/worker, preview_compile
##   serveWorker(compilePreview)       # proc(req: PreviewRequest): PreviewResult
##
## The main thread talks to it through a `WorkerBridge[Req, Resp]`:
##
##   let bridge = newWorkerBridge[PreviewRequest, PreviewResult]("preview.worker.js")
##   bridge.onResult proc(rev: int; res: PreviewResult) = patch(res)
##   discard bridge.post(PreviewRequest(text: editor.text))
##
## Every request carries a revision (1, 2, 3, ... per bridge). `onResult`
## sees a response only when its revision is the newest one posted; older
## ones are counted in `dropped` and discarded, so a slow answer to a stale
## request never overwrites a newer one.
##
## Messages cross the thread boundary as plain JS values (`toWire` /
## `fromWire`): strings, numbers, booleans, enums, seqs and arrays, objects,
## tuples and refs of those. Closures, JS objects and variant objects are
## not messages.
##
## `newInlineBridge` has the same API and the same serialization but runs
## the handler on the main thread (one task later). It is the fallback where
## Workers are unavailable, and the in-thread build the off-main-thread
## guarantee is measured against.
##
## CANCELLING CPU WORK. `serveWorker`'s handler runs to completion, so a
## stale request still costs its whole computation. A handler that can work
## in steps uses `serveWorkerSteps` instead: `start` builds a run from the
## request, `step` advances it (true when done) and `finish` makes the
## response. The worker yields to its message queue between steps, and when
## a newer revision has arrived it abandons the current run and starts the
## newest one, so a superseded request stops after at most one step. Each
## request is acknowledged (`seen`) as soon as the worker takes it.
##
## A single step that runs long cannot be interrupted from inside the
## worker. `newSupervisedBridge` covers that case on the main thread: it
## keeps a second, pre-started worker, and when the worker has acknowledged
## no revision newer than the one it is running within `overrunMs` of the
## first such revision being posted (later posts do not extend the deadline),
## it terminates the busy worker, promotes the spare (which is already
## loaded), starts a new spare and posts the newest revision to the promoted
## worker. `restarts` counts the replacements.

when not defined(js):
  {.error: "isonim/web/worker requires the JS backend".}

import std/jsffi

# ---------------------------------------------------------------------------
# The wire format
# ---------------------------------------------------------------------------

proc newJsArr(): JsObject =
  {.emit: [result, " = [];"].}
proc push(a, v: JsObject) {.importjs: "#.push(#)".}
proc jsLen(a: JsObject): int {.importjs: "#.length".}
proc jsNull(): JsObject =
  {.emit: [result, " = null;"].}
proc isJsNull(v: JsObject): bool {.importjs: "(# == null)".}

proc toWire*[T](x: T): JsObject =
  ## `x` as a structured-clonable JS value.
  when T is string:
    result = toJs(cstring(x))
  elif T is cstring or T is bool or T is SomeNumber:
    result = toJs(x)
  elif T is enum:
    result = toJs(ord(x))
  elif T is seq or T is array:
    result = newJsArr()
    for e in x:
      result.push(toWire(e))
  elif T is ref:
    result = if x.isNil: jsNull() else: toWire(x[])
  elif T is object or T is tuple:
    result = newJsObject()
    for name, v in x.fieldPairs:
      result[cstring(name)] = toWire(v)
  else:
    {.error: "isonim/web/worker: " & $T & " cannot cross a worker boundary".}

proc fromWire*[T](v: JsObject; t: typedesc[T]): T =
  ## The value `toWire` turned into `v`.
  when T is string:
    result = $v.to(cstring)
  elif T is cstring or T is bool or T is SomeNumber:
    result = v.to(T)
  elif T is enum:
    result = T(v.to(int))
  elif T is seq:
    let n = v.jsLen
    result.setLen(n)
    for i in 0 ..< n:
      result[i] = fromWire(v[i], typeof(result[0]))
  elif T is array:
    for i in 0 ..< min(v.jsLen, result.len):
      result[i] = fromWire(v[i], typeof(result[0]))
  elif T is ref:
    if not v.isJsNull:
      new(result)
      result[] = fromWire(v, typeof(result[]))
  elif T is object or T is tuple:
    for name, f in result.fieldPairs:
      f = fromWire(v[cstring(name)], typeof(f))
  else:
    {.error: "isonim/web/worker: " & $T & " cannot cross a worker boundary".}

proc envelope(rev: int; key: cstring; value: JsObject): JsObject =
  result = newJsObject()
  result["rev"] = toJs(rev)
  result[key] = value

# ---------------------------------------------------------------------------
# The worker side
# ---------------------------------------------------------------------------

proc inWorkerScope*(): bool =
  ## True when running on a worker thread.
  {.emit: [result, " = (typeof WorkerGlobalScope !== 'undefined' && self instanceof WorkerGlobalScope);"].}

when defined(isonimWebWorker):
  proc postToMain(msg: JsObject) {.importjs: "self.postMessage(#)".}
  proc setOnMessage(cb: proc(ev: JsObject)) {.importjs: "self.onmessage = #".}

  proc serveWorker*[Req, Resp](handler: proc(req: Req): Resp) =
    ## Answers each request the main thread posts with `handler`'s result,
    ## tagged with the request's revision. An exception is sent back as an
    ## error for that revision (the bridge's `onError`).
    setOnMessage proc(ev: JsObject) =
      let data = ev["data"]
      let rev = data["rev"].to(int)
      try:
        let resp = handler(fromWire(data["body"], Req))
        postToMain(envelope(rev, "body", toWire(resp)))
      except CatchableError as e:
        postToMain(envelope(rev, "error", toJs(cstring(e.msg))))

  proc yieldThen(cb: proc()) =
    ## Runs `cb` in a later task, after the messages already queued (a
    ## MessageChannel task, not clamped like a timer).
    {.emit: ["var ch = new MessageChannel(); ch.port1.onmessage = function () { ",
             cb, "(); }; ch.port2.postMessage(0);"].}

  proc serveWorkerSteps*[Req, Resp, Run](start: proc(req: Req): Run;
                                         step: proc(run: var Run): bool;
                                         finish: proc(run: Run): Resp) =
    ## Like `serveWorker`, for a computation made of steps (module doc,
    ## CANCELLING CPU WORK): the worker yields between steps and abandons a
    ## run once a newer revision has arrived. Every request is acknowledged
    ## with `seen` when the worker takes it.
    var pendingRev = 0
    var pendingBody: JsObject = nil
    var running = false
    var loop: proc()
    loop = proc() =
      if pendingBody == nil:
        running = false
        return
      let rev = pendingRev
      let body = pendingBody
      pendingBody = nil
      var run: Run
      var done = false
      try:
        run = start(fromWire(body, Req))
      except:
        # A bare `except`: a JavaScript error (a RangeError from a deep
        # recursion) is not a CatchableError, and an escaped one would leave
        # the loop marked running, answering nothing ever again.
        postToMain(envelope(rev, "error", toJs(cstring(getCurrentExceptionMsg()))))
        yieldThen(loop)
        return
      var advance: proc()
      advance = proc() =
        if pendingBody != nil:
          loop()                      # superseded: start the newest one
          return
        try:
          done = step(run)
          if done:
            postToMain(envelope(rev, "body", toWire(finish(run))))
        except:
          postToMain(envelope(rev, "error", toJs(cstring(getCurrentExceptionMsg()))))
          done = true
        if done: yieldThen(loop)
        else: yieldThen(advance)
      advance()
    setOnMessage proc(ev: JsObject) =
      let data = ev["data"]
      pendingRev = data["rev"].to(int)
      pendingBody = data["body"]
      postToMain(envelope(pendingRev, "seen", toJs(true)))
      if not running:
        running = true
        loop()

else:
  template serveWorker*(handler: untyped) =
    {.error: "serveWorker belongs in a worker chunk: build this module with " &
      "-d:isonimWebWorker (tools/isonim-bundle.mjs build --kind worker)".}
  template serveWorkerSteps*(start, step, finish: untyped) =
    {.error: "serveWorkerSteps belongs in a worker chunk: build this module with " &
      "-d:isonimWebWorker (tools/isonim-bundle.mjs build --kind worker)".}

# ---------------------------------------------------------------------------
# The main-thread side
# ---------------------------------------------------------------------------

type
  WorkerBridge*[Req, Resp] = ref object
    ## The main thread's end of a worker (or of an inline stand-in).
    worker: JsObject                   ## the Worker; nil for an inline bridge
    inline: proc(req: Req): Resp
    latest*: int                       ## the newest revision posted
    received*: int                     ## responses received, stale ones included
    dropped*: int                      ## stale responses discarded
    resultCb: proc(rev: int; resp: Resp)
    errorCb: proc(rev: int; msg: string)
    # Supervision (newSupervisedBridge; module doc).
    scriptUrl: string
    spare: JsObject                    ## the pre-started replacement
    overrunMs: int
    seen: int                          ## the newest revision the worker took
    answered: int                      ## the newest revision answered
    lastMsg: JsObject                  ## the newest request, to re-post
    restarts*: int                     ## busy workers replaced
    overrunArmed: bool                 ## an overrun check is pending (post)
    restartCb: proc(rev: int)

proc newWorker(url: cstring): JsObject {.importjs: "new Worker(#)".}
proc postToWorker(w, msg: JsObject) {.importjs: "#.postMessage(#)".}
proc terminateWorker(w: JsObject) {.importjs: "#.terminate()".}
proc setTimeout0(cb: proc()) {.importjs: "setTimeout(#, 0)".}

proc setTimeoutMs(cb: proc(); ms: int) {.importjs: "setTimeout(#, #)".}

proc deliver[Req, Resp](b: WorkerBridge[Req, Resp]; msg: JsObject) =
  let rev = msg["rev"].to(int)
  var seenMsg: bool
  {.emit: [seenMsg, " = ('seen' in ", msg, ");"].}
  if seenMsg:
    b.seen = max(b.seen, rev)
    return
  b.answered = max(b.answered, rev)
  inc b.received
  if rev != b.latest:
    inc b.dropped
    return
  var isError: bool
  {.emit: [isError, " = ('error' in ", msg, ");"].}
  if isError:
    if b.errorCb != nil:
      b.errorCb(rev, $msg["error"].to(cstring))
  elif b.resultCb != nil:
    b.resultCb(rev, fromWire(msg["body"], Resp))

proc wire[Req, Resp](b: WorkerBridge[Req, Resp]) =
  let onMessage = proc(ev: JsObject) = b.deliver(ev["data"])
  b.worker["onmessage"] = toJs(onMessage)

proc newWorkerBridge*[Req, Resp](scriptUrl: string): WorkerBridge[Req, Resp] =
  ## Starts the worker chunk at `scriptUrl` (a dedicated, classic Worker).
  let b = WorkerBridge[Req, Resp](worker: newWorker(cstring(scriptUrl)))
  b.wire()
  b

proc newSupervisedBridge*[Req, Resp](scriptUrl: string;
                                     overrunMs = 32): WorkerBridge[Req, Resp] =
  ## A worker bridge with a pre-started spare (module doc, CANCELLING CPU
  ## WORK): a newer revision that the busy worker has not taken within
  ## `overrunMs` replaces the worker. Pair it with `serveWorkerSteps`, whose
  ## acknowledgements the supervision watches.
  let b = WorkerBridge[Req, Resp](worker: newWorker(cstring(scriptUrl)), scriptUrl: scriptUrl,
                                  spare: newWorker(cstring(scriptUrl)), overrunMs: overrunMs)
  b.wire()
  b

proc replaceBusy[Req, Resp](b: WorkerBridge[Req, Resp]) =
  ## The busy worker is terminated and the spare takes the newest request.
  b.worker.terminateWorker()
  b.worker = b.spare
  b.spare = newWorker(cstring(b.scriptUrl))
  b.wire()
  b.seen = 0
  b.answered = 0
  inc b.restarts
  b.worker.postToWorker(b.lastMsg)
  if b.restartCb != nil: b.restartCb(b.latest)

proc newInlineBridge*[Req, Resp](handler: proc(req: Req): Resp): WorkerBridge[Req, Resp] =
  ## A bridge whose "worker" is `handler` on the main thread.
  WorkerBridge[Req, Resp](inline: handler)

proc onResult*[Req, Resp](b: WorkerBridge[Req, Resp];
                          cb: proc(rev: int; resp: Resp)) =
  ## Called with the response to the newest revision only.
  b.resultCb = cb

proc onRestart*[Req, Resp](b: WorkerBridge[Req, Resp]; cb: proc(rev: int)) =
  ## Called when the supervision replaced a busy worker, with the revision
  ## re-posted to the promoted spare (newSupervisedBridge).
  b.restartCb = cb

proc onError*[Req, Resp](b: WorkerBridge[Req, Resp];
                         cb: proc(rev: int; msg: string)) =
  ## Called when the handler raised for the newest revision.
  b.errorCb = cb

proc post*[Req, Resp](b: WorkerBridge[Req, Resp]; req: Req): int =
  ## Sends `req` as the next revision and returns that revision. Earlier
  ## revisions still in flight become stale.
  inc b.latest
  result = b.latest
  let msg = envelope(result, "body", toWire(req))
  if b.worker != nil:
    let outstanding = b.answered < result - 1 and b.lastMsg != nil
    b.lastMsg = msg
    b.worker.postToWorker(msg)
    if b.spare != nil and outstanding and not b.overrunArmed:
      # An older revision is still running, and this one is the first to
      # wait for it: the worker must take it (or any later one) within
      # `overrunMs`, or its current step has overrun. The deadline runs from
      # the FIRST waiting revision and later posts do not move it, so a
      # stream of revisions posted faster than `overrunMs` cannot keep a
      # stuck worker from being replaced (each post re-arming the check made
      # only the last one count, and a step that ended before the stream did
      # was never replaced however long it had held the newer ones).
      let first = result
      b.overrunArmed = true
      let check = proc() =
        b.overrunArmed = false
        if b.seen < first and b.answered < b.latest:
          b.replaceBusy()
      setTimeoutMs(check, b.overrunMs)
  else:
    let rev = result
    setTimeout0 proc() =
      var reply: JsObject
      try:
        reply = envelope(rev, "body",
          toWire(b.inline(fromWire(msg["body"], Req))))
      except CatchableError as e:
        reply = envelope(rev, "error", toJs(cstring(e.msg)))
      b.deliver(reply)

proc terminate*[Req, Resp](b: WorkerBridge[Req, Resp]) =
  ## Stops the worker at once, mid-request if need be (a stuck request is
  ## abandoned this way; post to a fresh bridge afterwards).
  if b.worker != nil:
    b.worker.terminateWorker()
  if b.spare != nil:
    b.spare.terminateWorker()
    b.spare = nil
