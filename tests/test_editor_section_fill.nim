## Fill-section renderer-neutral selection hydration tests.
## MockRenderer replaces only DOM mounting/events so selection and property
## signals run through the production editor/section. It does not simulate a
## successful source edit or compiler. The mounted compiled-browser suite owns
## actual preview selection, popup reachability/focus and refused edits; the real
## consumer-adapter suite owns filesystem/compiler writeback. Existing add/seed
## checks are retained, with delayed same-element property delivery covered here.

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
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

suite "Phase G section_fill":

  test "mounts list + empty-state + add button":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionFill[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-fill-section-body", "true") != nil
      check findByAttr(root, "data-fill-list", "true") != nil
      let empty = findByAttr(root, "data-fill-empty", "true")
      check empty != nil
      check empty.styles.getOrDefault("display") == "block"
      check findByAttr(root, "data-fill-add", "true") != nil
      dispose()

  test "+ Add fill appends a row with swatch + hex + alpha":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionFill[MockRenderer, MockNode](r, root, vm)

      let addBtn = findByAttr(root, "data-fill-add", "true")
      fireEvent(addBtn, "click")
      check findByAttr(root, "data-fill-row", "0") != nil
      check findByAttr(root, "data-fill-row-swatch", "0") != nil
      check findByAttr(root, "data-fill-row-hex", "0") != nil
      check findByAttr(root, "data-fill-row-alpha", "0") != nil
      check findByAttr(root, "data-fill-row-bind", "0") != nil
      dispose()

  test "selection with background-color seeds a fill row":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionFill[MockRenderer, MockNode](r, root, vm)

      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        id: "elem-1",
        properties: @[PropertyInfo(name: "background-color",
          value: "#1A1B22")])
      check findByAttr(root, "data-fill-row", "0") != nil
      let hex = findByAttr(root, "data-fill-row-hex", "0")
      check hex != nil
      check r.inputValue(hex) == "#1A1B22"
      dispose()

  test "late computed fill properties on the same selected element reveal the real swatch":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionFill[MockRenderer, MockNode](r, root, vm)
      vm.inspector.selectedElement.val = ElementRef(tag: "button", id: "action")
      check findByAttr(root, "data-fill-row", "0") == nil
      vm.inspector.selectedElement.val = ElementRef(tag: "button", id: "action",
        properties: @[PropertyInfo(name: "background-color", value: "#112233")])
      let hex = findByAttr(root, "data-fill-row-hex", "0")
      check hex != nil
      if hex != nil: check r.inputValue(hex) == "#112233"
      dispose()

  test "updated computed fill value with stable identity follows the actual selection":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionFill[MockRenderer, MockNode](r, root, vm)
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "same",
        properties: @[PropertyInfo(name: "background-color", value: "#010203")])
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "same",
        properties: @[PropertyInfo(name: "background-color", value: "#AABBCC")])
      let hex = findByAttr(root, "data-fill-row-hex", "0")
      check hex != nil
      if hex != nil: check r.inputValue(hex) == "#AABBCC"
      dispose()

  test "text and box fill invokers target their actual fill property":
    for (tag, property) in [("p", "color"), ("div", "background-color")]:
      createRoot do (dispose: proc()):
        let r = MockRenderer()
        let root = r.createElement("div")
        let vm = createEditorVM()
        var requested = PropertyBindingKey()
        # Capture only the renderer-neutral admission request. This does not
        # substitute for selecting a token, editing source or successful I/O.
        vm.inspector.requestVariablePicker = proc(key: PropertyBindingKey; x, y, w, h: float) = requested = key
        mountSectionFill[MockRenderer, MockNode](r, root, vm)
        vm.inspector.selectedElement.val = ElementRef(tag: tag, id: "target",
          properties: @[PropertyInfo(name: "color", value: "#112233"),
            PropertyInfo(name: "background-color", value: "#445566")])
        let invoker = findByAttr(root, "data-fill-row-bind", "0")
        check invoker != nil
        if invoker != nil: invoker.fireEvent("click")
        check requested.elementId == "target"
        check requested.propertyName == property
        dispose()
