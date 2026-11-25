## The five statements an async value guarantees about what the View shows
## (`isonim/services/async_value`), each checked on every frame a View
## would render, under fake time:
##
## 1. What the View shows is a real answer, a declared placeholder or an
##    error, and a placeholder is never reported as an answer.
## 2. A new question never shows an older answer as the new one without
##    being pending.
## 3. Asking the same question again never shows loading or pending on its
##    own.
## 4. A replaced question never changes what the View shows after its
##    replacement was asked.
## 5. After dispose, nothing a ViewModel started writes to it.
##
## A "frame" is one run of an effect that reads the question and the value
## as a View does; the statements are checked on all of them, so a frame
## that a renderer would have shown for a moment counts as much as the
## last one.
##
## MOCK POLICY (workspace rule: every mock justified in the header). One
## recording service (`helpers/async_recording_service`): real `Deferred`
## futures and `newServiceStream` streams on the nim-everywhere clock,
## driven by `FakeAsyncContext`, which also records the questions, the
## answers it delivered, the cancels that reached it and its armed timers:
## the statements are about those (an answer shown must be one the service
## gave; nothing may be written after dispose), so the producer keeps them.
## The primitive, the ViewModel, signals and effects are the real ones. On
## the JS backend a future answers at the next drain rather than after its
## latency (see the helper's header); every statement holds on both.

import std/[options, strutils, tables, unittest]

import nim_everywhere
import isonim/core/[signals, owner, computation]
import isonim/services/async_value
import isonim/viewmodel

import helpers/async_recording_service

const Placeholder = "(placeholder)"

type
  Frame = object
    question: string
    shown: string
    status: AsyncStatus
    provisional: bool
    error: string

  Screen = ref object
    frames: seq[Frame]
    stop: proc()

proc watch(q: Signal[string]; av: AsyncValue[string]): Screen =
  let screen = Screen()
  createRoot proc(d: proc()) =
    screen.stop = d
    createEffect proc() =
      screen.frames.add Frame(question: q.val.strip, shown: av.val,
        status: av.status, provisional: av.provisional, error: av.error)
  screen

proc watch(q: Signal[string]; av: AsyncValue[seq[string]]): Screen =
  let screen = Screen()
  createRoot proc(d: proc()) =
    screen.stop = d
    createEffect proc() =
      screen.frames.add Frame(question: q.val.strip, shown: av.val.join(" "),
        status: av.status, provisional: av.provisional, error: av.error)
  screen

proc fetchOf(svc: RecordingService): proc(q: string): PlatformFuture[string] =
  result = proc(q: string): PlatformFuture[string] = svc.fetch(q)

proc streamOf(svc: RecordingService): proc(q: string): ServiceStream[string] =
  result = proc(q: string): ServiceStream[string] = svc.stream(q)

proc lastChunkQuestion(shown: string): string =
  ## The question the last chunk of a joined stream value belongs to.
  if shown.len == 0: return ""
  questionOf(shown.split(' ')[^1])

proc exercise(ctx: FakeAsyncContext; svc: RecordingService;
              q: Signal[string]; refresh: proc(); stepMs: int) =
  ## One script for every statement: first load, a new question, a quick
  ## replacement (the replaced answer arrives first on C), a same-question
  ## input change, a refresh, a failure, recovery.
  ctx.step(stepMs)
  q.val = "b"
  ctx.step(stepMs)
  q.val = "c"
  q.val = "d"
  ctx.step(stepMs * 4)
  q.val = " d "
  refresh()
  ctx.step(stepMs * 4)
  q.val = "bad"
  ctx.step(stepMs * 4)
  q.val = "e"
  ctx.step(stepMs * 4)

