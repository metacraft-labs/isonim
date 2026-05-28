## Phase G — section_selection_colors widget unit test.

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_selection_colors
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_selection_colors":

  test "looksLikeColor accepts hex + rgb / rejects junk":
    check looksLikeColor("#fff")
    check looksLikeColor("#0F172A")
    check looksLikeColor("rgb(10, 20, 30)")
    check looksLikeColor("rgba(0, 0, 0, 0.4)")
    check not looksLikeColor("none")
    check not looksLikeColor("transparent")
    check not looksLikeColor("")
    check not looksLikeColor("auto")

  test "collectSelectionColors de-duplicates and preserves first-seen order":
    let props = @[
      PropertyInfo(name: "background-color", value: "#0F172A"),
      PropertyInfo(name: "color", value: "#FFFFFF"),
      PropertyInfo(name: "border-color", value: "#0F172A"),
      PropertyInfo(name: "outline-color", value: "transparent")]
    let colors = collectSelectionColors(props)
    check colors == @["#0F172A", "#FFFFFF"]

  test "section mount renders list + empty-state":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionSelectionColors[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-selection-colors-body", "true") != nil
      check findByAttr(root, "data-selection-colors-list", "true") != nil
      let empty = findByAttr(root, "data-selection-colors-empty", "true")
      check empty != nil
      check empty.styles.getOrDefault("display") == "block"
      dispose()

  test "selection with colors populates the list":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionSelectionColors[MockRenderer, MockNode](r, root, vm)

      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        properties: @[
          PropertyInfo(name: "background-color", value: "#1A1B22"),
          PropertyInfo(name: "color", value: "#F1F5F9")])
      check findByAttr(root, "data-selection-color-row", "0") != nil
      check findByAttr(root, "data-selection-color-row", "1") != nil
      let empty = findByAttr(root, "data-selection-colors-empty", "true")
      check empty.styles.getOrDefault("display") == "none"
      dispose()
