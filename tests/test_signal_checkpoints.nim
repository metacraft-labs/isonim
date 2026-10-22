## Uses the real reactive graph and deterministic TestClock. The clock avoids
## physical sleeps; browser coverage separately exercises actual task ordering.
## The schedule-failure subclass injects a single exception and otherwise uses
## real TestClock scheduling, to cover rollback without sleeps or fake timers.
import std/[unittest, hashes, json]
import isonim/core/[signals, owner, graph, types, computation, batch, checkpoints, nondet]
from ./fixtures/checkpoint_hash/hashes import HashValue, hash

type
  Opaque = ref object
    content: int
  Hashed = object
    content: int
  Serialized = ref object
    content: int
  HashedRef = ref object
    content: int
  ExplicitHash = object
    content: int
proc hash(value: Hashed): Hash = Hash(value.content * 17)
proc hash(value: HashedRef): Hash = Hash(value.content * 31)
proc hash(value: Serialized): Hash = 0
proc hash(value: ExplicitHash): Hash = 0
proc checkpointHash(value: ExplicitHash): uint32 = uint32(value.content * 13)
proc checkpointSerialize(value: Serialized): string = $value.content
type CallbackValue = object
  content: int
type BornValue = object
  content: int
type
  Tree = object
    content: int
    children: seq[Tree]
  RecursiveA = object
    children: seq[RecursiveB]
  RecursiveB = object
    children: seq[RecursiveA]
    identity: Opaque
# This fixture chooses length equality; Nim 2.2.4 cannot infer noSideEffect for
# its generic equality through these mutually recursive sequence types.
func `==`(a, b: RecursiveA): bool = a.children.len == b.children.len
type
  FailingClock = ref object of TestClock
    failNext: bool
  UnsupportedClock = ref object of ClockBase
method schedule(clock: FailingClock; callback: proc(); delayMs: float64): int =
  if clock.failNext:
    clock.failNext = false
    raise newException(ValueError, "fixture initial schedule failure")
  procCall schedule(TestClock(clock), callback, delayMs)
when not defined(js):
  type CurrentValue = object
    payload: array[32, int]
  var currentTarget: Signal[CurrentValue]
  var releaseCurrent, failCurrent: bool
  var currentDestructions: int
  proc `=destroy`(value: var CurrentValue) =
    inc currentDestructions
    # An inline payload distinguishes a safe owned value copy from a borrow of
    # destroyed original storage; it does not mutate a shared ref/seq payload.
    value.payload[0] = -1
  proc checkpointSerialize(value: CurrentValue): string =
    if releaseCurrent: currentTarget = nil
    doAssert value.payload[0] == 42,
      "current contributor must read the original expected value"
    doAssert value.payload[31] == 43
    if failCurrent: raise newException(ValueError, "fixture contributor failure")
    $value.payload[0]
var contributionAction: proc()
var bornContributions: int
var laterVictim: Signal[int]
proc checkpointSerialize(value: CallbackValue): string =
  if contributionAction != nil: contributionAction()
  $value.content
proc checkpointSerialize(value: BornValue): string =
  inc bornContributions
  $value.content

proc scriptRun(changed = false): seq[SignalCheckpoint] =
  let backend = newTestBackend()
  var checkpoints: seq[SignalCheckpoint]
  let session = startCheckpoints(backend, proc(c: SignalCheckpoint) = checkpoints.add(c), every=2)
  createRoot proc(dispose: proc()) =
    let source = createSignal(1)
    let derived = createSignal(0)
    var scalars: seq[Signal[int]]
    for i in 0..<8: scalars.add(createSignal(i))
    let opaque = createSignal(Opaque(content:1))
    let custom = createSignal(Hashed(content:2))
    createEffect(proc() = derived.val = source.val * 3)
    doAssert liveSignalCount() == 12
    discard backend.schedule((proc() =
      batch(proc() =
        source.val = 2
        source.val = if changed: 4 else: 3)
      doAssert derived.val == (if changed: 12 else: 9)), 1)
    discard backend.schedule((proc() =
      scalars[0].val = 15
      opaque.val = Opaque(content:9)
      custom.val = Hashed(content:4)), 2)
    for i in 3..5:
      let value = i
      discard backend.schedule((proc() = scalars[1].val = value), float64(i))
    TestClock(backend).advance(100)
    doAssert backend.dispatchSequence == 5
    doAssert checkpoints.len == 3
    dispose()
    doAssert liveSignalCount() == 0
  session.stop()
  checkpoints

