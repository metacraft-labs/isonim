## ONE runtime: genuine DSL registration first; deliberate late private selection.
## No archive/startup claim. Prior context and owner log are supplied by integration.
import std/[json, jsffi, monotimes]
import isonim/core/nondet
import isonim/core/private/replay_reads
import isonim/dsl/[ui, stable_ids]
import isonim/web/[dom_api, web_renderer]
import nim_everywhere/time as neTime

proc leaf(): Element =
  ui(WebRenderer()):
    button: text "registered geometry"
proc create(key: string): Element =
  withStableKey(key):
    result = leaf()
proc mount(key: cstring): Element {.exportc: "xrMeasureMount".} =
  result = create($key)
  discard Node(document.getElementById("root")).appendChild(Node(result))
proc resolve(iid: cstring): Element {.exportc: "xrMeasureResolve".} = resolveIid($iid)
proc select() {.exportc: "xrMeasureSelect".} =
  proc context(): cstring {.importjs: "JSON.stringify(globalThis.xrReadBootContext)".}
  install(newInternalReadReplay(parseJson($context())))
proc controls(): cstring {.exportc: "xrMeasureControls".} =
  let boot = env()
  let tick = $nondet.now().ticks
  let neMillis = $neTime.monotonicNowMs()
  let missing = storageGet("missing")
  let empty = storageGet("empty")
  let value = storageGet("value")
  let cookie = cookieGet()
  let v = viewport()
  let media = matchMedia("screen")
  ($(%*{"env":boot,"tick":tick,"neMillis":neMillis,"missing":missing,
    "empty":empty,"value":value,"cookie":cookie,"media":media,
    "viewport":{"x":v.x,"y":v.y,"width":v.width,"height":v.height}})).cstring
proc observed(el: JsObject): cstring {.exportc: "xrMeasure".} =
  let r = measure(el)
  ($(%*{"x":r.x,"y":r.y,"width":r.width,"height":r.height})).cstring
proc privateObserved(el: JsObject): cstring {.exportc: "xrMeasurePrivate".} =
  ($readReplayMeasure(currentClock, el)).cstring
