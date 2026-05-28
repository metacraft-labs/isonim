## Phase G — section_stroke widget unit test.

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_stroke
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_stroke":

  test "mounts color + width + style + position rows":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionStroke[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-property-row", "color") != nil
      check findByAttr(root, "data-property-row", "width") != nil
      check findByAttr(root, "data-property-row", "style") != nil
      check findByAttr(root, "data-property-row", "position") != nil
      check findByAttr(root, "data-stroke-dash-host", "true") != nil
      dispose()

  test "dash host hides when style is solid":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionStroke[MockRenderer, MockNode](r, root, vm)

      let host = findByAttr(root, "data-stroke-dash-host", "true")
      check host != nil
      check host.styles.getOrDefault("display") == "none"
      dispose()
