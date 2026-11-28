## Callback services adapted to async values (`isonim/services/callbacks`),
## under fake time.
##
## `fromCallbacks` (a stream, for `createAsyncStream`): a callback that fires
## after its flight was replaced, after it settled, or after its owner was
## disposed reaches nothing; `Uninstall` runs exactly once on each of those
## three paths and never again; two flights in a row work on one client
## that keeps one callback set; an event that names no request reaches the
## only flight installed (or, with none, the set the client had before);
## `Uninstall` puts back the previous set, including when the completion
## hook starts the next flight; a flight that settles while `install` runs
## is undone when `install` returns; a producer that ends twice, or after a
## cancel, is undone once; `install` raising fails the question, and a
## callback it wrapped before raising reaches nothing; `Uninstall` runs
## before the value hears an end or a failure.
##
## `createAsyncFromCallback` (one answer): the value is the answer itself,
## not a sequence of one chunk; the same three stop paths drop late
## callbacks and run `Uninstall` once; a failure shows `failed`; a second
## answer is dropped and undoes nothing again; `install` raising fails the
## question and leaves no flight behind: a callback it wrapped before
## raising reaches nothing. Its answer
## travels through a platform future, which on JS is a promise whose
## callbacks run on a microtask a synchronous `unittest` case cannot wait
## for, so these cases are asynchronous scenarios on both backends (see
## `tests/test_async_timing_js.nim` for the same shape); each reports its
## own `[OK]` / `[FAILED]` line, and the process fails unless every
## scenario reported success.
##
## MOCK POLICY (workspace rule: every mock justified in the header). One
## fake client, `FakeClient`, standing in for a service that reports through
## callbacks: it keeps one set of callbacks, as a browser client object
## does; its transport captures the set current when a request is
## submitted, as such a client hands its callbacks to the connection that
## carries the request, and it can also dispatch an event through whatever
## set is current, as an event that names no request is. The test fires
## those events itself, at chosen times on the fake clock, because the
## point of each case is an event arriving after its flight stopped, which a
## real service cannot be made to do on cue. It also counts installs and
## uninstalls, which are the assertions. The adapter, the async value, its
## signals, effects, owners, the stream protocol and the futures are the
## real ones.

import std/unittest

import nim_everywhere
import nim_everywhere/async_compat
import isonim/core/[signals, owner, computation]
import isonim/services/[async_value, callbacks]

import helpers/async_recording_service

type
  ClientCallbacks = object
    ## One set of callbacks; `name` says whose it is.
    name: string
    onUpdate: proc(text: string) {.closure.}
    onEnd: proc(reason: string) {.closure.}
    onError: proc(message: string) {.closure.}

  FakeClient = ref object
    callbacks: ClientCallbacks   ## The one set the client keeps.
    submitted: seq[string]       ## Every request, in order.
    carried: seq[ClientCallbacks] ## The set each request's transport captured.
    installs: seq[string]
    uninstalls: seq[string]
    log: seq[string]             ## What reached a ViewModel or the base set.

proc newFakeClient(): FakeClient =
  ## A client whose own set records events that reach no flight.
  let c = FakeClient()
  c.callbacks = ClientCallbacks(name: "base",
    onUpdate: proc(text: string) = c.log.add("base:update:" & text),
    onEnd: proc(reason: string) = c.log.add("base:end:" & reason),
    onError: proc(message: string) = c.log.add("base:error:" & message))
  c

proc submit(c: FakeClient; request: string) =
  c.submitted.add request
  c.carried.add c.callbacks

proc transport(c: FakeClient; request: string): ClientCallbacks =
  ## The set the transport of `request` captured when it was submitted.
  for i in countdown(c.carried.high, 0):
    if c.submitted[i] == request: return c.carried[i]
  raise newException(KeyError, "no request " & request)

proc installer(c: FakeClient): proc(q: string): ServiceStream[string] =
  ## The service call of the stream cases: one flight per question, its
  ## callbacks writing to the log (a ViewModel's own state) as well as to
  ## the sink, so a late call is visible even when the stream protocol
  ## would ignore its chunk.
  result = proc(q: string): ServiceStream[string] =
    fromCallbacks(proc(sink: Sink[string]): Uninstall =
      c.installs.add q
      let previous = c.callbacks
      c.callbacks = ClientCallbacks(name: q,
        onUpdate: sink.wrap(proc(text: string) =
          c.log.add q & ":update:" & text
          sink.emit(text)),
        onEnd: sink.wrap(proc(reason: string) =
          c.log.add q & ":end:" & reason
          sink.finish()),
        onError: sink.wrap(proc(message: string) =
          c.log.add q & ":error:" & message
          sink.fail(message)))
      c.submit(q)
      result = proc() =
        c.uninstalls.add q
        c.callbacks = previous)

