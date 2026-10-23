## Source-aware text rows for compound CSS values in the section inspector.
## These rows use the same validation, source-scope admission, preview and
## automatic-save pipeline as the specialized numeric/choice controls. Only
## properties actually exposed by the selection are shown; a missing writer
## remains a visible refusal rather than a pretend local edit.
import std/options
import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/viewmodels
import ./property_row
import ./property_commit

proc mountExposedCssRow*[R, E](r: R; parent: E; vm: EditorVM; key: string;
    wiring: InspectorRowWiring) =
  ## One row for ``key``, committing through ``wiring``. A specialized editor
  ## that edits the same property shares the wiring, so a scope chosen on
  ## either applies to both.
  let value = createSignal("")
  let host = ui(r):
    tdiv(`data-exposed-css-property` = key,
         display = "none", flex_direction = "column")
  r.appendChild(parent, host)
  discard r.mountPropertyRow(host, propertyRowText(
    name = key, value = value,
    bindingReactive = vm.inspectorBindingThunk(key),
    onBindRequest = vm.inspectorBindRequestHandler(key),
    onDetachRequest = vm.inspectorDetachRequestHandler(key),
    wiring = wiring))
  createRenderEffect proc() =
    let prop = vm.inspectorProperty(key)
    r.setStyle(host, "display", if prop.isSome: "flex" else: "none")
    if prop.isSome:
      let current = prop.get
      value.val = if current.authoredValue.len > 0:
        current.authoredValue
      else: current.value

proc mountExposedCssRows*[R, E](r: R; parent: E; vm: EditorVM;
    properties: openArray[string]) =
  for property in properties:
    mountExposedCssRow(r, parent, vm, property, vm.inspectorRowWiring(property))
