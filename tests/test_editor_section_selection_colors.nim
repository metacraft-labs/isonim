## Selection Colors model/render tests. MockRenderer observes generated nodes,
## row ownership, cleanup and click dispatch without a browser. Picker callbacks
## are admission spies only; they do not simulate persistence or source success.
## Actual keyboard defaults, compiler/source and preview are covered by the
## existing compounds GUI; binding sidecar persistence has its real file e2e.

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

  test "shared color parser validates alpha forms and rejects malformed colors":
    check looksLikeColor("#1234")
    check looksLikeColor("#12345680")
    check looksLikeColor("hsl(210 50% 40% / 25%)")
    check not looksLikeColor("#ggg")
    check not looksLikeColor("rgba(1, 2, NaN, 0.5)")
    check collectSelectionColors(@[
      PropertyInfo(name: "color", value: "#ffffff"),
      PropertyInfo(name: "background-color", value: "rgb(255, 255, 255)")]) == @["#ffffff"]

  test "actual alpha and unique source owner bind while ambiguity and readonly refuse":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.workspacePermissions.val = EditorWorkspacePermissions(readSource: true, writeSource: true)
      var admitted: seq[string]
      vm.inspector.requestVariablePicker = proc(key: PropertyBindingKey; x,y,w,h: float) =
        admitted.add key.elementId & ":" & key.propertyName
      mountSectionSelectionColors[MockRenderer, MockNode](r, root, vm)
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "alpha",
        properties: @[PropertyInfo(name: "background-color", value: "#12345680",
          directStyleAllowed: true)])
      check findByAttr(root, "data-selection-color-hex", "0").textContent == "#123456"
      check findByAttr(root, "data-selection-color-opacity", "0").textContent == "50%"
      let oldBind = findByAttr(root, "data-selection-color-bind", "0")
      fireEvent(oldBind, "click")
      check admitted == @["alpha:background-color"]
      vm.foundations.tokens.val = @[FoundationTokenEntry(key: "color/alpha",
        kind: ftkSemanticColor, value: "#12345680")]
      vm.bindPropertyToVariable(PropertyBindingKey(elementId: "alpha",
        propertyName: "background-color"), "color/alpha")
      vm.workspacePermissions.val = EditorWorkspacePermissions(readSource: true, writeSource: false)
      let readonlyChip = findByAttr(root, "data-selection-color-linked-chip", "true")
      check readonlyChip != nil
      for attr in ["data-variable-chip-name", "data-variable-chip-chevron", "data-variable-chip-detach"]:
        let child = findByAttr(readonlyChip, attr, "true")
        check child.attributes["aria-disabled"] == "true"
        check child.attributes["tabindex"] == "-1"
        check child.attributes["title"].len > 0
        check child.styles["cursor"] == "default"
        fireEvent(child, "click")
      check vm.inspectorBindingFor("background-color").get.variableKey == "color/alpha"
      check vm.inspector.pendingSourceEdits.val.len == 0
      check admitted.len == 1
      vm.workspacePermissions.val = EditorWorkspacePermissions(readSource: true, writeSource: true)
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "mixed",
        properties: @[
          PropertyInfo(name: "background-color", value: "#12345680", directStyleAllowed: true),
          PropertyInfo(name: "color", value: "rgba(18,52,86,0.5)", directStyleAllowed: true)])
      let ambiguous = findByAttr(root, "data-selection-color-bind", "0")
      check ambiguous.attributes.getOrDefault("aria-disabled") == "true"
      check findByAttr(root, "data-selection-color-reason", "0").textContent.len > 0
      fireEvent(ambiguous, "click")
      fireEvent(oldBind, "click")
      check admitted.len == 1
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "unmapped",
        properties: @[PropertyInfo(name: "color", value: "#123456")])
      let readonly = findByAttr(root, "data-selection-color-bind", "0")
      check readonly.attributes.getOrDefault("aria-disabled") == "true"
      fireEvent(readonly, "click")
      check admitted.len == 1
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == 0
      check vm.inspector.redoStack.val.len == 0
      dispose()
      fireEvent(oldBind, "click")
      check admitted.len == 1
