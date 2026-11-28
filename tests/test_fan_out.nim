## The fan-out stream (`isonim/services/fan_out`), under fake time: each
## item's outcome arrives as a chunk carrying the item's index, in the order
## the calls settle, not the order of the items; a failure (a failed future,
## or a call that raises) is a chunk and the others still answer; the stream
## finishes exactly once, after the last chunk, also when every call fails
## at once; cancelling it delivers nothing more, starts no further call and
## asks the calls still running to stop, when the service can; an empty
## input finishes at once; `limit` bounds how many calls run at a time and
## changes nothing else; as an async value's service, a new question
## cancels the old fan-out.
##
## A platform future's callbacks run on a later microtask on the JS backend,
## which a synchronous `unittest` case cannot wait for, so every case is an
## asynchronous scenario on both backends (the shape of
## `tests/test_async_timing_js.nim`): each reports its own `[OK]` /
## `[FAILED]` line, and the process fails unless every scenario reported
## success.
##
## MOCK POLICY (workspace rule: every mock justified in the header). One fake
## service, `Calls`, standing in for a service that answers one request per
## item: its answers are real `Deferred` futures settled by timers on the
## nim-everywhere clock (driven by `FakeAsyncContext`) after a latency chosen
## per item, failing or raising on cue. The point of each case is the order
## and the timing of the answers, which a real service cannot be made to
## produce on cue. It also records what a real service would not report:
## every call started, every cancel that reached it, and how many calls were
## running at once, which are the assertions. The fan-out, the stream
## protocol, the futures, and in the last case the async value with its
## signals and owner, are the real ones.

import std/[algorithm, sequtils, strutils, tables]

import nim_everywhere
import nim_everywhere/async_compat
import isonim/core/signals
import isonim/services/[async_value, deferred, fan_out]

import helpers/async_recording_service

type
  Scenario = ref object
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

type
  Calls = ref object
    ## The fake per-item service (see the header).
    latency: Table[string, int]      ## Milliseconds until the item answers.
    failures: Table[string, string]  ## Items whose future fails, and why.
    raises: seq[string]              ## Items whose call raises.
    started: seq[string]             ## Every call, in order.
    cancels: seq[string]             ## Every cancel that reached the service.
    running: int                     ## Calls started and not settled.
    maxRunning: int                  ## The most calls running at once.
    timers: Table[string, TimerHandle] ## The calls whose timer is armed.

proc newCalls(latency: openArray[(string, int)] = []): Calls =
  result = Calls()
  for (item, ms) in latency: result.latency[item] = ms

proc fetchOf(c: Calls): proc(item: string): PlatformFuture[string] =
  result = proc(item: string): PlatformFuture[string] =
    c.started.add item
    if item in c.raises:
      raise newException(IOError, "cannot reach " & item)
    inc c.running
    c.maxRunning = max(c.maxRunning, c.running)
    let d = newDeferred[string]("fan-out item")
    let failure = c.failures.getOrDefault(item, "")
    c.timers[item] = scheduleAt(c.latency.getOrDefault(item, 10), proc() =
      c.timers.del item
      dec c.running
      if failure.len > 0: d.reject(failure)
      else: d.resolve("answer:" & item))
    d.future

proc cancelOf(c: Calls): proc(item: string) =
  ## The service's way to stop a call: its future then never settles.
  result = proc(item: string) =
    c.cancels.add item
    if item in c.timers:
      cancelTimer(c.timers[item])
      c.timers.del item
      dec c.running

proc describe(chunk: FanOutChunk[string]): string =
  ## One line per chunk, so a scenario can compare the whole sequence.
  result = $chunk.index & ":"
  case chunk.outcome.kind
  of OutcomeKind.answered: result.add "answered:" & chunk.outcome.value
  of OutcomeKind.failed: result.add "failed:" & chunk.outcome.error
  of OutcomeKind.interrupted: result.add "interrupted"
  of OutcomeKind.refused: result.add "refused"

type Log = ref object
  chunks: seq[string]
  done: int
  chunksAtDone: seq[int]   ## How many chunks had arrived at each done.
  errors: seq[string]

proc sinkFor(log: Log): StreamSink[FanOutChunk[string]] =
  result.onChunk = proc(c: FanOutChunk[string]) = log.chunks.add describe(c)
  result.onDone = proc() =
    inc log.done
    log.chunksAtDone.add log.chunks.len
  result.onError = proc(m: string) = log.errors.add m

