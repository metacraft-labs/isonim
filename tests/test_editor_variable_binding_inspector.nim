## VBIND-M1 — live-inspector read-path for design-system variable
## bindings.
##
## When a selected element's property is bound to a design-system
## variable, the inspector section row must render the real
## ``variable_chip`` (variable name + chip chrome) instead of the
## inert ``◇`` diamond. When nothing is bound (the default — an empty
## ``propertyBindings`` table), the row renders exactly as before.
##
## These tests exercise the REAL section render path
## (``mountSectionStroke`` / ``mountSectionFill``) plus the VM read
## helper ``inspectorBindingFor``. They are the RED→GREEN gate for the
## read path: red before the sections thread the binding through,
## green after.

import std/[options, tables, strutils, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_stroke
import isonim/editor/views/widgets/section_fill
import isonim/editor/views/widgets/variable_picker
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

proc seedSurfaceToken(vm: EditorVM) =
  vm.foundations.tokens.val = @[
    FoundationTokenEntry(key: "color/surface", kind: ftkSemanticColor,
      value: "#0F172A", sourceFile: "foundations/colour.nim",
      sourceLine: 12)]

suite "VBIND-M1 inspector binding read-path":

  # ---- VM read helper ---------------------------------------------------- #

  test "inspectorBindingFor resolves the selected element's binding":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.seedSurfaceToken()
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-1")

      # Unbound by default — the M1 backward-compat guarantee.
      check vm.inspectorBindingFor("border-color").isNone

      vm.bindPropertyToVariable(PropertyBindingKey(
        elementId: "frame-1", propertyName: "border-color"), "color/surface")

      let bound = vm.inspectorBindingFor("border-color")
      check bound.isSome
      check bound.get().variableKey == "color/surface"
      check bound.get().state == vbsBound

      # A different property on the same element stays unbound.
      check vm.inspectorBindingFor("border-width").isNone

      # Switching selection away from the bound element drops the chip.
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-2")
      check vm.inspectorBindingFor("border-color").isNone
      dispose()

  # ---- Property-row section (stroke) ------------------------------------- #

  test "stroke Color row renders the inert diamond when unbound":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.seedSurfaceToken()
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-1")

      mountSectionStroke[MockRenderer, MockNode](r, root, vm)

      let colorRow = findByAttr(root, "data-property-row", "color")
      check colorRow != nil
      check colorRow.attributes.getOrDefault("data-property-row-linked") ==
        "false"
      # No chip; the literal value input + inert bind slot are present.
      check findByAttr(colorRow, "data-variable-chip", "true") == nil
      check findByAttr(colorRow, "data-property-row-input", "true") != nil
      check findByAttr(colorRow, "data-property-row-slot", "bind") != nil
      dispose()

  test "stroke Color row renders the linked chip when bound":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.seedSurfaceToken()
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-1")
      vm.bindPropertyToVariable(PropertyBindingKey(
        elementId: "frame-1", propertyName: "border-color"), "color/surface")

      mountSectionStroke[MockRenderer, MockNode](r, root, vm)

      let colorRow = findByAttr(root, "data-property-row", "color")
      check colorRow != nil
      check colorRow.attributes.getOrDefault("data-property-row-linked") ==
        "true"
      check findByAttr(colorRow, "data-property-row-linked-chip", "true") != nil
      check findByAttr(colorRow, "data-variable-chip-key", "color/surface") !=
        nil
      check findByAttr(colorRow, "data-property-row-linked-variable",
        "color/surface") != nil
      # The literal hex input is gone — the chip replaced the value slot.
      check findByAttr(colorRow, "data-property-row-input", "true") == nil

      # A sibling row that is NOT bound still shows the literal control.
      let widthRow = findByAttr(root, "data-property-row", "width")
      check widthRow != nil
      check widthRow.attributes.getOrDefault("data-property-row-linked") ==
        "false"
      check findByAttr(widthRow, "data-variable-chip", "true") == nil
      dispose()

  # ---- Hand-rolled section (fill) ---------------------------------------- #

  test "fill row renders the inert diamond when unbound":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.seedSurfaceToken()
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-1",
        properties: @[PropertyInfo(name: "background-color", value: "#1A1B22")])

      mountSectionFill[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-fill-row", "0") != nil
      check findByAttr(root, "data-fill-row-hex", "0") != nil
      check findByAttr(root, "data-fill-row-bind", "0") != nil
      check findByAttr(root, "data-variable-chip", "true") == nil
      check findByAttr(root, "data-fill-row-linked", "true") == nil
      dispose()

  test "fill row renders the linked chip when background-color is bound":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.seedSurfaceToken()
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-1",
        properties: @[PropertyInfo(name: "background-color", value: "#1A1B22")])
      vm.bindPropertyToVariable(PropertyBindingKey(
        elementId: "frame-1", propertyName: "background-color"),
        "color/surface")

      mountSectionFill[MockRenderer, MockNode](r, root, vm)

      let fillRow = findByAttr(root, "data-fill-row", "0")
      check fillRow != nil
      check fillRow.attributes.getOrDefault("data-fill-row-linked") == "true"
      check findByAttr(fillRow, "data-fill-row-linked-chip", "true") != nil
      check findByAttr(fillRow, "data-variable-chip-key", "color/surface") != nil
      # The literal hex input + inert ◇ bind slot are gone.
      check findByAttr(fillRow, "data-fill-row-hex", "0") == nil
      check findByAttr(fillRow, "data-fill-row-bind", "0") == nil
      dispose()

