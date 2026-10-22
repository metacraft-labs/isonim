## MockRenderer isolates section visibility and renderer-independent controls;
## real source/compiler and physical pointer coverage lives in the inspector
## compound and source-style GUI suites. Controlled completion callbacks test
## submission planning/lifetime and the new shared-impact display only; they
## provide no native persistence or compiler evidence.
## The synchronous-writer case uses real temporary files and the production CSS
## patcher on native and Node JS. Its explicit apply runs the production workspace
## transaction; MockRenderer does not run the browser autosave timer or compiler.
## Phase G — section_layout widget unit test.

import std/[options, tables, unittest, strutils]
when not defined(js):
  import std/[os, tempfiles]
import isonim/editor/css_patch

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

proc ownedDirectory(): string =
  when defined(js):
    var path: cstring
    {.emit: [path, " = require('node:fs').mkdtempSync(require('node:os').tmpdir() + '/layout-sync-');"].}
    result = $path
  else:
    result = createTempDir("layout-sync-", "")

proc actualWrite(path, content: string) =
  when defined(js):
    let p = cstring(path)
    let c = cstring(content)
    {.emit: ["require('node:fs').writeFileSync(", p, ",", c, ",'utf8');"].}
  else: writeFile(path, content)

proc actualRead(path: string): string =
  when defined(js):
    let p = cstring(path)
    var content: cstring
    {.emit: [content, " = require('node:fs').readFileSync(", p, ",'utf8');"].}
    result = $content
  else: result = readFile(path)

