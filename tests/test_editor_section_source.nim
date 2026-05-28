## Phase G — section_source widget unit test.

import std/[options, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_source
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil: return hit
  return nil

suite "Phase G section_source":

  test "mounts file / scope / staged / ownership rows":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionSource[MockRenderer, MockNode](r, root, vm)

      check findByAttr(root, "data-source-section-body", "true") != nil
      check findByAttr(root, "data-source-file-line", "true") != nil
      check findByAttr(root, "data-source-scope", "true") != nil
      check findByAttr(root, "data-source-staged-count", "true") != nil
      check findByAttr(root, "data-source-ownership", "true") != nil
      dispose()

  test "file:line reflects the selected element":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionSource[MockRenderer, MockNode](r, root, vm)

      vm.inspector.selectedElement.val = ElementRef(tag: "div",
        sourceFile: "src/views/home.nim", sourceLine: 42)
      let fl = findByAttr(root, "data-source-file-line", "true")
      check fl != nil
      check fl.textContent == "src/views/home.nim:42"

      let scope = findByAttr(root, "data-source-scope", "true")
      check scope != nil
      check scope.textContent == "Local"
      dispose()

  test "ownership warning surfaces when conflicts exist":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      mountSectionSource[MockRenderer, MockNode](r, root, vm)

      let ownership = findByAttr(root, "data-source-ownership", "true")
      check ownership != nil
      check ownership.textContent == "No conflicts"
      check ownership.attributes.getOrDefault(
        "data-source-ownership-warning") == "false"

      vm.inspector.conflicts.val = @[CSSSourceConflict(),
        CSSSourceConflict()]
      check ownership.textContent == "2 conflict(s)"
      check ownership.attributes.getOrDefault(
        "data-source-ownership-warning") == "true"
      dispose()