proc fireLate(c: FakeClient; request: string) =
  ## Every callback the transport of `request` captured, fired once.
  let cb = c.transport(request)
  cb.onUpdate("late")
  cb.onEnd("late")
  cb.onError("late")

suite "fromCallbacks":
  test "a callback after supersession reaches nothing; Uninstall runs once":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let c = newFakeClient()
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, c.installer)
    check c.installs == @["a"]
    discard scheduleAt(5, proc() = c.transport("a").onUpdate("a1"))
    ctx.step(5)
    check av.val == @["a1"]
    q.val = "b"
    check c.uninstalls == @["a"]
    check c.installs == @["a", "b"]
    let before = c.log
    c.fireLate("a")
    ctx.step(5)
    check c.log == before
    check av.pending
    check av.val == @["a1"]
    check c.uninstalls == @["a"]
    av.dispose()
    check c.uninstalls == @["a", "b"]
    c.fireLate("a")
    c.fireLate("b")
    check c.log == before
    check c.uninstalls == @["a", "b"]

  test "a callback after settlement reaches nothing; Uninstall runs once":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let c = newFakeClient()
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, c.installer)
    discard scheduleAt(5, proc() = c.transport("a").onUpdate("a1"))
    discard scheduleAt(10, proc() = c.transport("a").onEnd("stop"))
    ctx.step(10)
    check av.ready and av.done
    check av.val == @["a1"]
    check c.log == @["a:update:a1", "a:end:stop"]
    check c.uninstalls == @["a"]
    check c.callbacks.name == "base"
    c.fireLate("a")
    ctx.step(5)
    check c.log == @["a:update:a1", "a:end:stop"]
    check av.val == @["a1"]
    # Neither a new question nor the dispose undoes it again.
    q.val = "b"
    av.dispose()
    check c.uninstalls == @["a", "b"]

  test "a failure settles the flight too; later callbacks reach nothing":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let c = newFakeClient()
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, c.installer)
    discard scheduleAt(5, proc() = c.transport("a").onError("gone"))
    ctx.step(5)
    check av.status == AsyncStatus.failed
    check av.error == "gone"
    check c.uninstalls == @["a"]
    c.fireLate("a")
    check c.log == @["a:error:gone"]
    check av.error == "gone"
    av.dispose()
    check c.uninstalls == @["a"]

  test "a callback after the owner is disposed reaches nothing; Uninstall runs once":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let c = newFakeClient()
    let q = createSignal("a")
    var av: AsyncValue[seq[string]]
    var disposeOwner: proc()
    createRoot proc(d: proc()) =
      disposeOwner = d
      av = createAsyncStream(proc(): string = q.val, c.installer)
    discard scheduleAt(5, proc() = c.transport("a").onUpdate("a1"))
    ctx.step(5)
    check av.val == @["a1"]
    disposeOwner()
    check av.isDisposed
    check c.uninstalls == @["a"]
    check c.callbacks.name == "base"
    c.fireLate("a")
    ctx.step(5)
    check c.log == @["a:update:a1"]
    q.val = "b"
    ctx.step(5)
    check c.installs == @["a"]
    check c.uninstalls == @["a"]

  test "two flights in a row on one client":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let c = newFakeClient()
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, c.installer)
    discard scheduleAt(5, proc() = c.transport("a").onUpdate("a1"))
    discard scheduleAt(10, proc() = c.transport("a").onEnd("stop"))
    ctx.step(10)
    check av.done and av.val == @["a1"]
    q.val = "b"
    check c.callbacks.name == "b"
    discard scheduleAt(5, proc() = c.transport("b").onUpdate("b1"))
    discard scheduleAt(10, proc() = c.transport("b").onUpdate("b2"))
    discard scheduleAt(15, proc() = c.transport("b").onEnd("stop"))
    ctx.step(15)
    check av.done and av.val == @["b1", "b2"]
    check c.installs == @["a", "b"]
    check c.uninstalls == @["a", "b"]
    check c.callbacks.name == "base"
    check c.log == @["a:update:a1", "a:end:stop", "b:update:b1",
                     "b:update:b2", "b:end:stop"]
    av.dispose()
    check c.uninstalls == @["a", "b"]

  test "an event that names no request reaches the only installed flight":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let c = newFakeClient()
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, c.installer)
    q.val = "b"
    # Dispatched through whatever set the client holds now: flight "b"'s,
    # since "a" was undone before "b" was installed.
    discard scheduleAt(5, proc() = c.callbacks.onUpdate("x"))
    ctx.step(5)
    check c.log == @["b:update:x"]
    check av.val == @["x"]
    discard scheduleAt(5, proc() = c.callbacks.onEnd("stop"))
    ctx.step(5)
    check av.done
    # No flight is installed now: the event reaches the client's own set.
    c.callbacks.onUpdate("y")
    check c.log == @["b:update:x", "b:end:stop", "base:update:y"]
    check av.val == @["x"]
    av.dispose()

  test "Uninstall restores the client's previous callback set":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let c = newFakeClient()
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, c.installer)
    check c.callbacks.name == "a"
    q.val = "b"                     # superseded: "a" restores the base set,
    check c.callbacks.name == "b"   # which "b" then replaces
    c.callbacks.onEnd("stop")       # settled: back to the base set
    check c.callbacks.name == "base"
    check av.done
    q.val = "c"
    check c.callbacks.name == "c"
    av.dispose()                    # disposed: back to the base set
    check c.callbacks.name == "base"
    check c.installs == @["a", "b", "c"]
    check c.uninstalls == @["a", "b", "c"]

  test "a completion hook that asks the next question installs over a restored set":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let c = newFakeClient()
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, c.installer,
      onDone = proc(question: string; chunks: seq[string]) =
        if question == "a": q.val = "b")
    c.callbacks.onUpdate("a1")
    c.callbacks.onEnd("stop")
    # "a" was undone before its end reached the value, so "b" saved the
    # base set and holds the client now.
    check c.installs == @["a", "b"]
    check c.uninstalls == @["a"]
    check c.callbacks.name == "b"
    c.callbacks.onUpdate("b1")
    check av.val == @["b1"]
    av.dispose()
    check c.callbacks.name == "base"
    check c.uninstalls == @["a", "b"]

  test "a flight that settles while install runs is undone when install returns":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    var undone = 0
    var lateCalls = 0
    var keep: proc()
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val,
      proc(question: string): ServiceStream[string] =
        fromCallbacks(proc(sink: Sink[string]): Uninstall =
          keep = sink.wrap(proc() = inc lateCalls)
          sink.emit("at once")
          sink.finish()
          check undone == 0         # not while install is running
          result = proc() = inc undone))
    check undone == 1
    check av.done and av.val == @["at once"]
    keep()
    check lateCalls == 0
    av.dispose()
    check undone == 1

  test "a producer that ends twice, or after a cancel, is undone once":
    # The sink is used directly here, not through a wrapped callback: a
    # producer whose own timer still fires after the end.
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    var undone: seq[string]
    var sinks: seq[Sink[string]]
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val,
      proc(question: string): ServiceStream[string] =
        fromCallbacks(proc(sink: Sink[string]): Uninstall =
          sinks.add sink
          result = proc() = undone.add question))
    sinks[0].emit("a1")
    sinks[0].finish()
    sinks[0].fail("late")
    sinks[0].finish()
    sinks[0].emit("late")
    check undone == @["a"]
    check av.done and av.val == @["a1"]
    check av.error == ""
    q.val = "b"                      # replaced before it ends
    check undone == @["a"]
    q.val = "c"
    check undone == @["a", "b"]
    check not sinks[1].isCurrent
    sinks[1].emit("late")
    sinks[1].fail("late")
    sinks[1].finish()
    check undone == @["a", "b"]
    check av.pending and av.val == @["a1"]
    av.dispose()
    check undone == @["a", "b", "c"]

  test "install raising fails the question; what it wrapped first reaches nothing":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    var lateCalls = 0
    var kept: proc(text: string)
    var sink0: Sink[string]
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val,
      proc(question: string): ServiceStream[string] =
        fromCallbacks(proc(sink: Sink[string]): Uninstall =
          # A callback handed to the service before install fails. Nothing
          # undoes the hand-over, so the wrap is what must drop it.
          sink0 = sink
          kept = sink.wrap(proc(text: string) =
            inc lateCalls
            sink.emit(text))
          raise newException(IOError, "no connection")))
    check av.status == AsyncStatus.failed
    check av.error == "no connection"
    check not sink0.isCurrent
    kept("late")
    check lateCalls == 0
    check av.status == AsyncStatus.failed
    av.dispose()

  test "Uninstall runs before the value hears the end or the failure":
    # The Uninstall of each flight records what the value showed when it
    # ran, which must be what it showed just before the end: the end and
    # the failure are heard only after it.
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    var sinks: seq[Sink[string]]
    var seen, beforeEnd: seq[string]
    var av: AsyncValue[seq[string]]
    proc shown(question: string): string =
      question & ":" & $av.status & ":" & $av.done & ":" & av.error
    let q = createSignal("a")
    av = createAsyncStream(proc(): string = q.val,
      proc(question: string): ServiceStream[string] =
        fromCallbacks(proc(sink: Sink[string]): Uninstall =
          sinks.add sink
          result = proc() = seen.add shown(question)))
    sinks[0].emit("a1")
    beforeEnd.add shown("a")
    sinks[0].finish()
    check av.done
    q.val = "b"
    beforeEnd.add shown("b")
    sinks[1].fail("gone")
    check av.status == AsyncStatus.failed
    check beforeEnd == @["a:ready:false:", "b:pending:true:"]
    check seen == beforeEnd
    av.dispose()

  test "wrap passes calls through while current, with two and three parameters":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    var seen: seq[string]
    var two: proc(a: string; b: int)
    var three: proc(a: string; b: int; c: bool)
    var current: proc(): bool
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val,
      proc(question: string): ServiceStream[string] =
        fromCallbacks(proc(sink: Sink[string]): Uninstall =
          two = sink.wrap(proc(a: string; b: int) = seen.add a & $b)
          three = sink.wrap(proc(a: string; b: int; c: bool) =
            seen.add a & $b & $c)
          current = proc(): bool = sink.isCurrent
          nil))
    check current()
    two("x", 1)
    three("y", 2, true)
    check seen == @["x1", "y2true"]
    av.dispose()
    check not current()
    two("x", 1)
    three("y", 2, true)
    check seen == @["x1", "y2true"]

