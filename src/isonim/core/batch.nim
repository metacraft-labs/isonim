## isonim/core/batch.nim
##
## Batching and untracking utilities: batch, untrack, runUpdates, flushUpdates.
## Defers reactive updates until the batch completes to avoid redundant work.
##
## Port of SolidJS signal.ts batching logic.

import types, graph, platform
export platform

when defined(js):
  # On JS, NativeSeq is JsArray (ref) — must be initialized eagerly.
  var Updates* = newNativeSeq[ComputationBase]()
  var Effects* = newNativeSeq[ComputationBase]()
  var batchDepth*: int
else:
  var Updates* {.threadvar.}: NativeSeq[ComputationBase]
  var Effects* {.threadvar.}: NativeSeq[ComputationBase]
  var batchDepth* {.threadvar.}: int

when defined(isonimInternalFlushObservation):
  type
    InternalFlushState* = enum
      ## The actual outermost flush is still running, returned, or unwound.
      ifsActive, ifsReturned, ifsUnwound
    InternalFlushEpoch* = ref object
      # Only this module issues valid tokens. Default construction is invalid.
      issued: bool
      state: InternalFlushState
    InternalBatchActivity* = object
      ## A copied activity snapshot, not an event/microtask quiescence proof.
      batchDepth*: int
      activeFlushDepth*: int
      globalUpdatesPending*: bool
      globalEffectsPending*: bool

  when defined(js):
    var activeFlushDepth: int
    var activeFlushEpoch: InternalFlushEpoch
    var flushEpochConstructions: uint64
  else:
    var activeFlushDepth {.threadvar.}: int
    var activeFlushEpoch {.threadvar.}: InternalFlushEpoch
    var flushEpochConstructions {.threadvar.}: uint64

  proc currentInternalFlushEpoch*(): InternalFlushEpoch =
    ## Passive, lazy identity for the entire active outermost/nested flush stack.
    ## Nil means no flush is active, not that all reactive/event work is idle.
    if activeFlushDepth == 0:
      return nil
    if activeFlushEpoch == nil:
      activeFlushEpoch = InternalFlushEpoch(issued: true, state: ifsActive)
      inc flushEpochConstructions
    activeFlushEpoch

  proc internalFlushState*(epoch: InternalFlushEpoch): InternalFlushState =
    ## Read only an issued token. Retained tokens have no cross-thread contract.
    if epoch == nil:
      raise newException(ValueError, "internal flush epoch is nil")
    if not epoch.issued:
      raise newException(ValueError, "internal flush epoch was not issued")
    epoch.state

  proc internalBatchActivity*(): InternalBatchActivity =
    ## Globals may be empty while the active flush still owns local callbacks.
    InternalBatchActivity(batchDepth: batchDepth, activeFlushDepth: activeFlushDepth,
      globalUpdatesPending: Updates.len > 0, globalEffectsPending: Effects.len > 0)

  proc internalFlushEpochConstructionCount*(): uint64 =
    ## Narrow private proof counter; reading it never queries/creates a token.
    flushEpochConstructions

# Forward declarations — implemented in computation.nim, registered here via
# callbacks so this module does not import it.
var updateComputationCb*: proc(comp: ComputationBase)
var runTopCb*: proc(comp: ComputationBase)
  ## Brings a queued computation up to date: a stale one re-runs; a pending
  ## one first refreshes the memos it read and re-runs only if one of them
  ## actually changed (see `computation.runTop`).

# ---------------------------------------------------------------------------
# Marking
# ---------------------------------------------------------------------------
#
# A write marks the computations that read the written signal *stale* (they
# must re-run) and everything downstream of the memos among them *pending*
# (they may have to re-run, if a memo they read ends up with a new value).
# Every marked computation is queued once: memos (`pure`) in `Updates`,
# effects in `Effects`. The flush then brings each queued node up to date by
# pulling its sources first, so no computation ever runs against a mix of
# old and new inputs, and a node whose memo inputs all turn out unchanged
# does not run at all.

proc enqueue(comp: ComputationBase) {.inline.} =
  if comp.pure: Updates.add(comp)
  else: Effects.add(comp)

proc markDownstream*(signal: SignalStateBase) =
  ## Mark every clean computation downstream of `signal` pending and queue it.
  var i = 0
  while i < signal.observers.len:
    let obs = signal.observers[i]
    if obs.state == csClean:
      obs.state = csPending
      enqueue(obs)
      if obs.memoSignal != nil: markDownstream(obs.memoSignal)
    inc i

