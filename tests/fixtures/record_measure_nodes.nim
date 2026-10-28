## Genuine DSL/M6 nodes, shared by separately compiled Record/Replay realms.
import isonim/dsl/[ui, stable_ids]
import isonim/web/[dom_api, web_renderer]
proc leaf(): Element =
  ui(WebRenderer()):
    button: text "registered native geometry"
proc rqMount(key: cstring): Element {.exportc.} =
  withStableKey($key):
    result = leaf()
  discard Node(document.getElementById("root")).appendChild(Node(result))
proc rqResolve(iid: cstring): Element {.exportc.} = resolveIid($iid)
