import unittest
import isonim/core/[types, graph, signals, owner, computation, batch]

suite "Effects":
  test "createEffect tracks signal and re-runs on change":
    createRoot do (dispose: proc()):
      let s = createSignal(0)
      var observed = -1
      createEffect do:
        observed = s.val
      check observed == 0  # Initial run
      s.val = 5
      check observed == 5  # Re-run after signal change

  test "effect cleanup runs before re-execution":
    createRoot do (dispose: proc()):
      let s = createSignal(0)
      var cleanupRan = false
      createEffect do:
        discard s.val
        onCleanup do:
          cleanupRan = true
      check cleanupRan == false
      s.val = 1  # Should trigger cleanup then re-run
      check cleanupRan == true

  test "nested effects track independently":
    createRoot do (dispose: proc()):
      let a = createSignal(0)
      let b = createSignal(0)
      var outerRuns = 0
      var innerRuns = 0
      createEffect do:
        inc outerRuns
        discard a.val
        createEffect do:
          inc innerRuns
          discard b.val
      check outerRuns == 1
      check innerRuns == 1
      b.val = 1  # Only inner should re-run
      check outerRuns == 1
      check innerRuns == 2

suite "Memos":
  type
    Row = object
      name: string
      value: int

  test "createMemo caches and updates":
    createRoot do (dispose: proc()):
      let a = createSignal(1)
      let b = createSignal(2)
      let sum = createMemo(proc(): int = a.val + b.val)
      check sum.val == 3
      a.val = 10
      check sum.val == 12

  test "memo only recomputes when dependencies change":
    createRoot do (dispose: proc()):
      let s = createSignal(0)
      var computeCount = 0
      let doubled = createMemo do () -> int:
        inc computeCount
        s.val * 2
      check doubled.val == 0
      check computeCount == 1
      discard doubled.val  # cached read
      check computeCount == 1  # no recompute
      s.val = 5
      check doubled.val == 10
      check computeCount == 2

  test "memo diamond dependency":
    createRoot do (dispose: proc()):
      let s = createSignal(1)
      let doubled = createMemo(proc(): int = s.val * 2)
      let tripled = createMemo(proc(): int = s.val * 3)
      let sum = createMemo(proc(): int = doubled.val + tripled.val)
      check sum.val == 5  # 2 + 3
      s.val = 2
      check sum.val == 10  # 4 + 6

  test "memo preserves seqs of value objects on JS target":
    createRoot do (dispose: proc()):
      let rows = createSignal(newSeq[Row]())
      let visible = createMemo[seq[Row]] proc(): seq[Row] =
        for row in rows.val:
          result.add(row)

      check visible.val.len == 0
      rows.val = @[Row(name: "main", value: 1), Row(name: "helper", value: 2)]

      let snapshot = visible.val
      check snapshot.len == 2
      check snapshot[0].name == "main"
      check snapshot[0].value == 1
      check snapshot[1].name == "helper"
      check snapshot[1].value == 2

suite "Owners":
  test "createRoot disposal cleans up effects":
    var observed = -1
    var disposeRoot: proc()
    let s = createSignal(0)
    createRoot do (dispose: proc()):
      disposeRoot = dispose
      createEffect do:
        observed = s.val
    check observed == 0
    s.val = 1
    check observed == 1
    disposeRoot()
    s.val = 2
    check observed == 1  # Effect was disposed

  test "nested createRoot - disposing child doesn't affect parent":
    createRoot do (dispose: proc()):
      var parentObserved = -1
      var childObserved = -1
      var disposeChild: proc()
      let s = createSignal(0)
      createEffect do:
        parentObserved = s.val
      createRoot do (innerDispose: proc()):
        disposeChild = innerDispose
        createEffect do:
          childObserved = s.val
      s.val = 1
      check parentObserved == 1
      check childObserved == 1
      disposeChild()
      s.val = 2
      check parentObserved == 2
      check childObserved == 1  # Child disposed

  test "onCleanup runs on disposal":
    var cleaned = false
    createRoot do (dispose: proc()):
      onCleanup do:
        cleaned = true
      check cleaned == false
      dispose()
    check cleaned == true

  test "runWithOwner runs in given owner context":
    var ownerRef: OwnerBase
    createRoot do (dispose: proc()):
      ownerRef = getOwner()
    var observed = -1
    let s = createSignal(0)
    runWithOwner(ownerRef) do:
      createEffect do:
        observed = s.val
    check observed == 0

suite "Batch":
  test "batch coalesces multiple writes":
    createRoot do (dispose: proc()):
      let s = createSignal(0)
      var runCount = 0
      createEffect do:
        discard s.val
        inc runCount
      check runCount == 1
      batch proc() =
        s.val = 1
        s.val = 2
        s.val = 3
      check runCount == 2  # Only one re-execution after batch

  test "untrack prevents dependency registration":
    createRoot do (dispose: proc()):
      let a = createSignal(1)
      let b = createSignal(2)
      var observed = -1
      createEffect do:
        observed = a.val + untrack(proc(): int = b.val)
      check observed == 3
      b.val = 10  # Should NOT trigger re-run
      check observed == 3
      a.val = 5  # SHOULD trigger re-run
      check observed == 15  # 5 + 10
