## Async resources for IsoNim.
## createResource wraps a fetcher function with reactive state tracking.

import std/json
import signals, computation
import nim_everywhere/async_compat

type
  ResourceState* = enum
    rsUnresolved  ## Initial state, fetch not started
    rsPending     ## Fetch in progress
    rsReady       ## Data available
    rsRefreshing  ## Refetching (previous data still available)
    rsErrored     ## Fetch failed

  ResourceFetcherInfo*[T] = object
    ## Mirrors SolidJS's ~ResourceFetcherInfo<T, R>~ (with ~R = JsonNode~).
    ## Passed to async fetchers on every invocation. On the initial load
    ## ~refetching~ is ~false~ and ~info~ is ~nil~; on a refresh
    ## ~refetching~ is ~true~ and ~info~ is whatever opaque payload the
    ## caller passed to ~r.refresh(payload)~ (or ~nil~ when none was
    ## supplied).
    value*: T               ## current resource value (default(T) on first load)
    refetching*: bool       ## false on initial load, true on r.refresh(...)
    info*: JsonNode         ## opaque payload from r.refresh(info); nil otherwise

  Resource*[T] = object
    data*: Signal[T]
    state*: Signal[ResourceState]
    error*: Signal[string]
    refresher*: proc(info: JsonNode) {.closure.}
      ## Optional re-fetch trigger installed by async createResource overloads.
      ## Sync overloads leave this `nil`; calling `refresh(r)` on a sync resource
      ## is a no-op. Async overloads populate this so callers can request a
      ## manual re-fetch via `r.refresh()` (optionally with a JsonNode payload
      ## forwarded to the fetcher via ~info.info~).

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
  fetcher: proc(info: ResourceFetcherInfo[T]): PlatformFuture[T];
  initialValue: T = default(T)
): Resource[T] =
  ## Async overload — initial fetch begins immediately; state transitions
  ## ~rsPending~ → ~rsReady~ (or ~rsErrored~). Subsequent ~refresh~ calls
  ## transition ~rsReady~ → ~rsRefreshing~ → ~rsReady~/~rsErrored~ while
  ## keeping the previous `data.val` visible during the refetch.
  ##
  ## The fetcher always receives a ~ResourceFetcherInfo[T]~ — callers that
  ## don't care about it can ignore the parameter (Nim allows unused
  ## parameters; the convention is to name it ~_info~).
  let data = createSignal(initialValue)
  let state = createSignal(rsPending)
  let error = createSignal("")
  # Generation counter lives in a ref cell so the closures below share it
  # without it becoming a tracked signal (we don't want anyone subscribing
  # to "the request id changed").
  let generation = new(int)
  generation[] = 0

  proc launch(refetching: bool; payload: JsonNode) =
    let prev = state.value  # untracked
    if prev == rsReady or prev == rsRefreshing:
      state.val = rsRefreshing
    else:
      state.val = rsPending
    generation[].inc
    let myGen = generation[]
    let info = ResourceFetcherInfo[T](
      value: data.value,  # untracked read of the current value
      refetching: refetching,
      info: payload)
    let fut = fetcher(info)
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
    refresher: proc(info: JsonNode) = launch(true, info))
  launch(false, nil)

proc createResource*[S, T](
  source: proc(): S;
  fetcher: proc(s: S; info: ResourceFetcherInfo[T]): PlatformFuture[T];
  initialValue: T = default(T)
): Resource[T] =
  ## Source-tracked async overload — refetches whenever `source()` changes.
  ## Transitions ~rsReady~ → ~rsRefreshing~ → ~rsReady~/~rsErrored~ on a
  ## refetch. Out-of-order completions are discarded via a generation
  ## counter. `refresh(r)` re-runs the fetcher with the current source
  ## value.
  ##
  ## The fetcher always receives a ~ResourceFetcherInfo[T]~ as its second
  ## argument. ~refetching~ is ~false~ only on the very first invocation;
  ## every subsequent fetch (whether triggered by a source change or by
  ## ~r.refresh(...)~) sets ~refetching = true~.
  let data = createSignal(initialValue)
  let state = createSignal(rsUnresolved)
  let error = createSignal("")
  let generation = new(int)
  generation[] = 0
  var lastSource: S
  var firstRun = true

  proc fire(sourceVal: S; refetching: bool; payload: JsonNode) =
    let prev = state.value
    if prev == rsReady or prev == rsRefreshing:
      state.val = rsRefreshing
    else:
      state.val = rsPending
    generation[].inc
    let myGen = generation[]
    let info = ResourceFetcherInfo[T](
      value: data.value,
      refetching: refetching,
      info: payload)
    let fut = fetcher(sourceVal, info)
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
    let isRefetch = not firstRun
    firstRun = false
    fire(sourceVal, isRefetch, nil)

  result = Resource[T](
    data: data, state: state, error: error,
    refresher: proc(info: JsonNode) = fire(lastSource, true, info))

proc refresh*[T](r: Resource[T]; info: JsonNode = nil) =
  ## Manually trigger a re-fetch on an async resource. State transitions:
  ##   - ~rsReady~ / ~rsRefreshing~ → ~rsRefreshing~ (data.val stays visible)
  ##   - ~rsErrored~ / ~rsUnresolved~ / ~rsPending~ → ~rsPending~
  ##   - on success → ~rsReady~ with the new value
  ##   - on failure → ~rsErrored~ with the error message
  ##
  ## When ~info~ is non-nil, the JsonNode is forwarded to the fetcher via
  ## ~ResourceFetcherInfo[T].info~. Default-nil so existing callers can
  ## continue to write ~r.refresh()~ unchanged.
  ##
  ## A no-op when called on a sync-created resource (the resource has no
  ## installed `refresher` closure).
  if r.refresher != nil:
    r.refresher(info)
