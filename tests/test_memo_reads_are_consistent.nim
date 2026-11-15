## A computation never observes a memo that is older than a change which has
## already reached another of its sources.
##
## Uses the real reactive core through its public API (createRoot,
## createSignal, createMemo, createEffect, `val=`); no renderer, no mocks.
##
## Graph, built inside one root:
##
##     a --> m1 ----------> total --> effect
##     a --> m2 --> m3 ---> total
##
## `m1 = a`, `m2 = a`, `m3 = m2`, `total = m1 + m3`, and the effect records
## every value of `total` it is run with. `total` reads two memos that sit at
## different depths below the same signal. In every state of `a` the sum is
## `2 * a`, so for the single write `a: 1 -> 2` the only values a computation
## may see are 2 (before) and 4 (after). A 3 is the new `m1` added to the old
## `m3`: a value that no state of `a` produces.
##
## Scenarios:
##
## 1. The shallow source subscribes to the signal first (`m1` is created
##    before `m2`). The state before the write is asserted first with
##    `require`, so a graph that did not come up as described stops the test
##    and cannot be read as the property failing. After the write the test
##    asserts, in this order: the write reached the effect and the graph
##    settled on 4; the effect never saw 3; the effect saw exactly 2 then 4;
##    `total` was computed once for the write.
## 2. The same graph with `m2` created before `m1`, held to the same
##    assertions. The result must not depend on the order in which the two
##    memos happened to subscribe to the signal.
import unittest
import isonim/core/[signals, computation, owner]

type
  Probe = ref object
    a: Signal[int]
    seen: seq[int]   ## every value of `total` the effect was run with
    totalRuns: int   ## how many times `total` was computed
    dispose: proc()

proc buildGraph(deepArmFirst: bool): Probe =
  ## Builds the graph of the header inside one root. `deepArmFirst` creates
  ## `m2`, the source of the two-memo arm, before `m1`; nothing else differs.
  let p = Probe()
  createRoot do (dispose: proc()):
    p.dispose = dispose
    p.a = createSignal(1)
    var m1, m2: Memo[int]
    if deepArmFirst:
      m2 = createMemo(proc(): int = p.a.val)
      m1 = createMemo(proc(): int = p.a.val)
    else:
      m1 = createMemo(proc(): int = p.a.val)
      m2 = createMemo(proc(): int = p.a.val)
    let m3 = createMemo(proc(): int = m2.val)
    let computeTotal = proc(): int =
      inc p.totalRuns
      m1.val + m3.val
    let total = createMemo(computeTotal)
    createEffect proc() =
      p.seen.add(total.val)
  p

suite "Memo reads are consistent":
  test "a computation reading memos of unequal depth sees no value that no signal state produces":
    let p = buildGraph(deepArmFirst = false)

    # Setup: the state before the write. `require` stops the test here, so
    # nothing below can fail because the graph was not built as described.
    require p.seen == @[2]
    require p.totalRuns == 1

    p.a.val = 2

    # The write reached the effect and the graph settled on the new state;
    # without this the checks below could pass because nothing ran.
    require p.seen.len >= 2
    require p.seen[^1] == 4

    # The property: no run of the effect saw the new `m1` with the old `m3`.
    check 3 notin p.seen
    # The whole history: one value per state of `a`.
    check p.seen == @[2, 4]
    # `total` was computed once when created and once for the write.
    check p.totalRuns == 2

    p.dispose()

  test "the same holds when the deeper source subscribed to the signal first":
    let p = buildGraph(deepArmFirst = true)

    require p.seen == @[2]
    require p.totalRuns == 1

    p.a.val = 2

    require p.seen.len >= 2
    require p.seen[^1] == 4

    check 3 notin p.seen
    check p.seen == @[2, 4]
    check p.totalRuns == 2

    p.dispose()
