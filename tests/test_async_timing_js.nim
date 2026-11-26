## The timing checks of the async value tests on the JS backend, with
## futures that answer after their latency.
##
## The other async value tests run on JS too, but there a future answers at
## the next drain of platform callbacks, because a promise's callback runs
## on a microtask that a synchronous `unittest` case cannot wait for. The
## checks that need time to pass between a question and its answer, or one
## answer to arrive before another, are made here instead: each scenario is
## an asynchronous procedure that advances fake time with `stepAsync`, which
## awaits after every millisecond so the promise callbacks run in between.
## The same checks run on C in `test_async_value.nim`,
## `test_async_stream.nim`, `test_async_provisional.nim` and
## `test_async_fundamentals.nim`: among them a local write replaced by the
## answer after its latency, completion inside the callback that delivers
## the answer, a known answer replacing a call in flight, and a list
## fetched page after page whose paging a new load stops mid-way.
##
## MOCK POLICY (workspace rule: every mock justified in the header). One
## recording service (`helpers/async_recording_service`, made with
## `timedFutures = true`): its futures are real promise `Deferred`s settled
## by timers on the nim-everywhere clock, driven by `FakeAsyncContext`; it
## also records every question asked, every answer delivered, every cancel
## that reached it and its armed timers, which a real service would not
## report and which are what these checks assert. The primitive, its
## signals, effects and owners are the real ones.
##
## Promises settle after `unittest`'s synchronous cases would have
## finished, so each scenario reports its own `[OK]` / `[FAILED]` line,
## which `tools/run_nim_js_test.py` checks, and the process fails unless
## every scenario reported success: a scenario that never finishes cannot
## pass by saying nothing.

when not defined(js):
  {.error: "test_async_timing_js is the JS backend's timing test".}

import std/[options, strutils, tables]

import nim_everywhere
import nim_everywhere/async_compat
import isonim/core/[signals, owner, computation]
import isonim/services/[async_value, readiness]
import isonim/viewmodel

import helpers/async_recording_service

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

proc fetchOf(svc: RecordingService): proc(q: string): PlatformFuture[string] =
  result = proc(q: string): PlatformFuture[string] = svc.fetch(q)

proc streamOf(svc: RecordingService): proc(q: string): ServiceStream[string] =
  result = proc(q: string): ServiceStream[string] = svc.stream(q)

type Frames = ref object
  shown: seq[string]
  status: seq[AsyncStatus]

proc watch(av: AsyncValue[string]): (Frames, proc()) =
  let frames = Frames()
  var dispose: proc()
  createRoot proc(d: proc()) =
    dispose = d
    createEffect proc() =
      frames.shown.add av.val
      frames.status.add av.status
  (frames, dispose)

