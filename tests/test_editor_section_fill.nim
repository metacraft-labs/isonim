## Phase G — section_fill widget unit test.

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