proc markSignalWrite*(signal: SignalStateBase) =
  ## A plain signal was written: its readers are stale. Each is queued even
  ## if it is already marked, so a write made from inside a flush (nested
  ## batch) still runs its readers before that nested batch returns.
  var i = 0
  while i < signal.observers.len:
    let obs = signal.observers[i]
    let wasClean = obs.state == csClean
    obs.state = csStale
    enqueue(obs)
    if wasClean and obs.memoSignal != nil: markDownstream(obs.memoSignal)
    inc i

proc markMemoChanged*(signal: SignalStateBase) =
  ## A memo produced a new value: its readers are stale. They were already
  ## marked pending and queued when the memo itself was marked; a reader that
  ## is clean (it subscribed after that) is queued now.
  var i = 0
  while i < signal.observers.len:
    let obs = signal.observers[i]
    let wasClean = obs.state == csClean
    obs.state = csStale
    if wasClean:
      enqueue(obs)
      if obs.memoSignal != nil: markDownstream(obs.memoSignal)
    inc i

proc flushUpdates*() =
  ## Process all queued updates: memos (pure) first, then effects. Each
  ## queued node is brought up to date through `runTopCb`, which pulls the
  ## memos it reads before deciding whether it must re-run.
  if batchDepth > 0:
    return
  when defined(isonimInternalFlushObservation):
    inc activeFlushDepth
    var internalFlushReturned = false
    defer:
      # No observer, allocation, assertion, or application callback on unwind.
      # Inner errors caught by outer application work do not settle its epoch.
      dec activeFlushDepth
      if activeFlushDepth == 0:
        if activeFlushEpoch != nil:
          activeFlushEpoch.state =
            if internalFlushReturned: ifsReturned else: ifsUnwound
        activeFlushEpoch = nil
  inc ExecCount
  let pendingUpdates = Updates
  let pendingEffects = Effects
  Updates = newNativeSeq[ComputationBase]()
  Effects = newNativeSeq[ComputationBase]()
  var phase = 0
  var i = 0
  var completed = false
  try:
    if runTopCb != nil:
      while i < pendingUpdates.len:
        runTopCb(pendingUpdates[i])
        inc i
      phase = 1
      i = 0
      while i < pendingEffects.len:
        runTopCb(pendingEffects[i])
        inc i
    completed = true
  finally:
    if not completed:
      # An exception abandons the rest of this flush and propagates
      # unchanged. The abandoned nodes must stay reachable by later writes:
      # a pending node, or a stale effect, goes back to clean so the next
      # change it depends on queues it again; a stale memo stays stale so
      # the next read recomputes it.
      proc release(comp: ComputationBase) =
        if comp.state == csPending or (comp.state == csStale and not comp.pure):
          comp.state = csClean
      if phase == 0:
        for k in i + 1 ..< pendingUpdates.len: release(pendingUpdates[k])
        for k in 0 ..< pendingEffects.len: release(pendingEffects[k])
      else:
        for k in i + 1 ..< pendingEffects.len: release(pendingEffects[k])
  when defined(isonimInternalFlushObservation):
    internalFlushReturned = true

proc runUpdates*(fn: proc()) =
  ## If we're already inside an update cycle, just run fn.
  ## Otherwise, initialize queues, run fn, then flush.
  if batchDepth > 0:
    fn()
    return
  inc batchDepth
  Updates = newNativeSeq[ComputationBase]()
  Effects = newNativeSeq[ComputationBase]()
  try:
    fn()
  finally:
    dec batchDepth
    flushUpdates()

proc batch*(fn: proc()) =
  ## Batches signal writes — observers execute once after fn completes.
  inc batchDepth
  try:
    fn()
  finally:
    dec batchDepth
    if batchDepth == 0:
      flushUpdates()

proc untrack*[T](fn: proc(): T): T =
  ## Suspends dependency tracking inside fn.
  let prevListener = Listener
  Listener = nil
  try:
    result = fn()
  finally:
    Listener = prevListener

proc untrack*(fn: proc()) =
  ## Suspends dependency tracking inside fn (void variant).
  let prevListener = Listener
  Listener = nil
  try:
    fn()
  finally:
    Listener = prevListener
