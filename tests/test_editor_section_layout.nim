## MockRenderer isolates section visibility and renderer-independent controls;
## real source/compiler and physical pointer coverage lives in the inspector
## compound and source-style GUI suites. Controlled completion callbacks test
## submission planning/lifetime only; they provide no native persistence evidence.
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
      var permissions = vm.workspacePermissions.val
      permissions.writeSource = true
      vm.workspacePermissions.val = permissions
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

  test "ordinary flow retains padding controls while gap requires flex or grid":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      var permissions = vm.workspacePermissions.val
      permissions.writeSource = true
      vm.workspacePermissions.val = permissions
      mountSectionLayout[MockRenderer, MockNode](r, root, vm)

      let gapHost = findByAttr(root, "data-layout-gap-host", "true")
      check gapHost != nil
      check gapHost.styles.getOrDefault("display") == "none"
      let paddingHost = findByAttr(root, "data-layout-padding-host", "true")
      check paddingHost != nil
      check paddingHost.styles.getOrDefault("display") == "flex"
      for property in ["padding-top", "padding-right", "padding-bottom", "padding-left"]:
        check findByAttr(paddingHost, "data-property-row-css-property", property) != nil

      let flexBtn = findByAttr(root, "data-layout-mode", "vertical")
      fireEvent(flexBtn, "click")
      check gapHost.styles.getOrDefault("display") == "flex"
      fireEvent(findByAttr(root, "data-layout-mode", "none"), "click")
      check gapHost.styles.getOrDefault("display") == "none"
      check paddingHost.styles.getOrDefault("display") == "flex"
      dispose()

  test "native compound layout refusal preserves source mode and retired controls are inert":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      var permissions = vm.workspacePermissions.val
      permissions.writeSource = true
      vm.workspacePermissions.val = permissions
      vm.hasAsyncSourceProject = true
      vm.sourceAdapterReady.val = true
      vm.inspector.selectedElement.val = ElementRef(id: "panel", properties: @[
        PropertyInfo(name: "display", value: "block", authoredValue: "block"),
        PropertyInfo(name: "flex-direction", value: "row")])
      mountSectionLayout[MockRenderer, MockNode](r, root, vm)
      let vertical = findByAttr(root, "data-layout-mode", "vertical")
      fireEvent(vertical, "click")
      check findByAttr(root, "data-layout-mode", "none").attributes.getOrDefault("data-layout-mode-active") == "true"
      let message = findByAttr(root, "data-layout-mode-message", "true")
      check textContent(message) == "The editor cannot safely change both layout declarations together yet."
      for key in ["Tab", "Escape"]:
        fireEventWith(vertical, "keydown", MockEvent(`type`: "keydown", key: key))
        check findByAttr(root, "data-layout-mode", "none").attributes.getOrDefault("data-layout-mode-active") == "true"
      dispose()
      let before = textContent(message)
      fireEvent(vertical, "click")
      check textContent(message) == before

  test "a supported single display declaration uses one shared native boundary":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.hasAsyncSourceProject = true
      vm.sourceAdapterReady.val = true
      var permissions = vm.workspacePermissions.val
      permissions.writeSource = true
      vm.workspacePermissions.val = permissions
      vm.inspector.selectedElement.val = ElementRef(id: "panel", properties: @[
        PropertyInfo(name: "display", value: "block", authoredValue: "block", directStyleAllowed: true)])
      var requests: seq[string]
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
        requests.add property & "=" & value
        done(true, "")
      mountSectionLayout[MockRenderer, MockNode](r, root, vm)
      let grid = findByAttr(root, "data-layout-mode", "grid")
      fireEvent(grid, "click")
      check requests == @["display=grid"]
      check grid.attributes.getOrDefault("data-layout-mode-active") == "true"
      dispose()
      fireEvent(grid, "click")
      check requests == @["display=grid"]

  test "four padding sides retain different authored units and values":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.inspector.selectedElement.val = ElementRef(id: "panel", properties: @[
        PropertyInfo(name: "padding-top", value: "32px", authoredValue: "2em"),
        PropertyInfo(name: "padding-right", value: "8px", authoredValue: "8px"),
        PropertyInfo(name: "padding-bottom", value: "10px", authoredValue: "10%"),
        PropertyInfo(name: "padding-left", value: "16px", authoredValue: "1rem")])
      mountSectionLayout[MockRenderer, MockNode](r, root, vm)
      for (name, value, unit) in [("pad-top", "2", "em"), ("pad-right", "8", "px"), ("pad-bottom", "10", "%"), ("pad-left", "1", "rem")]:
        let row = findByAttr(root, "data-property-row", name)
        check r.inputValue(findByAttr(row, "data-property-row-input", "true")) == value
        check textContent(findByAttr(row, "data-property-row-unit", "true")) == unit
      dispose()

  test "inline and reverse layout preserve their existing display and direction semantics":
    check layoutModeFor("inline-flex", "column-reverse") == "vertical"
    check layoutModeFor("inline-flex", "row-reverse") == "horizontal"
    check layoutModeFor("inline-grid", "row") == "grid"
    check layoutModeChanges("inline-flex", "column-reverse", "horizontal") == @[("flex-direction", "row-reverse")]
    check layoutModeChanges("inline-flex", "row-reverse", "vertical") == @[("flex-direction", "column-reverse")]
    check layoutModeChanges("inline-flex", "column-reverse", "vertical").len == 0
    check layoutModeChanges("inline-grid", "row", "horizontal") == @[("display", "inline-flex")]
    check layoutModeChanges("inline-block", "row", "none").len == 0
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.inspector.selectedElement.val = ElementRef(id: "panel", properties: @[
        PropertyInfo(name: "display", value: "flex", authoredValue: "inline-flex"),
        PropertyInfo(name: "flex-direction", value: "row", authoredValue: "column-reverse")])
      mountSectionLayout[MockRenderer, MockNode](r, root, vm)
      check findByAttr(root, "data-layout-mode", "vertical").attributes.getOrDefault("data-layout-mode-active") == "true"
      dispose()

  test "readonly layout pills explain refusal in both source and preview compositions":
    for native in [false, true]:
      createRoot do (dispose: proc()):
        let r = MockRenderer()
        let root = r.createElement("div")
        let vm = createEditorVM()
        vm.hasAsyncSourceProject = native
        vm.sourceAdapterReady.val = true
        vm.inspector.selectedElement.val = ElementRef(id: "panel", properties: @[
          PropertyInfo(name: "display", value: "block", authoredValue: "block", directStyleAllowed: true)])
        mountSectionLayout[MockRenderer, MockNode](r, root, vm)
        let grid = findByAttr(root, "data-layout-mode", "grid")
        check grid.attributes.getOrDefault("aria-disabled") == "true"
        fireEvent(grid, "click")
        check findByAttr(root, "data-layout-mode", "none").attributes.getOrDefault("data-layout-mode-active") == "true"
        check textContent(findByAttr(root, "data-layout-mode-message", "true")) == "This workspace is read-only for source changes."
        dispose()
