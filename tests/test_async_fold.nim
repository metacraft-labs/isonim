## A stream folded into an accumulator (`isonim/services/async_value`,
## `createAsyncStream` with `init` and `fold`), under fake time: each chunk
## is folded in place into the accumulator the current question's `init`
## built, and the value's readers hear each chunk once; a fact about the
## call (the request was admitted) is a chunk the fold stores, and a stream
## that ends without its terminal chunk is `done` with an accumulator that
## lacks it, from which the ViewModel derives "interrupted"; the first chunk
## of a new question, or of a refresh, starts a fresh accumulator; a stopped
## flight (replaced, finished or disposed) folds nothing; an `init` or
## `fold` that raises fails the question and stops the stream. And the cost
## of a long stream: 5 000 chunks, read through `withVal`, cost time linear
## in the number of chunks, measured against a quarter of them, so a fold
## that copies the accumulator on each chunk fails the bound.
##
## MOCK POLICY (workspace rule: every mock justified in the header). The
## streams are real `newServiceStream`s whose emitters the test drives by
## hand (`ManualStream`), so a test says exactly which chunk arrives when
## and can emit 5 000 of them with no timer per chunk; the recording kept
## (the questions asked, the cancels that reached the producer) is what the
## tests assert, which a real service would not report. One test uses a
## raw `ServiceStream` that ignores its cancellation and keeps calling the
## sink, because its point is a producer that misbehaves that way (a
## callback client that cannot be stopped): the primitive must fold
## nothing from it once its flight is stopped. The primitive, its signals,
## effects and owners are the real ones. The timing test reads the host's
## monotonic clock (`std/monotimes`), not the fake one, because the cost of
## folding is what it measures; it compares two runs on the same host in
## the same process, so the bound is a ratio, not a duration.

import std/[monotimes, options, strutils, times, unittest]

import nim_everywhere
import isonim/core/[signals, owner, computation]
import isonim/services/async_value

import helpers/async_recording_service

type
  ManualStream[C] = ref object
    ## A producer the test drives: one emitter per subscription.
    emitters: seq[StreamEmitter[C]]
    asks: seq[string]
    cancels: seq[string]

proc newManualStream[C](): ManualStream[C] = ManualStream[C]()

proc callOf[C](m: ManualStream[C]): proc(q: string): ServiceStream[C] =
  result = proc(q: string): ServiceStream[C] =
    m.asks.add q
    newServiceStream[C](proc(e: StreamEmitter[C]) =
      m.emitters.add e
      e.onCancel(proc() = m.cancels.add q))

proc last[C](m: ManualStream[C]): StreamEmitter[C] = m.emitters[^1]

type
  ChunkKind = enum admitted, text, stopped
  Chunk = object
    ## What a reply stream carries: a fact about the call (`admitted`, with
    ## the request's place in the queue), text, and a terminal chunk
    ## (`stopped`, with the reason the producer stopped).
    case kind: ChunkKind
    of admitted: place: int
    of text: text: string
    of stopped: reason: string

  Reply = object
    ## The accumulator: what the ViewModel shows of one reply.
    question: string
    place: int        ## -1 until the call is admitted.
    text: string
    chunks: int       ## Chunks folded into this accumulator.
    reason: string    ## Why the producer stopped; "" without the terminal chunk.
    ended: bool       ## The terminal chunk arrived.

proc admittedAt(place: int): Chunk = Chunk(kind: admitted, place: place)
proc textOf(s: string): Chunk = Chunk(kind: text, text: s)
proc stoppedFor(reason: string): Chunk = Chunk(kind: stopped, reason: reason)

type FoldLog = ref object
  ## What `init` and `fold` were called with.
  inits: seq[string]
  folds: seq[string]       ## "<question>:<chunks before the fold>"

proc replyInit(log: FoldLog): proc(q: string): Reply =
  result = proc(q: string): Reply =
    log.inits.add q
    Reply(question: q, place: -1)

proc replyFold(log: FoldLog): proc(acc: var Reply; c: Chunk) =
  result = proc(acc: var Reply; c: Chunk) =
    log.folds.add acc.question & ":" & $acc.chunks
    inc acc.chunks
    case c.kind
    of admitted: acc.place = c.place
    of text:
      if c.text == "boom": raise newException(ValueError, "cannot fold boom")
      acc.text.add c.text
    of stopped:
      acc.reason = c.reason
      acc.ended = true

