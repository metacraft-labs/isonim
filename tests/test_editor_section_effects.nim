## MockRenderer checks portable metadata inspection and inert unsupported edit
## controls. It does not simulate source persistence; real pointer/keyboard,
## source/catalog/compiler/preview/history checks live in the compound GUI suite.
## The source callback is an admission-only spy required to receive zero calls;
## it does not simulate a successful write. Historical case names are retained:
## their old local-list success expectations violated the guarded edit contract.
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
      check findByAttr(root, "data-effects-row", "0") == nil
      let empty = findByAttr(root, "data-effects-empty", "true")
      check empty.styles.getOrDefault("display") == "block"
      check addBtn.attributes.getOrDefault("aria-disabled") == "true"
      check vm.inspector.undoStack.val.len == 0
      check vm.inspector.redoStack.val.len == 0
      dispose()

  test "delete button removes the entry":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.inspector.selectedElement.val = ElementRef(id: "shadowed", properties: @[
        PropertyInfo(name: "box-shadow", value: "rgb(18, 52, 86) 1px 2px 3px 0px",
          authoredValue: "1px 2px 3px #123456")])
      let original = vm.inspector.selectedElement.val
      var submissions = 0
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
        inc submissions
        done(true, "")
      mountSectionEffects[MockRenderer, MockNode](r, root, vm)

      let addBtn = findByAttr(root, "data-effects-add", "true")
      let current = findByAttr(root, "data-effects-row", "0")
      require current != nil
      check textContent(current) == effectKindGlyph(eekDropShadow) & "box-shadow: 1px 2px 3px #123456"
      check findByAttr(root, "data-effects-empty", "true").styles.getOrDefault("display") == "none"
      fireEvent(addBtn, "click")
      let del = findByAttr(root, "data-effects-row-delete", "0")
      check del == nil
      check findByAttr(root, "data-effects-row", "0") == current
      check vm.inspector.selectedElement.val == original
      check submissions == 0
      check vm.inspector.undoStack.val.len == 0
      check vm.inspector.redoStack.val.len == 0
      vm.inspector.selectedElement.val = ElementRef(id: "filtered", properties: @[
        PropertyInfo(name: "filter", value: "blur(2px)")])
      check textContent(findByAttr(root, "data-effects-row", "0")) == effectKindGlyph(eekFilter) & "filter: blur(2px)"
      vm.inspector.selectedElement.val = ElementRef(id: "plain", properties: @[
        PropertyInfo(name: "box-shadow", value: "none")])
      check findByAttr(root, "data-effects-row", "0") == nil
      check findByAttr(root, "data-effects-empty", "true").styles.getOrDefault("display") == "block"
      dispose()

  test "unsupported effect input cannot invent rows or change selection and history":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      let original = vm.inspector.selectedElement.val
      mountSectionEffects[MockRenderer, MockNode](r, root, vm)
      let addBtn = findByAttr(root, "data-effects-add", "true")
      for event in ["click", "keydown"]:
        fireEvent(addBtn, event)
        check findByAttr(root, "data-effects-row", "0") == nil
      check addBtn.attributes.getOrDefault("aria-disabled") == "true"
      let message = findByAttr(root, "data-effects-readonly-message", "true")
      require message != nil
      check textContent(message).len > 0
      check vm.inspector.selectedElement.val == original
      check vm.inspector.undoStack.val.len == 0
      check vm.inspector.redoStack.val.len == 0
      dispose()
