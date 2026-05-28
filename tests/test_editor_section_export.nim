## Phase G — section_export widget unit test.

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_export
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_export":

  test "mounts list + empty-state + add button":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionExport[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-export-section-body", "true") != nil
      check findByAttr(root, "data-export-list", "true") != nil
      let empty = findByAttr(root, "data-export-empty", "true")
      check empty != nil
      check empty.styles.getOrDefault("display") == "block"
      check findByAttr(root, "data-export-add", "true") != nil
      dispose()

  test "+ Add export creates a row with size + format + suffix":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionExport[MockRenderer, MockNode](r, root, vm)

      let addBtn = findByAttr(root, "data-export-add", "true")
      fireEvent(addBtn, "click")
      check findByAttr(root, "data-export-row", "0") != nil
      check findByAttr(root, "data-export-row-size", "0") != nil
      check findByAttr(root, "data-export-row-format", "0") != nil
      check findByAttr(root, "data-export-row-suffix", "0") != nil
      check findByAttr(root, "data-export-row-delete", "0") != nil
      dispose()

  test "size and format cycle through their enums":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionExport[MockRenderer, MockNode](r, root, vm)

      let addBtn = findByAttr(root, "data-export-add", "true")
      fireEvent(addBtn, "click")
      # Re-query each iteration — the row tree rebuilds on signal
      # write so the prior ``sizeBtn`` reference is detached after a
      # click. The data-attribute query is stable across rebuilds.
      var sizeBtn = findByAttr(root, "data-export-row-size", "0")
      check sizeBtn.textContent == "1x"
      fireEvent(sizeBtn, "click")
      sizeBtn = findByAttr(root, "data-export-row-size", "0")
      check sizeBtn.textContent == "2x"

      var formatBtn = findByAttr(root, "data-export-row-format", "0")
      check formatBtn.textContent == "PNG"
      fireEvent(formatBtn, "click")
      formatBtn = findByAttr(root, "data-export-row-format", "0")
      check formatBtn.textContent == "SVG"
      dispose()
