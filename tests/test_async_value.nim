## An async value over a future-returning service call
## (`isonim/services/async_value`), under fake time: a first load is
## loading, not pending; a new question is pending and keeps the old answer
## until its own arrives; an answer to a replaced question never shows, and
## its call is cancelled when the service can stop it; asking the same
## question again is quiet; an error shows as an error and a new question
## recovers; the value ends with its owner.
##
## MOCK POLICY (workspace rule: every mock justified in the header). One
## recording service (`helpers/async_recording_service`): its futures are
## real `Deferred`s settled by timers on the nim-everywhere clock, driven by
## `FakeAsyncContext`; it also records every question asked, every cancel
## that reached it and its armed timers, which a real service would not
## report and which are what these tests assert. The primitive, its
## signals, effects and owners are the real ones.
##
## On the JS backend a future's callback runs at the next drain of
## platform callbacks rather than after its latency (see the helper's
## header), so the checks between a question and its answer are made right
## after the question, and the checks that depend on one answer arriving
## before another are C-only, marked where they are.

import std/[options, strutils, tables, unittest]

import nim_everywhere
import isonim/core/[signals, owner, computation]
import isonim/services/async_value
import isonim/viewmodel

import helpers/async_recording_service

type Frames = ref object
  ## What a View reading the value saw, one entry per run.
  shown: seq[string]
  status: seq[AsyncStatus]

proc watch(av: AsyncValue[string]): (Frames, proc()) =
  ## An effect that reads the value as a View does.
  let frames = Frames()
  var dispose: proc()
  createRoot proc(d: proc()) =
    dispose = d
    createEffect proc() =
      frames.shown.add av.val
      frames.status.add av.status
  (frames, dispose)

proc fetchOf(svc: RecordingService): proc(q: string): PlatformFuture[string] =
  result = proc(q: string): PlatformFuture[string] = svc.fetch(q)

