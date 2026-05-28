## Phase G — section_layout widget unit test.

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_layout
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_layout":

  test "mounts W / H + overflow rows + mode + constraint":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionLayout[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-property-row", "w") != nil
      check findByAttr(root, "data-property-row", "h") != nil
      check findByAttr(root, "data-property-row", "overflow") != nil
      check findByAttr(root, "data-layout-mode-row", "true") != nil
      check findByAttr(root, "data-layout-constraint", "true") != nil
      for slug in ["none", "vertical", "horizontal", "grid"]:
        check findByAttr(root, "data-layout-mode", slug) != nil
      dispose()

  test "layout mode button click flips the active slug":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionLayout[MockRenderer, MockNode](r, root, vm)

      let flexBtn = findByAttr(root, "data-layout-mode", "horizontal")
      check flexBtn != nil
      fireEvent(flexBtn, "click")
      check flexBtn.attributes.getOrDefault("data-layout-mode-active") ==
        "true"
      let noneBtn = findByAttr(root, "data-layout-mode", "none")
      check noneBtn.attributes.getOrDefault("data-layout-mode-active") ==
        "false"
      dispose()

  test "gap host hides when layout is none":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionLayout[MockRenderer, MockNode](r, root, vm)

      let gapHost = findByAttr(root, "data-layout-gap-host", "true")
      check gapHost != nil
      check gapHost.styles.getOrDefault("display") == "none"

      let flexBtn = findByAttr(root, "data-layout-mode", "vertical")
      fireEvent(flexBtn, "click")
      check gapHost.styles.getOrDefault("display") == "flex"
      dispose()
