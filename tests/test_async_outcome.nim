## The settle hook and the in-flight accessor of the async value primitive
## (`isonim/services/async_value`), under fake time: an open stream is in
## flight under `ready` and `done` only once it has finished; `onSettled`
## receives each question's `Outcome` (answered or failed) once, in the
## batch that writes it, only for the current question of a live value, so
## a superseded, refreshed-over or disposed flight runs no hook; a failure
## is an outcome and never reaches an error handler; `onDone` is the
## answered case; a hook that raises is an error of the graph, which goes
## to the nearest owner's handler.
##
## MOCK POLICY (workspace rule: every mock justified in the header). One
## recording service (`helpers/async_recording_service`): its futures are
## real `Deferred`s and its streams real `newServiceStream`s, settled by
## timers on the nim-everywhere clock driven by `FakeAsyncContext`; it also
## records every question asked and every answer it delivered, which a real
## service would not report and which some of these tests assert. A few
## tests use an inline call that raises or returns nil, because that exact
## service behaviour is their point. The primitive, its signals, effects,
## owners and error handlers are the real ones. On the JS backend a
## recording future answers at the next drain (see the helper's header), so
## every check between a question and its answer is made right after the
## question.

import std/[options, strutils, tables, unittest]

import nim_everywhere
import isonim/core/[signals, owner, computation]
import isonim/services/async_value

import helpers/async_recording_service

proc fetchOf(svc: RecordingService): proc(q: string): PlatformFuture[string] =
  result = proc(q: string): PlatformFuture[string] = svc.fetch(q)

proc streamOf(svc: RecordingService): proc(q: string): ServiceStream[string] =
  result = proc(q: string): ServiceStream[string] = svc.stream(q)

proc describe[T](o: Outcome[T]): string =
  ## One line per outcome, so a test can compare the whole sequence.
  case o.kind
  of OutcomeKind.answered: "answered " & $o.value
  of OutcomeKind.failed: "failed " & o.error
  of OutcomeKind.interrupted: "interrupted"
  of OutcomeKind.refused: "refused"

suite "async value: an open stream and inFlight":
  test "an open stream is in flight under ready, and done once it finishes":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(intervalMs = 10, chunkCount = 2)
    svc.streamFailAfter["bad"] = 1
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, svc.streamOf)
    check av.loading
    check av.inFlight
    check not av.done
    ctx.step(10)
    check av.ready                    # one chunk: ready, still delivering
    check av.inFlight
    check not av.done
    ctx.step(10)
    check av.val == @[chunkFor("a", 1), chunkFor("a", 2)]
    check av.inFlight                 # the producer has not finished yet
    ctx.step(10)
    check av.ready
    check not av.inFlight
    check av.done
    # A new question: the finished chunks are not its answer.
    q.val = "b"
    check av.pending
    check av.inFlight
    check not av.done
    ctx.step(30)
    check av.done
    check not av.inFlight
    # A quiet refresh: the old chunks stay shown as the answer while the new
    # stream runs; its first chunk replaces them.
    av.refresh()
    check av.ready
    check av.inFlight
    check av.done
    ctx.step(10)
    check av.val == @[chunkFor("b", 1)]
    check av.inFlight
    check not av.done
    ctx.step(20)
    check av.done
    check not av.inFlight
    # A stream that breaks off has settled.
    q.val = "bad"
    ctx.step(20)
    check av.status == AsyncStatus.failed
    check not av.inFlight
    check not av.done
    av.dispose()

