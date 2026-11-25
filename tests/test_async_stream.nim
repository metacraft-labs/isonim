## An async value over a streamed service call
## (`isonim/services/async_value`, `createAsyncStream`), under fake time:
## chunks accumulate in order; done is set once; a new question cancels the
## old stream at the producer and its chunks never show again; a stream
## that breaks off shows the error and keeps what arrived; disposing the
## value (or the ViewModel that created it) cancels the stream.
##
## MOCK POLICY (workspace rule: every mock justified in the header). One
## recording service (`helpers/async_recording_service`): its streams are
## real (`newServiceStream`, paced by timers on the nim-everywhere clock and
## driven by `FakeAsyncContext`); it also records every question asked,
## every cancel that reached the producer and its armed timers, which a
## real service would not report and which are what these tests assert.
## The primitive, its signals, effects and owners are the real ones.
## Streams behave the same on the C and JS backends.

import std/[options, tables, unittest]

import nim_everywhere
import isonim/core/[signals, owner, computation]
import isonim/services/async_value
import isonim/viewmodel

import helpers/async_recording_service

proc streamOf(svc: RecordingService): proc(q: string): ServiceStream[string] =
  result = proc(q: string): ServiceStream[string] = svc.stream(q)

proc chunks(question: string; n: int): seq[string] =
  for i in 1 .. n: result.add chunkFor(question, i)

suite "async value over a stream":
  test "chunks accumulate in order and done is set once":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(intervalMs = 10, chunkCount = 3)
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, svc.streamOf)
    var doneWrites: seq[bool]
    var stopWatching: proc()
    createRoot proc(d: proc()) =
      stopWatching = d
      createEffect proc() = doneWrites.add av.done
    check av.loading
    check av.val.len == 0
    ctx.step(10)
    check av.ready          # its first chunk is shown
    check not av.done
    check av.val == chunks("a", 1)
    ctx.step(10)
    check av.val == chunks("a", 2)
    ctx.step(10)
    check av.val == chunks("a", 3)
    check not av.done       # the producer has not said it is finished
    ctx.step(10)
    check av.done
    check av.ready
    check av.val == chunks("a", 3)
    ctx.step(50)
    check doneWrites == @[false, true]
    check svc.armedTimers == 0
    check svc.cancels.len == 0
    stopWatching()
    av.dispose()

  test "a new question cancels the old stream at the producer":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(intervalMs = 10, chunkCount = 3)
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, svc.streamOf)
    var shown: seq[seq[string]]
    var stopWatching: proc()
    createRoot proc(d: proc()) =
      stopWatching = d
      createEffect proc() = shown.add av.val
    ctx.step(10)
    check av.val == chunks("a", 1)
    check svc.armedTimers == 1
    q.val = "b"
    check svc.cancels == @["a"]
    check svc.armedTimers == 1      # only the new stream's
    # The old chunks stay shown until the new stream's first chunk.
    check av.pending
    check av.val == chunks("a", 1)
    ctx.step(10)
    check av.ready
    check av.val == chunks("b", 1)
    ctx.step(30)
    check av.done
    check av.val == chunks("b", 3)
    # "a" never showed more than it had before it was replaced.
    check shown == @[newSeq[string](), chunks("a", 1), chunks("b", 1),
                     chunks("b", 2), chunks("b", 3)]
    stopWatching()
    av.dispose()

  test "refresh re-subscribes quietly and replaces the chunks":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(intervalMs = 10, chunkCount = 2)
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, svc.streamOf)
    ctx.step(30)
    check av.done
    av.refresh()
    check svc.asks == @["a", "a"]
    check av.ready
    check av.done
    check av.val == chunks("a", 2)
    ctx.step(10)
    check av.val == chunks("a", 1)   # the new stream's first chunk
    check not av.done
    ctx.step(20)
    check av.done
    check av.val == chunks("a", 2)
    av.dispose()

  test "a stream that breaks off shows the error and keeps its chunks":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(intervalMs = 10, chunkCount = 3)
    svc.streamFailAfter["bad"] = 2
    let q = createSignal("bad")
    let av = createAsyncStream(proc(): string = q.val, svc.streamOf)
    ctx.step(30)
    check av.status == AsyncStatus.failed
    check av.error == "stream bad broke off"
    check av.val == chunks("bad", 2)
    check not av.done
    q.val = "a"
    check av.pending
    ctx.step(40)
    check av.ready
    check av.done
    check av.error == ""
    check av.val == chunks("a", 3)
    av.dispose()

  test "an Option input that becomes none cancels the stream":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(intervalMs = 10, chunkCount = 3)
    let q = createSignal(some("a"))
    let av = createAsyncStream(proc(): Option[string] = q.val,
      proc(question: Option[string]): ServiceStream[string] =
        svc.stream(question.get))
    ctx.step(10)
    check av.val == chunks("a", 1)
    q.val = none(string)
    check svc.cancels == @["a"]
    check svc.armedTimers == 0
    check av.status == AsyncStatus.idle
    check av.val.len == 0
    av.dispose()

  test "dispose cancels the stream":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(intervalMs = 10, chunkCount = 3)
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, svc.streamOf)
    ctx.step(10)
    var writes = 0
    var stopWatching: proc()
    createRoot proc(d: proc()) =
      stopWatching = d
      createEffect proc() =
        discard av.val
        inc writes
    av.dispose()
    check av.isDisposed
    check svc.cancels == @["a"]
    check svc.armedTimers == 0
    ctx.step(50)
    check writes == 1
    av.dispose()                    # again: nothing more happens
    check svc.cancels == @["a"]
    stopWatching()

  test "disposing the ViewModel that created it cancels the stream":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(intervalMs = 10, chunkCount = 3)
    type ReplyVM = ref object of ViewModel
      prompt: Signal[string]
      reply: AsyncValue[seq[string]]
    let vm = withViewModel proc(dispose: proc()): ReplyVM =
      let vm = ReplyVM(prompt: createSignal("a"))
      vm.reply = createAsyncStream(proc(): string = vm.prompt.val,
                                   svc.streamOf)
      vm
    ctx.step(10)
    vm.dispose()
    check vm.reply.isDisposed
    check svc.cancels == @["a"]
    check svc.armedTimers == 0
    ctx.step(50)
    check vm.reply.val == chunks("a", 1)