# --------------------------------------------------------------------------- #
#  VBIND-M2 — link flow (row → picker) + hot-swap of the static rows.
# --------------------------------------------------------------------------- #

proc wirePicker(vm: EditorVM; picker: VariablePickerState) =
  ## Wire the inspector's picker hook the same way the shell does, so a
  ## section row's bind affordance opens ``picker``.
  vm.inspector.requestVariablePicker =
    proc(key: PropertyBindingKey; x, y, w, h: float) {.closure.} =
      openVariablePickerWithRect(picker, key, x, y, w, h)

suite "VBIND-M2 inspector link flow":

  test "clicking a stroke row's bind slot opens the picker for its key":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.seedSurfaceToken()
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-1")
      let picker = createVariablePickerState()
      vm.wirePicker(picker)

      mountSectionStroke[MockRenderer, MockNode](r, root, vm)

      let colorRow = findByAttr(root, "data-property-row", "color")
      check colorRow != nil
      let bindSlot = findByAttr(colorRow, "data-property-row-slot", "bind")
      check bindSlot != nil
      check picker.open.val == false

      fireEvent(bindSlot, "click")

      check picker.open.val == true
      check picker.targetPropertyKey.val.elementId == "frame-1"
      check picker.targetPropertyKey.val.propertyName == "border-color"
      dispose()

  test "picking a variable binds the property and hot-swaps the row to a chip":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.seedSurfaceToken()
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-1")
      let picker = createVariablePickerState()
      vm.wirePicker(picker)

      # Section + picker share the VM, exactly as the live shell mounts
      # them (picker at the shell root, sections in the inspector body).
      mountSectionStroke[MockRenderer, MockNode](r, root, vm)
      discard r.mountVariablePicker(root, vm, picker)

      # Before linking: the Color row is a literal control.
      block:
        let colorRow = findByAttr(root, "data-property-row", "color")
        check colorRow.attributes.getOrDefault(
          "data-property-row-linked") == "false"
        check findByAttr(colorRow, "data-property-row-input", "true") != nil

      # Open the picker from the row, then pick a variable.
      let bindSlot = findByAttr(
        findByAttr(root, "data-property-row", "color"),
        "data-property-row-slot", "bind")
      fireEvent(bindSlot, "click")
      check picker.open.val == true

      let pickerRoot = findByAttr(root, "data-variable-picker", "true")
      let surfaceRow = findByAttr(pickerRoot,
        "data-variable-picker-row", "color/surface")
      check surfaceRow != nil
      fireEvent(surfaceRow, "click")

      # The picker committed the binding under the row's canonical key
      # and closed itself.
      check picker.open.val == false
      let bound = vm.propertyBindingFor(PropertyBindingKey(
        elementId: "frame-1", propertyName: "border-color"))
      check bound.isSome
      check bound.get.variableKey == "color/surface"

      # The static stroke row hot-swapped to the chip WITHOUT a remount.
      let colorRow = findByAttr(root, "data-property-row", "color")
      check colorRow.attributes.getOrDefault(
        "data-property-row-linked") == "true"
      check findByAttr(colorRow, "data-property-row-linked-chip", "true") != nil
      check findByAttr(colorRow, "data-variable-chip-key", "color/surface") !=
        nil
      check findByAttr(colorRow, "data-property-row-input", "true") == nil
      dispose()

  test "binding after mount hot-swaps a static row to the chip":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.seedSurfaceToken()
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-1")

      mountSectionStroke[MockRenderer, MockNode](r, root, vm)

      block:
        let colorRow = findByAttr(root, "data-property-row", "color")
        check colorRow.attributes.getOrDefault(
          "data-property-row-linked") == "false"
        check findByAttr(colorRow, "data-property-row-input", "true") != nil

      # Seeding the binding AFTER the row is mounted must flip it to the
      # chip reactively (the M1 hot-swap gap this milestone closes).
      vm.bindPropertyToVariable(PropertyBindingKey(
        elementId: "frame-1", propertyName: "border-color"), "color/surface")

      let colorRow = findByAttr(root, "data-property-row", "color")
      check colorRow.attributes.getOrDefault(
        "data-property-row-linked") == "true"
      check findByAttr(colorRow, "data-variable-chip-key", "color/surface") !=
        nil
      check findByAttr(colorRow, "data-property-row-input", "true") == nil
      dispose()

  test "selecting a bound element hot-swaps the row to the chip":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.seedSurfaceToken()
      # frame-2 owns a binding; frame-1 does not.
      vm.bindPropertyToVariable(PropertyBindingKey(
        elementId: "frame-2", propertyName: "border-color"), "color/surface")
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-1")

      mountSectionStroke[MockRenderer, MockNode](r, root, vm)

      block:
        let colorRow = findByAttr(root, "data-property-row", "color")
        check colorRow.attributes.getOrDefault(
          "data-property-row-linked") == "false"

      # Move the selection to the bound element — the same row must now
      # render the chip without being re-mounted.
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-2")

      let colorRow = findByAttr(root, "data-property-row", "color")
      check colorRow.attributes.getOrDefault(
        "data-property-row-linked") == "true"
      check findByAttr(colorRow, "data-variable-chip-key", "color/surface") !=
        nil
      dispose()

