## Two genuine graphs on two native threads, no callback replacement or GC-safety
## casts. Only POD synchronization/results are shared. If the owning graph API
## is not GC-safe, preserve that compile limit rather than manufacturing support.
import std/[atomics, monotimes, times, os]
import isonim/core/[batch, signals, computation, owner]

var entered: Atomic[int]
var results: array[2, int]
proc worker(id: int) {.thread.} =
  let source = createSignal(0)
  var epoch: InternalFlushEpoch
  createRoot proc(dispose: proc()) =
    defer: dispose()
    createEffect proc() =
      if source.val > 0:
        epoch = currentInternalFlushEpoch()
        doAssert epoch != nil
        doAssert internalFlushState(epoch) == ifsActive
        discard entered.fetchAdd(1)
        # Bounded rendezvous: no fake queues/depth and no transferred tokens.
        let deadline = getMonoTime() + initDuration(seconds = 10)
        while entered.load() < 2 and getMonoTime() < deadline:
          sleep(1)
        doAssert entered.load() == 2
        doAssert internalBatchActivity().activeFlushDepth == 1
        doAssert internalFlushState(epoch) == ifsActive
    batch proc() = source.val = 1
    doAssert internalFlushState(epoch) == ifsReturned
    doAssert internalFlushEpochConstructionCount() == 1
    results[id] = source.val
var threads: array[2, Thread[int]]
for id in 0 .. 1: createThread(threads[id], worker, id)
joinThreads(threads)
doAssert results == [1, 1]
echo "TWO REAL THREAD GRAPH EPOCHS INDEPENDENT"