suite "async value: a stream folded into an accumulator":
  test "chunks fold in place into the question's accumulator, one notification each":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let m = newManualStream[Chunk]()
    let log = FoldLog()
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, m.callOf,
                               log.replyInit, log.replyFold)
    var seenByWithVal: seq[int]
    var seenByVal: seq[string]
    var stopWatching: proc()
    createRoot proc(d: proc()) =
      stopWatching = d
      createEffect proc() =
        seenByWithVal.add av.withVal(proc(r: Reply): int = r.chunks)
      createEffect proc() =
        seenByVal.add av.val.text
    check av.loading
    check log.inits.len == 0          # no accumulator before the first chunk
    m.last.emit(admittedAt(2))
    check av.ready
    check not av.done
    m.last.emit(textOf("Hel"))
    m.last.emit(textOf("lo"))
    check av.val.text == "Hello"
    check av.val.place == 2
    # One accumulator, built once, each fold given the chunks before it.
    check log.inits == @["a"]
    check log.folds == @["a:0", "a:1", "a:2"]
    # Each reader ran once per chunk (and once at the start), no more.
    check seenByWithVal == @[0, 1, 2, 3]
    check seenByVal == @["", "", "Hel", "Hello"]
    m.last.finish()
    check av.done
    check av.val.chunks == 3
    # Finishing adds nothing to the value: its readers do not run again.
    check seenByWithVal == @[0, 1, 2, 3]
    check seenByVal.len == 4
    stopWatching()
    av.dispose()

  test "a fact is a chunk the fold stores; a stream ended without its terminal chunk lacks it":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let m = newManualStream[Chunk]()
    let log = FoldLog()
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, m.callOf,
                               log.replyInit, log.replyFold)
    # What a ViewModel derives: the reply ended without saying why.
    let interrupted = createMemo(proc(): bool =
      av.done and not av.withVal(proc(r: Reply): bool = r.ended))
    m.last.emit(admittedAt(3))
    check av.val.place == 3           # the fact is in the accumulator
    m.last.emit(textOf("Hi"))
    m.last.emit(stoppedFor("end of turn"))
    m.last.finish()
    check av.done
    check av.val.ended
    check av.val.reason == "end of turn"
    check not interrupted.val
    # The producer ends the next reply without its terminal chunk.
    q.val = "b"
    m.last.emit(admittedAt(1))
    m.last.emit(textOf("Partial"))
    check not interrupted.val         # still delivering
    m.last.finish()
    check av.ready
    check av.done
    check av.error == ""
    check av.val.question == "b"
    check av.val.place == 1
    check av.val.text == "Partial"
    check not av.val.ended
    check av.val.reason == ""
    check interrupted.val
    av.dispose()

  test "the first chunk of a new question, or of a refresh, starts a fresh accumulator":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let m = newManualStream[Chunk]()
    let log = FoldLog()
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, m.callOf,
                               log.replyInit, log.replyFold)
    m.last.emit(textOf("a1"))
    m.last.emit(textOf("a2"))
    m.last.finish()
    check av.val.text == "a1a2"
    q.val = "b"
    # The old accumulator stays shown until the new stream's first chunk.
    check av.pending
    check av.val.text == "a1a2"
    check log.inits == @["a"]
    m.last.emit(textOf("b1"))
    check av.ready
    check av.val.question == "b"
    check av.val.text == "b1"
    check av.val.chunks == 1
    check log.inits == @["a", "b"]
    m.last.finish()
    # A quiet refresh keeps the shown accumulator until its first chunk.
    av.refresh()
    check av.ready
    check av.val.text == "b1"
    m.last.emit(textOf("again"))
    check av.val.text == "again"
    check av.val.chunks == 1
    check log.inits == @["a", "b", "b"]
    check log.folds == @["a:0", "a:1", "b:0", "b:0"]
    # A stream that finishes with no chunk answers with a fresh, empty
    # accumulator.
    q.val = "c"
    m.last.finish()
    check av.done
    check av.val.question == "c"
    check av.val.chunks == 0
    check log.inits == @["a", "b", "b", "c"]
    av.dispose()

  test "a stopped flight folds nothing":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    # A producer that cannot be stopped: it keeps every sink and ignores
    # the cancellation.
    var sinks: seq[StreamSink[Chunk]]
    let call = proc(q: string): ServiceStream[Chunk] =
      result = proc(sink: StreamSink[Chunk]): StreamSubscription =
        sinks.add sink
        StreamSubscription()
    let log = FoldLog()
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, call,
                               log.replyInit, log.replyFold)
    sinks[0].onChunk(textOf("a1"))
    check log.folds == @["a:0"]
    q.val = "b"                       # a's flight is stopped
    sinks[0].onChunk(textOf("late"))
    check log.folds == @["a:0"]
    check av.val.text == "a1"
    check av.pending
    sinks[1].onChunk(textOf("b1"))
    sinks[1].onDone()
    check av.done
    # A finished flight folds nothing either.
    sinks[1].onChunk(textOf("after the end"))
    check log.folds == @["a:0", "b:0"]
    check av.val.text == "b1"
    # Nor does a refreshed-over one, nor one whose value has ended.
    av.refresh()
    sinks[1].onChunk(textOf("refreshed over"))
    check log.folds == @["a:0", "b:0"]
    sinks[2].onChunk(textOf("b2"))
    check log.folds == @["a:0", "b:0", "b:0"]
    av.dispose()
    sinks[2].onChunk(textOf("disposed"))
    check log.folds == @["a:0", "b:0", "b:0"]
    check log.inits == @["a", "b", "b"]
    check av.val.text == "b2"

  test "known answers, local writes and the settle hook carry the accumulator":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let m = newManualStream[Chunk]()
    let log = FoldLog()
    var settled: seq[string]
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, m.callOf,
      log.replyInit, log.replyFold,
      known = proc(question: string): Option[Reply] =
        if question == "k": some(Reply(question: "k", text: "cached"))
        else: none(Reply),
      onSettled = proc(question: string; outcome: Outcome[Reply]) =
        case outcome.kind
        of OutcomeKind.answered:
          settled.add question & " answered " & outcome.value.text
        of OutcomeKind.failed: settled.add question & " failed " & outcome.error
        else: settled.add question & " other")
    m.last.emit(textOf("one"))
    # A local write on a stream still delivering is folded into further on.
    var edited = av.value
    edited.text = "local+"
    av.mutate(edited)
    check av.local
    check av.val.text == "local+"
    m.last.emit(textOf("two"))
    check not av.local
    check av.val.text == "local+two"
    check settled.len == 0            # chunks are not the end
    m.last.finish()
    check settled == @["a answered local+two"]
    q.val = "k"
    check av.done
    check av.val.text == "cached"
    check m.asks == @["a"]            # no call for a known answer
    check settled[^1] == "k answered cached"
    check log.inits == @["a"]
    av.dispose()

  test "an init or fold that raises fails the question and stops the stream":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let m = newManualStream[Chunk]()
    let log = FoldLog()
    var settled: seq[string]
    let q = createSignal("a")
    let av = createAsyncStream(proc(): string = q.val, m.callOf,
      proc(question: string): Reply =
        if question == "no init": raise newException(IOError, "no accumulator")
        log.replyInit()(question),
      log.replyFold,
      onSettled = proc(question: string; outcome: Outcome[Reply]) =
        if outcome.kind == OutcomeKind.failed:
          settled.add question & ": " & outcome.error)
    # A View that reads only the accumulator.
    var seenChunks: seq[int]
    var stopWatching: proc()
    createRoot proc(d: proc()) =
      stopWatching = d
      createEffect proc() =
        seenChunks.add av.withVal(proc(r: Reply): int = r.chunks)
    m.last.emit(textOf("ok"))
    check seenChunks == @[0, 1]
    m.last.emit(textOf("boom"))
    check av.status == AsyncStatus.failed
    check av.error == "cannot fold boom"
    check av.val.text == "ok"          # what was folded before stays shown
    # The fold counted the chunk before it raised: that change stays shown
    # too, and the View that reads the accumulator hears it.
    check av.val.chunks == 2
    check seenChunks == @[0, 1, 2]
    check not av.inFlight
    check m.cancels == @["a"]          # stopped at the producer
    m.last.emit(textOf("ignored"))
    check av.val.text == "ok"
    check settled == @["a: cannot fold boom"]
    q.val = "no init"
    m.last.emit(textOf("first"))
    check av.status == AsyncStatus.failed
    check av.error == "no accumulator"
    check m.cancels == @["a", "no init"]
    check settled[^1] == "no init: no accumulator"
    stopWatching()
    av.dispose()

