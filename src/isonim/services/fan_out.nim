## One answer built from many service calls, as a stream.
##
## A screen sometimes needs one call per item: the details of each of the
## last twenty runs, the thumbnail of each file in a folder. Knowing when all
## of them have answered usually means a hand-written counter, decremented in
## every callback, plus a check in each callback that the work is still
## wanted. `fanOut` writes that once:
##
## .. code-block:: nim
##   # Inside the ViewModel's constructor (`withViewModel`):
##   vm.runs = createAsyncStream(
##     proc(): string = vm.briefId.val,
##     proc(brief: string): ServiceStream[FanOutChunk[RunDetails]] =
##       fanOut(services.recentRunIds(brief), services.fetchRun, limit = 6))
##   # vm.runs.val holds the chunks so far; vm.runs.done says all have come.
##
## Subscribing starts the calls, one per item. Each call's outcome arrives
## as a chunk (`FanOutChunk`) that carries the item's index and its
## `Outcome`: `answered` with the answer, or `failed` with the message. The
## stream finishes once every call has settled.
##
## Behaviour:
##
## - *Settle order.* Chunks arrive in the order the calls settle, not the
##   order of the items; the index says which item a chunk belongs to. Sort
##   by it when the order of the items matters.
## - *A failure is a chunk.* A call whose future fails, that raises a
##   `CatchableError`, or that returns no future gives its item a `failed`
##   chunk. The stream does not fail, the other calls go on, and the answers
##   that arrived are kept. (This is the difference from an all-or-nothing
##   join, which drops every answer when one call fails.) A `Defect` raised
##   by a call is a programming error and propagates.
## - *Exactly once.* Every item yields exactly one chunk, and the stream
##   finishes exactly once, after the last chunk, unless it is cancelled
##   first. An empty list of items finishes at once, during the
##   subscription.
## - *Cancelling.* Cancelling the subscription (an async value does it when
##   its question changes, on a refresh and when it ends) delivers nothing
##   more and starts no further call. A future cannot be stopped, so the
##   calls already running go on to their end and their answers are
##   ignored, unless the service can stop a call: then pass `cancel`, which
##   is called with each item whose call is still running.
## - *Limit.* With `limit` above zero, at most that many calls run at once;
##   the others start in the order of the items as running calls settle.
##   The limit changes only how many run together, never what is emitted.
##   There is no retry.
##
## Like the other stream producers, it uses only closures and futures, so a
## `FakeAsyncContext` drives it in tests on every backend. Nothing in the
## reactive core or the renderers imports this module, so a page that does
## not use it carries none of its code. Not yet a stable API.

import nim_everywhere/async_compat

import ./streams
import ./async_value

export streams
export async_value.Outcome, async_value.OutcomeKind

type
  FanOutChunk*[T] = object
    ## The outcome of one item's call.
    index*: int
      ## The item's position in the list given to `fanOut`.
    outcome*: Outcome[T]
      ## How its call settled: `answered` with the answer, or `failed` with
      ## the message.

  FanOutRun[I, T] = ref object
    ## The state of one subscription.
    items: seq[I]
    fetch: proc(item: I): PlatformFuture[T]
    cancel: proc(item: I)
    limit: int
    next: int             ## The next item to start.
    running: int          ## Calls started whose outcome has not arrived.
    settled: int          ## Items whose chunk has been emitted (or dropped).
    open: seq[bool]       ## Per item: started, and not settled.
    pumping: bool         ## `pump` is on the stack: a nested call returns.

proc `==`*[T](a, b: FanOutChunk[T]): bool =
  ## Equal index and equal outcome (same kind, and the same answer or the
  ## same message). An async value compares the chunks it holds with it.
  if a.index != b.index or a.outcome.kind != b.outcome.kind: return false
  case a.outcome.kind
  of OutcomeKind.answered: a.outcome.value == b.outcome.value
  of OutcomeKind.failed: a.outcome.error == b.outcome.error
  of OutcomeKind.interrupted, OutcomeKind.refused: true

proc answeredChunk[T](index: int; value: T): FanOutChunk[T] =
  FanOutChunk[T](index: index,
                 outcome: Outcome[T](kind: OutcomeKind.answered, value: value))

