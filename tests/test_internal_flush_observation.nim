## Real graph, signals, pure memos, effects, owners and batch calls; no mocks,
## queue injection or replacement computation callbacks. Retained epochs prove
## passive state only, not event/microtask quiescence or weak GC lifetime.
import isonim/core/[batch, signals, computation, owner, graph]

const observationScenario {.strdefine.} = "all"

proc snapshotNoRaise(): InternalBatchActivity {.raises: [].} =
  internalBatchActivity()

proc readIssuedState(epoch: InternalFlushEpoch): InternalFlushState {.raises: [ValueError].} =
  internalFlushState(epoch)

template expect(condition: bool; label: string) =
  if not condition:
    echo "FAIL:", label
    raise newException(AssertionDefect, label)

proc scenario(name: string; body: proc()) =
  if observationScenario == "all" or observationScenario == name:
    echo "BEGIN:", name
    body()
    echo "PASS:", name

scenario("local", proc() =
  let source = createSignal(0)
  var trace: seq[int]
  var epoch: InternalFlushEpoch
  var dispose: proc()
  createRoot proc(stop: proc()) =
    dispose = stop
    createEffect proc() =
      let value = source.val
      if value > 0:
        trace.add(1)
        epoch = currentInternalFlushEpoch()
        echo "WITNESS:local:first-effect"
        expect(epoch != nil, "local-issued")
        expect(internalFlushState(epoch) == ifsActive, "local-active")
        let before = ExecCount
        let activity = internalBatchActivity()
        expect(not activity.globalUpdatesPending and not activity.globalEffectsPending,
          "local-globals-cleared")
        for i in 0 .. 3:
          expect(currentInternalFlushEpoch() == epoch, "local-same-token")
          expect(internalFlushState(epoch) == ifsActive, "local-passive-active")
          expect(internalBatchActivity() == activity, "local-snapshot-stable")
        expect(ExecCount == before and trace == @[1], "local-query-is-passive")
        var copied = activity
        copied.activeFlushDepth = 999
        copied.globalEffectsPending = true
        expect(internalBatchActivity() == activity, "local-snapshot-is-value")
    createEffect proc() =
      let value = source.val
      if value > 0: trace.add(2)
  defer: dispose()
  batch proc() = source.val = 1
  expect(trace == @[1, 2] and source.val == 1, "local-real-order-value")
  expect(internalFlushState(epoch) == ifsReturned, "local-returned")
  expect(currentInternalFlushEpoch() == nil, "local-cleared")
)

scenario("activity", proc() =
  let source = createSignal(0)
  var trace: seq[int]
  var dispose: proc()
  createRoot proc(stop: proc()) =
    dispose = stop
    createEffect proc() =
      if source.val > 0:
        trace.add(1)
        echo "WITNESS:activity:first-effect"
        let snapshot = internalBatchActivity()
        expect(not snapshot.globalUpdatesPending and not snapshot.globalEffectsPending,
          "activity-real-globals-empty")
        expect(snapshot.activeFlushDepth == 1, "activity-local-work-is-active")
        expect(trace == @[1], "activity-later-pending")
    createEffect proc() =
      if source.val > 0: trace.add(2)
  defer: dispose()
  batch proc() = source.val = 1
  expect(trace == @[1, 2], "activity-later-ran")
)

scenario("nested", proc() =
  let outer = createSignal(0)
  let inner = createSignal(0)
  var trace: seq[int]
  var epoch: InternalFlushEpoch
  var dispose: proc()
  createRoot proc(stop: proc()) =
    dispose = stop
    createEffect proc() =
      if inner.val > 0:
        trace.add(2)
        expect(currentInternalFlushEpoch() == epoch, "nested-same-token")
        expect(internalFlushState(epoch) == ifsActive, "nested-inner-active")
        expect(internalBatchActivity().activeFlushDepth == 2, "nested-real-depth")
    createEffect proc() =
      if outer.val > 0:
        trace.add(1)
        epoch = currentInternalFlushEpoch()
        batch proc() = inner.val = 1
        echo "WITNESS:nested:inner-returned"
        expect(trace == @[1, 2], "nested-real-trace")
        expect(internalFlushState(epoch) == ifsActive, "nested-outer-still-active")
        expect(currentInternalFlushEpoch() == epoch, "nested-outer-same-token")
    createEffect proc() =
      if outer.val > 0: trace.add(3)
  defer: dispose()
  batch proc() = outer.val = 1
  expect(trace == @[1, 2, 3], "nested-remaining-outer-ran")
  expect(internalFlushState(epoch) == ifsReturned, "nested-outer-returned")
)

