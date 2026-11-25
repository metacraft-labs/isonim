## A recording service for the async value tests.
##
## MOCK POLICY (workspace rule: every mock justified in the header of the
## tests that use it, which repeat this). The tests need a service that
## answers chosen questions at chosen times, fails on cue, and reports what a
## real service would not: every question it was asked, every cancel that
## reached it, and how many of its timers are still armed. Those records are
## the assertions themselves ("the old stream was cancelled at the
## producer", "no timer is left after dispose"), so the producer has to keep
## them. Everything else is real: futures are `Deferred`s settled by timers
## on the nim-everywhere clock (driven by `FakeAsyncContext`), streams are
## `newServiceStream` with the real protocol, and the primitive under test,
## its signals and its owner are the real ones.
##
## The JS backend's futures are promises, whose callbacks run on a later
## microtask that a synchronous test cannot wait for. So by default a JS
## future answer is an already-settled future (`newCompletedFuture` /
## `newFailedFuture`): its callback is queued and runs at the next
## `drainPlatformCallbacks`, that is, at the test's next step, whatever
## latency was asked for, and the order of answers is the order of the
## questions. A service made with `timedFutures = true` answers on JS as on
## C, by a `Deferred` settled by a timer after the latency; an asynchronous
## test drives it with `stepAsync`, which lets the promise callbacks run
## after each millisecond (`tests/test_async_timing_js.nim`). Streams use
## timers on both backends and behave the same.

import std/[strutils, tables]

import nim_everywhere
import nim_everywhere/async_compat
import isonim/services/streams
import isonim/services/deferred

export streams

type
  RecordingService* = ref object
    latencyMs*: int                  ## Default future latency (C backend).
    latencies*: Table[string, int]   ## Per question.
    failures*: Table[string, string] ## Questions whose answer is an error.
    intervalMs*: int                 ## Stream pacing: first chunk and each next.
    chunkCount*: int                 ## Chunks per stream answer.
    streamFailAfter*: Table[string, int]  ## Fail a stream after n chunks.
    asks*: seq[string]               ## Every question asked, in order.
    cancels*: seq[string]            ## Every cancel that reached the service.
    armedTimers*: int                ## Timers scheduled, neither fired nor cancelled.
    answered*: seq[string]           ## Every future answer it delivered.
    timedFutures*: bool              ## Futures settle after their latency
                                     ## (always on C; on JS, see the header).

proc newRecordingService*(latencyMs = 10; intervalMs = 10;
                          chunkCount = 3;
                          timedFutures = not defined(js)): RecordingService =
  RecordingService(latencyMs: latencyMs, intervalMs: intervalMs,
                   chunkCount: chunkCount,
                   timedFutures: timedFutures or not defined(js))

proc countOf(svc: RecordingService; question: string): int =
  for q in svc.asks:
    if q == question: inc result

proc answerFor*(question: string; n: int): string =
  ## The answer to the `n`th asking of `question`.
  "answer:" & question & "#" & $n

proc questionOf*(answer: string): string =
  ## The question an answer (`answerFor`) or chunk (`chunkFor`) belongs to.
  if answer.startsWith("answer:"):
    answer["answer:".len ..< answer.rfind('#')]
  else:
    answer[0 ..< answer.rfind('.')]

proc chunkFor*(question: string; index: int): string =
  question & "." & $index

proc arm(svc: RecordingService; afterMs: int; fire: proc()): TimerHandle =
  inc svc.armedTimers
  scheduleAt(afterMs, proc() =
    dec svc.armedTimers
    fire())

proc disarm(svc: RecordingService; timer: var TimerHandle) =
  if timer != nil:
    cancelTimer(timer)
    timer = nil
    dec svc.armedTimers

type FutureCall = ref object
  ## One future call in flight, so a cancel can find its timer.
  question: string
  timer: TimerHandle

var calls: seq[FutureCall]

proc fetch*(svc: RecordingService; question: string): PlatformFuture[string] =
  ## Answers `answerFor(question, n)` (or fails with the scripted message)
  ## after the question's latency.
  svc.asks.add question
  let answer = answerFor(question, svc.countOf(question))
  let failure = svc.failures.getOrDefault(question, "")
  if not svc.timedFutures:
    svc.answered.add answer
    if failure.len > 0: return newFailedFuture[string](failure)
    return newCompletedFuture(answer)
  let d = newDeferred[string]("recording")
  let call = FutureCall(question: question)
  calls.add call
  call.timer = svc.arm(svc.latencies.getOrDefault(question, svc.latencyMs),
    proc() =
      call.timer = nil
      if failure.len > 0: d.reject(failure)
      else:
        svc.answered.add answer
        d.resolve(answer))
  d.future

proc cancelFetch*(svc: RecordingService; question: string) =
  ## The service's way to stop a call: records the cancel and, on the C
  ## backend, stops the timer of the oldest call for `question` still in
  ## flight, so its future never settles.
  svc.cancels.add question
  for call in calls:
    if call.question == question and call.timer != nil:
      svc.disarm(call.timer)
      break

proc stream*(svc: RecordingService; question: string): ServiceStream[string] =
  ## Streams `chunkFor(question, 1 .. chunkCount)`, one every `intervalMs`,
  ## then finishes (or fails after the scripted number of chunks).
  svc.asks.add question
  let failAfter = svc.streamFailAfter.getOrDefault(question, -1)
  newServiceStream[string](proc(e: StreamEmitter[string]) =
    var timer: TimerHandle
    var index = 0
    e.onCancel(proc() =
      svc.cancels.add question
      svc.disarm(timer))
    proc next() =
      timer = nil
      if not e.isActive: return
      if failAfter >= 0 and index >= failAfter:
        e.fail("stream " & question & " broke off")
        return
      if index >= svc.chunkCount:
        e.finish()
        return
      inc index
      e.emit(chunkFor(question, index))
      timer = svc.arm(svc.intervalMs, next)
    timer = svc.arm(svc.intervalMs, next))

proc step*(ctx: FakeAsyncContext; ms: int) =
  ## Advance one millisecond at a time, delivering future callbacks too.
  for _ in 0 ..< ms:
    ctx.advance(1)
    ctx.runPending()
    drainPlatformCallbacks()
    ctx.runPending()

when defined(js):
  proc microtaskTurn(): Future[void] =
    ## A promise that is already resolved: awaiting it lets the promise
    ## callbacks queued before it run first.
    newPromise(proc(resolve: proc()) = resolve())

  proc stepAsync*(ctx: FakeAsyncContext; ms: int) {.async.} =
    ## `step` for promise futures: after each millisecond, awaits so that
    ## the callbacks of the promises settled in it run, then delivers what
    ## they queued.
    for _ in 0 ..< ms:
      ctx.advance(1)
      ctx.runPending()
      drainPlatformCallbacks()
      for _ in 0 ..< 3:
        await microtaskTurn()
      drainPlatformCallbacks()
      ctx.runPending()