proc failedChunk[T](index: int; message: string): FanOutChunk[T] =
  FanOutChunk[T](index: index,
                 outcome: Outcome[T](kind: OutcomeKind.failed, error: message))

proc pump[I, T](run: FanOutRun[I, T]; e: StreamEmitter[FanOutChunk[T]])

proc settle[I, T](run: FanOutRun[I, T]; e: StreamEmitter[FanOutChunk[T]];
                  index: int; chunk: FanOutChunk[T]; wasRunning: bool) =
  ## Item `index` has its outcome: emit it, then start what the freed slot
  ## allows and finish when it was the last.
  if not run.open[index] and wasRunning: return
  if wasRunning:
    run.open[index] = false
    dec run.running
  inc run.settled
  e.emit(chunk)
  run.pump(e)

proc start[I, T](run: FanOutRun[I, T]; e: StreamEmitter[FanOutChunk[T]];
                 index: int) =
  ## Call the service for item `index`.
  let item = run.items[index]
  var future: PlatformFuture[T]
  try:
    future = run.fetch(item)
  except CatchableError as error:
    run.settle(e, index, failedChunk[T](index, error.msg), wasRunning = false)
    return
  if future.isNil:
    run.settle(e, index, failedChunk[T](index, "the service returned no future"),
               wasRunning = false)
    return
  run.open[index] = true
  inc run.running
  if not e.isActive:
    # Cancelled while calling (a call that reaches back into the
    # subscriber): the call was made and is no longer wanted.
    run.open[index] = false
    if run.cancel != nil: run.cancel(item)
  # Subscribed even when cancelled (the callbacks then deliver nothing), so
  # a failure of the unwanted call is still observed and is not an
  # unhandled rejection on the JS backend.
  future.onComplete(
    proc(value: T) =
      if not e.isActive: return
      run.settle(e, index, answeredChunk[T](index, value), wasRunning = true),
    proc(message: string) =
      if not e.isActive: return
      run.settle(e, index, failedChunk[T](index, message), wasRunning = true))

proc pump[I, T](run: FanOutRun[I, T]; e: StreamEmitter[FanOutChunk[T]]) =
  ## Start items while the limit allows, then finish if every item has
  ## settled. A call that fails at once settles inside `start` and reaches
  ## here again; the outer loop does its work, so the nested call returns.
  ## Only this loop finishes the stream.
  if run.pumping: return
  run.pumping = true
  try:
    while e.isActive and run.next < run.items.len and
        (run.limit <= 0 or run.running < run.limit):
      let index = run.next
      inc run.next
      run.start(e, index)
  finally:
    run.pumping = false
  if e.isActive and run.settled == run.items.len:
    e.finish()

proc fanOut*[I, T](items: openArray[I];
                   fetch: proc(item: I): PlatformFuture[T];
                   limit = 0; cancel: proc(item: I) = nil):
    ServiceStream[FanOutChunk[T]] =
  ## A stream that calls `fetch` once per item and emits each call's outcome
  ## as a `FanOutChunk` carrying the item's index, in the order the calls
  ## settle, then finishes (see the module documentation). Each subscription
  ## starts the calls again.
  ##
  ## Invariants: every item yields exactly one chunk and the stream finishes
  ## exactly once, unless it is cancelled; a failed call is a `failed` chunk,
  ## never a failure of the stream; an empty `items` finishes at once.
  ## `limit` above zero bounds how many calls run at once (zero or below:
  ## all at once) and changes nothing else. After a cancel nothing is
  ## delivered and nothing more is started; `cancel`, when given, is called
  ## with each item whose call was still running, so the service can stop
  ## it; without it those calls run to their end, ignored.
  ##
  ## Known limits: chunks are in settle order, not item order; there is no
  ## retry; a call is stopped only through `cancel`.
  let data = @items
  result = newServiceStream[FanOutChunk[T]](
    proc(e: StreamEmitter[FanOutChunk[T]]) =
      let run = FanOutRun[I, T](items: data, fetch: fetch, cancel: cancel,
                                limit: limit, open: newSeq[bool](data.len))
      e.onCancel(proc() =
        # The emitter already drops anything delivered from now on; stop
        # the calls still running when the service can.
        for index in 0 ..< run.open.len:
          if run.open[index]:
            run.open[index] = false
            if run.cancel != nil: run.cancel(run.items[index]))
      run.pump(e))
