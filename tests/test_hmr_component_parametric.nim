## tests/test_hmr_component_parametric.nim
##
## Headless tests for the parametric `{.uiComponent.}` dispatch path.
##
## Browser-side guarantees (DOM identity preservation under `mountUiHot`)
## live in the Playwright spec at `tests/browser/specs/hmr_parametric.spec.ts`.
## This file pins the runtime contract: parametric procs marked
## `{.uiComponent.}` register a slot at their definition location, the
## dispatch passes args through to the current slot factory, and a
## `hmrRegisterFactory` call with a new hash redirects subsequent
## dispatches to the new factory.

when not defined(js):
  {.error: "test_hmr_component_parametric requires the JS backend".}

import std/[unittest, jsffi]
import isonim/web/dom_api

when defined(isonimHmr):
  import isonim/web/hmr_component
  import isonim/web/hmr_ui_registry

  # Counters live at module scope so the macro-generated dispatch can
  # observe their writes regardless of which slot factory is currently
  # installed.
  var addV1Calls = 0
  var addV2Calls = 0
  var greetCalls = 0

  # ---------------------------------------------------------------------------
  # Components under test
  # ---------------------------------------------------------------------------

  # A two-arg parametric component returning an int. The body sums the
  # args and bumps a call-counter so the test can detect re-runs.
  proc addOp*(a: int; b: int): int {.uiComponent.} =
    inc addV1Calls
    a + b

  # A second parametric component at a different definition site. Used
  # to verify that slots are isolated per definition location even when
  # they take similar argument shapes.
  proc greet*(prefix: cstring; name: cstring): cstring {.uiComponent.} =
    inc greetCalls
    var combined: cstring
    {.emit: [combined, " = ", prefix, " + ", name, ";"].}
    combined

  # Alternative implementation — has a different body so re-registering
  # at the same location with a fresh hash and this factory redirects
  # subsequent dispatches here. We need a separate proc symbol because
  # the slot stores the type-erased factory pointer, not the original
  # `_impl` symbol; reusing the same symbol with a new hash would not
  # exercise the factory-replacement path.
  proc addV2Impl(a: int; b: int): int =
    inc addV2Calls
    a + b + 100

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  proc replaceSlotFactory(loc, hash: string; f: proc(a, b: int): int) =
    ## Simulate "the new bundle's module init re-registered this slot"
    ## by directly calling `hmrRegisterFactory` with a new hash and a
    ## new (type-erased) factory pointer.
    var fObj: JsObject
    {.emit: [fObj, " = ", f, ";"].}
    hmrRegisterFactory(loc, hash, fObj)

  proc resetCounters() =
    addV1Calls = 0
    addV2Calls = 0
    greetCalls = 0

  suite "HMR parametric component dispatch":
    test "dispatch forwards args to the slot factory and returns its result":
      ensureUiRegistry()
      resetCounters()
      check addOp(2, 3) == 5
      check addV1Calls == 1
      check addOp(10, 20) == 30
      # No memoisation on the parametric path — every call hits the
      # factory. This is the contract documented in `hmr_component.nim`.
      check addV1Calls == 2

    test "different locations have independent slots":
      ensureUiRegistry()
      resetCounters()
      check addOp(1, 2) == 3
      let combined = greet(cstring"hi ", cstring"world")
      check $combined == "hi world"
      check addV1Calls == 1
      check greetCalls == 1

    test "re-register with a new hash and a new factory redirects dispatch":
      ensureUiRegistry()
      resetCounters()
      # The slot was already registered at module init by the
      # `{.uiComponent.}` pragma; the location lives in `addOpLoc`,
      # also emitted by the pragma.
      check addOp(4, 5) == 9
      check addV1Calls == 1
      check addV2Calls == 0

      # Simulate "the user edited addOp's source — its symBodyHash
      # changed and the new bundle re-registered the slot with a new
      # factory pointer." Subsequent dispatches must reach the new
      # factory; the old `addV1` body must not run.
      replaceSlotFactory(addOpLoc, "addV2-hash", addV2Impl)
      check addOp(4, 5) == 109   # 4 + 5 + 100
      check addV1Calls == 1      # unchanged
      check addV2Calls == 1

      # Putting the original factory back must restore behaviour and
      # again invoke the original body. Hash must differ so the slot
      # actually rewrites — otherwise it's a no-op (verified separately
      # below).
      replaceSlotFactory(addOpLoc, "addV1-restored", proc(a, b: int): int =
        inc addV1Calls
        a + b)
      check addOp(4, 5) == 9
      check addV1Calls == 2
      check addV2Calls == 1      # unchanged

    test "re-register with the same hash is a no-op":
      ensureUiRegistry()
      resetCounters()
      let priorHash = "noop-hash"
      replaceSlotFactory(addOpLoc, priorHash, proc(a, b: int): int =
        inc addV1Calls
        a + b + 7)
      let g1 = currentGeneration()
      check addOp(1, 1) == 9
      # Re-register with the SAME hash and a different factory body.
      # `hmrRegisterFactory` must skip the slot write because the hash
      # matches — the new factory body must not be reachable from
      # subsequent dispatches.
      replaceSlotFactory(addOpLoc, priorHash, proc(a, b: int): int =
        inc addV2Calls
        a + b + 999)
      let g2 = currentGeneration()
      # Generation always advances per call (it tracks claimed-this-pass
      # bookkeeping), even when the hash matches.
      check g2 > g1
      # Dispatch still hits the prior factory.
      check addOp(1, 1) == 9
      check addV2Calls == 0

    test "missing slot raises a Defect":
      ensureUiRegistry()
      var raised = false
      try:
        # No slot has ever been registered at this fabricated location.
        let dummy = newJsArray()
        discard hmrInvokeParametric("nonexistent:slot", dummy)
      except Defect:
        raised = true
      check raised

else:
  import isonim/web/hmr_component

  proc addOpPlain(a: int; b: int): int {.uiComponent.} =
    a + b

  suite "Parametric uiComponent is a no-op without -d:isonimHmr":
    test "without the flag the pragma leaves the proc untouched":
      check addOpPlain(2, 3) == 5
