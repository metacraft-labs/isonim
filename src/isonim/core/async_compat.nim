## isonim/core/async_compat.nim
##
## Cross-platform async abstraction layer. Provides unified types and
## callback helpers that map to:
##   JS backend:   std/asyncjs  (Promise-based)
##   C backend:    std/asyncdispatch (Future-based)
##
## This module complements `platform.nim` (which handles collections
## and strings) by covering the async/future split between backends.
##
## The key abstraction is `PlatformFuture[T]`, which is `Future[T]`
## on both backends but backed by different modules. The `onComplete`
## family of procs provides a single API for registering success/error
## callbacks regardless of backend.
##
## Usage:
##   import isonim/core/async_compat
##
##   proc handleResult(fut: PlatformFuture[JsonNode]) =
##     onComplete(fut,
##       onSuccess = proc(val: JsonNode) = echo "got: ", val,
##       onError = proc(msg: string) = echo "error: ", msg)

when defined(js):
  import std/asyncjs
  export asyncjs
else:
  import std/asyncdispatch
  export asyncdispatch

type PlatformFuture*[T] = Future[T]
  ## Alias for `Future[T]` from the platform-appropriate async module.
  ## On JS this is a Promise wrapper; on native it is an asyncdispatch
  ## Future.

proc onComplete*[T](fut: PlatformFuture[T];
                    onSuccess: proc(val: T);
                    onError: proc(msg: string)) =
  ## Register callbacks for a future's completion.
  ##
  ## - On JS: uses `Promise.then(success, failure)`.
  ## - On native: uses `Future.addCallback` and checks `fut.failed`.
  ##
  ## `onError` receives the error message as a string on both backends,
  ## normalising the JS `Error` object vs Nim `Exception`.
  when defined(js):
    proc success(v: T) = onSuccess(v)
    proc failure(e: Error) = onError($e.message)
    discard fut.then(success, failure)
  else:
    fut.addCallback proc() =
      {.cast(gcsafe).}:
        if fut.failed:
          onError(fut.readError.msg)
        else:
          onSuccess(fut.read)

proc onCompleteVoid*(
    fut: PlatformFuture[void];
    onSuccess: proc();
    onError: proc(msg: string)) =
  ## Variant of `onComplete` for `Future[void]` / `Promise[void]`.
  ##
  ## Since there is no result value, `onSuccess` takes no arguments.
  ## `onError` still receives the error message string.
  when defined(js):
    proc success() = onSuccess()
    proc failure(e: Error) = onError($e.message)
    discard fut.then(success, failure)
  else:
    fut.addCallback proc() =
      {.cast(gcsafe).}:
        if fut.failed:
          onError(fut.readError.msg)
        else:
          onSuccess()

proc newCompletedFuture*[T](val: T): PlatformFuture[T] =
  ## Create a future that is already resolved with `val`.
  ##
  ## Useful in mocks and tests where you need to return a future
  ## synchronously.
  when defined(js):
    result = newPromise proc(resolve: proc(v: T)) =
      resolve(val)
  else:
    result = newFuture[T]("newCompletedFuture")
    result.complete(val)

proc newFailedFuture*[T](msg: string): PlatformFuture[T] =
  ## Create a future that is already failed with the given error message.
  ##
  ## Useful in mocks and tests to simulate error conditions.
  when defined(js):
    # JS Promise rejection. We raise so the promise rejects.
    result = newPromise proc(resolve: proc(v: T)) =
      raise newException(CatchableError, msg)
  else:
    result = newFuture[T]("newFailedFuture")
    result.fail(newException(CatchableError, msg))
