## Streamed service responses.
##
## Some service operations answer with a sequence of increments rather than
## one value: an assistant's reply arriving a few words at a time, a log tail,
## search results as they are found. A ViewModel subscribes to such a
## `ServiceStream[T]` and renders each increment as it arrives, so the user
## sees the first part of the answer long before the last.
##
## A stream is a function from a sink to a subscription. Subscribing starts
## the work; the sink receives zero or more chunks, then exactly one of
## "done" or "error", and nothing after that. `cancel` on the subscription
## stops delivery and reaches the producer (`onCancel`), which stops its own
## work — a stand-in's timer, a real service's request.
##
## The same shape works on every backend: no async iterators, only closures
## and the clock from nim-everywhere, so a `FakeAsyncContext` drives streams in
## tests exactly as it drives futures.
##
## Producers build streams with `newServiceStream`, which hands them a
## `StreamEmitter` that enforces the protocol (no chunk after the end, one end
## only, nothing after a cancel):
##
## .. code-block:: nim
##   let reply = newServiceStream[string](proc(e: StreamEmitter[string]) =
##     e.emit("Hel")
##     e.emit("lo")
##     e.finish())
##
## `pacedStream` turns fixture data into a stream delivered at a chosen
## pacing, which is what a stand-in service needs; `tee` lets a service
## observe the chunks it forwards (to persist the complete reply, say).

import std/unicode

import nim_everywhere/time

type
  StreamSink*[T] = object
    ## What a subscriber receives. Any field may be nil.
    onChunk*: proc(chunk: T) {.closure.}
    onDone*: proc() {.closure.}
    onError*: proc(message: string) {.closure.}

  StreamSubscription* = ref object
    ## The subscriber's handle on a running stream.
    ended: bool
    cancelled: bool
    cancelHooks: seq[proc() {.closure.}]

  ServiceStream*[T] = proc(sink: StreamSink[T]): StreamSubscription {.closure.}
    ## Subscribing starts the stream.

  StreamEmitter*[T] = ref object
    ## The producer's side of one subscription.
    sink: StreamSink[T]
    subscription*: StreamSubscription

proc isActive*(s: StreamSubscription): bool =
  ## True until the stream ends or is cancelled.
  not s.ended and not s.cancelled

proc isCancelled*(s: StreamSubscription): bool = s.cancelled
proc isEnded*(s: StreamSubscription): bool = s.ended

proc onCancel*(s: StreamSubscription; hook: proc() {.closure.}) =
  ## Register producer clean-up to run when the subscriber cancels.
  s.cancelHooks.add hook

proc cancel*(s: StreamSubscription) =
  ## Stop the stream. The sink receives nothing more; the producer's
  ## `onCancel` hooks run once. Ignored after the stream has ended.
  if s.isNil or not s.isActive: return
  s.cancelled = true
  # Swap rather than copy-then-clear: under --mm:refc a `let` copy of a seq
  # may share the buffer that setLen(0) then empties.
  var hooks: seq[proc() {.closure.}]
  swap(hooks, s.cancelHooks)
  for hook in hooks: hook()

proc newStreamEmitter*[T](sink: StreamSink[T]): StreamEmitter[T] =
  StreamEmitter[T](sink: sink, subscription: StreamSubscription())

proc isActive*[T](e: StreamEmitter[T]): bool = e.subscription.isActive

proc onCancel*[T](e: StreamEmitter[T]; hook: proc() {.closure.}) =
  e.subscription.onCancel(hook)

proc emit*[T](e: StreamEmitter[T]; chunk: T) =
  ## Deliver one chunk. Ignored once the stream has ended or was cancelled.
  if not e.isActive: return
  if e.sink.onChunk != nil: e.sink.onChunk(chunk)

proc finish*[T](e: StreamEmitter[T]) =
  ## End the stream successfully. Ignored if it already ended.
  if not e.isActive: return
  e.subscription.ended = true
  e.subscription.cancelHooks.setLen(0)
  if e.sink.onDone != nil: e.sink.onDone()

