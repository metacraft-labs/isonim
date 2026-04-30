## isonim/core/computation.nim
##
## Computation — a reactive observer that re-runs when its dependencies change.
## Implements createEffect, createRenderEffect, and createMemo.
##
## Port of SolidJS signal.ts computation creation and update logic.

import types, graph, batch

type
  MemoSignalState*[T] = ref object of SignalStateBase
    ## A signal that is backed by a computation. When read, it ensures
    ## the computation is up-to-date, then returns the cached value.
    value*: T
    computation*: ComputationBase
    comparator*: EqualityFn[T]

  Memo*[T] = object
    ## User-facing memo handle. Reads are tracked like signals.
    signal*: MemoSignalState[T]
    computation*: ComputationBase

proc updateComputation*(comp: ComputationBase) =
  ## Re-executes a computation: cleans old dependencies, sets Listener,
  ## calls fn, collects new dependencies.
  if comp.fn == nil:
    return
  # Clean old dependencies and run cleanup callbacks
  cleanNode(comp)
  comp.state = csClean

  let prevListener = Listener
  let prevOwner = Owner
  Listener = comp
  Owner = comp
  try:
    comp.fn()
  finally:
    Listener = prevListener
    Owner = prevOwner

  comp.updatedAt = ExecCount

proc createComputation(fn: proc(); pure: bool; initial: bool = true) =
  ## Internal: creates a computation node attached to current Owner.
  let comp = ComputationBase(
    sources: @[],
    sourceSlots: @[],
    owned: @[],
    cleanups: @[],
    owner: Owner,
    state: csStale,
    pure: pure,
    fn: fn,
    updatedAt: 0,
    memoSignal: nil,
    contextTable: nil,
  )
  if Owner != nil:
    Owner.owned.add(comp)
  if initial:
    updateComputation(comp)

proc createEffect*(fn: proc()) =
  ## Creates an effect that tracks dependencies and re-runs on change.
  ## Effects are non-pure computations.
  createComputation(fn, pure = false, initial = true)

proc createRenderEffect*(fn: proc()) =
  ## Like createEffect but runs synchronously during render.
  ## Same as createEffect for now (scheduling difference comes in M3).
  createComputation(fn, pure = false, initial = true)

proc createComputed*(fn: proc()) =
  ## Creates a computation that runs immediately.
  createComputation(fn, pure = true, initial = true)

proc createMemo*[T](fn: proc(): T; equals: EqualityFn[T] = nil): Memo[T] =
  ## Creates a memoized computation that caches its result.
  ## Acts as both a signal (has observers, can be read with tracking)
  ## and a computation (has sources, re-runs when dependencies change).
  let memoSig = MemoSignalState[T](
    observers: @[],
    observerSlots: @[],
    comparator: equals,
  )

  var comp: ComputationBase

  let wrappedFn = proc() =
    let newVal = fn()
    if memoSig.comparator != nil:
      if memoSig.comparator(memoSig.value, newVal):
        return
    elif memoSig.value == newVal:
      return
    memoSig.value = newVal
    # Notify downstream observers of the memo signal
    notifyObservers(memoSig)
    # Queue downstream observers for execution.
    # Copy the observers list first because updateComputation may
    # add or remove observers (e.g. show/forEachKeyed toggling
    # subscriptions), which would mutate the seq during iteration.
    let observers = memoSig.observers
    for obs in observers:
      if obs.pure:
        if batchDepth > 0:
          Updates.add(obs)
        else:
          updateComputation(obs)
      else:
        if batchDepth > 0:
          Effects.add(obs)
        else:
          updateComputation(obs)

  comp = ComputationBase(
    sources: @[],
    sourceSlots: @[],
    owned: @[],
    cleanups: @[],
    owner: Owner,
    state: csStale,
    pure: true,
    fn: wrappedFn,
    updatedAt: 0,
    memoSignal: memoSig,
    contextTable: nil,
  )
  memoSig.computation = comp

  if Owner != nil:
    Owner.owned.add(comp)

  # Initial execution — capture the first value
  # We need to set fn to the wrapper that stores the initial value
  let initialFn = proc() =
    memoSig.value = fn()

  let prevListener = Listener
  let prevOwner = Owner
  Listener = comp
  Owner = comp
  cleanNode(comp)
  comp.state = csClean
  try:
    initialFn()
  finally:
    Listener = prevListener
    Owner = prevOwner
  comp.updatedAt = ExecCount

  result = Memo[T](signal: memoSig, computation: comp)

proc val*[T](m: Memo[T]): T =
  ## Reads the memo's cached value (tracked).
  ## If the memo is stale, re-evaluates it first.
  if m.computation.state == csStale:
    updateComputation(m.computation)
  trackRead(m.signal)
  m.signal.value

proc onMount*(fn: proc()) =
  ## Runs fn once after the current reactive root is fully set up.
  ## SolidJS equivalent: onMount(() => { ... })
  ##
  ## Implemented as createEffect(() => untrack(fn)) — creates an effect
  ## that runs once. Because fn is called inside untrack, no signal reads
  ## inside fn create subscriptions, so the effect never re-executes.
  createEffect(proc() = untrack(fn))

# Register updateComputation as the callback for batch.nim
updateComputationCb = updateComputation