suite "what an async value shows":
  test "what the View shows is a real answer, a declared placeholder or an error, and a placeholder is never reported as an answer":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(latencyMs = 10)
    svc.latencies["d"] = 30
    svc.failures["bad"] = "offline"
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val.strip, svc.fetchOf,
                         placeholder = some(Placeholder))
    let screen = watch(q, av)
    exercise(ctx, svc, q, proc() = av.refresh(), 10)
    check screen.frames.len >= 6
    check screen.frames[0].provisional
    for f in screen.frames:
      if f.provisional:
        check f.shown == Placeholder
        check f.status in {AsyncStatus.loading, AsyncStatus.failed}
      else:
        check f.shown != Placeholder
        check f.shown in svc.answered
      if f.status in {AsyncStatus.ready, AsyncStatus.pending}:
        check not f.provisional
      if f.status == AsyncStatus.loading:
        check f.provisional
      if f.status == AsyncStatus.failed:
        check f.error == "offline"
      else:
        check f.error == ""
    screen.stop()
    av.dispose()

  test "a new question never shows an older answer as the new one without being pending":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(latencyMs = 10, intervalMs = 10)
    svc.latencies["d"] = 30
    svc.failures["bad"] = "offline"
    svc.streamFailAfter["bad"] = 1
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val.strip, svc.fetchOf)
    let stream = createAsyncStream(proc(): string = q.val.strip, svc.streamOf)
    let screen = watch(q, av)
    let streamScreen = watch(q, stream)
    exercise(ctx, svc, q, proc() =
      av.refresh()
      stream.refresh(), 10)
    var pendingFrames = 0
    for f in screen.frames:
      if f.status == AsyncStatus.ready:
        check questionOf(f.shown) == f.question
      elif f.shown.len > 0 and questionOf(f.shown) != f.question:
        check f.status in {AsyncStatus.pending, AsyncStatus.failed}
        if f.status == AsyncStatus.pending: inc pendingFrames
    for f in streamScreen.frames:
      if f.status == AsyncStatus.ready:
        check lastChunkQuestion(f.shown) == f.question
      elif f.shown.len > 0 and lastChunkQuestion(f.shown) != f.question:
        check f.status in {AsyncStatus.pending, AsyncStatus.failed}
        if f.status == AsyncStatus.pending: inc pendingFrames
    # The script does ask new questions over old answers.
    check pendingFrames >= 4
    screen.stop()
    streamScreen.stop()
    av.dispose()
    stream.dispose()

  test "asking the same question again never shows loading or pending on its own":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(latencyMs = 10)
    let streams = newRecordingService(intervalMs = 10, chunkCount = 2)
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val.strip, svc.fetchOf)
    let stream = createAsyncStream(proc(): string = q.val.strip,
                                   streams.streamOf)
    ctx.step(40)
    check av.ready
    check stream.done
    let screen = watch(q, av)
    let streamScreen = watch(q, stream)
    for round in 0 ..< 3:
      av.refresh()
      stream.refresh()
      q.val = (if round mod 2 == 0: " a" else: "a ")
      ctx.step(5)
      av.refresh()
      ctx.step(40)
    check svc.asks.len == 7          # each refresh asked again
    check streams.asks.len == 4
    check av.val == answerFor("a", 7)
    check stream.done
    for f in screen.frames & streamScreen.frames:
      check f.status == AsyncStatus.ready
    screen.stop()
    streamScreen.stop()
    av.dispose()
    stream.dispose()

  test "a replaced question never changes what the View shows after its replacement was asked":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(latencyMs = 10)
    let streams = newRecordingService(intervalMs = 10)
    svc.latencies["b"] = 30     # C: "a" answers while "b" is in flight
    svc.latencies["c"] = 40     # C: "c" answers after "d"
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf)
    let stream = createAsyncStream(proc(): string = q.val, streams.streamOf)
    let screen = watch(q, av)
    let streamScreen = watch(q, stream)
    ctx.step(5)
    q.val = "b"
    let afterB = screen.frames.len
    let streamAfterB = streamScreen.frames.len
    ctx.step(40)
    q.val = "c"
    ctx.step(5)
    q.val = "d"
    let afterD = screen.frames.len
    let streamAfterD = streamScreen.frames.len
    ctx.step(60)
    check answerFor("a", 1) in svc.answered
    check answerFor("c", 1) in svc.answered
    check av.val == answerFor("d", 1)
    check stream.val == @[chunkFor("d", 1), chunkFor("d", 2), chunkFor("d", 3)]
    for f in screen.frames[afterB .. ^1]:
      check questionOf(f.shown) != "a"
    for f in screen.frames[afterD .. ^1]:
      check questionOf(f.shown) notin ["a", "c"]
    for f in streamScreen.frames[streamAfterB .. ^1]:
      check "a." notin f.shown
    for f in streamScreen.frames[streamAfterD .. ^1]:
      check "a." notin f.shown
      check "c." notin f.shown
    check streams.cancels == @["a", "c"]   # the two replaced streams
    screen.stop()
    streamScreen.stop()
    av.dispose()
    stream.dispose()

  test "after dispose, nothing a ViewModel started writes to it":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(latencyMs = 20, intervalMs = 10)
    type PageVM = ref object of ViewModel
      q: Signal[string]
      item: AsyncValue[string]
      reply: AsyncValue[seq[string]]
    let vm = withViewModel proc(dispose: proc()): PageVM =
      let vm = PageVM(q: createSignal("a"))
      vm.item = createAsync(proc(): string = vm.q.val, svc.fetchOf)
      vm.reply = createAsyncStream(proc(): string = vm.q.val, svc.streamOf)
      vm
    let screen = watch(vm.q, vm.item)
    let streamScreen = watch(vm.q, vm.reply)
    # Both are in flight: the stream's producer has a timer armed, the
    # item's answer is on its way.
    when not defined(js):
      check svc.armedTimers == 2
    let frames = screen.frames.len
    let streamFrames = streamScreen.frames.len
    vm.dispose()
    check svc.cancels == @["a"]    # the stream, at the producer
    ctx.step(100)                  # the item's answer arrives meanwhile
    check answerFor("a", 1) in svc.answered
    vm.item.refresh()
    vm.reply.refresh()
    ctx.step(100)
    check screen.frames.len == frames
    check streamScreen.frames.len == streamFrames
    check vm.item.val == ""
    check vm.reply.val.len == 0
    check svc.asks == @["a", "a"]
    when not defined(js):
      check svc.armedTimers == 0
    screen.stop()
    streamScreen.stop()