suite "async value over a future":
  test "a first load is loading, not pending":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf)
    check av.status == AsyncStatus.loading
    check av.loading
    check not av.pending
    check not av.ready
    check av.val == ""
    check svc.asks == @["a"]
    ctx.step(10)
    check av.status == AsyncStatus.ready
    check av.ready
    check av.val == answerFor("a", 1)
    check av.done
    av.dispose()

  test "a new question is pending and keeps the old answer until its own":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf)
    ctx.step(10)
    let (frames, stopWatching) = watch(av)
    q.val = "b"
    check av.status == AsyncStatus.pending
    check av.pending
    check not av.loading
    check av.val == answerFor("a", 1)
    check svc.asks == @["a", "b"]
    when not defined(js):
      ctx.step(5)
      check av.pending
      check av.val == answerFor("a", 1)
    ctx.step(10)
    check av.ready
    check av.val == answerFor("b", 1)
    check frames.shown == @[answerFor("a", 1), answerFor("a", 1),
                            answerFor("b", 1)]
    check frames.status == @[AsyncStatus.ready, AsyncStatus.pending,
                             AsyncStatus.ready]
    stopWatching()
    av.dispose()

  test "an answer to a replaced question never shows":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    # The replaced question is answered first (C: "a" at 10 ms, "b" at
    # 30 ms), which is the order in which a stale answer would show.
    svc.latencies["b"] = 30
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf)
    let (frames, stopWatching) = watch(av)
    q.val = "b"
    ctx.step(40)
    check av.val == answerFor("b", 1)
    check av.ready
    # The service did answer "a"; the value never showed it.
    check answerFor("a", 1) in svc.answered
    for shown in frames.shown:
      check shown != answerFor("a", 1)
    check frames.shown == @["", answerFor("b", 1)]
    stopWatching()
    av.dispose()

  test "an answer to a replaced question that arrives last never shows":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    svc.latencies["a"] = 30   # C: "b" at 10 ms, the stale "a" at 30 ms
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf)
    let (frames, stopWatching) = watch(av)
    q.val = "b"
    ctx.step(40)
    check av.val == answerFor("b", 1)
    check answerFor("a", 1) in svc.answered
    check frames.shown == @["", answerFor("b", 1)]
    stopWatching()
    av.dispose()

  test "a replaced call is cancelled when the service can stop it":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf,
      cancel = proc(question: string) = svc.cancelFetch(question))
    q.val = "b"
    check svc.cancels == @["a"]
    ctx.step(20)
    check av.val == answerFor("b", 1)
    when not defined(js):
      # The cancelled call's timer was stopped: "a" was never answered.
      check svc.answered == @[answerFor("b", 1)]
      check svc.armedTimers == 0
    # A call that has answered is not cancelled by the next question.
    q.val = "c"
    ctx.step(20)
    check svc.cancels == @["a"]
    check av.val == answerFor("c", 1)
    av.dispose()

  test "refresh asks the same question again without showing pending":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val.strip, svc.fetchOf)
    ctx.step(10)
    let (frames, stopWatching) = watch(av)
    av.refresh()
    check svc.asks == @["a", "a"]
    check av.ready
    check not av.pending
    check not av.loading
    check av.val == answerFor("a", 1)
    ctx.step(10)
    check av.val == answerFor("a", 2)
    # An input change that asks the same question is not a new question.
    q.val = " a "
    check svc.asks == @["a", "a"]
    check av.ready
    check frames.status == @[AsyncStatus.ready, AsyncStatus.ready]
    check frames.shown == @[answerFor("a", 1), answerFor("a", 2)]
    # The caller may say the refresh affects what is shown.
    av.refresh(pending = true)
    check av.pending
    check av.val == answerFor("a", 2)
    ctx.step(10)
    check av.ready
    check av.val == answerFor("a", 3)
    stopWatching()
    av.dispose()

  test "an error shows as an error and a new question recovers":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    svc.failures["bad"] = "boom"
    let q = createSignal("bad")
    let av = createAsync(proc(): string = q.val, svc.fetchOf)
    ctx.step(10)
    check av.status == AsyncStatus.failed
    check av.error == "boom"
    check av.val == ""
    check not av.done
    q.val = "a"
    check av.loading          # no answer is held, so this is a first load
    check av.error == ""
    ctx.step(10)
    check av.ready
    check av.error == ""
    check av.val == answerFor("a", 1)
    # A failure after an answer keeps the answer as the value.
    q.val = "bad"
    check av.pending
    ctx.step(10)
    check av.status == AsyncStatus.failed
    check av.error == "boom"
    check av.val == answerFor("a", 1)
    q.val = "b"
    check av.pending
    ctx.step(10)
    check av.ready
    check av.val == answerFor("b", 1)
    av.dispose()

  test "a call that raises is a failed question":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let q = createSignal(1)
    let av = createAsync(proc(): int = q.val,
      proc(n: int): PlatformFuture[string] =
        if n == 1: raise newException(ValueError, "no such item")
        newCompletedFuture("item " & $n))
    check av.status == AsyncStatus.failed
    check av.error == "no such item"
    q.val = 2
    ctx.step(1)
    check av.ready
    check av.val == "item 2"
    av.dispose()

  test "an Option input asks nothing while it is none":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let q = createSignal(none(string))
    let av = createAsync(proc(): Option[string] = q.val,
      proc(question: Option[string]): PlatformFuture[string] =
        svc.fetch(question.get))
    check av.status == AsyncStatus.idle
    check svc.asks.len == 0
    q.val = some("a")
    check av.loading
    ctx.step(10)
    check av.val == answerFor("a", 1)
    # Back to nothing: the answer is no longer shown, and the next question
    # is a first load again, not a new question over an old answer.
    q.val = none(string)
    check av.status == AsyncStatus.idle
    check av.val == ""
    q.val = some("a")
    check av.loading
    check av.val == ""
    ctx.step(10)
    check av.val == answerFor("a", 2)
    av.dispose()

  test "the value ends with the ViewModel that created it":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    type ItemVM = ref object of ViewModel
      id: Signal[string]
      item: AsyncValue[string]
    let vm = withViewModel proc(dispose: proc()): ItemVM =
      let vm = ItemVM(id: createSignal("a"))
      vm.item = createAsync(proc(): string = vm.id.val, svc.fetchOf,
        cancel = proc(question: string) = svc.cancelFetch(question))
      vm
    let (frames, stopWatching) = watch(vm.item)
    vm.dispose()
    check vm.item.isDisposed
    check svc.cancels == @["a"]
    ctx.step(20)
    check frames.shown == @[""]
    check vm.item.val == ""
    # Nothing more is asked after dispose.
    vm.id.val = "b"
    vm.item.refresh()
    check svc.asks == @["a"]
    when not defined(js):
      check svc.armedTimers == 0
    stopWatching()
