## tests/browser/hmr_fixture/main.nim
##
## Fixture app for the HMR Playwright spec. Exercises the
## ui-as-boundary HMR design via {.uiComponent.}-marked component
## procs:
##
##   `app` is the entry component: a div containing `unchangedRow`
##   (a sub-component the spec keeps stable across simulated reloads)
##   and `mutableRow` (a sub-component the spec swaps between two
##   variants).
##
## The Playwright spec drives "reloads" by directly invoking the
## registry-update API the new bundle's module-init code would call:
## `simulateReload(loc, newHash, newFactory)`. That isolates the
## runtime contract — slot signal write → only that subtree's memo
## invalidates — from a real recompile pipeline. End-to-end transport
## behaviour is covered by a separate milestone.

when not defined(js):
  {.error: "HMR fixture requires the JS backend".}

import std/jsffi
import isonim/core/signals
import isonim/web/dom_api
import isonim/web/client
import isonim/web/events
import isonim/web/hmr
import isonim/web/hmr_component
import isonim/rxcore

# State that survives reloads. Declared at module scope (not inside a
# component) so it persists naturally across re-evaluation. In a real
# app these would be module-scope or hmrSignal-protected.
let preservedCount = signals.createSignal(0)
let textInputValueSignal = signals.createSignal(cstring"")

# ---------------------------------------------------------------------------
# Components
# ---------------------------------------------------------------------------

# `unchangedRow` is what the spec keeps stable across reloads. Its
# DOM identity must survive when only `mutableRow` is "edited."
proc unchangedRow*(): Node {.uiComponent.} =
  let root = document.createElement(cstring"div")
  root.setAttribute(cstring"id", cstring"unchanged-row")

  let label = document.createElement(cstring"span")
  label.setAttribute(cstring"id", cstring"unchanged-label")
  label.textContent = cstring"unchanged"
  root.Node.appendChild(label.Node)

  let input = document.createElement(cstring"input")
  input.setAttribute(cstring"id", cstring"text-input")
  input.setAttribute(cstring"type", cstring"text")
  root.Node.appendChild(input.Node)

  # Reflect typed value into a module-scope signal so the spec can
  # introspect that the input element kept its identity (we read its
  # `.value` directly via the same DOM ref later).
  addEventListenerWeb(input.Node, cstring"input", proc(ev: Event) =
    # The `<input>.value` property isn't in dom_api's Element type;
    # use jsffi indexing to pull it as a typed cstring.
    textInputValueSignal.val = input.toJs["value"].to(cstring),
    delegate = false)

  let counterButton = document.createElement(cstring"button")
  counterButton.setAttribute(cstring"id", cstring"preserved-inc")
  counterButton.textContent = cstring"preserved+"
  root.Node.appendChild(counterButton.Node)

  let counterSpan = document.createElement(cstring"span")
  counterSpan.setAttribute(cstring"id", cstring"preserved-count")
  root.Node.appendChild(counterSpan.Node)
  insert(counterSpan.Node, proc(): cstring = cstring($preservedCount.val))

  addEventListenerWeb(
    counterButton.Node, cstring"click",
    proc(ev: Event) = preservedCount.val = preservedCount.val + 1,
    delegate = true)
  delegateEvents([cstring"click"])

  return root.Node

# `mutableRowBefore` and `mutableRowAfter` are TWO components — the
# spec triggers a "reload" by replacing the slot at `mutable-row` with
# the after-variant's factory. Both have the same shape (id, structure)
# but different inner text so the spec can detect the swap.
proc mutableRow*(): Node {.uiComponent.} =
  let root = document.createElement(cstring"div")
  root.setAttribute(cstring"id", cstring"mutable-row")

  let label = document.createElement(cstring"span")
  label.setAttribute(cstring"id", cstring"mutable-label")
  label.textContent = cstring"before"
  root.Node.appendChild(label.Node)

  return root.Node

# A second mutable-row factory used by the spec to simulate "user edits
# this component." We expose it via JS so the spec can swap to it.
proc mutableRowAfterImpl(): Node =
  let root = document.createElement(cstring"div")
  root.setAttribute(cstring"id", cstring"mutable-row")

  let label = document.createElement(cstring"span")
  label.setAttribute(cstring"id", cstring"mutable-label")
  label.textContent = cstring"after"
  root.Node.appendChild(label.Node)

  let extra = document.createElement(cstring"div")
  extra.setAttribute(cstring"id", cstring"mutable-extra")
  extra.textContent = cstring"new content from edit"
  root.Node.appendChild(extra.Node)

  return root.Node

proc mutableRowBrokenImpl(): Node =
  raise newException(ValueError, "boom")

