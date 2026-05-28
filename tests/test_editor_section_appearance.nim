## Phase G — section_appearance widget unit test.

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_appearance
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_appearance":

  test "mounts opacity / radius / blend mode / per-corner":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionAppearance[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-property-row", "opacity") != nil
      check findByAttr(root, "data-property-row", "corner-radius") != nil
      check findByAttr(root, "data-property-row", "blend-mode") != nil
      check findByAttr(root, "data-property-row", "per-corner") != nil
      check findByAttr(root, "data-appearance-percorner-host", "true") != nil
      dispose()

  test "per-corner host hides until the toggle is on":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionAppearance[MockRenderer, MockNode](r, root, vm)

      let host = findByAttr(root, "data-appearance-percorner-host", "true")
      check host != nil
      check host.styles.getOrDefault("display") == "none"

      let toggle = findByAttr(findByAttr(root, "data-property-row",
        "per-corner"), "data-property-row-input", "true")
      check toggle != nil
      fireEvent(toggle, "click")
      check host.styles.getOrDefault("display") == "flex"
      dispose()

  test "opacity seed converts CSS 0..1 to UI 0..100":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        properties: @[PropertyInfo(name: "opacity", value: "0.5")])
      mountSectionAppearance[MockRenderer, MockNode](r, root, vm)

      let opacityInput = findByAttr(findByAttr(root, "data-property-row",
        "opacity"), "data-property-row-input", "true")
      check opacityInput != nil
      check r.inputValue(opacityInput) == "50"
      dispose()