proc fail*[T](e: StreamEmitter[T]; message: string) =
  ## End the stream with an error. Ignored if it already ended.
  if not e.isActive: return
  e.subscription.ended = true
  e.subscription.cancelHooks.setLen(0)
  if e.sink.onError != nil: e.sink.onError(message)

proc newServiceStream*[T](start: proc(e: StreamEmitter[T]) {.closure.}):
    ServiceStream[T] =
  ## A stream whose producer is `start`, run once per subscription with a
  ## fresh emitter. `start` may emit synchronously or keep the emitter and
  ## emit later.
  result = proc(sink: StreamSink[T]): StreamSubscription =
    let e = newStreamEmitter[T](sink)
    start(e)
    e.subscription

proc subscribe*[T](s: ServiceStream[T];
                   onChunk: proc(chunk: T) {.closure.};
                   onDone: proc() {.closure.} = nil;
                   onError: proc(message: string) {.closure.} = nil):
    StreamSubscription =
  ## Convenience for `s(StreamSink[T](...))`.
  s(StreamSink[T](onChunk: onChunk, onDone: onDone, onError: onError))

proc pacedStream*[T](chunks: seq[T]; firstDelayMs = 0; intervalMs = 0;
                     failAfter = -1; failure = "stream failed"):
    ServiceStream[T] =
  ## Deliver `chunks` one at a time: the first after `firstDelayMs`, each
  ## later one `intervalMs` after the previous, then finish. With
  ## `failAfter >= 0` the stream fails after that many chunks instead.
  ## Delivery is always asynchronous (on the clock), even at zero delays, so
  ## a subscriber sees the same order of events whatever the pacing.
  let data = chunks
  result = newServiceStream[T](proc(e: StreamEmitter[T]) =
    var timer: TimerHandle
    var index = 0
    e.onCancel(proc() = cancelTimer(timer))
    proc step() =
      if not e.isActive: return
      if failAfter >= 0 and index >= failAfter:
        e.fail(failure)
        return
      if index >= data.len:
        e.finish()
        return
      e.emit(data[index])
      inc index
      if index >= data.len and not (failAfter >= 0 and index >= failAfter):
        e.finish()
        return
      timer = scheduleAt(intervalMs, step)
    timer = scheduleAt(firstDelayMs, step))

proc chunkText*(text: string; chunkRunes: int): seq[string] =
  ## Split `text` into pieces of at most `chunkRunes` characters (never
  ## splitting a UTF-8 sequence). `chunkRunes <= 0` gives the whole text as
  ## one piece.
  if text.len == 0: return @[]
  if chunkRunes <= 0: return @[text]
  var current = ""
  var count = 0
  for r in text.runes:
    current.add r.toUTF8
    inc count
    if count == chunkRunes:
      result.add current
      current = ""
      count = 0
  if current.len > 0: result.add current

proc tee*[T](s: ServiceStream[T]; observer: StreamSink[T]): ServiceStream[T] =
  ## A stream that forwards `s` to its subscriber and also reports every
  ## event to `observer` (before the subscriber sees it). Cancelling the
  ## returned stream cancels `s`; the observer then gets neither done nor an
  ## error.
  result = proc(sink: StreamSink[T]): StreamSubscription =
    let outer = newStreamEmitter[T](sink)
    let inner = s(StreamSink[T](
      onChunk: proc(chunk: T) =
        if not outer.isActive: return
        if observer.onChunk != nil: observer.onChunk(chunk)
        outer.emit(chunk),
      onDone: proc() =
        if not outer.isActive: return
        if observer.onDone != nil: observer.onDone()
        outer.finish(),
      onError: proc(message: string) =
        if not outer.isActive: return
        if observer.onError != nil: observer.onError(message)
        outer.fail(message)))
    outer.onCancel(proc() = inner.cancel())
    outer.subscription
