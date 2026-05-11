## examples/hmr-interop-vite/src/counter.nim
##
## A tiny isonim component for the Vite HMR interop demo.
##
## The component itself is unremarkable — what matters here is the
## integration shape:
##
## - `{.uiComponent.}` on `counterPanel` emits a top-level
##   `hmrRegisterFactory` call into the module init code. When Vite
##   replaces this module (after the plugin recompiles the .nim),
##   the new init runs and the slot's factory signal gets
##   rewritten if the body changed.
## - `mountUiHot` is the reactive boundary: it reads the slot's
##   factory signal, so it re-renders in place when the slot
##   updates.
## - The `vm` lives at module scope and survives the Vite HMR
##   update because Vite replaces only the module's JS code; the
##   already-created VM ref kept alive by the mount's closure keeps
##   pointing at the same Signal instances. (If we ever want the VM
##   to be re-initialised on edit, we'd opt in via `hmrSignal` —
##   not what this demo wants.)

when not defined(js):
  {.error: "Vite demo requires the JS backend".}

import std/jsffi
import isonim/core/signals
import isonim/dsl/ui
import isonim/web/dom_api as isonim_dom
import isonim/web/web_renderer
import isonim/web/events
import isonim/web/client  # for the reactive `insert(Node, accessor)` overload
import isonim/web/hmr_component
import isonim/web/hmr

type
  CounterVm* = ref object
    count*: Signal[int]
    label*: Signal[string]

let counterVm* = CounterVm(
  count: signals.createSignal(0),
  label: signals.createSignal("clicks"))

proc counterPanel*(vm: CounterVm): isonim_dom.Element {.uiComponent.} =
  ## Edit me and watch the running page update in place.
  ## Examples of edits that exercise HMR:
  ##   * change the "Count:" string below
  ##   * change the button's increment amount in onInc
  ##   * change the label suffix from "clicks" to "presses"
  ## In every case the counter value held in `vm.count` is preserved
  ## across the swap.
  let root = isonim_dom.document.createElement(cstring"div")
  root.setAttribute(cstring"class", cstring"counter")
  root.setAttribute(cstring"id", cstring"counter-root")

  let label = isonim_dom.document.createElement(cstring"span")
  label.setAttribute(cstring"id", cstring"counter-label")
  root.Node.appendChild(label.Node)
  let vmRef = vm
  insert(label.Node, proc(): cstring =
    cstring("Count: " & $vmRef.count.val & " " & vmRef.label.val))

  let incBtn = isonim_dom.document.createElement(cstring"button")
  incBtn.setAttribute(cstring"id", cstring"counter-inc")
  incBtn.textContent = cstring"+1"
  root.Node.appendChild(incBtn.Node)

  proc onInc(ev: isonim_dom.Event) =
    vmRef.count.val = vmRef.count.val + 1
  addEventListenerWeb(incBtn.Node, cstring"click", onInc, delegate = true)
  delegateEvents([cstring"click"])

  return root

# JS-side entry point. Vite imports this module for side effects;
# main.ts then calls `mountCounter` via globalThis (Nim's JS output
# is a script, not an ES module, so this is the contact surface).
proc mountCounter*() {.exportc.} =
  let container =
    isonim_dom.document.getElementById(cstring"counter-mount")
  discard mountUiHot(
    container,
    proc(): isonim_dom.Node = isonim_dom.Node(counterPanel(counterVm)))

bootstrapHmr()

var globalJs {.importjs: "globalThis".}: JsObject

# Module init: expose the mount fn on globalThis so the consumer
# can reach it after `import './counter.nim'` runs for side effects.
# (Nim's JS backend doesn't emit ES module exports, so this is the
# canonical handoff for an `import-for-side-effects` integration.)
globalJs["__isonim_demo_mountCounter"] = toJs(mountCounter)
globalJs["__isonim_demo_counterVm"] = toJs(counterVm)