# --------------------------------------------------------------------------

proc settleOrder(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let c = newCalls({"a": 30, "b": 10, "c": 20})
  let log = Log()
  discard fanOut(@["a", "b", "c"], c.fetchOf)(sinkFor(log))
  s.expect(c.started == @["a", "b", "c"],
           "every call starts at once, in input order: " & $c.started)
  s.expect(log.chunks.len == 0, "nothing before an answer: " & $log.chunks)
  await ctx.stepAsync(10)
  s.expect(log.chunks == @["1:answered:answer:b"],
           "the fastest answer first, with its item's index: " & $log.chunks)
  await ctx.stepAsync(10)
  s.expect(log.chunks == @["1:answered:answer:b", "2:answered:answer:c"],
           "then the next to settle: " & $log.chunks)
  s.expect(log.done == 0, "not finished while a call runs")
  await ctx.stepAsync(10)
  s.expect(log.chunks == @["1:answered:answer:b", "2:answered:answer:c",
                           "0:answered:answer:a"],
           "settle order, each chunk naming its item: " & $log.chunks)
  s.expect(log.done == 1, "finished once all settled: " & $log.done)
  s.expect(log.errors.len == 0, "no error: " & $log.errors)

proc failureIsAChunk(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let c = newCalls({"a": 30, "b": 10, "c": 20})
  c.failures["b"] = "b broke"
  c.raises.add "d"
  let log = Log()
  discard fanOut(@["a", "b", "c", "d"], c.fetchOf)(sinkFor(log))
  # A call that raises fails its item at once; the others are started.
  s.expect(c.started == @["a", "b", "c", "d"], "all started: " & $c.started)
  s.expect(log.chunks == @["3:failed:cannot reach d"],
           "a call that raises is a failed chunk: " & $log.chunks)
  await ctx.stepAsync(10)
  s.expect(log.chunks == @["3:failed:cannot reach d", "1:failed:b broke"],
           "a failed future is a failed chunk: " & $log.chunks)
  s.expect(log.errors.len == 0, "a failure does not fail the stream: " &
           $log.errors)
  s.expect(log.done == 0, "and does not end it")
  await ctx.stepAsync(20)
  s.expect(log.chunks == @["3:failed:cannot reach d", "1:failed:b broke",
                           "2:answered:answer:c", "0:answered:answer:a"],
           "the others still answer: " & $log.chunks)
  s.expect(log.done == 1 and log.errors.len == 0,
           "finished, not failed: done " & $log.done & " errors " & $log.errors)

proc finishesOnce(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  block:
    # One call at a time: the number running drops to zero after each
    # settles, and only the last settle finishes the stream.
    let c = newCalls({"a": 10, "b": 10, "c": 10})
    let log = Log()
    discard fanOut(@["a", "b", "c"], c.fetchOf, limit = 1)(sinkFor(log))
    await ctx.stepAsync(10)
    s.expect(log.done == 0, "not done after the first of three: " &
             $log.chunksAtDone)
    await ctx.stepAsync(30)
    s.expect(log.chunks.len == 3, "three chunks: " & $log.chunks)
    s.expect(log.chunksAtDone == @[3],
             "done exactly once, after the last chunk: " & $log.chunksAtDone)
    await ctx.stepAsync(50)
    s.expect(log.done == 1, "and never again: " & $log.done)
  block:
    # Every call fails while the stream is being subscribed to.
    let c = newCalls()
    c.raises = @["x", "y"]
    let log = Log()
    discard fanOut(@["x", "y"], c.fetchOf)(sinkFor(log))
    s.expect(log.chunks == @["0:failed:cannot reach x",
                             "1:failed:cannot reach y"],
             "both failures are chunks: " & $log.chunks)
    s.expect(log.chunksAtDone == @[2],
             "done once, after both: " & $log.chunksAtDone)
    await ctx.stepAsync(10)
    s.expect(log.done == 1, "and never again: " & $log.done)
  block:
    # The last item settles while a later one could still be started: a
    # short call behind a long one, under a limit.
    let c = newCalls({"a": 30, "b": 5, "c": 5})
    let log = Log()
    discard fanOut(@["a", "b", "c"], c.fetchOf, limit = 2)(sinkFor(log))
    await ctx.stepAsync(40)
    s.expect(log.chunks == @["1:answered:answer:b", "2:answered:answer:c",
                             "0:answered:answer:a"],
             "all three, in settle order: " & $log.chunks)
    s.expect(log.chunksAtDone == @[3], "done once, at the end: " &
             $log.chunksAtDone)

proc cancelIgnoresTheRest(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  block:
    # A service that can stop a call: the calls still running are asked to.
    let c = newCalls({"a": 10, "b": 20, "c": 30, "d": 10})
    let log = Log()
    let sub = fanOut(@["a", "b", "c", "d"], c.fetchOf, limit = 2,
                     cancel = c.cancelOf)(sinkFor(log))
    s.expect(c.started == @["a", "b"], "two at a time: " & $c.started)
    await ctx.stepAsync(10)
    s.expect(log.chunks == @["0:answered:answer:a"], "a answered: " &
             $log.chunks)
    s.expect(c.started == @["a", "b", "c"], "c took a's place: " & $c.started)
    sub.cancel()
    s.expect(c.cancels == @["b", "c"],
             "the calls still running are asked to stop, and only those: " &
             $c.cancels)
    await ctx.stepAsync(50)
    s.expect(log.chunks == @["0:answered:answer:a"], "nothing more: " &
             $log.chunks)
    s.expect(c.started == @["a", "b", "c"], "d is never started: " &
             $c.started)
    s.expect(log.done == 0 and log.errors.len == 0,
             "a cancelled stream neither finishes nor fails")
    sub.cancel()
    s.expect(c.cancels == @["b", "c"], "a second cancel does nothing: " &
             $c.cancels)
  block:
    # A service that cannot stop a call: its late answers are ignored, and
    # they start nothing.
    let c = newCalls({"a": 10, "b": 20, "c": 30, "d": 10})
    let log = Log()
    let sub = fanOut(@["a", "b", "c", "d"], c.fetchOf,
                     limit = 2)(sinkFor(log))
    await ctx.stepAsync(10)
    sub.cancel()
    await ctx.stepAsync(50)
    s.expect(c.running == 0, "the calls ran to their end: " & $c.running)
    s.expect(log.chunks == @["0:answered:answer:a"],
             "their answers are ignored: " & $log.chunks)
    s.expect(c.started == @["a", "b", "c"],
             "an ignored answer starts no further call: " & $c.started)
    s.expect(log.done == 0, "and does not finish the stream")
  block:
    # The subscriber cancels from inside a chunk.
    let c = newCalls({"a": 10, "b": 10, "c": 20, "d": 20})
    c.failures["a"] = "a broke"
    let log = Log()
    var sub: StreamSubscription
    var sink = sinkFor(log)
    let record = sink.onChunk
    sink.onChunk = proc(chunk: FanOutChunk[string]) =
      record(chunk)
      if chunk.outcome.kind == OutcomeKind.failed: sub.cancel()
    sub = fanOut(@["a", "b", "c", "d"], c.fetchOf, limit = 2,
                 cancel = c.cancelOf)(sink)
    await ctx.stepAsync(50)
    s.expect(log.chunks == @["0:failed:a broke"],
             "nothing after the chunk that cancelled: " & $log.chunks)
    s.expect(c.started == @["a", "b"],
             "nothing started after the cancel: " & $c.started)
    s.expect(c.cancels == @["b"], "b was asked to stop: " & $c.cancels)

proc emptyFinishesAtOnce(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let c = newCalls()
  let log = Log()
  let sub = fanOut(newSeq[string](), c.fetchOf)(sinkFor(log))
  s.expect(log.done == 1, "done during the subscription, before any time " &
           "passes: " & $log.done)
  s.expect(log.chunks.len == 0 and log.errors.len == 0, "and nothing else")
  s.expect(sub.isEnded, "the subscription has ended")
  s.expect(c.started.len == 0, "no call: " & $c.started)
  await ctx.stepAsync(10)
  s.expect(log.done == 1, "done once: " & $log.done)

proc limitBoundsConcurrency(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let items = @["a", "b", "c", "d", "e", "f"]
  let latency = {"a": 25, "b": 5, "c": 15, "d": 5, "e": 10, "f": 5}
  var runs: seq[(Calls, Log)]
  for limit in [2, 0, 10]:
    let c = newCalls(latency)
    c.failures["c"] = "c broke"
    let log = Log()
    discard fanOut(items, c.fetchOf, limit = limit)(sinkFor(log))
    if limit == 2:
      s.expect(c.started == @["a", "b"], "two start: " & $c.started)
    await ctx.stepAsync(100)
    runs.add (c, log)
  let (bounded, boundedLog) = runs[0]
  let (unbounded, unboundedLog) = runs[1]
  let (wide, wideLog) = runs[2]
  s.expect(bounded.maxRunning == 2, "at most 2 at once under limit 2: " &
           $bounded.maxRunning)
  s.expect(unbounded.maxRunning == 6, "all 6 at once with no limit: " &
           $unbounded.maxRunning)
  s.expect(wide.maxRunning == 6, "a limit above the count runs all: " &
           $wide.maxRunning)
  s.expect(bounded.started == items, "started in input order: " &
           $bounded.started)
  for (name, log) in [("limit 2", boundedLog), ("no limit", unboundedLog),
                      ("limit 10", wideLog)]:
    s.expect(log.chunksAtDone == @[6], name & ": done once after 6 chunks: " &
             $log.chunksAtDone)
    s.expect(log.errors.len == 0, name & ": no error: " & $log.errors)
  # The same chunks whatever the limit; only their order may differ.
  s.expect(boundedLog.chunks.sorted == unboundedLog.chunks.sorted,
           "the limit changes what is emitted: " & $boundedLog.chunks &
           " against " & $unboundedLog.chunks)
  s.expect(wideLog.chunks == unboundedLog.chunks,
           "an unreached limit changes nothing: " & $wideLog.chunks)
  s.expect(boundedLog.chunks.mapIt(it.split(':')[0]).sorted ==
           @["0", "1", "2", "3", "4", "5"],
           "every index once: " & $boundedLog.chunks)

proc asAnAsyncValue(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let c = newCalls({"a1": 10, "a2": 20, "b1": 10, "b2": 10})
  let q = createSignal("a")
  let av = createAsyncStream(
    proc(): string = q.val,
    proc(question: string): ServiceStream[FanOutChunk[string]] =
      fanOut(@[question & "1", question & "2"], c.fetchOf,
             cancel = c.cancelOf))
  s.expect(av.loading, "loading before any answer: " & $av.status)
  await ctx.stepAsync(10)
  s.expect(av.ready and not av.done, "ready after the first chunk, not done")
  s.expect(av.val.mapIt(describe(it)) == @["0:answered:answer:a1"],
           "the first chunk: " & $av.val.mapIt(describe(it)))
  q.val = "b"
  s.expect(c.cancels == @["a2"], "the old fan-out's call is stopped: " &
           $c.cancels)
  await ctx.stepAsync(10)
  s.expect(av.ready and av.done, "the new fan-out finished: " & $av.status)
  s.expect(av.val.mapIt(describe(it)) ==
           @["0:answered:answer:b1", "1:answered:answer:b2"],
           "only the new question's chunks: " & $av.val.mapIt(describe(it)))
  av.dispose()

# --------------------------------------------------------------------------

when defined(js):
  {.emit: "process.exitCode = 1;".}

proc main() {.async.} =
  var ok = true
  proc run(name: string; body: proc(s: Scenario): Future[void]) {.async.} =
    let s = Scenario(name: name)
    await body(s)
    if not s.report(): ok = false
  echo "[Suite] fanOut"
  await run("chunks arrive in settle order, each carrying its item's index",
    proc(s: Scenario): Future[void] = settleOrder(s))
  await run("a failure is a chunk; the others still answer",
    proc(s: Scenario): Future[void] = failureIsAChunk(s))
  await run("the stream finishes exactly once, after the last chunk",
    proc(s: Scenario): Future[void] = finishesOnce(s))
  await run("cancelling ignores the remaining answers and starts nothing",
    proc(s: Scenario): Future[void] = cancelIgnoresTheRest(s))
  await run("an empty input finishes at once",
    proc(s: Scenario): Future[void] = emptyFinishesAtOnce(s))
  await run("limit bounds how many calls run at once, and nothing else",
    proc(s: Scenario): Future[void] = limitBoundsConcurrency(s))
  await run("as an async value's service, a new question cancels the old one",
    proc(s: Scenario): Future[void] = asAnAsyncValue(s))
  when defined(js):
    if ok:
      {.emit: "process.exitCode = 0;".}
  else:
    if not ok: quit(1)

when defined(js):
  discard main()
else:
  waitFor main()
