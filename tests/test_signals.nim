import unittest
import isonim/core/[types, graph, signals]

suite "Signal Creation and Basic Operations":
  test "createSignal returns typed signal with initial value":
    let s = createSignal(42)
    check s.value == 42

  test "val reads current value":
    let s = createSignal("hello")
    check s.val == "hello"

  test "val= writes new value":
    let s = createSignal(0)
    s.val = 5
    check s.val == 5

  test "update applies function to current value":
    let s = createSignal(10)
    s.update(proc(x: int): int = x * 2)
    check s.val == 20

  test "default equality skips notification for same value":
    let s = createSignal(7)
    let initialObserverCount = s.observers.len
    s.val = 7 # same value — should not trigger anything
    check s.val == 7

  test "custom equality comparator":
    # Comparator that considers values equal if they have the same sign
    let sameSign = proc(a, b: int): bool = (a >= 0) == (b >= 0)
    let s = createSignal(5, sameSign)
    s.val = 10 # same sign — should be treated as "equal", no notification
    check s.value == 5 # value should NOT have changed
    s.val = -3 # different sign — should update
    check s.value == -3

suite "Dependency Tracking":
  test "trackRead registers observer when Listener is set":
    let s = createSignal(0)
    var comp = ComputationBase(
      sources: @[],
      sourceSlots: @[],
      state: csClean,
      pure: false,
    )
    # Simulate being inside a computation
    Listener = comp
    discard s.val # This should register the dependency
    Listener = nil

    check s.observers.len == 1
    check s.observers[0] == comp
    check comp.sources.len == 1
    check comp.sources[0] == SignalStateBase(s)

  test "trackRead does not register when no Listener":
    let s = createSignal(0)
    Listener = nil
    discard s.val
    check s.observers.len == 0

  test "multiple observers tracked correctly":
    let s = createSignal(0)
    var comp1 =
      ComputationBase(sources: @[], sourceSlots: @[], state: csClean, pure: false)
    var comp2 =
      ComputationBase(sources: @[], sourceSlots: @[], state: csClean, pure: false)

    Listener = comp1
    discard s.val
    Listener = comp2
    discard s.val
    Listener = nil

    check s.observers.len == 2
    check s.observers[0] == comp1
    check s.observers[1] == comp2

  test "bidirectional slot indices are correct":
    var s1 = createSignal(1)
    var s2 = createSignal(2)
    var comp =
      ComputationBase(sources: @[], sourceSlots: @[], state: csClean, pure: false)

    Listener = comp
    discard s1.val # comp.sources[0] = s1, s1.observers[0] = comp
    discard s2.val # comp.sources[1] = s2, s2.observers[0] = comp
    Listener = nil

    # s1's observer slot should point to comp's source index 0
    check s1.observerSlots[0] == 0
    # s2's observer slot should point to comp's source index 1
    check s2.observerSlots[0] == 1
    # comp's source slots should point to observer indices
    check comp.sourceSlots[0] == 0 # index in s1.observers
    check comp.sourceSlots[1] == 0 # index in s2.observers

suite "Write Notification":
  test "writing signal marks observers as stale":
    let s = createSignal(0)
    var comp =
      ComputationBase(sources: @[], sourceSlots: @[], state: csClean, pure: false)

    Listener = comp
    discard s.val
    Listener = nil

    check comp.state == csClean
    s.val = 1
    check comp.state == csStale

  test "writing same value does not mark observers":
    let s = createSignal(42)
    var comp =
      ComputationBase(sources: @[], sourceSlots: @[], state: csClean, pure: false)

    Listener = comp
    discard s.val
    Listener = nil

    s.val = 42 # same value
    check comp.state == csClean # should remain clean

  test "writing notifies all observers":
    let s = createSignal(0)
    var comp1 =
      ComputationBase(sources: @[], sourceSlots: @[], state: csClean, pure: false)
    var comp2 =
      ComputationBase(sources: @[], sourceSlots: @[], state: csClean, pure: false)

    Listener = comp1
    discard s.val
    Listener = comp2
    discard s.val
    Listener = nil

    s.val = 1
    check comp1.state == csStale
    check comp2.state == csStale

suite "Signal compiles on both targets":
  test "basic operations work":
    # This test existing and compiling on both JS and C verifies cross-target support
    let a = createSignal(1)
    let b = createSignal("test")
    let c = createSignal(3.14)
    check a.val == 1
    check b.val == "test"
    check c.val == 3.14
    a.val = 2
    b.val = "updated"
    c.val = 2.71
    check a.val == 2
    check b.val == "updated"
    check c.val == 2.71
