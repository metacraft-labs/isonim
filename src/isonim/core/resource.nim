## Async resources for IsoNim.
## createResource wraps a fetcher function with reactive state tracking.

import signals, computation
import nim_everywhere/async_compat

type
  ResourceState* = enum
    rsUnresolved  ## Initial state, fetch not started
    rsPending     ## Fetch in progress
    rsReady       ## Data available
    rsRefreshing  ## Refetching (previous data still available)
    rsErrored     ## Fetch failed

  Resource*[T] = object
    data*: Signal[T]
    state*: Signal[ResourceState]
    error*: Signal[string]
    refresher*: proc() {.closure.}
      ## Optional re-fetch trigger installed by async createResource overloads.
      ## Sync overloads leave this `nil`; calling `refresh(r)` on a sync resource
      ## is a no-op. Async overloads populate this so callers can request a
      ## manual re-fetch via `r.refresh()`.

proc createResource*[T](
  fetcher: proc(): T;
  initialValue: T = default(T)
): Resource[T] =
  ## Creates a synchronous resource (async version needs Future support).
  ## State transitions: unresolved -> pending -> ready (or errored)
  let data = createSignal(initialValue)
  let state = createSignal(rsUnresolved)
  let error = createSignal("")

  # Trigger initial fetch
  state.val = rsPending
  try:
    let fetchResult = fetcher()
    data.val = fetchResult
    state.val = rsReady
  except CatchableError as e:
    error.val = e.msg
    state.val = rsErrored

  Resource[T](data: data, state: state, error: error)

proc createResource*[S, T](
  source: proc(): S;
  fetcher: proc(s: S): T;
  initialValue: T = default(T)
): Resource[T] =
  ## Creates a resource that refetches when source changes.
  ## The source accessor is tracked -- when it changes, fetcher is re-called.
  let data = createSignal(initialValue)
  let state = createSignal(rsUnresolved)
  let error = createSignal("")

  createEffect proc() =
    let sourceVal = source()  # tracked dependency
    let prevState = state.value  # untracked read of raw value
    if prevState == rsReady or prevState == rsRefreshing:
      state.val = rsRefreshing
    else:
      state.val = rsPending
    try:
      let fetchResult = fetcher(sourceVal)
      data.val = fetchResult
      state.val = rsReady
      error.val = ""
    except CatchableError as e:
      error.val = e.msg
      state.val = rsErrored

  Resource[T](data: data, state: state, error: error)

proc val*[T](r: Resource[T]): T =
  ## Reads the resource data (tracked).
  r.data.val

proc loading*[T](r: Resource[T]): bool =
  ## Returns true if the resource is pending or refreshing.
  let s = r.state.val
  s == rsPending or s == rsRefreshing

type
  DeferredResource*[T] = object
    resource*: Resource[T]
    resolve*: proc(value: T)
    reject*: proc(msg: string)

proc createDeferredResource*[T](initialValue: T = default(T)): DeferredResource[T] =
  ## Creates a resource that starts in rsPending state.
  ## Call resolve(value) to transition to rsReady.
  ## Call reject(msg) to transition to rsErrored.
  let data = createSignal(initialValue)
  let state = createSignal(rsPending)
  let error = createSignal("")

  let resolve = proc(value: T) =
    data.val = value
    error.val = ""
    state.val = rsReady

  let reject = proc(msg: string) =
    error.val = msg
    state.val = rsErrored

  DeferredResource[T](
    resource: Resource[T](data: data, state: state, error: error),
    resolve: resolve,
    reject: reject
  )

# ---------------------------------------------------------------------------
# Async overloads — depend on nim_everywhere/async_compat
# ---------------------------------------------------------------------------
##
## The two async overloads below mirror the sync overloads above. The
## fetcher returns a `PlatformFuture[T]` and the resource transitions
## through ~rsUnresolved~ → ~rsPending~ → ~rsReady~/~rsErrored~ (or
## ~rsReady~ → ~rsRefreshing~ → ~rsReady~/~rsErrored~ on a refetch).
##
## A generation counter guards against out-of-order completions: when
## `source` changes (or `refresh` is called) twice in rapid succession,
## the older fetch's late completion is discarded — only the most-recent
## fetch's result is applied. This mirrors SolidJS's behaviour.
##
## Both overloads install an internal closure on `r.refresher` so callers
## can request a manual re-fetch via `r.refresh()` without re-supplying
## the fetcher.