suite "signal checkpoints":
  test "native current contribution owns value through last-reference release and errors":
    when not defined(js):
      for failing in [false, true]:
        let empty = signalStateHash(0)
        var input: CurrentValue
        input.payload[0] = 42
        input.payload[31] = 43
        currentTarget = createSignal(input)
        check liveSignalCount() == 1
        currentDestructions = 0
        releaseCurrent = true
        failCurrent = failing
        if failing:
          expect ValueError: discard signalStateHash(0)
        else:
          check signalStateHash(0) == empty
        releaseCurrent = false
        failCurrent = false
        check currentTarget == nil
        check currentDestructions >= 1
        check liveSignalCount() == 0
    else:
      check liveSignalCount() == 0

  test "native value copy sink overwrite preserves its original lifetime":
    when not defined(js):
      let original = createSignal(42)
      var snapshot = original[]
      snapshot = default(typeof(snapshot))
      check snapshot.value == 0
      check original.val == 42
      check liveSignalCount() == 1
    else:
      check liveSignalCount() == 0

  test "native signal value copy destruction and overwrite preserve live originals":
    when not defined(js):
      block:
        let first = createSignal(42)
        let second = createSignal(43)
        let before = signalStateHash(0)
        proc inspectCopies() =
          let snapshot = first[]
          check snapshot.value == 42
          var overwritten = first[]
          overwritten = second[]
          check overwritten.value == 43
          check liveSignalCount() == 2
        inspectCopies()
        check first.val == 42
        check second.val == 43
        check liveSignalCount() == 2
        check signalStateHash(0) == before
      check liveSignalCount() == 0
    else:
      # JS ownership remains WeakRef-based; this regression is native-only.
      check liveSignalCount() == 0

  test "native original destruction invalidates metadata while its value copy survives":
    when not defined(js):
      var original = createSignal(42)
      let snapshot = original[]
      check liveSignalCount() == 1
      original = nil
      check snapshot.value == 42
      check liveSignalCount() == 0
      discard signalStateHash(0)
    else:
      check liveSignalCount() == 0

  test "native owner disposal excludes retained originals and surviving value copies":
    when not defined(js):
      var retained: Signal[int]
      var snapshot: typeof(default(Signal[int])[])
      createRoot proc(dispose: proc()) =
        retained = createSignal(42)
        snapshot = retained[]
        check liveSignalCount() == 1
        dispose()
        check liveSignalCount() == 0
      check retained.val == 42
      check snapshot.value == 42
      check liveSignalCount() == 0
    else:
      check liveSignalCount() == 0

  test "failed initial scheduling releases observer and permits a clean retry":
    let backend = FailingClock(failNext:true)
    var calls: int
    try:
      discard startCheckpoints(backend, proc(c: SignalCheckpoint) = inc calls)
      check false
    except ValueError as error:
      check error.msg == "fixture initial schedule failure"
    check backend.checkpointDispatch == nil
    check backend.dispatchSequence == 0
    check backend.randomDrawCount == 0
    let retry = startCheckpoints(backend, proc(c: SignalCheckpoint) = inc calls)
    TestClock(backend).advance(100)
    check calls == 1
    check backend.dispatchSequence == 0
    retry.stop()
    check backend.checkpointDispatch == nil
    TestClock(backend).advance(100)
    check calls == 1
    let unsupported = UnsupportedClock()
    for attempt in 0..1:
      expect ValueError:
        discard startCheckpoints(unsupported, proc(c: SignalCheckpoint) = discard)
      check unsupported.checkpointDispatch == nil

  test "sessions remain scoped to supplied backends across current backend changes":
    let first = newTestBackend()
    let second = newTestBackend()
    let previous = currentClock
    install(second)
    defer: install(previous)
    var firstCalls, secondCalls: int
    let a = startCheckpoints(first, (proc(c: SignalCheckpoint) = inc firstCalls), every=1)
    let b = startCheckpoints(second, (proc(c: SignalCheckpoint) = inc secondCalls), every=1)
    expect ValueError:
      discard startCheckpoints(first, proc(c: SignalCheckpoint) = discard)
    discard first.schedule((proc() = discard), 1)
    discard second.schedule((proc() = discard), 1)
    TestClock(first).advance(100)
    check firstCalls == 1
    check secondCalls == 0
    a.stop()
    a.stop()
    TestClock(second).advance(100)
    check secondCalls == 1
    check first.dispatchSequence == 1
    check second.dispatchSequence == 1
    b.stop()

  test "hook exceptions preserve sequence deduplication and permit clean restart":
    let backend = newTestBackend()
    var calls: int
    let session = startCheckpoints(backend, (proc(c: SignalCheckpoint) =
      inc calls
      raise newException(ValueError, "fixture hook failure")), every=1)
    discard backend.schedule((proc() = discard), 1)
    expect ValueError: TestClock(backend).advance(1)
    TestClock(backend).advance(100)
    check calls == 1
    session.stop()
    let replacement = startCheckpoints(backend, proc(c: SignalCheckpoint) = inc calls)
    TestClock(backend).advance(100)
    check calls == 2
    check backend.dispatchSequence == 1
    replacement.stop()

  test "recursive value hashes terminate while mutual identity cycles use write counts":
    createRoot proc(dispose: proc()) =
      let tree = createSignal(Tree(content:1, children: @[Tree(content:2)]))
      var before = signalStateHash(0)
      tree.value.children[0].content = 3
      check before != signalStateHash(0)
      # Exercise accepted and suppressed writes through the public comparator.
      let recursive = createSignal(RecursiveA(children: @[RecursiveB(identity:Opaque(content:1))]),
        equals = proc(a, b: RecursiveA): bool = a.children.len == b.children.len)
      before = signalStateHash(0)
      recursive.value.children[0].identity.content = 2
      check before == signalStateHash(0)
      recursive.value.children[0].identity = Opaque(content:2)
      check before == signalStateHash(0)
      recursive.val = RecursiveA(children: @[RecursiveB(identity:Opaque(content:3))])
      check before == signalStateHash(0) # comparator-suppressed assignment
      recursive.val = RecursiveA()
      check before != signalStateHash(0) # accepted write changes fallback
      dispose()
  test "user hashes module keeps existing value hash semantics":
    createRoot proc(dispose: proc()) =
      let custom = createSignal(HashValue(content:1))
      let before = signalStateHash(0)
      custom.value.content = 2
      check before != signalStateHash(0)
      dispose()

  test "initial idle observes startup signals once without a dispatch and can cancel":
    let backend = newTestBackend()
    var seen: seq[SignalCheckpoint]
    let session = startCheckpoints(backend, proc(c: SignalCheckpoint) = seen.add(c))
    createRoot proc(dispose: proc()) =
      let state = createSignal(42)
      let expected = signalStateHash(0)
      TestClock(backend).advance(100)
      check seen.len == 1
      check seen[0] == SignalCheckpoint(afterSeq:0, hash:expected)
      TestClock(backend).advance(10000)
      check seen.len == 1
      check backend.dispatchSequence == 0
      check backend.randomDrawCount == 0
      check state.val == 42
      dispose()
    session.stop()
    let canceled = startCheckpoints(backend, proc(c: SignalCheckpoint) = seen.add(c))
    canceled.stop()
    TestClock(backend).advance(100)
    check seen.len == 1

  test "stop during graph flush cancels emission before contributors":
    let backend = newTestBackend()
    var calls, contributions: int
    let session = startCheckpoints(backend, (proc(c: SignalCheckpoint) = inc calls), every=1)
    createRoot proc(dispose: proc()) =
      let trigger = createSignal(CallbackValue(content:1))
      let source = createSignal(0)
      createEffect(proc() =
        if source.val == 1: session.stop())
      let effect = Owner.owned[^1]
      contributionAction = proc() = inc contributions
      discard backend.schedule((proc() =
        source.value = 1
        effect.state = csStale
        Effects.add(effect)), 1)
      TestClock(backend).advance(100)
      contributionAction = nil
      check calls == 0
      check contributions == 0
      check trigger.val.content == 1
      check backend.dispatchSequence == 1
      dispose()

  test "stop from contribution and owner unmount cancel emission and idle":
    for unmount in [false, true]:
      let backend = newTestBackend()
      var calls, contributions: int
      let session = startCheckpoints(backend, (proc(c: SignalCheckpoint) = inc calls), every=1)
      createRoot proc(dispose: proc()) =
        let trigger = createSignal(CallbackValue(content:1))
        onCleanup(proc() = session.stop())
        contributionAction = proc() =
          inc contributions
          if unmount: dispose()
          else: session.stop()
        discard backend.schedule((proc() = discard), 1)
        TestClock(backend).advance(100)
        contributionAction = nil
        check contributions == 1
        check calls == 0
        check trigger.val.content == 1
        check backend.dispatchSequence == 1
        dispose()

  test "contributor release invalidates later native addresses without retention":
    when not defined(js):
      block:
        let trigger = createSignal(CallbackValue(content:1))
        let expected = signalStateHash(0)
        laterVictim = createSignal(42)
        contributionAction = proc() = laterVictim = nil
        check liveSignalCount() == 2
        let observed = signalStateHash(0)
        contributionAction = nil
        check observed == expected
        check liveSignalCount() == 1
        check trigger.val.content == 1
    # Also exercise deterministic owner invalidation in both native and JS.
    createRoot proc(dispose: proc()) =
      let trigger = createSignal(CallbackValue(content:1))
      let expected = signalStateHash(0)
      var release: proc()
      var retained: Signal[int]
      createRoot proc(disposeVictim: proc()) =
        release = disposeVictim
        retained = createSignal(42)
      contributionAction = proc() = release()
      let observed = signalStateHash(0)
      contributionAction = nil
      check observed == expected
      check liveSignalCount() == 1
      check retained.val == 42
      check trigger.val.content == 1
      dispose()

  test "metadata snapshot bounds contributor creation and tolerates compaction":
    createRoot proc(dispose: proc()) =
      let trigger = createSignal(CallbackValue(content:1))
      let expected = signalStateHash(0)
      var release: proc()
      var retained: Signal[int]
      createRoot proc(disposeVictim: proc()) =
        release = disposeVictim
        retained = createSignal(42)
      var born: Signal[BornValue]
      bornContributions = 0
      contributionAction = proc() =
        contributionAction = nil
        release()
        discard liveSignalCount()
        born = createSignal(BornValue(content:99))
      check signalStateHash(0) == expected
      check bornContributions == 0
      check liveSignalCount() == 2
      check signalStateHash(0) != expected
      check bornContributions == 1
      check retained.val == 42
      check born.val.content == 99
      check trigger.val.content == 1
      dispose()

  test "metadata snapshot excludes newly created signals before next checkpoint":
    createRoot proc(dispose: proc()) =
      let trigger = createSignal(CallbackValue(content:1))
      let expected = signalStateHash(0)
      var born: Signal[BornValue]
      bornContributions = 0
      contributionAction = proc() =
        contributionAction = nil
        born = createSignal(BornValue(content:99))
      check signalStateHash(0) == expected
      check bornContributions == 0
      check liveSignalCount() == 2
      check signalStateHash(0) != expected
      check bornContributions == 1
      check born.val.content == 99
      check trigger.val.content == 1
      dispose()

  test "entry disposed by its own contribution is excluded":
    let expected = signalStateHash(0)
    createRoot proc(dispose: proc()) =
      let trigger = createSignal(CallbackValue(content:1))
      contributionAction = proc() = dispose()
      let observed = signalStateHash(0)
      contributionAction = nil
      check observed == expected
      check liveSignalCount() == 0
      check trigger.val.content == 1

  test "hook can stop and replace its session without stale cancellation":
    let backend = newTestBackend()
    var oldCalls, newCalls: int
    var session, replacement: CheckpointSession
    session = startCheckpoints(backend, (proc(c: SignalCheckpoint) =
      inc oldCalls
      session.stop()
      replacement = startCheckpoints(backend, (proc(c: SignalCheckpoint) = inc newCalls), every=1)), every=1)
    discard backend.schedule((proc() = discard), 1)
    TestClock(backend).advance(100)
    check oldCalls == 1
    check newCalls == 1
    session.stop()
    discard backend.schedule((proc() = discard), 1)
    TestClock(backend).advance(100)
    check oldCalls == 1
    check newCalls == 2
    check backend.dispatchSequence == 2
    replacement.stop()
  test "two independent recording roots produce identical nonempty sequences":
    let first = scriptRun()
    let second = scriptRun()
    check first == second
    check first.len == 3
    check first[0].afterSeq == 2
    check first[1].afterSeq == 4
    check first[2].afterSeq == 5
    check first != scriptRun(true)

  test "stable existing hashes serializers and identity fallbacks":
    createRoot proc(dispose: proc()) =
      let custom = createSignal(Hashed(content:1))
      var before = signalStateHash(0)
      custom.val = Hashed(content:2)
      check before != signalStateHash(0)
      let customRef = createSignal(HashedRef(content:1))
      before = signalStateHash(0)
      customRef.value.content = 3
      check before != signalStateHash(0)
      let serialized = createSignal(Serialized(content:1))
      before = signalStateHash(0)
      serialized.value.content = 2
      check before != signalStateHash(0)
      let explicit = createSignal(ExplicitHash(content:1))
      before = signalStateHash(0)
      explicit.value.content = 2
      check before != signalStateHash(0)
      let opaque = createSignal(Opaque(content:1))
      before = signalStateHash(0)
      opaque.value.content = 9
      check before == signalStateHash(0)
      opaque.val = Opaque(content:9)
      check before != signalStateHash(0)
      before = signalStateHash(0)
      opaque.val = opaque.value
      check before == signalStateHash(0)
      let sequence = createSignal(@[1,2])
      before = signalStateHash(0)
      sequence.val = @[1,3]
      check before != signalStateHash(0)
      let nestedIdentity = createSignal(@[Opaque(content:1)])
      before = signalStateHash(0)
      nestedIdentity.value[0].content = 7
      check before == signalStateHash(0)
      nestedIdentity.val = @[Opaque(content:7)]
      check before != signalStateHash(0)
      let nestedCustom = createSignal(@[HashedRef(content:1)])
      before = signalStateHash(0)
      nestedCustom.value[0].content = 7
      check before != signalStateHash(0)
      dispose()
    check liveSignalCount() == 0

  test "native destruction excludes unowned signals without owner cleanup":
    when not defined(js):
      proc transient() =
        let signal = createSignal(23)
        check liveSignalCount() == 1
        check signal.val == 23
      transient()
      check liveSignalCount() == 0
    else:
      # Actual JS GC/WeakRef lifetime is covered in the Chromium fixture.
      check liveSignalCount() == 0

  test "owner cleanup never retains a signal and nested cleanup invalidates retained signals":
    createRoot proc(dispose: proc()) =
      when not defined(js):
        proc transient() =
          let signal = createSignal(23)
          check signal.val == 23
        transient()
        check liveSignalCount() == 0
      var retained: Signal[int]
      createRoot proc(disposeNested: proc()) =
        retained = createSignal(1)
        check liveSignalCount() == 1
        disposeNested()
        check liveSignalCount() == 0
      check retained.val == 1
      dispose()

  test "nested cleanup exceptions and recreation preserve creation order":
    let backend = newTestBackend()
    let session = startCheckpoints(backend, proc(c: SignalCheckpoint) = discard)
    createRoot proc(dispose: proc()) =
      let root = getOwner()
      let first = createSignal(1)
      let firstOrdinal = root.checkpointSignals[^1].ordinal
      var nestedOrdinal: int
      expect ValueError:
        createRoot proc(disposeNested: proc()) =
          defer: disposeNested()
          let nested = createSignal(2)
          nestedOrdinal = getOwner().checkpointSignals[^1].ordinal
          check nested.val == 2
          raise newException(ValueError, "fixture owner failure")
      check getOwner() == root
      let recreated = createSignal(3)
      check firstOrdinal < nestedOrdinal
      check nestedOrdinal < root.checkpointSignals[^1].ordinal
      check first.val == 1
      check recreated.val == 3
      check liveSignalCount() == 2
      dispose()
      check liveSignalCount() == 0
    session.stop()

  test "maintenance flush observes genuinely pending batched graph updates":
    let backend = newTestBackend()
    var seen: seq[SignalCheckpoint]
    let session = startCheckpoints(backend, proc(c: SignalCheckpoint) = seen.add(c), every=1)
    createRoot proc(dispose: proc()) =
      let source = createSignal(1)
      let derived = createSignal(0)
      createEffect(proc() = derived.val = source.val * 10)
      let effect = Owner.owned[^1]
      var expected: string
      discard backend.schedule((proc() =
        # Stage the same real queue that a batch leaves for flushUpdates.
        # Comparing against the fully flushed graph catches a pre-flush hash.
        batch(proc() = source.val = 3)
        expected = signalStateHash(0)
        derived.value = -1
        effect.state = csStale
        Effects.add(effect)), 1)
      TestClock(backend).advance(100)
      check seen.len == 1
      check seen[0].hash == expected
      check derived.val == 30
      dispose()
    session.stop()

  test "idle distinct from periodic and maintenance cannot count or rearm":
    let backend = newTestBackend()
    var seen: seq[SignalCheckpoint]
    let session = startCheckpoints(backend, proc(c: SignalCheckpoint) = seen.add(c), every=2, idleMs=10)
    discard backend.schedule((proc() = discard), 1)
    TestClock(backend).advance(12)
    check seen.len == 1
    check seen[0].afterSeq == 1
    discard backend.schedule((proc() = discard), 1)
    TestClock(backend).advance(1)
    check seen.len == 2
    check seen[1].afterSeq == 2
    TestClock(backend).advance(10000)
    check seen.len == 2
    check backend.dispatchSequence == 2
    session.stop()

  test "default interval and successful RNG calls including scripted draws":
    let backend = newTestBackend()
    let previous = currentClock
    install(backend)
    defer: install(previous)
    backend.script("random", @[%1])
    backend.script("randomFloat", @[%0.5])
    let before = signalStateHash(backend.randomDrawCount)
    discard nondet.random()
    discard nondet.randomFloat()
    check backend.randomDrawCount == 2
    check before != signalStateHash(backend.randomDrawCount)
    expect ValueError: discard nondet.random()
    check backend.randomDrawCount == 2
    var seen: seq[SignalCheckpoint]
    let session = startCheckpoints(backend, proc(c: SignalCheckpoint) = seen.add(c))
    for i in 1..16: discard backend.schedule((proc() = discard), float64(i))
    TestClock(backend).advance(16)
    check seen.len == 1
    check seen[0].afterSeq == 16
    TestClock(backend).advance(100)
    check seen.len == 1
    session.stop()