proc successfulEpoch(): InternalFlushEpoch =
  let source = createSignal(0)
  var captured: InternalFlushEpoch
  var calls = 0
  var dispose: proc()
  createRoot proc(stop: proc()) =
    dispose = stop
    createEffect proc() =
      if source.val > 0:
        inc calls
        captured = currentInternalFlushEpoch()
  defer: dispose()
  batch proc() = source.val = 1
  expect(calls == 1 and source.val == 1, "success-real-work")
  expect(captured != nil, "success-issued")
  result = captured

proc thrownEpoch(defect: bool): InternalFlushEpoch =
  let source = createSignal(0)
  var captured: InternalFlushEpoch
  var trace: seq[int]
  let ordinaryError = newException(ValueError, "retained original flush error")
  let originalDefect = newException(Defect, "retained original flush defect")
  var dispose: proc()
  createRoot proc(stop: proc()) =
    dispose = stop
    createEffect proc() =
      if source.val > 0:
        trace.add(1)
        captured = currentInternalFlushEpoch()
        if defect: raise originalDefect
        raise ordinaryError
    createEffect proc() =
      if source.val > 0: trace.add(2)
  defer: dispose()
  var caught = false
  try:
    batch proc() = source.val = 1
  except ValueError as actual:
    expect(not defect and actual == ordinaryError, "throw-exact-catchable-identity")
    caught = true
  except Defect as actual:
    expect(defect and actual == originalDefect, "throw-exact-defect-identity")
    caught = true
  echo "WITNESS:throw:original-object-caught"
  expect(caught and trace == @[1] and source.val == 1, "throw-real-abandoned-work")
  expect(captured != nil, "throw-issued")
  result = captured

scenario("throw", proc() =
  let errorEpoch = thrownEpoch(false)
  expect(internalFlushState(errorEpoch) == ifsUnwound, "throw-unwound")
  expect(currentInternalFlushEpoch() == nil, "throw-cleared")
  let defectEpoch = thrownEpoch(true)
  expect(internalFlushState(defectEpoch) == ifsUnwound, "defect-unwound")
  expect(defectEpoch != errorEpoch, "defect-new-epoch")
)

scenario("reset", proc() =
  let failed = thrownEpoch(false)
  let fresh = successfulEpoch()
  echo "WITNESS:reset:subsequent-success-ran"
  expect(fresh != failed, "reset-fresh-after-unwind")
  expect(internalFlushState(failed) == ifsUnwound, "reset-old-unwound")
  expect(internalFlushState(fresh) == ifsReturned, "reset-new-returned")
  expect(currentInternalFlushEpoch() == nil, "reset-cleared")
)

scenario("reuse", proc() =
  let first = successfulEpoch()
  let second = successfulEpoch()
  echo "WITNESS:reuse:two-successes-ran"
  expect(first != second, "reuse-fresh-identities")
  expect(internalFlushState(first) == ifsReturned and
    internalFlushState(second) == ifsReturned, "reuse-old-state-stable")
)

scenario("caught-inner", proc() =
  let outer = createSignal(0)
  let inner = createSignal(0)
  var epoch: InternalFlushEpoch
  var trace: seq[int]
  let original = newException(ValueError, "caught inner flush")
  var dispose: proc()
  createRoot proc(stop: proc()) =
    dispose = stop
    createEffect proc() =
      if inner.val > 0:
        trace.add(2)
        expect(currentInternalFlushEpoch() == epoch, "caught-inner-same-token")
        raise original
    createEffect proc() =
      if outer.val > 0:
        trace.add(1)
        epoch = currentInternalFlushEpoch()
        var caught = false
        try:
          batch proc() = inner.val = 1
        except ValueError as actual:
          expect(actual == original, "caught-inner-exact-error")
          caught = true
        expect(caught and trace == @[1, 2], "caught-inner-real-error")
        expect(internalFlushState(epoch) == ifsActive, "caught-inner-outer-active")
    createEffect proc() =
      if outer.val > 0: trace.add(3)
  defer: dispose()
  batch proc() = outer.val = 1
  expect(trace == @[1, 2, 3], "caught-inner-remaining-outer-ran")
  expect(internalFlushState(epoch) == ifsReturned, "caught-inner-outer-returned")
)