# --------------------------------------------------------------------------- #
#  VBIND-M3 — unlink → local literal override (journal the detached value).
# --------------------------------------------------------------------------- #

suite "VBIND-M3 inspector unlink → local override":

  test "unlinking a stroke Color row converts it to a seeded local literal":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.seedSurfaceToken()
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-1",
        sourceFile: "components/Frame.nim", sourceLine: 10,
        properties: @[PropertyInfo(name: "border-color", value: "#1A1B22",
          origin: poInherited, sourceFile: "components/Frame.nim",
          sourceLine: 10, directStyleAllowed: true)])
      vm.bindPropertyToVariable(PropertyBindingKey(
        elementId: "frame-1", propertyName: "border-color"), "color/surface")

      mountSectionStroke[MockRenderer, MockNode](r, root, vm)

      # Bound → the chip (with a detach affordance) is present.
      var colorRow = findByAttr(root, "data-property-row", "color")
      check colorRow.attributes.getOrDefault(
        "data-property-row-linked") == "true"
      let detach = findByAttr(colorRow, "data-variable-chip-detach", "true")
      check detach != nil

      # Click the chip's UNLINK affordance.
      fireEvent(detach, "click")

      # (a) the property is now UNBOUND.
      check vm.propertyBindingFor(PropertyBindingKey(
        elementId: "frame-1", propertyName: "border-color")).isNone

      # (b) a LOCAL literal override carrying the resolved value is
      # journaled onto pendingSourceEdits (the override actually applies).
      let edits = vm.inspector.pendingSourceEdits.val
      check edits.len == 1
      check edits[0].property == "border-color"
      check edits[0].scope == pesLocal
      check edits[0].newValue.toLowerAscii() == "#0f172a"

      # (c) the row reactively swapped chip → editable literal, seeded to
      # the detached (resolved) value.
      colorRow = findByAttr(root, "data-property-row", "color")
      check colorRow.attributes.getOrDefault(
        "data-property-row-linked") == "false"
      check findByAttr(colorRow, "data-variable-chip", "true") == nil
      let input = findByAttr(colorRow, "data-property-row-input", "true")
      check input != nil
      check r.inputValue(input).toLowerAscii() == "#0f172a"
      check r.inputValue(input) == edits[0].newValue
      dispose()

  test "unlinking is a pure no-op path when nothing is bound":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.seedSurfaceToken()
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-1",
        sourceFile: "components/Frame.nim", sourceLine: 10,
        properties: @[PropertyInfo(name: "border-color", value: "#1A1B22",
          origin: poInherited, sourceFile: "components/Frame.nim",
          sourceLine: 10, directStyleAllowed: true)])

      mountSectionStroke[MockRenderer, MockNode](r, root, vm)

      # Firing the detach handler with no binding stages nothing.
      vm.inspectorDetachRequestHandler("border-color")()
      check vm.inspector.pendingSourceEdits.val.len == 0
      let colorRow = findByAttr(root, "data-property-row", "color")
      check colorRow.attributes.getOrDefault(
        "data-property-row-linked") == "false"
      check findByAttr(colorRow, "data-property-row-input", "true") != nil
      dispose()

  test "unlinking the primary fill chip journals a local override":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.seedSurfaceToken()
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-1",
        sourceFile: "components/Frame.nim", sourceLine: 10,
        properties: @[PropertyInfo(name: "background-color", value: "#1A1B22",
          origin: poInherited, sourceFile: "components/Frame.nim",
          sourceLine: 10, directStyleAllowed: true)])
      vm.bindPropertyToVariable(PropertyBindingKey(
        elementId: "frame-1", propertyName: "background-color"),
        "color/surface")

      mountSectionFill[MockRenderer, MockNode](r, root, vm)

      var fillRow = findByAttr(root, "data-fill-row", "0")
      check fillRow.attributes.getOrDefault("data-fill-row-linked") == "true"
      let detach = findByAttr(fillRow, "data-variable-chip-detach", "true")
      check detach != nil

      fireEvent(detach, "click")

      # Unbound + local override journaled with the resolved value.
      check vm.propertyBindingFor(PropertyBindingKey(
        elementId: "frame-1", propertyName: "background-color")).isNone
      let edits = vm.inspector.pendingSourceEdits.val
      check edits.len == 1
      check edits[0].property == "background-color"
      check edits[0].scope == pesLocal
      check edits[0].newValue.toLowerAscii() == "#0f172a"

      # The row reactively fell back to the literal hex control (+ inert ◇).
      fillRow = findByAttr(root, "data-fill-row", "0")
      check fillRow.attributes.getOrDefault("data-fill-row-linked") != "true"
      check findByAttr(fillRow, "data-variable-chip", "true") == nil
      check findByAttr(root, "data-fill-row-hex", "0") != nil
      dispose()
