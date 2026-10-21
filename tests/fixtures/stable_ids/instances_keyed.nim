## Two reusable keyed lists share the same row template and the same item keys.
## Real DOM and reactive owners, with no alternate reconciliation implementation.
import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import isonim/web/[dom_api, web_renderer, client]

let items = createSignal(@["a", "b", "c"])
proc leaf(r: WebRenderer; item: proc(): string): Element =
  ui(r):
    button(onclick = proc() = discard): text item()
proc row(r: WebRenderer; item: proc(): string): Element =
  ui(r):
    li:
      raw leaf(r, item)
      raw leaf(r, item)
proc list(r: WebRenderer; values: Signal[seq[string]]): Element =
  result = r.createElement("ul")
  forEachKeyed(r, result, proc(): seq[string] = values.val,
    proc(item: proc(): string; index: proc(): int): Element = row(r, item))
proc app(r: WebRenderer): Element =
  ui(r):
    tdiv:
      raw list(r, items)
      raw list(r, createSignal(@["a", "b", "c"]))
var unmount = render(proc(): Node = Node(app(WebRenderer())), document.getElementById("root"))
proc updateInstances(mode: int) {.exportc.} =
  case mode
  of 0: items.val = @["c", "b", "a"]
  of 1: items.val = @["c", "a"]
  of 2: items.val = @["b", "c", "a"]
  else: items.val = @["d", "c", "a"]
proc disposeInstances() {.exportc.} =
  unmount()
  unmount = nil
# Deliberately bypass the DSL's caller slots: mounting two such targets must
# fail explicitly rather than changing the first node's index entry silently.
proc outsideLeaf(): Element =
  ui(WebRenderer()):
    button(onclick = proc() = discard): text "outside DSL"
proc outsideTargets() {.exportc.} =
  let a = outsideLeaf()
  discard Node(document.getElementById("root")).appendChild(Node(a))
  let b = outsideLeaf()
  discard Node(document.getElementById("root")).appendChild(Node(b))
proc resolveInstanceIid(iid: cstring): Element {.exportc.} =
  resolveIid($iid)
proc reclaimInstance(iid: cstring) {.exportc.} =
  let node = resolveIid($iid)
  noteElement(node, $iid)
