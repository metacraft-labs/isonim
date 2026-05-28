## Phase G — section_typography widget unit test.

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_typography
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_typography":

  test "mounts every typography control row":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionTypography[MockRenderer, MockNode](r, root, vm)

      for slug in ["font-family", "font-weight", "font-size",
                   "line-height", "letter-spacing", "paragraph-spacing",
                   "text-alignment", "decoration", "text-transform",
                   "list-style"]:
        check findByAttr(root, "data-property-row", slug) != nil
      dispose()

  test "non-text selection surfaces the empty-state placeholder":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionTypography[MockRenderer, MockNode](r, root, vm)

      let empty = findByAttr(root, "data-typography-empty", "true")
      check empty != nil
      check empty.styles.getOrDefault("display") == "none"

      vm.inspector.selectedElement.val = ElementRef(tag: "div")
      check empty.styles.getOrDefault("display") == "block"

      vm.inspector.selectedElement.val = ElementRef(tag: "p")
      check empty.styles.getOrDefault("display") == "none"
      dispose()

  test "isTextLikeTag classifies common text tags":
    check isTextLikeTag("p")
    check isTextLikeTag("h1")
    check isTextLikeTag("span")
    check isTextLikeTag("label")
    check not isTextLikeTag("div")
    check not isTextLikeTag("button")
    check not isTextLikeTag("img")
