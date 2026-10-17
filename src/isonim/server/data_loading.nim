## isonim/server/data_loading.nim
##
## `createServerResource`: a resource whose data comes from a server
## function.
##
## Server functions return `Future[T]` on both targets:
##
## * on the C target (SSR) the server function runs in-process; when its
##   future is already complete (it awaited nothing, or only completed
##   futures), the resource is `rsReady` before rendering continues, so the
##   SSR HTML contains the data.  Otherwise the resource is `rsPending` and
##   becomes ready when the future completes (on the server's event loop).
## * on the JS target the server function is the `fetch` stub: the resource
##   starts `rsPending` (Suspense shows its fallback) and becomes `rsReady`
##   or `rsErrored` when the response arrives.  A response the client drops
##   as stale (URL-Schema.md §5.4) never settles the future, so the
##   resource keeps what it had.
##
## The source variant refetches whenever the source signal changes; a late
## result of an older fetch is discarded.
##
## ```nim
## proc getUser(id: int): Future[User] {.server.} = ...
## let user = createServerResource(proc(): Future[User] = getUser(42))
## ```

import ../core/[resource, computation]

when defined(js):
  import std/asyncjs
else:
  import std/asyncdispatch

proc settle[T](fut: Future[T]; current: proc(): bool;
               resolve: proc(value: T); reject: proc(msg: string)) =
  when defined(js):
    proc ok(value: T) =
      if current(): resolve(value)
    proc failed(err: Error) =
      if current(): reject($err.message)
    discard fut.then(ok, failed)
  else:
    if fut.finished:
      # Synchronous resolution: what SSR relies on.
      if fut.failed: reject(fut.error.msg)
      else: resolve(fut.read)
    else:
      fut.addCallback(proc() {.gcsafe.} =
        {.cast(gcsafe).}:
          # The resource's closures touch signals; nginx and the test
          # loops run single-threaded.
          if current():
            if fut.failed: reject(fut.error.msg)
            else: resolve(fut.read))

proc createServerResource*[T](
    serverFn: proc(): Future[T];
    initialValue: T = default(T)): Resource[T] =
  ## A resource holding the result of `serverFn()`.
  let d = createDeferredResource[T](initialValue)
  var fut: Future[T]
  try:
    fut = serverFn()
  except CatchableError as e:
    d.reject(e.msg)
    return d.resource
  settle(fut, proc(): bool = true, d.resolve, d.reject)
  d.resource

proc createServerResource*[S, T](
    source: proc(): S;
    serverFn: proc(s: S): Future[T];
    initialValue: T = default(T)): Resource[T] =
  ## A resource holding the result of `serverFn(source())`, refetched when
  ## the source changes.  Only the latest fetch may update it.
  let d = createDeferredResource[T](initialValue)
  let generation = new(int)
  createEffect proc() =
    let s = source()  # tracked
    inc generation[]
    let mine = generation[]
    d.resource.state.val = (if d.resource.state.value == rsReady: rsRefreshing
                            else: rsPending)
    var fut: Future[T]
    try:
      fut = serverFn(s)
    except CatchableError as e:
      d.reject(e.msg)
      return
    settle(fut, proc(): bool = mine == generation[], d.resolve, d.reject)
  d.resource
