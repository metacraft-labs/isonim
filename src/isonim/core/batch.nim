## isonim/core/batch.nim
##
## Batching and untracking utilities: batch, untrack, runUpdates, flushUpdates.
## Defers reactive updates until the batch completes to avoid redundant work.
##
## Port of SolidJS signal.ts batching logic.