proc removeOwnedDirectory(path: string) =
  when defined(js):
    let p = cstring(path)
    {.emit: ["require('node:fs').rmSync(", p, ",{recursive:true});"].}
  else: removeDir(path)

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

  test "configured synchronous layout writer stages and applies real source while guarding readiness and permission":
    let directory = ownedDirectory()
    defer: removeOwnedDirectory(directory)
    let source = directory & "/styles.nim"
    let original = "const styles* = \"\"\"#panel { display:flex; }\"\"\"\n"
    actualWrite(source, original)
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.workspacePermissions.val = EditorWorkspacePermissions(readSource: true, writeSource: true)
      vm.selectedStory.val = StoryRef(group: "Card", name: "ready", kind: skComponent)
      vm.inspector.selectedElement.val = ElementRef(id: "panel", tag: "div", sourceFile: source,
        properties: @[PropertyInfo(name: "display", value: "flex",
          sourceFile: source, schemaKey: "style.display", directStyleAllowed: true)])
      let adapter = WorkspaceEditAdapter(schema: @[WorkspaceEditableSchemaEntry(
        key: "style.display", file: source, kind: wskSourceMap, property: "display")])
      adapter.readFile = proc(file: string): WorkspaceReadResult =
        WorkspaceReadResult(ok: true, content: actualRead(file))
      adapter.writeFile = proc(file, content: string): WorkspaceOperationResult =
        actualWrite(file, content)
        WorkspaceOperationResult(ok: true)
      adapter.patchFile = proc(plan: SourceEditPlan; content: string;
          schema: WorkspaceEditableSchemaEntry): WorkspacePatchResult =
        let patch = patchCssInNimConst(content, "styles", "#panel", plan.property, plan.newValue)
        WorkspacePatchResult(ok: patch.ok, patch: WorkspaceFilePatch(file: schema.file, afterContent: patch.content))
      vm.workspaceEditAdapter = adapter
      # The property's own shared-class owner (keyed by its schema key, so
      # both selected elements below have it). A shared-class `display` is a
      # family with no shared writer yet (`sharedDesignCategory`), so the
      # visible default scope refuses a mode until the user picks the local
      # instance. (Keyed `unrelated.display` before 2026-10-22, when any node
      # of the property was offered to every element; scope choices now come
      # from the element's own ownership.)
      vm.designSystemSchema.val = DesignSystemSchema(nodes: @[DesignSchemaNode(
        key: "style.display", kind: dsnClassDefinition, property: "display",
        sourceSpan: SourceSpan(file: source, line: 1))])
      mountSectionLayout[MockRenderer, MockNode](r, root, vm)
      let none = findByAttr(root, "data-layout-mode", "none")
      check none.attributes.getOrDefault("aria-disabled") == "true"
      fireEvent(none, "click")
      check vm.inspector.pendingSourceEdits.val.len == 0
      check actualRead(source) == original
      vm.sourceAdapterReady.val = true
      check none.attributes.getOrDefault("aria-disabled") == "false"
      let beforeUndo = vm.inspector.undoStack.val.len
      fireEvent(none, "click")
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == beforeUndo
      check actualRead(source) == original
      check "read-only" in textContent(findByAttr(root, "data-layout-mode-message", "true"))
      let displayScopes = findByAttr(root, "data-layout-source-scope-property", "display")
      let local = findByAttr(displayScopes, "data-source-scope-kind", "sskLocalInstance")
      require local != nil
      fireEvent(local, "click")
      check findByAttr(displayScopes, "data-source-scope-kind", "sskLocalInstance").attributes.getOrDefault("aria-pressed") == "true"
      fireEvent(none, "click")
      require vm.inspector.pendingSourceEdits.val.len == 1
      check vm.inspector.pendingSourceEdits.val[0].property == "display"
      check vm.inspector.pendingSourceEdits.val[0].newValue == "block"
      check vm.inspector.undoStack.val.len == beforeUndo + 1
      check actualRead(source) == original
      check vm.applyWorkspaceFileEdits().ok
      check none.attributes.getOrDefault("data-layout-mode-active") == "true"
      let saved = actualRead(source)
      check "display:block" in saved.replace(" ", "")
      check vm.inspector.pendingSourceEdits.val.len == 0
      let savedUndo = vm.inspector.undoStack.val.len
      fireEvent(none, "click")
      check actualRead(source) == saved
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == savedUndo
      check none.attributes.getOrDefault("data-layout-mode-active") == "true"
      let retiredLocal = findByAttr(displayScopes, "data-source-scope-kind", "sskLocalInstance")
      check retiredLocal.attributes.getOrDefault("aria-pressed") == "true"
      vm.inspector.selectedElement.val = ElementRef(id: "other", tag: "div", sourceFile: source,
        properties: @[PropertyInfo(name: "display", value: "block", sourceFile: source,
          schemaKey: "style.display", directStyleAllowed: true)])
      fireEvent(retiredLocal, "click")
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == savedUndo
      check actualRead(source) == saved
      let grid = findByAttr(root, "data-layout-mode", "grid")
      fireEvent(grid, "click")
      check vm.inspector.pendingSourceEdits.val.len == 0
      check actualRead(source) == saved
      check "read-only" in textContent(findByAttr(root, "data-layout-mode-message", "true"))
      let freshLocal = findByAttr(findByAttr(root, "data-layout-source-scope-property", "display"),
        "data-source-scope-kind", "sskLocalInstance")
      check freshLocal != retiredLocal
      fireEvent(freshLocal, "click")
      vm.selectedStory.val = StoryRef(group: "Card", name: "other", kind: skComponent)
      fireEvent(grid, "click")
      check vm.inspector.pendingSourceEdits.val.len == 0
      check actualRead(source) == saved
      check "read-only" in textContent(findByAttr(root, "data-layout-mode-message", "true"))
      vm.workspacePermissions.val = EditorWorkspacePermissions(readSource: true)
      check grid.attributes.getOrDefault("aria-disabled") == "true"
      fireEvent(grid, "click")
      check actualRead(source) == saved
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == savedUndo
      dispose()
      fireEvent(none, "click")
      check actualRead(source) == saved

  test "selected layout scope visibly exposes its actual impact before shared admission and resets with identity":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.hasAsyncSourceProject = true
      vm.sourceAdapterReady.val = true
      vm.workspacePermissions.val = EditorWorkspacePermissions(readSource: true, writeSource: true)
      vm.selectedStory.val = StoryRef(group: "Card", name: "first", kind: skComponent)
      # The panel's display is mapped to the shared class by an ownership
      # entry for this element; scope choices come from the element's own
      # ownership, so the other elements selected below have no such owner.
      vm.designSystemSchema.val = DesignSystemSchema(ownerPackage: "Ui kit", nodes: @[
        DesignSchemaNode(key: "classes.panel", name: "Panel layout", kind: dsnClassDefinition,
          property: "display", usageCount: 3, sourceSpan: SourceSpan(file: "shared-styles.nim", line: 12))],
        sourceOwnership: @[DesignSourceOwnership(elementSourceKey: "panel",
          property: "display", nodeKey: "classes.panel")])
      vm.inspector.selectedElement.val = ElementRef(id: "panel", tag: "div", properties: @[
        PropertyInfo(name: "display", value: "block", authoredValue: "block", schemaKey: "local.panel",
          sourceFile: "component.nim", sourceLine: 4, directStyleAllowed: true)])
      var requests: seq[SourceScopeChoiceKind]
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
        check element.id == "panel"
        check property == "display"
        check value == "grid"
        requests.add scope
        done(true, "")
      mountSectionLayout[MockRenderer, MockNode](r, root, vm)
      let impact = findByAttr(root, "data-layout-source-impact-property", "display")
      require impact != nil
      check "display · Shared class" in textContent(impact)
      check "Owner: Ui kit:" in textContent(impact)
      check "Panel layout" in textContent(impact)
      check "Source: shared-styles.nim:12" in textContent(impact)
      check "Known uses: 3" in textContent(impact)
      check "Changes the shared source definition; other mapped uses may change." in textContent(impact)
      check requests.len == 0
      let scopes = findByAttr(root, "data-layout-source-scope-property", "display")
      fireEvent(findByAttr(scopes, "data-source-scope-kind", "sskLocalInstance"), "click")
      check "display · Local instance" in textContent(impact)
      check "Owner: Selected instance" in textContent(impact)
      check "Source: component.nim:4" in textContent(impact)
      check "Known uses: 1" in textContent(impact)
      check "Changes the shared source definition" notin textContent(impact)
      fireEvent(findByAttr(scopes, "data-source-scope-kind", "sskSharedClass"), "click")
      check "Known uses: 3" in textContent(impact)
      check "Changes the shared source definition" in textContent(impact)
      fireEvent(findByAttr(root, "data-layout-mode", "grid"), "click")
      check requests == @[sskSharedClass]
      let retiredText = textContent(impact)
      vm.inspector.selectedElement.val = ElementRef(id: "other", tag: "div", properties: @[
        PropertyInfo(name: "display", value: "block", authoredValue: "block", directStyleAllowed: true)])
      let currentImpact = findByAttr(root, "data-layout-source-impact-property", "display")
      check currentImpact != impact
      check "Local instance" in textContent(currentImpact)
      check "Source: not mapped" in textContent(currentImpact)
      check "Ui kit" notin textContent(currentImpact)
      check "Known uses: 1" in textContent(currentImpact)
      check textContent(impact) == retiredText
      # Removing the schema on the new identity exposes genuinely unknown source
      # information rather than carrying the prior selected owner's metadata.
      vm.designSystemSchema.val = DesignSystemSchema()
      vm.inspector.selectedElement.val = ElementRef(id: "schema-only", tag: "div", properties: @[
        PropertyInfo(name: "display", value: "block", authoredValue: "block", directStyleAllowed: true,
          schemaKey: "classes.schema-only", sharedCount: 0)])
      let schemaImpact = findByAttr(root, "data-layout-source-impact-property", "display")
      check "Schema: classes.schema-only" in textContent(schemaImpact)
      check "Known uses: unknown" in textContent(schemaImpact)
      check "Changes the shared source definition" in textContent(schemaImpact)
      vm.selectedStory.val = StoryRef(group: "Card", name: "second", kind: skComponent)
      check "shared-styles.nim" notin textContent(findByAttr(root, "data-layout-source-impact-property", "display"))
      vm.inspector.selectedElement.val = ElementRef(id: "fixture", tag: "div", properties: @[
        PropertyInfo(name: "display", value: "block", authoredValue: "block", directStyleAllowed: true,
          schemaKey: "fixtures.panel.display", sourceFile: "story-fixture.schema", sourceLine: 6, sharedCount: 1)])
      let fixtureImpact = findByAttr(root, "data-layout-source-impact-property", "display")
      check "Story fixture" in textContent(fixtureImpact)
      check "Source: story-fixture.schema:6" in textContent(fixtureImpact)
      check "Changes this story fixture." in textContent(fixtureImpact)
      check "Changes the shared source definition" notin textContent(fixtureImpact)
      check requests == @[sskSharedClass]
      dispose()
      let after = textContent(currentImpact)
      vm.inspector.selectedElement.val = ElementRef(id: "late", tag: "div")
      check textContent(currentImpact) == after
