## examples/hmr-interop-webpack/src/counter.nim
##
## Same component shape as the Vite demo (a single-button counter
## using mountUiHot + a {.uiComponent.}-marked panel). The
## difference is purely the host pipeline: Webpack's nim-loader
## handles compilation + HMR self-accept emission instead of
## Vite's plugin.

when not defined(js):
  {.error: "Webpack demo requires the JS backend".}

import std/jsffi
import isonim/core/signals
import isonim/dsl/ui
import isonim/web/dom_api as isonim_dom
import isonim/web/web_renderer
import isonim/web/events
import isonim/web/client
import isonim/web/hmr_component
import isonim/web/hmr

type
  CounterVm* = ref object
    count*: Signal[int]

let counterVm* = CounterVm(count: signals.createSignal(0))

proc counterPanel*(vm: CounterVm): isonim_dom.Element {.uiComponent.} =
  ## Edit me and watch the running page update in place. Examples:
  ## change "Count:" to something else, or change the increment.
  let root = isonim_dom.document.createElement(cstring"div")
  root.setAttribute(cstring"class", cstring"counter")
  root.setAttribute(cstring"id", cstring"counter-root")

  let label = isonim_dom.document.createElement(cstring"span")
  label.setAttribute(cstring"id", cstring"counter-label")
  root.Node.appendChild(label.Node)
  let vmRef = vm
  insert(label.Node, proc(): cstring =
    cstring("Count: " & $vmRef.count.val))

  let incBtn = isonim_dom.document.createElement(cstring"button")
  incBtn.setAttribute(cstring"id", cstring"counter-inc")
  incBtn.textContent = cstring"+1"
  root.Node.appendChild(incBtn.Node)

  proc onInc(ev: isonim_dom.Event) =
    vmRef.count.val = vmRef.count.val + 1
  addEventListenerWeb(incBtn.Node, cstring"click", onInc, delegate = true)
  delegateEvents([cstring"click"])

  return root

proc mountCounter*() {.exportc.} =
  let container =
    isonim_dom.document.getElementById(cstring"counter-mount")
  discard mountUiHot(
    container,
    proc(): isonim_dom.Node = isonim_dom.Node(counterPanel(counterVm)))

bootstrapHmr()

var globalJs {.importjs: "globalThis".}: JsObject
globalJs["__isonim_webpack_demo_mountCounter"] = toJs(mountCounter)