# --------------------------------------------------------------------------
# The one-answer form, as asynchronous scenarios on both backends.
# --------------------------------------------------------------------------

type Scenario = ref object
  name: string
  failures: seq[string]

proc expect(s: Scenario; ok: bool; what: string) =
  if not ok: s.failures.add what

proc report(s: Scenario): bool =
  if s.failures.len == 0:
    echo "  [OK] ", s.name
  else:
    echo "  [FAILED] ", s.name
    for f in s.failures: echo "    Check failed: ", f
  s.failures.len == 0

when not defined(js):
  proc stepAsync(ctx: FakeAsyncContext; ms: int) {.async.} =
    ## On C a future's callback runs at the next poll, which `step` does.
    ctx.step(ms)

type AnswerClient = ref object
  ## A client whose one callback, `onAnswer`, is replaced per request.
  onAnswer: proc(text: string) {.closure.}
  onFailure: proc(message: string) {.closure.}
  carried: seq[proc(text: string) {.closure.}]
  failCarried: seq[proc(message: string) {.closure.}]
  installs, uninstalls, log: seq[string]

proc answerInstall(c: AnswerClient):
    proc(q: string; sink: AnswerSink[string]): Uninstall =
  result = proc(q: string; sink: AnswerSink[string]): Uninstall =
    c.installs.add q
    let previous = c.onAnswer
    let previousFailure = c.onFailure
    c.onAnswer = sink.wrap(proc(text: string) =
      c.log.add q & ":" & text
      sink.answer(text))
    c.onFailure = sink.wrap(proc(message: string) =
      c.log.add q & ":failed:" & message
      sink.fail(message))
    c.carried.add c.onAnswer
    c.failCarried.add c.onFailure
    result = proc() =
      c.uninstalls.add q
      c.onAnswer = previous
      c.onFailure = previousFailure

