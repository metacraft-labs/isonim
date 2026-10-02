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

else:
  template serveWorker*(handler: untyped) =
    {.error: "serveWorker belongs in a worker chunk: build this module with " &
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

proc newWorker(url: cstring): JsObject {.importjs: "new Worker(#)".}
proc postToWorker(w, msg: JsObject) {.importjs: "#.postMessage(#)".}
proc terminateWorker(w: JsObject) {.importjs: "#.terminate()".}
proc setTimeout0(cb: proc()) {.importjs: "setTimeout(#, 0)".}

proc deliver[Req, Resp](b: WorkerBridge[Req, Resp]; msg: JsObject) =
  let rev = msg["rev"].to(int)
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

proc newWorkerBridge*[Req, Resp](scriptUrl: string): WorkerBridge[Req, Resp] =
  ## Starts the worker chunk at `scriptUrl` (a dedicated, classic Worker).
  let b = WorkerBridge[Req, Resp](worker: newWorker(cstring(scriptUrl)))
  let onMessage = proc(ev: JsObject) = b.deliver(ev["data"])
  b.worker["onmessage"] = toJs(onMessage)
  b

proc newInlineBridge*[Req, Resp](handler: proc(req: Req): Resp): WorkerBridge[Req, Resp] =
  ## A bridge whose "worker" is `handler` on the main thread.
  WorkerBridge[Req, Resp](inline: handler)

proc onResult*[Req, Resp](b: WorkerBridge[Req, Resp];
                          cb: proc(rev: int; resp: Resp)) =
  ## Called with the response to the newest revision only.
  b.resultCb = cb

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
    b.worker.postToWorker(msg)
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
