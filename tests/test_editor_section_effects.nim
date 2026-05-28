## Phase G — section_effects widget unit test.

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_effects
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_effects":

  test "mounts list + empty-state + add button":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionEffects[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-effects-section-body", "true") != nil
      check findByAttr(root, "data-effects-list", "true") != nil
      let empty = findByAttr(root, "data-effects-empty", "true")
      check empty != nil
      check empty.styles.getOrDefault("display") == "block"
      check findByAttr(root, "data-effects-add", "true") != nil
      dispose()

  test "+ Add effect appends an entry and hides the empty-state":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionEffects[MockRenderer, MockNode](r, root, vm)

      let addBtn = findByAttr(root, "data-effects-add", "true")
      fireEvent(addBtn, "click")
      check findByAttr(root, "data-effects-row", "0") != nil
      let empty = findByAttr(root, "data-effects-empty", "true")
      check empty.styles.getOrDefault("display") == "none"
      dispose()

  test "delete button removes the entry":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionEffects[MockRenderer, MockNode](r, root, vm)

      let addBtn = findByAttr(root, "data-effects-add", "true")
      fireEvent(addBtn, "click")
      let del = findByAttr(root, "data-effects-row-delete", "0")
      check del != nil
      fireEvent(del, "click")
      check findByAttr(root, "data-effects-row", "0") == nil
      dispose()
