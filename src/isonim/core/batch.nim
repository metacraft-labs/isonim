## isonim/core/batch.nim
##
## Batching and untracking utilities: batch, untrack, runUpdates, flushUpdates.
## Defers reactive updates until the batch completes to avoid redundant work.
##
## The flush is synchronous: it runs when the outermost write or batch
## ends, before that call returns, so code that writes a signal and then
## reads anything derived from it sees the write. Every write that is not
## inside a batch flushes on its own; there is no automatic batching.
##
## Port of SolidJS signal.ts batching logic.

import types, graph, platform
export platform

when defined(js):
  # On JS, NativeSeq is JsArray (ref) — must be initialized eagerly.
  var Updates* = newNativeSeq[ComputationBase]()
    ## The memos and pure computations queued for the next flush.
  var Effects* = newNativeSeq[ComputationBase]()
    ## The effects queued for the next flush, run after `Updates`.
  var batchDepth*: int
    ## How many `batch` (or `runUpdates`) calls are running; the flush
    ## waits until it is back to 0.
else:
  var Updates* {.threadvar.}: NativeSeq[ComputationBase]
    ## The memos and pure computations queued for the next flush.
  var Effects* {.threadvar.}: NativeSeq[ComputationBase]
    ## The effects queued for the next flush, run after `Updates`.
  var batchDepth* {.threadvar.}: int
    ## How many `batch` (or `runUpdates`) calls are running; the flush
    ## waits until it is back to 0.

when defined(isonimInternalFlushObservation):
  type
    InternalFlushState* = enum
      ## The actual outermost flush is still running, returned, or unwound.
      ifsActive, ifsReturned, ifsUnwound
    InternalFlushEpoch* = ref object
      ## An opaque token naming one outermost flush (only with
      ## `-d:isonimInternalFlushObservation`); read it with
      ## `internalFlushState`.
      # Only this module issues valid tokens. Default construction is invalid.
      issued: bool
      state: InternalFlushState
    InternalBatchActivity* = object
      ## A copied activity snapshot, not an event/microtask quiescence proof.
      batchDepth*: int
        ## `batchDepth` when the snapshot was taken.
      activeFlushDepth*: int
        ## How many flushes (nested ones included) were running.
      globalUpdatesPending*: bool
        ## Memos or pure computations were queued for the next flush.
      globalEffectsPending*: bool
        ## Effects were queued for the next flush.

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

# Forward declaration — implemented in computation.nim, registered here via
# a callback so this module does not import it.
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
# Marked computations are queued: memos (`pure`) in `Updates`, effects in
# `Effects`. A downstream node is queued once, when it is first marked; a
# direct reader of the written signal is queued on every write (see
# `markSignalWrite`). A queued node that is already clean when the flush
# reaches it is skipped, so a duplicate entry costs one state check.
# The flush then brings each queued node up to date by
# pulling its sources first, so no computation ever runs against a mix of
# old and new inputs, and a node whose memo inputs all turn out unchanged
# does not run at all.

var ownerMarked* {.threadvar.}: bool
  ## Set when a computation that owns children is marked during the current
  ## outermost flush. Only then can a queued node have an out-of-date owner,
  ## so `runTop` walks owner chains only then (the common case, many leaf
  ## effects and no re-running parent, skips the walk entirely).
var flushDepth* {.threadvar.}: int
  ## How many flushes are running (nested ones included).

proc enqueue(comp: ComputationBase) {.inline.} =
  if comp.owned.len > 0: ownerMarked = true
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
  ## is clean (it subscribed after that) is queued now. A reader that is a
  ## stale memo is queued again too: a flush abandoned by a `Defect` leaves
  ## the memos it did not reach stale and in no queue (see `flushUpdates`),
  ## and marking skips a node that is not clean, so without this its readers
  ## would never hear of the change. When it is queued already, the second
  ## entry finds it clean and costs one state check.
  var i = 0
  while i < signal.observers.len:
    let obs = signal.observers[i]
    let previous = obs.state
    obs.state = csStale
    if previous == csClean:
      enqueue(obs)
      if obs.memoSignal != nil: markDownstream(obs.memoSignal)
    elif previous == csStale and obs.pure:
      enqueue(obs)
    inc i

var flushError* {.threadvar.}: ref CatchableError
  ## The first error of the current outermost flush that no handler took
  ## (`computation.handleError` keeps it; the outermost flush rethrows it).

proc flushUpdates*() =
  ## Process all queued updates: memos (pure) first, then effects. Each
  ## queued node is brought up to date through `runTopCb`, which pulls the
  ## memos it reads before deciding whether it must re-run.
  ##
  ## A computation that raises a `CatchableError` does not stop the flush:
  ## the error goes to the nearest handler above it (see
  ## `computation.handleError`), and one no handler takes is rethrown by the
  ## outermost flush after the queue is empty.
  ##
  ## A `Defect`, and on the JS backend an exception that is not a Nim
  ## exception, is not routed: it abandons the rest of the flush and
  ## propagates as the same object to the code that wrote or ran the batch.
  ## The abandoned nodes are released so that the graph stays usable: the
  ## next change they depend on queues them again, and a memo left out of
  ## date recomputes on its next read. An error kept for the outermost flush
  ## is dropped then, so it never leaks into a later flush.
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
  inc flushDepth
  let pendingUpdates = Updates
  let pendingEffects = Effects
  Updates = newNativeSeq[ComputationBase]()
  Effects = newNativeSeq[ComputationBase]()
  var phase = 0
  var i = 0
  var completed = false
  var failure: ref CatchableError
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
    dec flushDepth
    if not completed:
      # Only a `Defect`, or on JS an exception that is not a Nim exception
      # (a `TypeError` from a host API), gets here: those are not routed to
      # handlers and still abandon the rest of the flush, propagating
      # unchanged. The abandoned nodes must stay reachable by later writes:
      # marking skips a node that is not clean, so a pending node, or a
      # stale effect, goes back to clean and the next change it depends on
      # queues it again; a stale memo stays stale so the next read
      # recomputes it, and a change of a memo it reads queues it again
      # (`markMemoChanged`). The release starts at the node being processed
      # (index `i`): the exception may have come from a memo it was pulling,
      # in which case that node is still pending and in no other queue.
      proc release(comp: ComputationBase) =
        if comp.state == csPending or (comp.state == csStale and not comp.pure):
          comp.state = csClean
      if phase == 0:
        for k in i ..< pendingUpdates.len: release(pendingUpdates[k])
        for k in 0 ..< pendingEffects.len: release(pendingEffects[k])
      else:
        for k in i ..< pendingEffects.len: release(pendingEffects[k])
    if flushDepth == 0:
      ownerMarked = false
      # Taken even when unwinding, so a kept error never leaks into the next
      # flush; the exception that is unwinding wins.
      failure = flushError
      flushError = nil
  if failure != nil: raise failure
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
  ##
  ## Nested batches flush once, when the outermost ends, synchronously,
  ## before `batch` returns. Inside the batch a memo read is already
  ## current: reading it brings it up to date first. Effects run after the
  ## batch, once each, and never see some derived values updated and
  ## others not. Why synchronous: a read always sees the write before it,
  ## unlike frameworks that defer the update to a microtask.
  ##
  ## If a computation of the flush raised an ordinary error that no handler
  ## took, `batch` raises it, the same object, after the whole flush has
  ## run. A `Defect` raised by a computation of the flush propagates at
  ## once and abandons the rest of the flush (see `flushUpdates`). An
  ## exception raised by `fn` itself propagates after the writes made
  ## before it have been flushed.
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
