## Normal application builds retain dispatch ordering without coverage state.
## This target intentionally does not enable the seam suite's instrumentation.
import std/[unittest, monotimes]
import isonim/core/nondet
import isonim/core/graph

static:
  doAssert compiles(newRealBackend(1).dispatchSequence)
  doAssert not compiles(newRealBackend(1).seamCalls)
  doAssert not compiles(newRealBackend(1).randomDrawCount)
  doAssert not compiles(newRealBackend(1).checkpointDispatch)
  doAssert not compiles(SignalStateBase().checkpointLease)
  doAssert not compiles(OwnerBase().checkpointSignals)

suite "normal nondeterminism backend":
  test "coverage is absent while the real clock remains usable":
    install(newRealBackend(1))
    defer: install(NondetBackend(nil))
    check backend().dispatchSequence == 0
    check nondet.now().ticks > 0
