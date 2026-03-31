## isonim/core/batch.nim
##
## Batching and untracking utilities: batch, untrack, runUpdates, flushUpdates.
## Defers reactive updates until the batch completes to avoid redundant work.
##
## Port of SolidJS signal.ts batching logic.

import types, graph

var Updates* {.threadvar.}: seq[ComputationBase]
var Effects* {.threadvar.}: seq[ComputationBase]
var batchDepth* {.threadvar.}: int

# Forward declaration — implemented in computation.nim, registered here via callback
var updateComputationCb*: proc(comp: ComputationBase)

proc flushUpdates*() =
  ## Process all queued updates: memos (pure) first, then effects.
  if batchDepth > 0:
    return
  inc ExecCount
  let pendingUpdates = Updates
  let pendingEffects = Effects
  Updates = @[]
  Effects = @[]
  if updateComputationCb != nil:
    for comp in pendingUpdates:
      if comp.state == csStale:
        updateComputationCb(comp)
    for comp in pendingEffects:
      if comp.state == csStale:
        updateComputationCb(comp)

proc runUpdates*(fn: proc()) =
  ## If we're already inside an update cycle, just run fn.
  ## Otherwise, initialize queues, run fn, then flush.
  if batchDepth > 0:
    fn()
    return
  inc batchDepth
  Updates = @[]
  Effects = @[]
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
