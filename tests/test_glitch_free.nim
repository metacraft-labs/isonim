## Glitch-free propagation: no computation runs against a mix of old and new
## inputs, a reader whose memo inputs are unchanged does not run, and an out
## of date owner is brought up to date before its children.
##
## Real signals, memos, effects and owners; no mocks.

import unittest
import isonim/core/[signals, computation, batch, owner]

suite "Glitch-free propagation":
  test "diamond: the effect runs once and sees one consistent frame":
    var seen: seq[string]
    var bRuns, cRuns, dRuns = 0
    var dispose: proc()
    let a = createSignal(1)
    createRoot proc(stop: proc()) =
      dispose = stop
      let b = createMemo(proc(): int = (inc bRuns; a.val * 2))
      let c = createMemo(proc(): int = (inc cRuns; a.val * 3))
      let d = createMemo(proc(): int = (inc dRuns; b.val + c.val))
      createEffect proc() =
        seen.add($a.val & "/" & $b.val & "/" & $c.val & "/" & $d.val)
    seen = @[]; bRuns = 0; cRuns = 0; dRuns = 0
    a.val = 2
    check seen == @["2/4/6/10"]
    check bRuns == 1 and cRuns == 1 and dRuns == 1
    dispose()

  test "a reader of an unchanged memo does not run":
    var effRuns = 0
    var dispose: proc()
    let n = createSignal(1)
    createRoot proc(stop: proc()) =
      dispose = stop
      let parity = createMemo(proc(): bool = n.val mod 2 == 0)
      createEffect proc() =
        discard parity.val
        inc effRuns
    effRuns = 0
    n.val = 3          # parity stays odd
    check effRuns == 0
    n.val = 4          # parity changes
    check effRuns == 1
    dispose()

  test "a memo chain is pulled in order when read inside an effect":
    var seen: seq[int]
    var dispose: proc()
    let s = createSignal(1)
    createRoot proc(stop: proc()) =
      dispose = stop
      let m1 = createMemo(proc(): int = s.val + 1)
      let m2 = createMemo(proc(): int = m1.val * 10)
      createEffect proc() =
        seen.add s.val * 1000 + m2.val
    seen = @[]
    s.val = 2
    check seen == @[2030]
    dispose()

  test "batched writes produce one run with the final values":
    var seen: seq[string]
    var dispose: proc()
    let x = createSignal(0)
    let y = createSignal(0)
    createRoot proc(stop: proc()) =
      dispose = stop
      let sum = createMemo(proc(): int = x.val + y.val)
      createEffect proc() =
        seen.add $x.val & "+" & $y.val & "=" & $sum.val
    seen = @[]
    batch proc() =
      x.val = 1
      y.val = 2
    check seen == @["1+2=3"]
    dispose()

  test "an owner that re-runs disposes its child before the child runs":
    var childRuns: seq[int]
    var dispose: proc()
    let show = createSignal(true)
    let value = createSignal(0)
    createRoot proc(stop: proc()) =
      dispose = stop
      createEffect proc() =
        if show.val:
          createEffect proc() =
            childRuns.add value.val
    childRuns = @[]
    batch proc() =
      value.val = 1
      show.val = false
    check childRuns.len == 0
    dispose()

  test "reading a memo right after a write outside any batch is current":
    let s = createSignal(1)
    var dispose: proc()
    var m: Memo[int]
    createRoot proc(stop: proc()) =
      dispose = stop
      m = createMemo(proc(): int = s.val * 2)
    s.val = 21
    check m.val == 42
    dispose()
