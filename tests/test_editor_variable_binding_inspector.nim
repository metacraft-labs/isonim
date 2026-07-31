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

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_stroke
import isonim/editor/views/widgets/section_fill
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