proc createResource*[T](
  fetcher: proc(): PlatformFuture[T];
  initialValue: T = default(T)
): Resource[T] =
  ## Async overload — initial fetch begins immediately; state transitions
  ## ~rsPending~ → ~rsReady~ (or ~rsErrored~). Subsequent ~refresh~ calls
  ## transition ~rsReady~ → ~rsRefreshing~ → ~rsReady~/~rsErrored~ while
  ## keeping the previous `data.val` visible during the refetch.
  let data = createSignal(initialValue)
  let state = createSignal(rsPending)
  let error = createSignal("")
  # Generation counter lives in a ref cell so the closures below share it
  # without it becoming a tracked signal (we don't want anyone subscribing
  # to "the request id changed").
  let generation = new(int)
  generation[] = 0

  proc launch() =
    let prev = state.value  # untracked
    if prev == rsReady or prev == rsRefreshing:
      state.val = rsRefreshing
    else:
      state.val = rsPending
    generation[].inc
    let myGen = generation[]
    let fut = fetcher()
    fut.onComplete(
      onSuccess = proc(value: T) =
        if myGen == generation[]:
          data.val = value
          error.val = ""
          state.val = rsReady,
      onError = proc(message: string) =
        if myGen == generation[]:
          error.val = message
          state.val = rsErrored)

  result = Resource[T](
    data: data, state: state, error: error,
    refresher: proc() = launch())
  launch()

proc createResource*[S, T](
  source: proc(): S;
  fetcher: proc(s: S): PlatformFuture[T];
  initialValue: T = default(T)
): Resource[T] =
  ## Source-tracked async overload — refetches whenever `source()` changes.
  ## Transitions ~rsReady~ → ~rsRefreshing~ → ~rsReady~/~rsErrored~ on a
  ## refetch. Out-of-order completions are discarded via a generation
  ## counter. `refresh(r)` re-runs the fetcher with the current source
  ## value.
  let data = createSignal(initialValue)
  let state = createSignal(rsUnresolved)
  let error = createSignal("")
  let generation = new(int)
  generation[] = 0
  var lastSource: S

  proc fire(sourceVal: S) =
    let prev = state.value
    if prev == rsReady or prev == rsRefreshing:
      state.val = rsRefreshing
    else:
      state.val = rsPending
    generation[].inc
    let myGen = generation[]
    let fut = fetcher(sourceVal)
    fut.onComplete(
      onSuccess = proc(value: T) =
        if myGen == generation[]:
          data.val = value
          error.val = ""
          state.val = rsReady,
      onError = proc(message: string) =
        if myGen == generation[]:
          error.val = message
          state.val = rsErrored)

  createEffect proc() =
    let sourceVal = source()  # tracked dependency
    lastSource = sourceVal
    fire(sourceVal)

  result = Resource[T](
    data: data, state: state, error: error,
    refresher: proc() = fire(lastSource))

proc refresh*[T](r: Resource[T]) =
  ## Manually trigger a re-fetch on an async resource. State transitions:
  ##   - ~rsReady~ / ~rsRefreshing~ → ~rsRefreshing~ (data.val stays visible)
  ##   - ~rsErrored~ / ~rsUnresolved~ / ~rsPending~ → ~rsPending~
  ##   - on success → ~rsReady~ with the new value
  ##   - on failure → ~rsErrored~ with the error message
  ##
  ## A no-op when called on a sync-created resource (the resource has no
  ## installed `refresher` closure).
  if r.refresher != nil:
    r.refresher()

proc refresh*[T](r: Resource[T]; fetcher: proc(): PlatformFuture[T]) =
  ## Manually trigger a re-fetch using a caller-supplied fetcher. Useful
  ## when the original fetcher is not stored on the resource (e.g. when a
  ## consumer wants to vary the fetcher across refreshes).
  let prev = r.state.value
  if prev == rsReady or prev == rsRefreshing:
    r.state.val = rsRefreshing
  else:
    r.state.val = rsPending
  let fut = fetcher()
  fut.onComplete(
    onSuccess = proc(value: T) =
      r.data.val = value
      r.error.val = ""
      r.state.val = rsReady,
    onError = proc(message: string) =
      r.error.val = message
      r.state.val = rsErrored)
