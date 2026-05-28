## Phase G — section_component_props widget unit test.

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_component_props
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_component_props":

  test "mounts empty-state when selection is not a component instance":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionComponentProps[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-component-props-body", "true") != nil
      check findByAttr(root, "data-component-props-list", "true") != nil
      let empty = findByAttr(root, "data-component-props-empty", "true")
      check empty != nil
      check empty.styles.getOrDefault("display") == "block"

      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        properties: @[
          PropertyInfo(name: "padding", value: "16px")])
      check empty.styles.getOrDefault("display") == "block"
      dispose()

  test "schema-backed properties populate the list":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionComponentProps[MockRenderer, MockNode](r, root, vm)

      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        schemaKey: "Button",
        properties: @[
          PropertyInfo(name: "variant", value: "primary",
            schemaKey: "Button.variant"),
          PropertyInfo(name: "size", value: "md",
            schemaKey: "Button.size"),
          PropertyInfo(name: "padding", value: "16px")])
      check findByAttr(root, "data-property-row", "variant") != nil
      check findByAttr(root, "data-property-row", "size") != nil
      # ``padding`` has no schemaKey — it should not appear.
      check findByAttr(root, "data-property-row", "padding") == nil
      let empty = findByAttr(root, "data-component-props-empty", "true")
      check empty.styles.getOrDefault("display") == "none"
      dispose()

  test "isComponentInstance flags any schema-bound property":
    let withSchema = ElementRef(tag: "div", properties: @[
      PropertyInfo(name: "label", value: "Save", schemaKey: "Btn.label")])
    check isComponentInstance(withSchema)
    let plain = ElementRef(tag: "div", properties: @[
      PropertyInfo(name: "padding", value: "0")])
    check not isComponentInstance(plain)
