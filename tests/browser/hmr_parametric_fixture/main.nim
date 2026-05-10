## tests/browser/hmr_parametric_fixture/main.nim
##
## Browser fixture for the parametric `{.uiComponent.}` integration
## tests. Two independent IsoNim views are mounted via `mountUiHot` into
## sibling DOM containers, each rendering a panel through a parametric
## component that takes its own ViewModel:
##
##   Panel A — unchanged across swaps. Renders an `<input>`, a counter
##     button, and a counter span. The Playwright spec types into the
##     input and clicks the counter, then triggers a swap of Panel B.
##     Panel A's DOM identity, focus, typed input value and counter
##     state must all survive intact.
##
##   Panel B — the mutation target. The fixture ships three factories
##     (`before` / `after` / `broken`); the spec calls
##     `__hmrTest.simulateMutateB('after' | 'broken')` to swap. Only
##     Panel B's DOM rebuilds.
##
## The "swap" mechanism is the same as the existing zero-arg fixture:
## a direct `hmrRegisterFactory` call from a JS-side harness, so we
## can drive the runtime contract deterministically without involving
## the recompile pipeline. End-to-end transport behaviour stays out of
## this spec — it's covered by `hmr_transport.spec.ts`.

when not defined(js):
  {.error: "HMR parametric fixture requires the JS backend".}

import std/jsffi
import isonim/core/signals
import isonim/web/dom_api
import isonim/web/client
import isonim/web/events
import isonim/web/hmr
import isonim/web/hmr_component

# ---------------------------------------------------------------------------
# View models
# ---------------------------------------------------------------------------

type
  PanelAVm = ref object
    counter: Signal[int]
    typedValue: Signal[cstring]
  PanelBVm = ref object
    label: Signal[cstring]

let panelAVm = PanelAVm(
  counter: signals.createSignal(0),
  typedValue: signals.createSignal(cstring""))
let panelBVm = PanelBVm(
  label: signals.createSignal(cstring"before"))

# ---------------------------------------------------------------------------
# Components
# ---------------------------------------------------------------------------

# The parametric component the spec keeps stable across a Panel B swap.
# Identity of every element produced here must survive when Panel B
# changes — that's the v2 contract for parametric components mounted in
# independent `mountUiHot` boundaries.
proc panelA*(vm: PanelAVm): Node {.uiComponent.} =
  let root = document.createElement(cstring"div")
  root.setAttribute(cstring"id", cstring"panel-a-content")

  let input = document.createElement(cstring"input")
  input.setAttribute(cstring"id", cstring"panel-a-input")
  input.setAttribute(cstring"type", cstring"text")
  root.Node.appendChild(input.Node)

  # Reflect typed value back into the VM so the spec can introspect
  # the signal independently of the live DOM.
  addEventListenerWeb(input.Node, cstring"input", proc(ev: Event) =
    vm.typedValue.val = input.toJs["value"].to(cstring),
    delegate = false)

  let incBtn = document.createElement(cstring"button")
  incBtn.setAttribute(cstring"id", cstring"panel-a-inc")
  incBtn.textContent = cstring"+"
  root.Node.appendChild(incBtn.Node)

  let counterSpan = document.createElement(cstring"span")
  counterSpan.setAttribute(cstring"id", cstring"panel-a-counter")
  root.Node.appendChild(counterSpan.Node)
  insert(counterSpan.Node, proc(): cstring = cstring($vm.counter.val))

  addEventListenerWeb(
    incBtn.Node, cstring"click",
    proc(ev: Event) = vm.counter.val = vm.counter.val + 1,
    delegate = true)
  delegateEvents([cstring"click"])

  return root.Node

# Two-arg parametric component: takes a VM ref AND a string suffix.
# This exists purely to exercise the multi-arg path of the
# parametric dispatch — `panelA` is one-arg; we need at least one
# multi-arg test in the fixture's compiled output to be sure
# `cloneParamsWithFreshNames` produced a well-formed dispatch for
# parameter lists with more than one entry.
proc panelB*(vm: PanelBVm; suffix: cstring): Node {.uiComponent.} =
  let root = document.createElement(cstring"div")
  root.setAttribute(cstring"id", cstring"panel-b-content")

  let labelSpan = document.createElement(cstring"span")
  labelSpan.setAttribute(cstring"id", cstring"panel-b-label")
  root.Node.appendChild(labelSpan.Node)
  let vmRef = vm
  let suffixCopy = suffix
  insert(labelSpan.Node, proc(): cstring =
    var combined: cstring
    let labelVal = vmRef.label.val
    {.emit: [combined, " = ", labelVal, " + ", suffixCopy, ";"].}
    combined)

  return root.Node

