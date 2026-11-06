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

# Forward declaration — implemented in computation.nim, registered here via callback
var updateComputationCb*: proc(comp: ComputationBase)

proc flushUpdates*() =
  ## Process all queued updates: memos (pure) first, then effects.
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
  if updateComputationCb != nil:
    for comp in pendingUpdates:
      if comp.state == csStale:
        updateComputationCb(comp)
    for comp in pendingEffects:
      if comp.state == csStale:
        updateComputationCb(comp)
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