# Filler so we have something to scroll past, kept inside the entry's
# DOM (not in a sub-component) to verify scroll preservation across
# parent-component re-renders.
proc app*(): Node {.uiComponent.} =
  let root = document.createElement(cstring"div")
  root.setAttribute(cstring"id", cstring"root")

  let header = document.createElement(cstring"h1")
  header.setAttribute(cstring"id", cstring"heading")
  header.textContent = cstring"HMR fixture"
  root.Node.appendChild(header.Node)

  root.Node.appendChild(unchangedRow())
  root.Node.appendChild(mutableRow())

  let filler = document.createElement(cstring"div")
  filler.setAttribute(cstring"id", cstring"filler")
  filler.setAttribute(cstring"style", cstring"height:2000px;")
  root.Node.appendChild(filler.Node)

  return root.Node

bootstrapHmr()

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

# Locations: must match what the {.uiComponent.} pragma derived from
# the proc decls above. We could expose them programmatically; for the
# fixture's purposes, hard-coded strings are fine. Update if you move
# the proc decls.
# These three exposed bridges let the Playwright spec inspect or
# perturb the registry without depending on a transport. They use
# `findSlotEndingWith` so the spec doesn't depend on the absolute
# file path the {.uiComponent.} pragma embeds.

proc isonimHmrSimulateMutableAfter*() {.exportc.} =
  ## Simulate "user edited the mutableRow component." Compute a fresh
  ## hash for the after variant (any string different from the current
  ## hash works) and write the new factory pointer into the slot.
  ## `mutableRowLoc` is the const emitted by the {.uiComponent.} pragma
  ## for the mutableRow proc (full path:line:col).
  hmrRegisterFactory(
    mutableRowLoc, "after-variant-hash", toJs(mutableRowAfterImpl))

proc isonimHmrSimulateMutableBroken*() {.exportc.} =
  hmrRegisterFactory(
    mutableRowLoc, "broken-variant-hash", toJs(mutableRowBrokenImpl))

proc isonimHmrRegistrySize*(): int {.exportc.} = registrySize()
proc isonimHmrGeneration*(): int {.exportc.} = currentGeneration()

# ---------------------------------------------------------------------------
# Mount
# ---------------------------------------------------------------------------

var globalJs {.importjs: "globalThis".}: JsObject

proc main() =
  let container = document.getElementById(cstring"app")

  # An empty JS array for spec-supplied error callbacks. `newJsObject`
  # gives `{}`; we need `[]` so `.length` and `.push` behave correctly.
  proc newJsArray(): JsObject {.importjs: "[@]".}
  let errorCallbacks = newJsArray()
  globalJs["__hmrTestErrorCallbacks"] = errorCallbacks

  proc captureError(err: ref Exception) =
    let msg = cstring(err.msg)
    let len = errorCallbacks["length"].to(int)
    for i in 0 ..< len:
      # JS method dispatch needs the right `this` — calling
      # `errorCallbacks[i].to(proc)(msg)` loses the array context. The
      # callbacks themselves are user-supplied and don't need `this`,
      # so direct call is fine here, but use the jsffi `.()` macro
      # which generates correct dispatch.
      let cb = errorCallbacks[i].to(proc(m: cstring))
      cb(msg)

  # Wire the registry's slot-level error callback so factories that
  # throw during a simulated reload surface to the spec's onError
  # listeners rather than crashing through to JS top-level.
  globalUiOnError = proc(loc: string; err: ref Exception) =
    captureError(err)

  discard renderHot(app, container, captureError)

  globalJs["__hmrNavigations"] = toJs(0)
  proc registerPageShowCounter()
    {.importjs: "window.addEventListener('pageshow', function () { globalThis.__hmrNavigations += 1; })".}
  registerPageShowCounter()

  # Build the test harness as a JS object. Each entry is a thin shim
  # to a Nim {.exportc.} proc; the harness itself is the JS-side API
  # the spec interacts with, so a single `globalThis.__hmrTest = {...}`
  # is the natural shape.
  let harness = newJsObject()
  proc onErrorBridge(cb: JsObject) =
    # Use jsffi's experimental `.()` method-call macro which generates
    # the correct `this`-bound dispatch. `errorCallbacks.push(cb)`
    # otherwise loses the array as receiver.
    discard errorCallbacks.push(cb)
  harness["simulateMutableAfter"] = toJs(isonimHmrSimulateMutableAfter)
  harness["simulateMutableBroken"] = toJs(isonimHmrSimulateMutableBroken)
  harness["registrySize"] = toJs(isonimHmrRegistrySize)
  harness["generation"] = toJs(isonimHmrGeneration)
  harness["onError"] = toJs(onErrorBridge)
  globalJs["__hmrTest"] = harness

main()
