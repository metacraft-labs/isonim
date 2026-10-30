## Actual authored literal promotion, shipped editor registry and renderer.
## No mocks: mutate the real editable cells; WebRenderer uses real Chromium.
import std/tables
import isonim/rxcore
import isonim/dsl/ui
import isonim/editor/editable_cells
when defined(isonimPublicBrowser):
  import isonim/web/[web_renderer, dom_api]
  type Renderer = WebRenderer
  proc attribute(n: Element; name: string): string =
    WebRenderer().getAttribute(n, name)
  proc writes(): int = meter.ops[boSetAttribute]
  meterEnabled = true
else:
  import isonim/renderers/native
  type Renderer = NativeRenderer
  proc attribute(n: NativeWidget; name: string): string =
    n.attributes.getOrDefault(name)

proc mount(r: Renderer): auto =
  ui(r):
    input(public = true, `type` = "text", autocomplete = "off")

for property in ["type", "autocomplete"]:
  resetEditableCells()
  var id: string
  var identity: Signal[string]
  createRoot do (dispose: proc()):
    let target = mount(Renderer())
    id = attribute(target, "data-isonim-src")
    identity = editableCell(id, property)
    doAssert id.len > 0 and not identity.isNil, "public editor actual cell exists"
    doAssert editableCell(id, "public").isNil, "public directive must not be editable"
    doAssert attribute(target, "public") == "", "public editor consumes directive"
    doAssert attribute(target, "data-isonim-public") == "true", "public editor marker"
    let legal = if property == "type": "EMAIL" else: "name email"
    doAssert setEditableValue(id, property, legal)
    doAssert attribute(target, property) == legal, "public editor legal exact bytes"
    doAssert editableCell(id, property) == identity, "public editor retains identity"
    when defined(isonimPublicBrowser):
      let count = writes()
    var refused = false
    try:
      discard setEditableValue(id, property,
        if property == "type": "PaSsWoRd" else: "name\tCC-number")
    except ValueError as e:
      refused = e.msg == "credential input cannot be public"
    doAssert refused, "public editor cell credential guard"
    doAssert attribute(target, property) == legal, "public editor refusal preserves renderer"
    when defined(isonimPublicBrowser):
      doAssert writes() == count, "public editor refusal precedes backend noteOp"
    doAssert setEditableValue(id, property, "text"), "public editor legal update after refusal"
    doAssert attribute(target, property) == "text"
    dispose()
  # Rebuilding the same authored location reuses the edited cell, not its seed.
  createRoot do (dispose: proc()):
    let target = mount(Renderer())
    doAssert attribute(target, "data-isonim-src") == id
    doAssert editableCell(id, property) == identity, "public editor rebuild retains cell"
    doAssert attribute(target, property) == "text", "public editor rebuild retains edit"
    dispose()
  # With old effects disposed, an invalid edit reaches the initial reused-cell
  # read on the next mount. It must be checked there as well as on updates.
  doAssert setEditableValue(id, property,
    if property == "type": "password" else: "one-time-code")
  createRoot do (dispose: proc()):
    var refused = false
    try: discard mount(Renderer())
    except ValueError as e:
      refused = e.msg == "credential input cannot be public"
    doAssert refused, "public editor reused cell credential guard"
    doAssert editableCell(id, property) == identity
    dispose()
  doAssert setEditableValue(id, property, "email")
  createRoot do (dispose: proc()):
    let target = mount(Renderer())
    doAssert attribute(target, property) == "email", "public editor legal rebuild after refusal"
    doAssert editableCell(id, property) == identity
    dispose()

resetEditableCells()
createRoot do (dispose: proc()):
  let r = Renderer()
  let target = ui(r):
    textarea(public = true, `type` = "text")
  let id = attribute(target, "data-isonim-src")
  doAssert setEditableValue(id, "type", "password")
  doAssert attribute(target, "type") == "password", "public editor noninput type remains ordinary"
  let ordinary = ui(r):
    input(`type` = "text", autocomplete = "off")
  let ordinaryId = attribute(ordinary, "data-isonim-src")
  doAssert setEditableValue(ordinaryId, "type", "password")
  doAssert setEditableValue(ordinaryId, "autocomplete", "cc-number")
  doAssert attribute(ordinary, "type") == "password", "ordinary editor type unchanged"
  doAssert attribute(ordinary, "autocomplete") == "cc-number", "ordinary editor autocomplete unchanged"
  dispose()
when defined(isonimPublicBrowser):
  {.emit: "globalThis.publicDirectivePassed = true;".}
