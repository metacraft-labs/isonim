## Edge cases of the async value primitive (`isonim/services/async_value`):
## a service that answers or fails while it is being subscribed to, input
## changes inside a batch, a refresh while a new question is in flight, an
## input that raises, a call that changes the question it was asked, a View
## that disposes the value when it sees an answer, a value created inside
## a batch, a completion that ends its own question and writes another
## value, a completion that asks a new question or disposes the value, and
## a local write in the batch that asks a new question or while a new
## question is pending.
##
## MOCK POLICY (workspace rule: every mock justified in the header). One
## recording service (`helpers/async_recording_service`): its futures are
## real `Deferred`s and its streams real `newServiceStream`s, settled by
## timers on the nim-everywhere clock driven by `FakeAsyncContext`; it also
## records every question asked, every answer it delivered, every cancel
## that reached it and its armed timers, which a real service would not
## report and which are what these tests assert. A few tests use inline
## services (`newServiceStream` producers that answer at once, a call that
## writes the input) because their point is that exact behaviour of the
## service. The primitive, its signals, effects and owners are the real
## ones. On the JS backend a recording future answers at the next drain
## (see the helper's header); the checks that need its latency are C-only
## and marked.

import std/[options, strutils, unittest]

import nim_everywhere
import isonim/core/[signals, owner, computation, batch]
import isonim/services/async_value

import helpers/async_recording_service

proc fetchOf(svc: RecordingService): proc(q: string): PlatformFuture[string] =
  result = proc(q: string): PlatformFuture[string] = svc.fetch(q)

proc streamOf(svc: RecordingService): proc(q: string): ServiceStream[string] =
  result = proc(q: string): ServiceStream[string] = svc.stream(q)

