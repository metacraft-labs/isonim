## Real enabled-but-unobserved graph work, measured by the private construction
## counter rather than a query that itself creates the token or heap estimates.
import isonim/core/[batch, signals, computation, owner]

let before = internalFlushEpochConstructionCount()
let source = createSignal(0)
var trace: seq[int]
var dispose: proc()
createRoot proc(stop: proc()) =
  dispose = stop
  discard createMemo(proc(): int =
    let value = source.val
    trace.add(value * 10)
    value * 2)
  createEffect proc() = trace.add(source.val)
batch proc() = source.val = 1
batch proc() = source.val = 2
flushUpdates() # Empty real invocation also allocates no token.
doAssert trace == @[0, 0, 10, 1, 20, 2]
doAssert internalFlushEpochConstructionCount() == before
doAssert currentInternalFlushEpoch() == nil
doAssert internalFlushEpochConstructionCount() == before
var captured: InternalFlushEpoch
createRoot proc(stop: proc()) =
  defer: stop()
  createEffect proc() =
    if source.val == 3:
      captured = currentInternalFlushEpoch()
      doAssert captured != nil
      doAssert internalFlushState(captured) == ifsActive
  batch proc() = source.val = 3
doAssert internalFlushEpochConstructionCount() == before + 1
doAssert internalFlushState(captured) == ifsReturned
dispose()
echo "UNUSED REAL GRAPH ZERO TOKEN CONSTRUCTIONS; OBSERVED POSITIVE ONE"