proc oneAnswerIsTheValue(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let c = AnswerClient()
  let q = createSignal("a")
  let av = createAsyncFromCallback(proc(): string = q.val, c.answerInstall)
  # The value is the answer's own type, not a sequence of chunks.
  let typed: AsyncValue[string] = av
  s.expect(typed.loading, "loading before the answer: " & $av.status)
  discard scheduleAt(5, proc() = c.carried[0]("hello"))
  await ctx.stepAsync(10)
  s.expect(av.ready and av.done, "ready after the answer: " & $av.status)
  s.expect(av.val == "hello", "the answer is the value: " & av.value)
  s.expect(c.uninstalls == @["a"], "undone once on the answer: " & $c.uninstalls)
  s.expect(c.onAnswer == nil, "the previous (empty) callback is back")
  c.carried[0]("again")
  await ctx.stepAsync(5)
  s.expect(av.val == "hello", "a second answer is dropped: " & av.value)
  s.expect(c.log == @["a:hello"], "nothing late reached the log: " & $c.log)
  q.val = "b"
  av.dispose()
  s.expect(c.uninstalls == @["a", "b"], "each flight undone once: " & $c.uninstalls)

proc oneAnswerSuperseded(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let c = AnswerClient()
  let q = createSignal("a")
  let av = createAsyncFromCallback(proc(): string = q.val, c.answerInstall)
  q.val = "b"
  s.expect(c.uninstalls == @["a"], "a undone when replaced: " & $c.uninstalls)
  s.expect(c.installs == @["a", "b"], "b installed: " & $c.installs)
  c.carried[0]("late a")
  c.failCarried[0]("late a")
  await ctx.stepAsync(5)
  s.expect(c.log.len == 0, "the replaced flight's callbacks reach nothing: " & $c.log)
  s.expect(av.loading, "still waiting for b: " & $av.status)
  # An answer that names no request reaches the only flight installed.
  s.expect(c.onAnswer != nil, "b's callback is installed")
  if c.onAnswer != nil: c.onAnswer("b answer")
  await ctx.stepAsync(5)
  s.expect(av.ready and av.val == "b answer", "b answered: " & av.value)
  s.expect(c.uninstalls == @["a", "b"], "b undone once: " & $c.uninstalls)
  av.dispose()
  s.expect(c.uninstalls == @["a", "b"], "dispose undoes nothing again: " & $c.uninstalls)

proc oneAnswerDisposed(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let c = AnswerClient()
  let q = createSignal("a")
  var av: AsyncValue[string]
  var disposeOwner: proc()
  createRoot proc(d: proc()) =
    disposeOwner = d
    av = createAsyncFromCallback(proc(): string = q.val, c.answerInstall)
  disposeOwner()
  s.expect(c.uninstalls == @["a"], "undone with its owner: " & $c.uninstalls)
  c.carried[0]("late")
  await ctx.stepAsync(5)
  s.expect(c.log.len == 0, "a callback after dispose reaches nothing: " & $c.log)
  s.expect(av.value == "", "nothing written after dispose: " & av.value)
  s.expect(c.uninstalls == @["a"], "undone once: " & $c.uninstalls)

proc oneAnswerFails(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let c = AnswerClient()
  let q = createSignal("a")
  let av = createAsyncFromCallback(proc(): string = q.val, c.answerInstall)
  c.failCarried[0]("refused")
  await ctx.stepAsync(5)
  s.expect(av.status == AsyncStatus.failed, "failed: " & $av.status)
  s.expect(av.error == "refused", "its message: " & av.error)
  s.expect(c.uninstalls == @["a"], "undone once on the failure: " & $c.uninstalls)
  c.carried[0]("late")
  await ctx.stepAsync(5)
  s.expect(av.status == AsyncStatus.failed, "a late answer is dropped: " & $av.status)
  s.expect(c.log == @["a:failed:refused"], "only the failure was heard: " & $c.log)
  av.dispose()
  s.expect(c.uninstalls == @["a"], "dispose undoes nothing again: " & $c.uninstalls)

proc oneAnswerRefreshed(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let c = AnswerClient()
  let q = createSignal("a")
  let av = createAsyncFromCallback(proc(): string = q.val, c.answerInstall)
  # The same question asked again: the oldest current flight for it is
  # the one undone.
  av.refresh()
  s.expect(c.installs == @["a", "a"], "asked twice: " & $c.installs)
  s.expect(c.uninstalls == @["a"], "the first flight undone: " & $c.uninstalls)
  c.carried[0]("first")
  await ctx.stepAsync(5)
  s.expect(c.log.len == 0, "the refreshed-over flight reaches nothing: " & $c.log)
  c.carried[1]("second")
  await ctx.stepAsync(5)
  s.expect(av.val == "second", "the refresh's answer: " & av.value)
  s.expect(c.uninstalls == @["a", "a"], "each undone once: " & $c.uninstalls)
  av.dispose()

proc oneAnswerGivenTwice(s: Scenario) {.async.} =
  # The sink is used directly, not through a wrapped callback.
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  var undone = 0
  var sinks: seq[AnswerSink[string]]
  let q = createSignal("a")
  let av = createAsyncFromCallback(proc(): string = q.val,
    proc(question: string; sink: AnswerSink[string]): Uninstall =
      sinks.add sink
      result = proc() = inc undone)
  sinks[0].answer("first")
  sinks[0].answer("second")
  sinks[0].fail("late")
  s.expect(undone == 1, "undone once: " & $undone)
  s.expect(not sinks[0].isCurrent, "no longer current")
  await ctx.stepAsync(5)
  s.expect(av.ready and av.val == "first", "the first answer: " & av.value)
  av.dispose()
  s.expect(undone == 1, "dispose undoes nothing again: " & $undone)

proc oneAnswerInstallRaises(s: Scenario) {.async.} =
  # The first install raises before it sets anything; the next question on
  # the same value installs normally and is the only flight undone.
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  var installs = 0
  var undone: seq[string]
  var sinks: seq[AnswerSink[string]]
  var raisedSink: AnswerSink[string]
  var kept: proc(text: string)
  var lateCalls = 0
  let q = createSignal("a")
  let av = createAsyncFromCallback(proc(): string = q.val,
    proc(question: string; sink: AnswerSink[string]): Uninstall =
      inc installs
      if question == "a":
        # A callback handed to the service before install fails: nothing
        # undoes the hand-over, so the wrap is what must drop it.
        raisedSink = sink
        kept = sink.wrap(proc(text: string) =
          inc lateCalls
          sink.answer(text))
        raise newException(IOError, "no connection")
      sinks.add sink
      result = proc() = undone.add question)
  await ctx.stepAsync(5)
  s.expect(av.status == AsyncStatus.failed, "failed: " & $av.status)
  s.expect(av.error == "no connection", "its message: " & av.error)
  s.expect(not raisedSink.isCurrent, "the raised flight is not current")
  kept("late")
  await ctx.stepAsync(5)
  s.expect(lateCalls == 0, "its wrapped callback reaches nothing: " & $lateCalls)
  s.expect(av.status == AsyncStatus.failed, "still failed: " & $av.status)
  q.val = "b"
  s.expect(installs == 2, "b installed: " & $installs)
  s.expect(undone.len == 0, "nothing undone yet: " & $undone)
  if sinks.len == 1: sinks[0].answer("b answer")
  await ctx.stepAsync(5)
  s.expect(av.ready and av.val == "b answer", "b answered: " & av.value)
  s.expect(undone == @["b"], "only b undone, once: " & $undone)
  av.dispose()
  s.expect(undone == @["b"], "dispose undoes nothing again: " & $undone)

when defined(js):
  {.emit: "process.exitCode = 1;".}

proc main() {.async.} =
  var ok = true
  proc run(name: string; body: proc(s: Scenario): Future[void]) {.async.} =
    let s = Scenario(name: name)
    await body(s)
    if not s.report(): ok = false
  echo "[Suite] createAsyncFromCallback"
  await run("one answer is the value, and a second answer is dropped",
    proc(s: Scenario): Future[void] = oneAnswerIsTheValue(s))
  await run("a replaced flight's late callbacks reach nothing",
    proc(s: Scenario): Future[void] = oneAnswerSuperseded(s))
  await run("a flight disposed with its owner is undone once",
    proc(s: Scenario): Future[void] = oneAnswerDisposed(s))
  await run("a failure shows failed and undoes the flight once",
    proc(s: Scenario): Future[void] = oneAnswerFails(s))
  await run("a refresh undoes the flight it replaces",
    proc(s: Scenario): Future[void] = oneAnswerRefreshed(s))
  await run("an answer given twice by the producer is undone once",
    proc(s: Scenario): Future[void] = oneAnswerGivenTwice(s))
  await run("install raising fails the question; the next one installs",
    proc(s: Scenario): Future[void] = oneAnswerInstallRaises(s))
  when defined(js):
    if ok:
      {.emit: "process.exitCode = 0;".}
  else:
    if not ok: quit(1)

when defined(js):
  discard main()
else:
  waitFor main()