suite "async value edge cases":
  test "a stream that answers while it is subscribed to":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let q = createSignal("a")
    var statuses: seq[AsyncStatus]
    let av = createAsyncStream(proc(): string = q.val,
      proc(s: string): ServiceStream[string] =
        newServiceStream[string](proc(e: StreamEmitter[string]) =
          e.emit(s & ".1")
          e.emit(s & ".2")
          e.finish()))
    createRoot proc(d: proc()) =
      createEffect proc() = statuses.add av.status
    check av.ready
    check av.done
    check av.val == @["a.1", "a.2"]
    q.val = "b"
    check av.ready
    check av.done
    check av.val == @["b.1", "b.2"]
    # The answer arrived during the subscription, in the same propagation
    # as the question: no View frame showed it loading.
    check statuses == @[AsyncStatus.ready, AsyncStatus.ready]
    av.dispose()

  test "a stream that fails while it is subscribed to":
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val,
      proc(s: string): ServiceStream[string] =
        newServiceStream[string](proc(e: StreamEmitter[string]) =
          e.fail("nope " & s)))
    check av.status == AsyncStatus.failed
    check av.error == "nope a"
    av.dispose()

  test "two input changes in one batch ask only the last question":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf)
    ctx.step(10)
    batch proc() =
      q.val = "b"
      q.val = "c"
    check svc.asks == @["a", "c"]
    check av.pending
    ctx.step(10)
    check av.val == answerFor("c", 1)
    # back and forth inside a batch: no new question
    batch proc() =
      q.val = "x"
      q.val = "c"
    check svc.asks == @["a", "c"]
    check av.ready
    av.dispose()

  test "refresh while pending re-asks the pending question":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf,
      cancel = proc(question: string) = svc.cancelFetch(question))
    ctx.step(10)
    q.val = "b"
    when not defined(js): ctx.step(5)
    check av.pending
    av.refresh()
    check av.pending
    check svc.asks == @["a", "b", "b"]
    check svc.cancels == @["b"]
    ctx.step(20)
    check av.ready
    check av.val == answerFor("b", 2)
    when not defined(js):
      check svc.answered == @[answerFor("a", 1), answerFor("b", 2)]
    av.dispose()

  test "a quiet refresh over a refresh that shows the wait settles":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf)
    ctx.step(10)
    av.refresh(pending = true)
    check av.pending
    av.refresh()
    ctx.step(10)
    check av.ready
    check av.val == answerFor("a", 3)
    av.dispose()

  test "an input that raises routes to the owner's handler, and recovers":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let q = createSignal("a")
    var errors: seq[string]
    var av: AsyncValue[string]
    var disposeAll: proc()
    createRoot proc(d: proc()) =
      disposeAll = d
      onError proc(e: ref CatchableError) =
        errors.add e.msg
      av = createAsync(proc(): string =
        if q.val == "x": raise newException(ValueError, "bad input")
        q.val, svc.fetchOf)
    ctx.step(10)
    check av.val == answerFor("a", 1)
    q.val = "x"
    # The error is the graph's (as for any memo): it reaches the owner's
    # handler, nothing is asked, and reading the value raises it.
    check errors == @["bad input"]
    var raised = false
    try: discard av.status
    except ValueError: raised = true
    check raised
    q.val = "b"
    check av.pending
    ctx.step(10)
    check av.ready
    check av.val == answerFor("b", 1)
    check svc.asks == @["a", "b"]
    disposeAll()

  test "a call that changes its own question is cancelled":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val,
      proc(s: string): PlatformFuture[string] =
        if s == "redirect": q.val = "target"
        svc.fetch(s),
      cancel = proc(question: string) = svc.cancelFetch(question))
    ctx.step(10)
    q.val = "redirect"
    ctx.step(20)
    check svc.asks == @["a", "target", "redirect"]
    check av.val == answerFor("target", 1)
    check av.ready
    # The replaced call was made, so the service is asked to stop it.
    check svc.cancels == @["redirect"]
    av.dispose()

  test "dispose from a View reacting to the answer":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, svc.streamOf)
    createRoot proc(d: proc()) =
      createEffect proc() =
        if av.val.len == 2: av.dispose()
    ctx.step(100)
    check svc.cancels == @["a"]
    check svc.armedTimers == 0
    check av.isDisposed

  test "created inside a batch":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let q = createSignal("a")
    var av: AsyncValue[string]
    batch proc() =
      av = createAsync(proc(): string = q.val, svc.fetchOf)
      q.val = "b"
    # Effects run at creation, so "a" is asked, then replaced by "b".
    check svc.asks == @["a", "b"]
    check av.loading
    ctx.step(10)
    check av.val == answerFor("b", 1)
    av.dispose()

  test "a View reading the question never sees an old answer as ready":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let q = createSignal("a")
    let upper = createMemo(proc(): string = q.val.toUpperAscii)
    let av = createAsync(proc(): string = upper.val, svc.fetchOf)
    var bad = 0
    createRoot proc(d: proc()) =
      createEffect proc() =
        let shownQ = upper.val
        if av.ready and questionOf(av.val) != shownQ: inc bad
    ctx.step(10)
    for s in ["b", "c", "d"]:
      q.val = s
      ctx.step(3)
    ctx.step(20)
    check bad == 0
    check av.val == answerFor("D", 1)
    av.dispose()

