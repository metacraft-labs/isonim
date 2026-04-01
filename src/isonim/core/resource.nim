## Async resources for IsoNim.
## createResource wraps a fetcher function with reactive state tracking.

import signals, computation

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

proc createResource*[T](
  fetcher: proc(): T;
  initialValue: T = default(T)
): Resource[T] =
  ## Creates a synchronous resource (async version needs Future support).
  ## State transitions: unresolved -> pending -> ready (or errored)
  var data = createSignal(initialValue)
  var state = createSignal(rsUnresolved)
  var error = createSignal("")

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
  var data = createSignal(initialValue)
  var state = createSignal(rsUnresolved)
  var error = createSignal("")

  createEffect proc() =
    let sourceVal = source()  # tracked dependency
    let prevState = state.state.value  # untracked read of raw value
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
  var data = createSignal(initialValue)
  var state = createSignal(rsPending)
  var error = createSignal("")

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
