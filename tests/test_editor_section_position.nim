## Phase G — section_position widget unit test.
##
## Verifies:
##   1. The section body mounts X / Y / Rotation property rows with
##      the expected ``data-property-row`` slugs.
##   2. The alignment + flip control rows render the data attributes
##      the visual review pipeline pins.
##   3. The empty-state placeholder visibility tracks
##      ``vm.inspector.hasElement``.

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_position
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_position":

  test "section_position mounts X / Y / Rotation property rows":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionPosition[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-property-row", "x") != nil
      check findByAttr(root, "data-property-row", "y") != nil
      check findByAttr(root, "data-property-row", "rotation") != nil
      check findByAttr(root, "data-position-alignment-row", "true") != nil
      check findByAttr(root, "data-position-flip-row", "true") != nil
      dispose()

  test "alignment row carries horizontal + vertical + distribute clusters":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionPosition[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-position-alignment-cluster",
        "horizontal") != nil
      check findByAttr(root, "data-position-alignment-cluster",
        "vertical") != nil
      check findByAttr(root, "data-position-alignment-cluster",
        "distribute") != nil
      check findByAttr(root, "data-position-distribute", "spacing") != nil
      for slug in ["left", "center", "right"]:
        check findByAttr(root, "data-position-align", slug) != nil
      for slug in ["top", "middle", "bottom"]:
        check findByAttr(root, "data-position-valign", slug) != nil
      for slug in ["horizontal", "vertical"]:
        check findByAttr(root, "data-position-flip", slug) != nil
      dispose()

  test "empty-state hides when an element is selected":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionPosition[MockRenderer, MockNode](r, root, vm)

      let empty = findByAttr(root, "data-position-empty", "true")
      check empty != nil
      check empty.attributes.getOrDefault("data-position-empty-visible") ==
        "true"

      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        properties: @[
          PropertyInfo(name: "left", value: "24px"),
          PropertyInfo(name: "top", value: "12px")])
      check empty.attributes.getOrDefault("data-position-empty-visible") ==
        "false"
      dispose()

  test "X / Y seed values reflect the current selection":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        properties: @[
          PropertyInfo(name: "left", value: "48px"),
          PropertyInfo(name: "top", value: "32px")])
      mountSectionPosition[MockRenderer, MockNode](r, root, vm)

      let xInput = findByAttr(findByAttr(root, "data-property-row", "x"),
        "data-property-row-input", "true")
      check xInput != nil
      check r.inputValue(xInput) == "48"

      let yInput = findByAttr(findByAttr(root, "data-property-row", "y"),
        "data-property-row-input", "true")
      check yInput != nil
      check r.inputValue(yInput) == "32"
      dispose()
