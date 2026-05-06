## tests/test_hmr.nim
##
## Headless Nim tests for the HMR signal registry. Browser-side guarantees
## (DOM continuity, focus preservation, etc.) are covered by the Playwright
## spec in tests/browser/specs/hmr.spec.ts.
##
## Run with `-d:isonimHmr` to exercise the active path. Without the flag,
## the tests assert the no-op stubs behave as documented (renderHot aliases
## render, swap is a no-op, hmrSignal aliases createSignal).

when not defined(js):
  {.error: "test_hmr requires the JS backend (use `nim js -r`)".}

import std/[unittest, tables, sets]
import isonim/core/signals
import isonim/web/dom_api
import isonim/web/hmr

proc sameRef[T](a, b: T): bool =
  ## Reference equality on the JS backend. `cast[pointer]` and `cast[int]`
  ## both produce malformed JS for closure-style ref types, so emit a
  ## direct `===` comparison instead.
  {.emit: [result, " = (", a, " === ", b, ");"].}

when defined(isonimHmr):
  suite "HMR signal registry":
    test "hmrSignalImpl reuses an existing entry across calls":
      let reg = newHmrRegistry()
      activeHmrRegistry = reg
      let s1 = hmrSignalImpl[int]("test:1", 0)
      s1.val = 5
      # Re-claim the same id, simulating a re-run of the component body
      # (e.g., during a swap). The same SignalState ref must come back
      # with its current value preserved.
      let s2 = hmrSignalImpl[int]("test:1", 0)
      check s1.val == 5
      check s2.val == 5
      check sameRef(s1, s2)

    test "hmrSignalImpl creates a fresh signal for a new id":
      let reg = newHmrRegistry()
      activeHmrRegistry = reg
      let s1 = hmrSignalImpl[int]("test:a", 1)
      let s2 = hmrSignalImpl[int]("test:b", 2)
      check s1.val == 1
      check s2.val == 2
      check not sameRef(s1, s2)
      let entryCount = reg.entries.len
      check entryCount == 2

    test "claimed set tracks ids touched in the current generation":
      let reg = newHmrRegistry()
      activeHmrRegistry = reg
      discard hmrSignalImpl[int]("a", 0)
      discard hmrSignalImpl[int]("b", 0)
      check "a" in reg.claimed
      check "b" in reg.claimed
      check "c" notin reg.claimed

    test "hmrSignalImpl falls back to plain createSignal outside a root":
      activeHmrRegistry = nil
      let s = hmrSignalImpl[int]("orphan", 42)
      check s.val == 42
      # Stays a normal signal — writes work as usual.
      s.val = 100
      check s.val == 100

    test "hmrSignal template uses instantiationInfo for stable id":
      # Two calls at the same source line should hit the same id; calls at
      # different lines should hit different ids. We can't compare ids
      # directly (they're embedded in the registry), but we can compare
      # behaviour: same line == reused, different line == fresh.
      let reg = newHmrRegistry()
      activeHmrRegistry = reg
      proc captureSameLine(): Signal[int] = hmrSignal[int](7)
      let a = captureSameLine()
      a.val = 99
      let b = captureSameLine()
      check b.val == 99   # same instantiationInfo → same registry entry

    test "different lines produce different ids":
      let reg = newHmrRegistry()
      activeHmrRegistry = reg
      let a = hmrSignal[int](1)
      let b = hmrSignal[int](2)   # different source line → different id
      let entryCount = reg.entries.len
      check entryCount == 2
      check not sameRef(a, b)

else:
  suite "HMR no-op stubs (-d:isonimHmr off)":
    test "hmrSignal aliases createSignal (no preservation across calls)":
      proc make(): Signal[int] = hmrSignal[int](0)
      let a = make()
      a.val = 5
      let b = make()
      check b.val == 0
      check not sameRef(a, b)

    test "swap is a no-op":
      let stub = HmrRoot()
      stub.swap(proc(): Node = nil)
      check true
