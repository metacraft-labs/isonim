## Phase G — section_export widget unit test.
## MockRenderer exposes generic production widget nodes and real signal updates
## for local configuration checks without a browser. Its logical focus records
## renderer reference ownership only; no UA activation or physical focus is
## simulated. Direct keydown proves absence of a wildcard widget listener, not
## native Enter/Space behavior. The registered real compounds GUI verifies actual
## keyboard/pointer defaults, focus, source/compiler/catalog/preview and history.
## No source, export engine or persistence success is mocked or claimed.

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
      # Query the configured row each time. The identity test below
      # also verifies that value changes retain its mounted controls.
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

  test "native button metadata and no wildcard keydown retain local configuration":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionExport[MockRenderer, MockNode](r, root, vm)
      let add = findByAttr(root, "data-export-add", "true")
      check add.tag == "button"
      check add.attributes.getOrDefault("type") == "button"
      check "keydown" notin add.eventListeners
      add.fireEvent("keydown")
      check findByAttr(root, "data-export-row", "0") == nil
      add.fireEvent("click")
      for attr in ["data-export-row-size", "data-export-row-format", "data-export-row-delete"]:
        let control = findByAttr(root, attr, "0")
        check control.tag == "button"
        check control.attributes.getOrDefault("type") == "button"
        check "keydown" notin control.eventListeners
      check vm.inspector.undoStack.val.len == 0
      check vm.inspector.redoStack.val.len == 0
      check vm.inspector.pendingSourceEdits.val.len == 0
      dispose()

  test "value updates preserve row identity and deletion restores only owned focus":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionExport[MockRenderer, MockNode](r, root, vm)
      let add = findByAttr(root, "data-export-add", "true")
      add.fireEvent("click")
      let size = findByAttr(root, "data-export-row-size", "0")
      let format = findByAttr(root, "data-export-row-format", "0")
      let suffix = findByAttr(root, "data-export-row-suffix", "0")
      r.focus(size)
      for expected in ["2x", "3x", "1x"]:
        size.fireEvent("click")
        check findByAttr(root, "data-export-row-size", "0") == size
        check size.textContent == expected
        check r.activeElement() == size
      r.focus(format)
      for expected in ["SVG", "PDF", "PNG"]:
        format.fireEvent("click")
        check findByAttr(root, "data-export-row-format", "0") == format
        check format.textContent == expected
        check r.activeElement() == format
      r.setInputValue(suffix, "-wide")
      suffix.fireEvent("change")
      check findByAttr(root, "data-export-row-suffix", "0") == suffix
      check r.inputValue(suffix) == "-wide"
      add.fireEvent("click")
      let lastDelete = findByAttr(root, "data-export-row-delete", "1")
      r.focus(lastDelete)
      lastDelete.fireEvent("click")
      check r.activeElement() == findByAttr(root, "data-export-row-delete", "0")
      check r.inputValue(findByAttr(root, "data-export-row-suffix", "0")) == "-wide"
      let remainingDelete = findByAttr(root, "data-export-row-delete", "0")
      r.focus(remainingDelete)
      remainingDelete.fireEvent("click")
      check r.activeElement() == add
      add.fireEvent("click")
      let unrelated = r.createElement("input")
      r.appendChild(root, unrelated)
      r.focus(unrelated)
      findByAttr(root, "data-export-row-delete", "0").fireEvent("click")
      check r.activeElement() == unrelated
      check vm.inspector.undoStack.val.len == 0
      check vm.inspector.redoStack.val.len == 0
      dispose()