proc runLongStream(n: int): tuple[seconds: float; runs: int] =
  ## Seconds to deliver `n` chunks to a default-fold stream whose View
  ## reads the chunk count through `withVal` after each one, and how many
  ## times the View ran.
  let m = newManualStream[string]()
  let av = createAsyncStream(proc(): string = "long", m.callOf)
  var stopWatching: proc()
  var lastLen = 0
  var runs = 0
  createRoot proc(d: proc()) =
    stopWatching = d
    createEffect proc() =
      inc runs
      lastLen = av.withVal(proc(chunks: seq[string]): int = chunks.len)
  let e = m.last
  let started = getMonoTime()
  for i in 1 .. n:
    e.emit("chunk")
  e.finish()
  result.seconds = (getMonoTime() - started).inNanoseconds.float / 1e9
  result.runs = runs
  doAssert lastLen == n
  doAssert av.done
  stopWatching()
  av.dispose()

suite "async value: the cost of a long stream":
  test "a 5 000-chunk stream costs linear time: no copy per chunk":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    const big = 5_000
    const small = big div 4
    # The fastest of three runs of each size, so a pause of the host or the
    # collector in one run does not decide the ratio.
    var tBig = Inf
    var tSmall = Inf
    for attempt in 1 .. 3:
      let s = runLongStream(small)
      tSmall = min(tSmall, s.seconds)
      check s.runs == small + 1       # one View run per chunk, and the first
      let b = runLongStream(big)
      tBig = min(tBig, b.seconds)
      check b.runs == big + 1
    let ratio = tBig / tSmall
    echo "long stream: ", small, " chunks ", formatFloat(tSmall * 1000, ffDecimal, 2),
      " ms, ", big, " chunks ", formatFloat(tBig * 1000, ffDecimal, 2),
      " ms, ratio ", formatFloat(ratio, ffDecimal, 2)
    # Linear: four times the chunks cost about four times the time. A fold
    # that copies the accumulator on each chunk costs about sixteen times.
    check ratio < 8.0