suite "async value: onSettled and Outcome":
  test "an answer settles once per question, in the batch that writes it":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    svc.failures["c"] = "offline"
    let seen = createSignal("")
    var settled: seq[string]
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf,
      onSettled = proc(question: string; outcome: Outcome[string]) =
        settled.add question & ": " & outcome.describe
        seen.val = outcome.describe)
    var frames: seq[(AsyncStatus, string, string)]
    var stop: proc()
    createRoot proc(d: proc()) =
      stop = d
      createEffect proc() = frames.add (av.status, av.val, seen.val)
    check settled.len == 0            # asked, not settled
    ctx.step(10)
    check settled == @["a: answered " & answerFor("a", 1)]
    q.val = "b"
    ctx.step(10)
    q.val = "c"
    ctx.step(10)
    check settled == @["a: answered " & answerFor("a", 1),
                       "b: answered " & answerFor("b", 1),
                       "c: failed offline"]
    # Every frame that shows a settled question shows what its hook wrote:
    # the hook ran in the batch that wrote the outcome.
    for f in frames:
      if f[0] == AsyncStatus.ready:
        check f[2] == "answered " & f[1]
      elif f[0] == AsyncStatus.failed:
        check f[2] == "failed offline"
    # A refresh asks the question again, and settles it once more.
    q.val = "d"
    ctx.step(10)
    av.refresh()
    ctx.step(10)
    check settled[3 .. ^1] == @["d: answered " & answerFor("d", 1),
                                "d: answered " & answerFor("d", 2)]
    # Nothing more without a new asking.
    ctx.step(30)
    check settled.len == 5
    stop()
    av.dispose()

  test "a failure is an outcome and never reaches an error handler":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    svc.failures["bad"] = "boom"
    var handled: seq[string]
    var settled: seq[string]
    let q = createSignal("bad")
    var av: AsyncValue[string]
    var disposeRoot: proc()
    createRoot proc(d: proc()) =
      disposeRoot = d
      onError proc(err: ref CatchableError) = handled.add err.msg
      av = createAsync(proc(): string = q.val,
        proc(question: string): PlatformFuture[string] =
          if question == "raises": raise newException(IOError, "no route")
          if question == "nil": return nil
          svc.fetch(question),
        onSettled = proc(question: string; outcome: Outcome[string]) =
          settled.add question & ": " & outcome.describe)
    ctx.step(10)
    check av.status == AsyncStatus.failed
    check av.error == "boom"
    q.val = "raises"
    check av.error == "no route"
    q.val = "nil"
    check av.status == AsyncStatus.failed
    check settled == @["bad: failed boom", "raises: failed no route",
                       "nil: failed the service returned no future"]
    check handled.len == 0
    disposeRoot()

  test "a stream settles once, when it finishes or breaks off, not per chunk":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService(intervalMs = 10, chunkCount = 3)
    svc.streamFailAfter["bad"] = 2
    var settled: seq[string]
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, svc.streamOf,
      onSettled = proc(question: string; outcome: Outcome[seq[string]]) =
        settled.add question & ": " & outcome.describe)
    ctx.step(30)
    check av.val.len == 3
    check settled.len == 0            # chunks are not the end
    ctx.step(10)
    check settled == @["a: answered " &
                       $(@[chunkFor("a", 1), chunkFor("a", 2), chunkFor("a", 3)])]
    q.val = "bad"
    ctx.step(40)
    check settled[1 .. ^1] == @["bad: failed stream bad broke off"]
    ctx.step(40)
    check settled.len == 2
    av.dispose()

  test "a superseded flight runs no hook":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    svc.failures["x"] = "late failure"
    let streams = newRecordingService(intervalMs = 10, chunkCount = 3)
    var settled: seq[string]
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf,
      onSettled = proc(question: string; outcome: Outcome[string]) =
        settled.add question & ": " & outcome.describe)
    # Replaced before it answered: the service still answers "a" (and fails
    # "x"), and neither reaches the hook.
    q.val = "x"
    q.val = "b"
    ctx.step(20)
    check answerFor("a", 1) in svc.answered
    check settled == @["b: answered " & answerFor("b", 1)]
    # Refreshed over: only the newer call settles.
    av.refresh()
    av.refresh()
    ctx.step(20)
    check settled[1 .. ^1] == @["b: answered " & answerFor("b", 3)]
    # A stream replaced while delivering never settles.
    var streamSettled: seq[string]
    let sq = createSignal("s1")
    let stream = createAsyncStream(proc(): string = sq.val, streams.streamOf,
      onSettled = proc(question: string; outcome: Outcome[seq[string]]) =
        streamSettled.add question & ": " & outcome.describe)
    ctx.step(10)
    sq.val = "s2"
    ctx.step(50)
    check streamSettled.len == 1
    check streamSettled[0].startsWith("s2: answered")
    stream.dispose()
    av.dispose()

  test "a disposed value runs no hook":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let streams = newRecordingService(intervalMs = 10, chunkCount = 2)
    var settled: seq[string]
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf,
      onSettled = proc(question: string; outcome: Outcome[string]) =
        settled.add question)
    av.dispose()
    ctx.step(20)
    check settled.len == 0
    # Ended with its owner.
    var stream: AsyncValue[seq[string]]
    var disposeRoot: proc()
    createRoot proc(d: proc()) =
      disposeRoot = d
      stream = createAsyncStream(proc(): string = q.val, streams.streamOf,
        onSettled = proc(question: string; outcome: Outcome[seq[string]]) =
          settled.add question)
    ctx.step(10)
    disposeRoot()
    ctx.step(30)
    check stream.isDisposed
    check settled.len == 0

  test "a known answer settles as answered; a local write settles nothing":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    var settled: seq[string]
    let q = createSignal("k")
    let av = createAsync(proc(): string = q.val, svc.fetchOf,
      known = proc(question: string): Option[string] =
        if question == "k": some("known:k") else: none(string),
      onSettled = proc(question: string; outcome: Outcome[string]) =
        settled.add question & ": " & outcome.describe)
    check settled == @["k: answered known:k"]
    av.mutate("local:k")
    q.val = "a"
    av.mutate("local:a")
    check settled.len == 1
    ctx.step(10)
    check settled[1 .. ^1] == @["a: answered " & answerFor("a", 1)]
    av.dispose()

  test "onDone is the answered case of the settle hook":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    svc.failures["bad"] = "boom"
    var calls: seq[string]
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf,
      onDone = proc(question, value: string) =
        calls.add("done " & question & " " & value),
      onSettled = proc(question: string; outcome: Outcome[string]) =
        calls.add "settled " & question & " " & $outcome.kind)
    ctx.step(10)
    q.val = "bad"
    ctx.step(10)
    check calls == @["done a " & answerFor("a", 1), "settled a answered",
                     "settled bad failed"]
    av.dispose()

  test "a hook that raises is an error of the graph":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    svc.failures["bad"] = "boom"
    var handled: seq[string]
    let q = createSignal("a")
    var av: AsyncValue[string]
    var disposeRoot: proc()
    createRoot proc(d: proc()) =
      disposeRoot = d
      onError proc(err: ref CatchableError) = handled.add err.msg
      av = createAsync(proc(): string = q.val, svc.fetchOf,
        known = proc(question: string): Option[string] =
          if question == "k": some("known:k") else: none(string),
        onSettled = proc(question: string; outcome: Outcome[string]) =
          raise newException(ValueError, "hook " & question & " " & $outcome.kind))
    ctx.step(10)
    # The handler got the hook's error, once; the outcome it was told of
    # stays written.
    check handled == @["hook a answered"]
    check av.ready
    check av.val == answerFor("a", 1)
    # A failure's hook that raises: the value still shows the service's
    # failure, and the handler gets the hook's error.
    q.val = "bad"
    ctx.step(10)
    check av.status == AsyncStatus.failed
    check av.error == "boom"
    check handled == @["hook a answered", "hook bad failed"]
    # Settled inside the propagation that asked (a known answer).
    q.val = "k"
    check av.ready
    check handled[^1] == "hook k answered"
    check handled.len == 3
    # The value goes on working.
    q.val = "b"
    ctx.step(10)
    check av.val == answerFor("b", 1)
    check handled.len == 4
    disposeRoot()

  test "a hook that raises with no handler is raised to the code that settled":
    # Like any computation's error with no handler: the flush that settled
    # the question raises it, once every queued node has run, to the code
    # whose write started that flush (here, the write that asks a question
    # the ViewModel already knows the answer to).
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let svc = newRecordingService()
    let q = createSignal("a")
    let av = createAsync(proc(): string = q.val, svc.fetchOf,
      known = proc(question: string): Option[string] =
        if question == "k": some("known:k") else: none(string),
      onSettled = proc(question: string; outcome: Outcome[string]) =
        if question == "k": raise newException(ValueError, "unhandled " & question))
    var raised = ""
    try:
      q.val = "k"
    except ValueError as e:
      raised = e.msg
    check raised == "unhandled k"
    check av.ready
    check av.val == "known:k"
    # The graph goes on working.
    q.val = "b"
    ctx.step(10)
    check av.val == answerFor("b", 1)
    av.dispose()