proc newQuestionKeepsOldAnswer(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newRecordingService(timedFutures = true)
  let q = createSignal("a")
  let av = createAsync(proc(): string = q.val, svc.fetchOf)
  s.expect(av.loading, "a first load is loading")
  await ctx.stepAsync(5)
  s.expect(av.loading and av.val == "", "still loading half-way: " & $av.status)
  await ctx.stepAsync(5)
  s.expect(av.ready and av.val == answerFor("a", 1), "a answered at 10 ms")
  let (frames, stopWatching) = watch(av)
  q.val = "b"
  await ctx.stepAsync(5)
  s.expect(av.pending, "pending half-way: " & $av.status)
  s.expect(av.val == answerFor("a", 1), "the old answer is held: " & av.value)
  await ctx.stepAsync(5)
  s.expect(av.ready and av.val == answerFor("b", 1), "b answered")
  s.expect(frames.shown == @[answerFor("a", 1), answerFor("a", 1),
                             answerFor("b", 1)], "frames " & $frames.shown)
  s.expect(frames.status == @[AsyncStatus.ready, AsyncStatus.pending,
                              AsyncStatus.ready], "statuses " & $frames.status)
  stopWatching()
  av.dispose()

proc replacedAnswer(s: Scenario; replacedFirst: bool) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newRecordingService(timedFutures = true)
  # "a" is replaced by "b"; its answer arrives first or last.
  if replacedFirst: svc.latencies["b"] = 30
  else: svc.latencies["a"] = 30
  let q = createSignal("a")
  let av = createAsync(proc(): string = q.val, svc.fetchOf)
  let (frames, stopWatching) = watch(av)
  q.val = "b"
  await ctx.stepAsync(15)
  if replacedFirst:
    s.expect(svc.answered == @[answerFor("a", 1)],
             "the replaced answer came first: " & $svc.answered)
    s.expect(av.loading and av.val == "", "still loading b: " & av.value)
  else:
    s.expect(svc.answered == @[answerFor("b", 1)],
             "b came first: " & $svc.answered)
    s.expect(av.ready and av.val == answerFor("b", 1), "b shown")
  await ctx.stepAsync(25)
  s.expect(answerFor("a", 1) in svc.answered, "the service answered a")
  s.expect(av.val == answerFor("b", 1) and av.ready, "b stays: " & av.value)
  s.expect(frames.shown == @["", answerFor("b", 1)], "frames " & $frames.shown)
  stopWatching()
  av.dispose()

proc cancelStopsTheCall(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newRecordingService(timedFutures = true)
  let q = createSignal("a")
  let av = createAsync(proc(): string = q.val, svc.fetchOf,
    cancel = proc(question: string) = svc.cancelFetch(question))
  q.val = "b"
  s.expect(svc.cancels == @["a"], "a cancelled: " & $svc.cancels)
  await ctx.stepAsync(20)
  s.expect(av.val == answerFor("b", 1), "b shown")
  s.expect(svc.answered == @[answerFor("b", 1)],
           "a never answered: " & $svc.answered)
  s.expect(svc.armedTimers == 0, "no timer left: " & $svc.armedTimers)
  q.val = "c"
  await ctx.stepAsync(20)
  s.expect(svc.cancels == @["a"], "an answered call is not cancelled")
  av.dispose()

proc endsWithViewModel(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newRecordingService(latencyMs = 20, timedFutures = true)
  type PageVM = ref object of ViewModel
    q: Signal[string]
    item: AsyncValue[string]
    reply: AsyncValue[seq[string]]
  let vm = withViewModel proc(dispose: proc()): PageVM =
    let vm = PageVM(q: createSignal("a"))
    vm.item = createAsync(proc(): string = vm.q.val, svc.fetchOf)
    vm.reply = createAsyncStream(proc(): string = vm.q.val, svc.streamOf)
    vm
  let (frames, stopWatching) = watch(vm.item)
  await ctx.stepAsync(5)
  s.expect(svc.armedTimers == 2, "both in flight: " & $svc.armedTimers)
  vm.dispose()
  s.expect(svc.cancels == @["a"], "the stream cancelled at the producer")
  await ctx.stepAsync(30)
  s.expect(answerFor("a", 1) in svc.answered, "the item's answer arrived")
  s.expect(frames.shown == @[""], "nothing written: " & $frames.shown)
  s.expect(vm.item.val == "" and vm.reply.val.len == 0, "values empty")
  vm.item.refresh()
  vm.reply.refresh()
  s.expect(svc.asks == @["a", "a"], "nothing asked after dispose")
  s.expect(svc.armedTimers == 0, "no timer left: " & $svc.armedTimers)
  stopWatching()

proc placeholderUntilAnswer(s: Scenario) {.async.} =
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newRecordingService(latencyMs = 20, timedFutures = true)
  let marks = newReadinessMarks()
  marks.beginLoad()
  let q = createSignal("a")
  let av = createAsync(proc(): string = q.val, svc.fetchOf,
                       placeholder = some("(loading...)"),
                       marks = marks, element = "item")
  await ctx.stepAsync(5)
  s.expect(av.provisional and av.loading, "the placeholder is flagged")
  s.expect(av.val == "(loading...)", "the placeholder is shown")
  s.expect(not marks.has("item:first"), ":first not for the placeholder")
  await ctx.stepAsync(15)
  s.expect(not av.provisional and av.val == answerFor("a", 1), "answered")
  s.expect(marks.firstAt("item") == 20, "first at 20 ms: " &
           $marks.firstAt("item"))
  s.expect(marks.completeAt("item") == 20, "complete at 20 ms")
  av.dispose()

proc replacedNeverChangesTheView(s: Scenario) {.async.} =
  ## Fundamental 4 with a replaced question answered after its replacement.
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newRecordingService(latencyMs = 10, timedFutures = true)
  svc.latencies["c"] = 30
  let q = createSignal("a")
  let av = createAsync(proc(): string = q.val.strip, svc.fetchOf)
  var frames: seq[(string, string, AsyncStatus)]
  var stop: proc()
  createRoot proc(d: proc()) =
    stop = d
    createEffect proc() =
      frames.add (q.val.strip, av.val, av.status)
  await ctx.stepAsync(10)
  q.val = "c"
  await ctx.stepAsync(2)
  q.val = "d"
  let afterD = frames.len
  await ctx.stepAsync(40)
  s.expect(answerFor("c", 1) in svc.answered, "c was answered, late")
  s.expect(av.val == answerFor("d", 1), "d shown: " & av.value)
  for f in frames[afterD - 1 .. ^1]:
    s.expect(questionOf(f[1]) != "c", "a frame showed c: " & $f)
    s.expect(f[2] != AsyncStatus.ready or questionOf(f[1]) == f[0],
             "a ready frame shows another question's answer: " & $f)
  stop()
  av.dispose()

proc localWriteUntilAnswer(s: Scenario) {.async.} =
  ## A local write during a load shows as the answer; the call goes on and
  ## its answer replaces it after the latency.
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newRecordingService(timedFutures = true)
  let q = createSignal("a")
  let av = createAsync(proc(): string = q.val, svc.fetchOf)
  let (frames, stopWatching) = watch(av)
  await ctx.stepAsync(5)
  av.mutate("local")
  s.expect(av.ready and av.val == "local", "the local value is shown: " &
           $av.status & " " & av.value)
  await ctx.stepAsync(2)
  s.expect(av.val == "local", "still local before the answer: " & av.value)
  await ctx.stepAsync(3)
  s.expect(av.ready and av.val == answerFor("a", 1),
           "the answer replaced it at 10 ms: " & av.value)
  s.expect(frames.shown == @["", "local", answerFor("a", 1)],
           "frames " & $frames.shown)
  s.expect(frames.status == @[AsyncStatus.loading, AsyncStatus.ready,
                              AsyncStatus.ready], "statuses " & $frames.status)
  stopWatching()
  av.dispose()

proc completionInTheAnswerFrame(s: Scenario) {.async.} =
  ## Completion runs inside the promise callback that delivers the answer,
  ## in the same batch: every frame showing an answer shows what it wrote.
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newRecordingService(timedFutures = true)
  svc.latencies["b"] = 30
  let seen = createSignal("")
  var completed: seq[string]
  let q = createSignal("a")
  let av = createAsync(proc(): string = q.val, svc.fetchOf,
    onDone = proc(question, value: string) =
      completed.add question
      seen.val = "seen " & value)
  var frames: seq[(string, string)]
  var stop: proc()
  createRoot proc(d: proc()) =
    stop = d
    createEffect proc() = frames.add (av.val, seen.val)
  await ctx.stepAsync(10)
  q.val = "b"
  await ctx.stepAsync(5)
  q.val = "c"                          # b is replaced; its answer comes last
  await ctx.stepAsync(40)
  s.expect(answerFor("b", 1) in svc.answered, "b was answered, late")
  s.expect(completed == @["a", "c"], "completed " & $completed)
  for f in frames:
    s.expect(f == ("", "") or f[1] == "seen " & f[0],
             "a frame shows an answer without its completion: " & $f)
  stop()
  av.dispose()

proc knownReplacesATimedCall(s: Scenario) {.async.} =
  ## A known answer replaces a call in flight at once; that call's answer,
  ## arriving later, never shows.
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newRecordingService(timedFutures = true)
  let q = createSignal("a")
  let av = createAsync(proc(): string = q.val, svc.fetchOf,
    known = proc(question: string): Option[string] =
      if question == "k": some("known:k") else: none(string))
  let (frames, stopWatching) = watch(av)
  await ctx.stepAsync(5)
  q.val = "k"
  s.expect(av.ready and av.val == "known:k", "known shown at once: " &
           $av.status & " " & av.value)
  await ctx.stepAsync(20)
  s.expect(svc.answered == @[answerFor("a", 1)], "a was answered: " &
           $svc.answered)
  s.expect(svc.asks == @["a"], "nothing asked for k: " & $svc.asks)
  s.expect(av.val == "known:k", "a's late answer never shows: " & av.value)
  s.expect(frames.shown == @["", "known:k"], "frames " & $frames.shown)
  stopWatching()
  av.dispose()

proc pages(svc: RecordingService; load: string; count: int):
    ServiceStream[string] =
  ## As in `test_async_stream.nim`: a list fetched page after page as one
  ## stream, whose producer stops asking once cancelled.
  newServiceStream[string](proc(e: StreamEmitter[string]) =
    var n = 0
    proc next() =
      if n >= count:
        e.finish()
        return
      inc n
      svc.fetch(load & "/" & $n).onComplete(
        proc(page: string) =
          e.emit(page)
          if e.isActive: next(),
        proc(message: string) = e.fail(message))
    next())

proc pagingStopsWithItsLoad(s: Scenario) {.async.} =
  ## A new load stops the old one's paging mid-way: no further page of it
  ## is asked, and none of its pages shows.
  let ctx = newFakeAsyncContext()
  ctx.install()
  defer: ctx.uninstall()
  let svc = newRecordingService(timedFutures = true)
  let load = createSignal("L1")
  let av = createAsyncStream(proc(): string = load.val,
    proc(l: string): ServiceStream[string] = pages(svc, l, 3))
  await ctx.stepAsync(15)
  s.expect(av.val == @[answerFor("L1/1", 1)], "one page of L1: " & $av.value)
  load.val = "L2"
  s.expect(av.pending, "the new load is pending: " & $av.status)
  await ctx.stepAsync(40)
  s.expect(svc.asks == @["L1/1", "L1/2", "L2/1", "L2/2", "L2/3"],
           "asks " & $svc.asks)
  s.expect(av.done and av.val == @[answerFor("L2/1", 1), answerFor("L2/2", 1),
                                    answerFor("L2/3", 1)],
           "L2's pages: " & $av.value)
  av.dispose()

{.emit: "process.exitCode = 1;".}

proc main() {.async.} =
  var ok = true
  proc run(name: string; body: proc(s: Scenario): Future[void]) {.async.} =
    let s = Scenario(name: name)
    await body(s)
    if not s.report(): ok = false
  await run("a new question is pending, holding the old answer, until its own arrives",
    proc(s: Scenario): Future[void] = newQuestionKeepsOldAnswer(s))
  await run("an answer to a replaced question that arrives first never shows",
    proc(s: Scenario): Future[void] = replacedAnswer(s, true))
  await run("an answer to a replaced question that arrives last never shows",
    proc(s: Scenario): Future[void] = replacedAnswer(s, false))
  await run("a replaced call is cancelled and never answers",
    proc(s: Scenario): Future[void] = cancelStopsTheCall(s))
  await run("after dispose, nothing a ViewModel started writes to it",
    proc(s: Scenario): Future[void] = endsWithViewModel(s))
  await run("a placeholder is flagged until the answer, which records the marks",
    proc(s: Scenario): Future[void] = placeholderUntilAnswer(s))
  await run("a replaced question answered late never changes the View",
    proc(s: Scenario): Future[void] = replacedNeverChangesTheView(s))
  await run("a local write shows until the answer replaces it",
    proc(s: Scenario): Future[void] = localWriteUntilAnswer(s))
  await run("completion runs in the frame that shows the answer",
    proc(s: Scenario): Future[void] = completionInTheAnswerFrame(s))
  await run("a known answer replaces a call in flight, whose answer never shows",
    proc(s: Scenario): Future[void] = knownReplacesATimedCall(s))
  await run("a new load stops the old one's paging mid-way",
    proc(s: Scenario): Future[void] = pagingStopsWithItsLoad(s))
  if ok:
    {.emit: "process.exitCode = 0;".}

discard main()