suite "async value edge cases: local writes and completion":
  test "a completion that ends the question and writes another value shows once":
    # The shape of a chat reply: a streamed reply that, when done, joins
    # the transcript (a local write to another value) and ends (its
    # question becomes none). No frame shows the reply twice (in the
    # transcript and as the reply) or not at all.
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(intervalMs = 10, chunkCount = 2)
    let conversation = createSignal("c1")
    let transcript = createAsync(proc(): string = conversation.val,
      svc.fetchOf)
    let prompt = createSignal(none(string))
    let reply = createAsyncStream(proc(): Option[string] = prompt.val,
      proc(p: Option[string]): ServiceStream[string] = svc.stream(p.get),
      onDone = proc(p: Option[string]; chunks: seq[string]) =
        transcript.mutate(transcript.value & "|" & chunks.join)
        prompt.val = none(string))
    ctx.step(10)
    check transcript.ready
    var frames: seq[(string, string, AsyncStatus)]
    var stop: proc()
    createRoot proc(d: proc()) =
      stop = d
      createEffect proc() =
        frames.add (transcript.val, reply.val.join, reply.status)
    prompt.val = some("p")
    ctx.step(40)
    let full = chunkFor("p", 1) & chunkFor("p", 2)
    check transcript.val == answerFor("c1", 1) & "|" & full
    check reply.status == AsyncStatus.idle
    check reply.val.len == 0
    for f in frames:
      let inTranscript = f[0].endsWith(full)
      let asReply = f[1] == full
      check not (inTranscript and asReply)
    check frames[^1] == (answerFor("c1", 1) & "|" & full, "",
                         AsyncStatus.idle)
    check frames[^2][1] == full and frames[^2][2] == AsyncStatus.ready
    stop()
    reply.dispose()
    transcript.dispose()

  test "a local write in the batch that asks a new question is that question's":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf)
    ctx.step(10)
    batch proc() =
      q.val = "b"
      av.mutate("local:b")
    # The write is read against the question the input yields now: "b",
    # whose call goes on and whose answer replaces the local value.
    check av.ready
    check av.val == "local:b"
    check svc.asks == @["a", "b"]
    ctx.step(10)
    check av.ready
    check av.val == answerFor("b", 1)
    av.dispose()

  test "a local write to a stream in the batch that asks a new question":
    # The flight in progress belongs to the old question and stops when the
    # batch ends; the local value is the new question's whole answer until
    # the new stream's first chunk replaces it.
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(intervalMs = 10, chunkCount = 3)
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, svc.streamOf)
    ctx.step(10)
    check av.val == @[chunkFor("a", 1)]
    batch proc() =
      q.val = "b"
      av.mutate(@["local:b"])
    check av.ready
    check av.done
    check av.val == @["local:b"]
    check svc.cancels == @["a"]
    ctx.step(10)
    check av.val == @[chunkFor("b", 1)]
    check not av.done
    ctx.step(30)
    check av.done
    check av.val == @[chunkFor("b", 1), chunkFor("b", 2), chunkFor("b", 3)]
    av.dispose()

  test "a local write while a new question is pending, then a replacement":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf)
    ctx.step(10)
    q.val = "b"
    check av.pending
    av.mutate("local:b")
    check av.ready
    check av.val == "local:b"
    var frames: seq[(string, AsyncStatus)]
    var stop: proc()
    createRoot proc(d: proc()) =
      stop = d
      createEffect proc() = frames.add (av.val, av.status)
    q.val = "c"                         # replaces "b", still in flight
    check av.pending
    check av.val == "local:b"
    ctx.step(30)
    check av.val == answerFor("c", 1)
    # The answer to "b" never showed.
    for f in frames: check f[0] != answerFor("b", 1)
    check frames == @[("local:b", AsyncStatus.ready),
                      ("local:b", AsyncStatus.pending),
                      (answerFor("c", 1), AsyncStatus.ready)]
    stop()
    av.dispose()

  test "a completion that asks a new question shows no frame of the old as ready":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let q = createSignal("a")
    var completed: seq[string]
    let av = createAsync(proc(): string = q.val, svc.fetchOf,
      onDone = proc(question, value: string) =
        completed.add question
        if question == "a": q.val = "b")
    var frames: seq[(string, AsyncStatus)]
    var stop: proc()
    createRoot proc(d: proc()) =
      stop = d
      createEffect proc() = frames.add (av.val, av.status)
    ctx.step(20)
    check completed == @["a", "b"]
    check frames == @[("", AsyncStatus.loading),
                      (answerFor("a", 1), AsyncStatus.pending),
                      (answerFor("b", 1), AsyncStatus.ready)]
    stop()
    av.dispose()

  test "a completion that disposes the value":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(intervalMs = 10, chunkCount = 2)
    let q = createSignal("a")
    var av: AsyncValue[seq[string]]
    var completed = 0
    av = createAsyncStream(proc(): string = q.val, svc.streamOf,
      onDone = proc(question: string; chunks: seq[string]) =
        inc completed
        q.val = "b"                     # asked after dispose: nothing
        av.dispose())
    ctx.step(40)
    check completed == 1
    check av.isDisposed
    check av.value == @[chunkFor("a", 1), chunkFor("a", 2)]
    ctx.step(40)
    check completed == 1
    check svc.asks == @["a"]
    when not defined(js):
      check svc.armedTimers == 0
