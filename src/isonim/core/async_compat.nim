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

when defined(js):
  # -- Deferred callback queue for JS headless tests -------------------------
  #
  # JS Promises always defer .then() callbacks to the microtask queue,
  # making it impossible to drain them synchronously.  To support the
  # headless test pattern (call action, drain(), assert), futures created
  # with `newCompletedFuture`/`newFailedFuture` carry sync metadata.
  # `onComplete` detects this and appends callbacks to `pendingCallbacks`
  # instead of using `.then()`.  The test harness calls `drainCallbacks()`
  # to flush the queue, giving identical semantics to native `poll(0)`.
  #
  # Production code (Electron) uses real async Promises unaffected by this.

  var pendingCallbacks*: seq[proc()] = @[]

  proc drainCallbacks*() =
    ## Flush all pending callbacks queued by `onComplete` for sync
    ## futures.  Callbacks may enqueue more callbacks (e.g. chained
    ## onComplete), so we loop until the queue is empty.
    while pendingCallbacks.len > 0:
      let cb = pendingCallbacks[0]
      pendingCallbacks.delete(0)
      cb()

  proc isSyncResolved*(fut: PlatformFuture): bool =
    var r: bool
    {.emit: "`r` = (`fut`.__syncResolved === true);".}
    return r

  proc isSyncFailed*(fut: PlatformFuture): bool =
    var r: bool
    {.emit: "`r` = (`fut`.__syncFailed === true);".}
    return r

  proc getSyncValue*[T](fut: PlatformFuture[T]): T =
    var r: T
    {.emit: "`r` = `fut`.__syncValue;".}
    return r

  proc getSyncError*(fut: PlatformFuture): string =
    var r: string
    {.emit: "`r` = `fut`.__syncError;".}
    return r

proc onComplete*[T](fut: PlatformFuture[T];
                    onSuccess: proc(val: T);
                    onError: proc(msg: string)) =
  ## Register callbacks for a future's completion.
  ##
  ## - On JS: if the future carries sync metadata (from
  ##   `newCompletedFuture`/`newFailedFuture`), the callback is queued
  ##   into `pendingCallbacks` for synchronous flushing by `drain()`.
  ##   Otherwise falls back to `Promise.then()`.
  ## - On native: uses `Future.addCallback` and checks `fut.failed`.
  ##
  ## `onError` receives the error message as a string on both backends,
  ## normalising the JS `Error` object vs Nim `Exception`.
  when defined(js):
    if isSyncResolved(fut):
      # Queue the callback for synchronous flushing by drain(),
      # matching native asyncdispatch.callSoon behavior (defers to
      # the next poll() call when the dispatcher is initialized).
      let val = getSyncValue[T](fut)
      pendingCallbacks.add(proc() = onSuccess(val))
    elif isSyncFailed(fut):
      let msg = getSyncError(fut)
      pendingCallbacks.add(proc() = onError(msg))
    else:
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
    if isSyncResolved(fut):
      pendingCallbacks.add(proc() = onSuccess())
    elif isSyncFailed(fut):
      let msg = getSyncError(fut)
      pendingCallbacks.add(proc() = onError(msg))
    else:
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
  ##
  ## On JS, the returned promise carries `__syncResolved = true` and
  ## `__syncValue = val` so that `onComplete` can fire the callback
  ## synchronously instead of deferring through `.then()`.
  when defined(js):
    result = newPromise proc(resolve: proc(v: T)) =
      resolve(val)
    {.emit: "`result`.__syncResolved = true; `result`.__syncValue = `val`;".}
  else:
    result = newFuture[T]("newCompletedFuture")
    result.complete(val)

proc newFailedFuture*[T](msg: string): PlatformFuture[T] =
  ## Create a future that is already failed with the given error message.
  ##
  ## Useful in mocks and tests to simulate error conditions.
  ##
  ## On JS, the returned promise carries `__syncFailed = true` and
  ## `__syncError = msg` so that `onComplete` can fire the error
  ## callback synchronously.
  when defined(js):
    # JS Promise rejection.  We raise so the promise rejects.
    # We also need to add a .catch() handler to prevent
    # Node.js "unhandled promise rejection" crashes.
    result = newPromise proc(resolve: proc(v: T)) =
      raise newException(CatchableError, msg)
    let m = msg
    {.emit: "`result`.__syncFailed = true; `result`.__syncError = `m`; `result`.catch(function(){});".}
  else:
    result = newFuture[T]("newFailedFuture")
    result.fail(newException(CatchableError, msg))