# Replacement implementations for Panel B. These are *not*
# `{.uiComponent.}`-pragma'd because we don't want them to register a
# slot of their own — they are the new factories the test harness
# writes into Panel B's existing slot, simulating "the user edited the
# Panel B source." Each must have the SAME signature as `panelB`.
proc panelBAfterImpl(vm: PanelBVm; suffix: cstring): Node =
  let root = document.createElement(cstring"div")
  root.setAttribute(cstring"id", cstring"panel-b-content")

  let labelSpan = document.createElement(cstring"span")
  labelSpan.setAttribute(cstring"id", cstring"panel-b-label")
  root.Node.appendChild(labelSpan.Node)
  let vmRef = vm
  let suffixCopy = suffix
  insert(labelSpan.Node, proc(): cstring =
    var combined: cstring
    let labelVal = vmRef.label.val
    {.emit: [combined, " = 'AFTER:' + ", labelVal, " + ", suffixCopy, ";"].}
    combined)

  let extra = document.createElement(cstring"div")
  extra.setAttribute(cstring"id", cstring"panel-b-extra")
  # `position: absolute` keeps the new element findable from the spec
  # without changing the panel's height. Otherwise the Panel B growth
  # triggers Chromium's scroll-anchoring, shifting scrollY by the
  # delta, which would mask the contract under test ("a swap of one
  # mount does not move other mounts").
  extra.setAttribute(cstring"style",
    cstring"position:absolute;visibility:hidden;")
  extra.textContent = cstring"new content from edit"
  root.Node.appendChild(extra.Node)

  return root.Node

proc panelBBrokenImpl(vm: PanelBVm; suffix: cstring): Node =
  raise newException(ValueError, "boom")

bootstrapHmr()

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

proc isonimHmrSimulateMutateBAfter*() {.exportc.} =
  ## Re-register Panel B's slot with a fresh hash and the after-variant
  ## factory. Mirrors what a bundle reload would do for a single
  ## changed component.
  hmrRegisterFactory(
    panelBLoc, "panel-b-after-hash", toJs(panelBAfterImpl))

proc isonimHmrSimulateMutateBBroken*() {.exportc.} =
  hmrRegisterFactory(
    panelBLoc, "panel-b-broken-hash", toJs(panelBBrokenImpl))

proc isonimHmrPanelBLabelSet*(s: cstring) {.exportc.} =
  panelBVm.label.val = s

proc isonimHmrPanelACounter*(): int {.exportc.} =
  panelAVm.counter.val

proc isonimHmrRegistrySize*(): int {.exportc.} = registrySize()
proc isonimHmrGeneration*(): int {.exportc.} = currentGeneration()

# ---------------------------------------------------------------------------
# Mount
# ---------------------------------------------------------------------------

var globalJs {.importjs: "globalThis".}: JsObject

proc main() =
  let panelAContainer = document.getElementById(cstring"panel-a")
  let panelBContainer = document.getElementById(cstring"panel-b")

  # An empty JS array for spec-supplied error callbacks, mirroring the
  # zero-arg fixture's pattern. Tests can register listeners that fire
  # whenever a slot factory throws inside a memo / parametric dispatch.
  proc newJsArray(): JsObject {.importjs: "[@]".}
  let errorCallbacks = newJsArray()
  globalJs["__hmrTestErrorCallbacks"] = errorCallbacks

  proc captureError(err: ref Exception) =
    let msg = cstring(err.msg)
    let len = errorCallbacks["length"].to(int)
    for i in 0 ..< len:
      let cb = errorCallbacks[i].to(proc(m: cstring))
      cb(msg)

  globalUiOnError = proc(loc: string; err: ref Exception) =
    captureError(err)

  # Two *independent* `mountUiHot` boundaries — the design point of
  # this fixture. A swap inside one must not invalidate the other's
  # render effect, and therefore not touch the other's DOM.
  let vmA = panelAVm
  let vmB = panelBVm
  discard mountUiHot(panelAContainer, proc(): Node = panelA(vmA), captureError)
  discard mountUiHot(panelBContainer,
                      proc(): Node = panelB(vmB, cstring"-suffix"),
                      captureError)

  globalJs["__hmrNavigations"] = toJs(0)
  proc registerPageShowCounter()
    {.importjs: "window.addEventListener('pageshow', function () { globalThis.__hmrNavigations += 1; })".}
  registerPageShowCounter()

  let harness = newJsObject()
  proc onErrorBridge(cb: JsObject) =
    discard errorCallbacks.push(cb)
  harness["simulateMutateBAfter"] = toJs(isonimHmrSimulateMutateBAfter)
  harness["simulateMutateBBroken"] = toJs(isonimHmrSimulateMutateBBroken)
  harness["setPanelBLabel"] = toJs(isonimHmrPanelBLabelSet)
  harness["panelACounter"] = toJs(isonimHmrPanelACounter)
  harness["registrySize"] = toJs(isonimHmrRegistrySize)
  harness["generation"] = toJs(isonimHmrGeneration)
  harness["onError"] = toJs(onErrorBridge)
  globalJs["__hmrTest"] = harness

main()
