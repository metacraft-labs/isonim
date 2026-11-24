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
    error*: ref CatchableError
      ## Set while the memo's last run raised: reading the memo raises it
      ## again (the value is the last good one, or `default(T)`).

  Memo*[T] = object
    ## User-facing memo handle. Reads are tracked like signals.
    signal*: MemoSignalState[T]
    computation*: ComputationBase

proc handleError*(source: ComputationBase; err: ref CatchableError) =
  ## Deliver `err`, raised by `source` (its run or a cleanup of its previous
  ## run), to the nearest handler registered on `source` or one of its
  ## owners (`owner.onError`, an effect's error arm, an error boundary). The
  ## handler runs untracked, with its own owner as the current owner. An
  ## error the handler raises goes on to the next handler above it. With no
  ## handler the error is unhandled.
  ##
  ## With `err` nil, `source` is a computation whose last run had failed and
  ## that has now run successfully: every handler above it is told (an
  ## error boundary shows its content again).
  var err = err
  var o: OwnerBase = source
  while o != nil:
    if not o.contextTable.isNil and errorHandlerKey in o.contextTable:
      let e = err
      let prevListener = Listener
      let prevOwner = Owner
      Listener = nil
      Owner = o
      err = nil
      try:
        ErrorBox(o.contextTable[errorHandlerKey]).handler(e, source)
      except CatchableError as x:
        err = x
      finally:
        Listener = prevListener
        Owner = prevOwner
      # Handled, unless the handler raised; a recovery goes on upwards.
      if e != nil and err == nil: return
    o = o.owner
  if err != nil:
    # Unhandled: inside a flush the first one is kept, and the outermost
    # flush rethrows it, unchanged, once every queued node has run
    # (`batch.flushUpdates`); outside a flush it is raised at once.
    if flushDepth == 0: raise err
    if flushError == nil: flushError = err

proc updateComputation*(comp: ComputationBase) =
  ## Re-executes a computation: cleans old dependencies, sets Listener,
  ## calls fn, collects new dependencies.
  ##
  ## A `CatchableError` from the run, or from a cleanup of the previous run,
  ## does not escape: it goes to `handleError`, so the rest of the flush
  ## still runs. A failing cleanup does not stop the run (every cleanup has
  ## run by then; `cleanNode` raises the first failure afterwards). A memo's
  ## own errors are its value, not a failure: see `createMemo`.
  if comp.fn == nil:
    return
  var err: ref CatchableError
  # Clean old dependencies and run cleanup callbacks. A Defect from a
  # cleanup propagates, as before (see `batch.flushUpdates`).
  try:
    cleanNode(comp)
  except CatchableError as e:
    err = e
  comp.state = csClean

  let prevListener = Listener
  let prevOwner = Owner
  Listener = comp
  Owner = comp
  try:
    comp.fn()
  except CatchableError as e:
    if err == nil: err = e
  finally:
    Listener = prevListener
    Owner = prevOwner

  # A failure, or the first success after one (`errored` is set only
  # while the last run failed, so the common case costs one test).
  if err != nil or comp.errored:
    comp.errored = err != nil
    handleError(comp, err)

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

proc createEffectWithErrorArm*(fn: proc(); onError: ErrorHandler) =
  ## An effect with an error arm (provisional API): a `CatchableError` raised
  ## by a run of `fn`, by one of its cleanups, or by a computation it owns
  ## goes to `onError` instead of the handlers above the effect. The effect
  ## stays subscribed to what it read before it failed, so a later change
  ## runs it again.
  ##
  ## A separate name, not an overload of `createEffect`: with an overload,
  ## `createEffect do: ...` blocks that capture locals stop compiling (the
  ## compiler reports "environment misses"), and a default parameter would
  ## make every page carry the arm's code.
  ##
  ## The arm is registered on the effect at the start of its first run (the
  ## effect is the current owner then), so `createComputation` stays as small
  ## as before for every page that does not use it.
  if onError == nil:
    createEffect(fn)
    return
  let box = errorBox(onError)
  createEffect proc() =
    if Owner.contextTable.isNil: setErrorBox(Owner, box)
    fn()

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
  ## When `fn` raises a `CatchableError` (on the first run too), the memo
  ## keeps the error and reading it raises it (see `val`).
  let memoSig = MemoSignalState[T](
    observers: @[],
    observerSlots: @[],
    comparator: equals,
  )

  var comp: ComputationBase

  let wrappedFn = proc() =
    # An error is the memo's state, like a value: it is kept, and readers
    # are told that the memo changed, so each re-runs and raises it again
    # when it reads the memo (and the nearest handler of each sees it). A
    # later run that succeeds replaces it, and readers are told again.
    let newVal =
      try: fn()
      except CatchableError as e:
        memoSig.error = e
        if memoSig.observers.len > 0:
          runUpdates proc() =
            markMemoChanged(memoSig)
        return
    if memoSig.error != nil:
      memoSig.error = nil
    elif memoSig.comparator != nil:
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
    memoSignal: memoSig,
    contextTable: nil,
  )
  memoSig.memoComputation = comp

  if Owner != nil:
    Owner.owned.add(comp)

  # Initial execution — capture the first value
  # We need to set fn to the wrapper that stores the initial value
  let initialFn = proc() =
    try:
      storeReactiveValue(memoSig.value, fn())
    except CatchableError as e:
      memoSig.error = e

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

  result = Memo[T](signal: memoSig, computation: comp)

proc val*[T](m: Memo[T]): T =
  ## Reads the memo's cached value (tracked).
  ## If the memo is stale or pending, brings it up to date first (see
  ## `refresh`), so a read right after a write is current even inside a batch.
  ## A memo whose last run raised raises that error again, the same object,
  ## after the read is tracked, so the reader re-runs when the memo does.
  if m.computation.state != csClean:
    refresh(m.computation)
  trackRead(m.signal)
  if m.signal.error != nil: raise m.signal.error
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
