## isonim/core/computation.nim
##
## Computation — a reactive observer that re-runs when its dependencies change.
## Implements createEffect, createRenderEffect, and createMemo.
##
## Port of SolidJS signal.ts computation creation and update logic.

import types, graph, batch

proc storeReactiveValue[T](dest: var T; value: T) {.inline.} =
  ## Avoid JS backend deep-copy corruption for seqs of value objects stored
  ## in memos. Reactive callers treat memo values as immutable snapshots.
  when defined(js):
    shallowCopy(dest, value)
  else:
    dest = value

type
  MemoSignalState*[T] = ref object of SignalStateBase
    ## A signal that is backed by a computation. When read, it ensures
    ## the computation is up-to-date, then returns the cached value.
    value*: T
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

proc refresh(comp: ComputationBase) =
  ## Bring `comp` up to date. A stale computation re-runs. A pending one first
  ## refreshes the memos it read, in the order it read them; a memo that ends
  ## up with a new value marks `comp` stale, and only then does `comp` re-run.
  ## A pending computation whose memo inputs are all unchanged becomes clean
  ## without running. This is what keeps every run glitch-free: a computation
  ## never runs before the memos it reads are current.
  if comp.state == csPending:
    # `comp` stays pending while its sources are refreshed, so a memo that
    # changes marks it stale without queueing it again. By index, without
    # copying the seq: refreshing a source re-runs that source, not `comp`.
    var i = 0
    while i < comp.sources.len:
      let upstream = comp.sources[i].memoComputation
      if upstream != nil and upstream.state != csClean:
        refresh(upstream)
        if comp.state == csStale: break
      inc i
    if comp.state == csPending: comp.state = csClean
  if comp.state == csStale:
    updateComputation(comp)

proc refreshOwners(node: OwnerBase) =
  ## Refresh the out-of-date computations among `node` and its owners,
  ## outermost first.
  if node == nil: return
  refreshOwners(node.owner)
  if isComputationNode(node):
    let c = asComputation(node)
    if c.state != csClean and c.fn != nil: refresh(c)

proc runTop*(comp: ComputationBase) =
  ## Process one queued computation. Owners first: when an owning
  ## computation is itself out of date, it is brought up to date before its
  ## child, because re-running it may dispose the child (a branch that is no
  ## longer shown), which then must not run at all.
  if comp.state == csClean or comp.fn == nil: return
  if ownerMarked: refreshOwners(comp.owner)
  if comp.fn != nil and comp.state != csClean:
    refresh(comp)

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
    storeReactiveValue(memoSig.value, newVal)
    # Readers were marked pending (and queued) when this memo was marked;
    # now they are stale. They run when the flush reaches them, after every
    # memo they read is current -- never from here, which would let a reader
    # run before its other inputs are refreshed.
    if memoSig.observers.len > 0:
      runUpdates proc() =
        markMemoChanged(memoSig)

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
  memoSig.memoComputation = comp

  if Owner != nil:
    Owner.owned.add(comp)

  # Initial execution — capture the first value
  # We need to set fn to the wrapper that stores the initial value
  let initialFn = proc() =
    storeReactiveValue(memoSig.value, fn())

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
  ## If the memo is stale or pending, brings it up to date first (see
  ## `refresh`), so a read right after a write is current even inside a batch.
  if m.computation.state != csClean:
    refresh(m.computation)
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

# Register runTop as the callback through which batch.nim's flush processes
# each queued computation.
runTopCb = runTop
