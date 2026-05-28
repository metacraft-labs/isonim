## Phase G — section_state widget unit test.

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_state
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_state":

  test "renders empty-state when no reactive properties present":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionState[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-state-section-body", "true") != nil
      let empty = findByAttr(root, "data-state-empty", "true")
      check empty != nil
      check empty.styles.getOrDefault("display") == "block"
      dispose()

  test "isReactiveStateProperty flags setStyle origin + signal: marker":
    check isReactiveStateProperty(PropertyInfo(name: "color",
      value: "#fff", origin: poSetStyle))
    check isReactiveStateProperty(PropertyInfo(name: "value",
      value: "1", origin: poInherited, originDetail: "signal:counter"))
    check not isReactiveStateProperty(PropertyInfo(name: "color",
      value: "#fff", origin: poTailwindClass))

  test "reactive properties populate the row list":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionState[MockRenderer, MockNode](r, root, vm)

      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        properties: @[
          PropertyInfo(name: "count", value: "3",
            origin: poInherited, originDetail: "signal:count"),
          PropertyInfo(name: "padding", value: "16px")])
      check findByAttr(root, "data-property-row", "count") != nil
      check findByAttr(root, "data-property-row", "padding") == nil
      let empty = findByAttr(root, "data-state-empty", "true")
      check empty.styles.getOrDefault("display") == "none"
      dispose()
