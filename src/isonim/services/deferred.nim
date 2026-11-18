## A future that is settled later by whoever holds it, on every backend.
##
## Services hand out `PlatformFuture[T]`s. Code that settles one at a time of
## its own choosing (a stand-in replying after a delay, the network simulator
## delivering a response) needs the producer side of a future: something to
## call `resolve` or `reject` on. The native backends have that built in
## (`newFuture` + `complete` / `fail`); the JS backend's futures are promises,
## whose resolve and reject functions only exist inside the executor. This
## module gives both the same shape:
##
## .. code-block:: nim
##   let d = newDeferred[int]("answer")
##   discard scheduleAt(50, proc() = d.resolve(42))
##   return d.future
##
## A deferred is settled at most once; later calls are ignored, so a
## cancellation and a late result cannot both reach the consumer.

import nim_everywhere/async_compat

type
  Deferred*[T] = ref object
    future*: PlatformFuture[T]
    settled: bool
    when defined(js):
      resolveFn: proc(value: T)
      rejectFn: proc(message: cstring)

proc newDeferred*[T](name = "deferred"): Deferred[T] =
  ## A pending future and the means to settle it.
  result = Deferred[T]()
  when defined(js):
    discard name
    var future: PlatformFuture[T]
    var resolveFn: proc(value: T)
    var rejectFn: proc(message: cstring)
    {.emit: [future, " = new Promise(function (res, rej) { ",
             resolveFn, " = res; ",
             rejectFn, " = function (m) { rej(new Error(m)); }; });"].}
    # A rejection nobody has subscribed to yet is not an error: the consumer
    # attaches with `onComplete` when it gets to it.
    {.emit: [future, ".catch(function () {});"].}
    result.future = future
    result.resolveFn = resolveFn
    result.rejectFn = rejectFn
  else:
    result.future = newFuture[T](name)

proc isSettled*[T](d: Deferred[T]): bool = d.settled

proc resolve*[T](d: Deferred[T]; value: T) =
  ## Complete the future with `value`. Ignored once settled.
  if d.settled: return
  d.settled = true
  when defined(js):
    d.resolveFn(value)
  else:
    d.future.complete(value)

proc reject*[T](d: Deferred[T]; message: string) =
  ## Fail the future with `message`. Ignored once settled.
  if d.settled: return
  d.settled = true
  when defined(js):
    d.rejectFn(message.cstring)
  else:
    d.future.fail(newException(CatchableError, message))
