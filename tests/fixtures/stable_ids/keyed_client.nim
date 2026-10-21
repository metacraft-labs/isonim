## Real keyed DOM fixture; exposes operations, never alternate implementations.
import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import isonim/web/[dom_api, web_renderer, client]

let items = createSignal(@["a", "b", "c"])
proc row(r: WebRenderer; item: proc(): string): Element =
  ui(r):
    button(onclick = proc() = discard): text item()

var unmount = render(proc(): Node =
  let r = WebRenderer()
  let list = r.createElement("ul")
  forEachKeyed(r, list, proc(): seq[string] = items.val,
    proc(item: proc(): string; index: proc(): int): Element = row(r, item))
  Node(list), document.getElementById("root"))

proc setRows(mode: int) {.exportc.} =
  case mode
  of 0: items.val = @["c", "b", "a"]
  of 1: items.val = @["c", "a"]
  else: items.val = @["b", "c", "a"]

proc disposeRows() {.exportc.} =
  unmount()
  unmount = nil
