## Portable Typography structure and CSS weight mapping checks. MockRenderer
## exercises the shared mounted choice wiring on native and strict JavaScript;
## it cannot prove physical browser input, filesystem persistence or compilation.
## The recording source callback is a narrow mapping spy, justified to isolate
## the exact proposed CSS value. The ordinary-properties GUI suite covers real
## authenticated native writes, compiler/catalog publication and browser preview.
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

  test "friendly font weight labels submit valid CSS numeric weights":
    for i, expected in ["100", "300", "400", "500", "600", "700"]:
      createRoot do (dispose: proc()):
        let r = MockRenderer()
        let root = r.createElement("div")
        let vm = createEditorVM()
        vm.inspector.selectedElement.val = ElementRef(id: "text", tag: "p",
          properties: @[PropertyInfo(name: "font-weight", value: "900")])
        vm.workspacePermissions.val = EditorWorkspacePermissions(readSource: true, writeSource: true)
        var submitted = ""
        vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
            scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
          check element.id == "text"
          check property == "font-weight"
          submitted = value
          done(true, "")
        mountSectionTypography[MockRenderer, MockNode](r, root, vm)
        let row = findByAttr(root, "data-property-row", "font-weight")
        let choice = findByAttr(row, "data-choice-group-option", $i)
        require choice != nil
        fireEvent(choice, "click")
        check submitted == expected
        dispose()

  test "unlisted and empty weight values stay honest without edits":
    for value in ["800", "650", "bolder", "var(--weight)", ""]:
      createRoot do (dispose: proc()):
        let r = MockRenderer()
        let root = r.createElement("div")
        let vm = createEditorVM()
        vm.inspector.selectedElement.val = ElementRef(id: "text", tag: "p",
          properties: @[PropertyInfo(name: "font-weight", value: value)])
        let before = vm.inspector.selectedElement.val
        mountSectionTypography[MockRenderer, MockNode](r, root, vm)
        let row = findByAttr(root, "data-property-row", "font-weight")
        check textContent(findByAttr(row, "data-choice-group-trigger-label", "true")) == value
        check vm.inspector.selectedElement.val == before
        check vm.inspector.undoStack.val.len == 0
        check vm.inspector.redoStack.val.len == 0
        dispose()
