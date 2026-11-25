## A ViewModel's async work ends with it. Disposing a ViewModel cancels the
## stream subscriptions it registered with `track`, and the cancel reaches
## the producer, which stops its timers; the answer of a future it
## registered with `own` that arrives after dispose writes nothing. Time is
## fake (`FakeAsyncContext`), so nothing sleeps and every step is exact.
##
## MOCK POLICY (workspace rule: every mock justified in the header). One
## stand-in, `RecordingService`: a service whose stream and future are real
## (`newServiceStream`, `Deferred`, timers from the nim-everywhere clock) and
## which also counts what the test needs to see and a real service would not
## report: how many cancels reached the producer and how many of its timers
## are still armed (scheduled, neither fired nor cancelled). Those counts are
## the assertions themselves ("the producer sees the cancel", "no timer
## leaks"), so they have to be kept by the producer. The ViewModel, its
## root, its signals and the stream protocol are the real ones.
##
## On JS a platform future is a promise whose callbacks run on a later
## microtask, which a synchronous test cannot wait for. There the late answer
## is an already-settled future (`newCompletedFuture`): its callbacks are
## queued and run by `drainPlatformCallbacks`, after the dispose, which is
## the same order of events the C case gets from a deferred settled by a
## timer after the dispose.

import std/unittest

import nim_everywhere
import nim_everywhere/async_compat
import isonim/core/[signals, owner, computation]
import isonim/services/streams
when not defined(js):
  import isonim/services/deferred
import isonim/viewmodel

type
  RecordingService = ref object
    chunks: seq[string]
    intervalMs: int
    cancels: int       ## cancels that reached the producer
    armedTimers: int   ## producer timers scheduled and not yet fired or cancelled

  ReplyVM = ref object of ViewModel
    service: RecordingService
    text: Signal[string]
    answer: Signal[string]

proc step(ctx: FakeAsyncContext; ms: int) =
  ## Advance one millisecond at a time, delivering future callbacks too.
  for _ in 0 ..< ms:
    ctx.advance(1)
    ctx.runPending()
    drainPlatformCallbacks()
    ctx.runPending()

proc reply(svc: RecordingService): ServiceStream[string] =
  ## Delivers `chunks`, one every `intervalMs`, then finishes.
  newServiceStream[string](proc(e: StreamEmitter[string]) =
    var timer: TimerHandle
    var index = 0
    proc arm(step: proc()) =
      inc svc.armedTimers
      timer = scheduleAt(svc.intervalMs, proc() =
        dec svc.armedTimers
        timer = nil
        step())
    e.onCancel(proc() =
      inc svc.cancels
      if timer != nil:
        cancelTimer(timer)
        timer = nil
        dec svc.armedTimers)
    proc next() =
      if not e.isActive: return
      if index >= svc.chunks.len:
        e.finish()
        return
      e.emit(svc.chunks[index])
      inc index
      arm(next)
    arm(next))

proc answerLater(svc: RecordingService; text: string;
                 afterMs: int): PlatformFuture[string] =
  ## A future that settles `afterMs` from now (see the header for JS).
  when defined(js):
    discard afterMs
    newCompletedFuture(text)
  else:
    let d = newDeferred[string]("answer")
    discard scheduleAt(afterMs, proc() = d.resolve(text))
    d.future

proc newReplyVM(svc: RecordingService): ReplyVM =
  withViewModel proc(dispose: proc()): ReplyVM =
    ReplyVM(service: svc, text: createSignal(""), answer: createSignal(""))

proc startReply(vm: ReplyVM) =
  vm.track(vm.service.reply().subscribe(proc(chunk: string) =
    vm.text.val = vm.text.val & chunk))

proc ask(vm: ReplyVM; afterMs: int) =
  vm.own(vm.service.answerLater("42", afterMs),
    proc(value: string) = vm.answer.val = value,
    proc(message: string) = vm.answer.val = "error: " & message)

suite "ViewModel dispose":
  test "disposing a ViewModel cancels its stream at the producer":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = RecordingService(chunks: @["a", "b", "c"], intervalMs: 10)
    let vm = newReplyVM(svc)
    vm.startReply()
    ctx.step(10)
    check vm.text.value == "a"
    check svc.armedTimers == 1
    vm.dispose()
    check vm.isDisposed
    check svc.cancels == 1
    check svc.armedTimers == 0
    ctx.step(50)
    check vm.text.value == "a"

  test "a future that settles after dispose writes nothing":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = RecordingService(intervalMs: 10)
    # Control: the same question on a live ViewModel is answered, so the
    # test can see a write when there is one.
    let live = newReplyVM(svc)
    live.ask(afterMs = 20)
    ctx.step(30)
    check live.answer.value == "42"
    live.dispose()

    let vm = newReplyVM(svc)
    var writes = 0
    var disposeWatcher: proc()
    createRoot proc(d: proc()) =
      disposeWatcher = d
      createEffect proc() =
        discard vm.answer.val
        inc writes
    check writes == 1
    vm.ask(afterMs = 20)
    vm.dispose()
    ctx.step(30)
    check vm.answer.value == ""
    check writes == 1
    disposeWatcher()

  test "no producer timer is left armed after dispose":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = RecordingService(chunks: @["x", "y"], intervalMs: 10)
    let vm = newReplyVM(svc)
    vm.startReply()       # will have finished before the dispose
    ctx.step(30)
    check vm.text.value == "xy"
    vm.startReply()       # still running at the dispose
    vm.startReply()
    ctx.step(10)
    check svc.armedTimers == 2
    vm.dispose()
    check svc.armedTimers == 0
    # Only the two running streams are cancelled: the finished one has
    # nothing left to stop.
    check svc.cancels == 2
    ctx.step(100)
    check vm.text.value == "xyxx"

  test "disposing the owner of a ViewModel's root cancels its stream":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = RecordingService(chunks: @["a", "b"], intervalMs: 10)
    var vm: ReplyVM
    var disposeScreen: proc()
    createRoot proc(d: proc()) =
      disposeScreen = d
      vm = newReplyVM(svc)
    vm.startReply()
    ctx.step(10)
    disposeScreen()
    check vm.isDisposed
    check svc.cancels == 1
    check svc.armedTimers == 0
    ctx.step(50)
    check vm.text.value == "a"
    vm.dispose()          # already disposed: nothing more happens
    check svc.cancels == 1

  test "a stream tracked after dispose is cancelled at once":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = RecordingService(chunks: @["a"], intervalMs: 10)
    let vm = newReplyVM(svc)
    vm.dispose()
    vm.startReply()
    check svc.cancels == 1
    check svc.armedTimers == 0
    ctx.step(50)
    check vm.text.value == ""

  test "a ViewModel without a root is disposed the same way":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = RecordingService(chunks: @["a", "b"], intervalMs: 10)
    let vm = ReplyVM(service: svc, text: createSignal(""),
                     answer: createSignal(""))
    vm.startReply()
    ctx.step(10)
    vm.ask(afterMs = 20)
    vm.dispose()
    check svc.cancels == 1
    check svc.armedTimers == 0
    ctx.step(50)
    check vm.text.value == "a"
    check vm.answer.value == ""