scenario("ambient-exception", proc() =
  let original = newException(ValueError, "ambient retained exception")
  var caught = false
  try:
    raise original
  except ValueError as actual:
    expect(actual == original and getCurrentException() == original, "ambient-real-except")
    let epoch = successfulEpoch()
    expect(internalFlushState(epoch) == ifsReturned, "ambient-success-returned")
    expect(getCurrentException() == original, "ambient-identity-preserved")
    caught = true
  expect(caught, "ambient-caught")
)

scenario("open-batch-and-pure", proc() =
  let source = createSignal(0)
  var trace: seq[int]
  var dispose: proc()
  createRoot proc(stop: proc()) =
    dispose = stop
    discard createMemo(proc(): int =
      let value = source.val
      if value > 0: trace.add(1)
      value * 2)
    createEffect proc() =
      if source.val > 0: trace.add(2)
  defer: dispose()
  batch proc() =
    source.val = 3
    expect(currentInternalFlushEpoch() == nil, "open-batch-no-flush")
    let snapshot = internalBatchActivity()
    expect(snapshot.batchDepth == 1 and snapshot.activeFlushDepth == 0,
      "open-batch-depth")
    expect(snapshot.globalUpdatesPending and snapshot.globalEffectsPending,
      "open-batch-real-pure-and-effect-queues")
    expect(trace.len == 0, "open-batch-deferred")
  expect(trace == @[1, 2], "open-batch-pure-before-effect")
)

scenario("direct-and-invalid", proc() =
  var direct = 0
  createRoot proc(dispose: proc()) =
    defer: dispose()
    createEffect proc() =
      inc direct
      expect(currentInternalFlushEpoch() == nil, "direct-effect-no-flush")
    discard createMemo(proc(): int =
      inc direct
      expect(currentInternalFlushEpoch() == nil, "direct-memo-no-flush")
      9)
  expect(direct == 2, "direct-real-computations")
  for invalid in [InternalFlushEpoch(nil), InternalFlushEpoch()]:
    var caught = false
    try:
      discard internalFlushState(invalid)
    except ValueError as actual:
      let expected = if invalid == nil: "internal flush epoch is nil"
        else: "internal flush epoch was not issued"
      expect(actual.msg == expected, "invalid-exact-refusal")
      caught = true
    expect(caught, "invalid-refused")
  let real = successfulEpoch()
  expect(readIssuedState(real) == ifsReturned, "invalid-real-issued-companion")
  expect(snapshotNoRaise().activeFlushDepth == 0, "snapshot-no-raise-companion")
)

scenario("nested-first-query", proc() =
  let outer = createSignal(0)
  let inner = createSignal(0)
  let initialConstructions = internalFlushEpochConstructionCount()
  var epoch: InternalFlushEpoch
  var trace: seq[int]
  var dispose: proc()
  createRoot proc(stop: proc()) =
    dispose = stop
    createEffect proc() =
      if inner.val > 0:
        trace.add(2)
        expect(internalBatchActivity().activeFlushDepth == 2, "lazy-nested-real-depth")
        epoch = currentInternalFlushEpoch()
        expect(epoch != nil and internalFlushState(epoch) == ifsActive,
          "lazy-nested-first-issued-active")
    createEffect proc() =
      if outer.val > 0:
        trace.add(1)
        expect(internalFlushEpochConstructionCount() == initialConstructions,
          "lazy-outer-entry-unobserved")
        batch proc() = inner.val = 1
        trace.add(3)
        expect(trace == @[1, 2, 3], "lazy-nested-real-order")
        expect(epoch != nil and currentInternalFlushEpoch() == epoch,
          "lazy-nested-outer-same-identity")
        expect(internalFlushState(epoch) == ifsActive, "lazy-nested-outer-still-active")
        expect(internalBatchActivity().activeFlushDepth == 1, "lazy-nested-outer-depth")
        expect(internalFlushEpochConstructionCount() == initialConstructions + 1,
          "lazy-nested-exactly-one-construction")
    createEffect proc() =
      if outer.val > 0:
        trace.add(4)
        expect(currentInternalFlushEpoch() == epoch, "lazy-later-outer-same-identity")
  defer: dispose()
  batch proc() = outer.val = 1
  expect(trace == @[1, 2, 3, 4] and outer.val == 1 and inner.val == 1,
    "lazy-real-remaining-outer-work")
  expect(internalFlushState(epoch) == ifsReturned, "lazy-outer-returned")
  expect(currentInternalFlushEpoch() == nil, "lazy-outer-cleared")
  expect(internalFlushEpochConstructionCount() == initialConstructions + 1,
    "lazy-only-one-total-construction")
)

echo "INTERNAL FLUSH OBSERVATION COMPLETE"
