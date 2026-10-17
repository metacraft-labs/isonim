## Reset to default: an empty commit removes the declaration that owns the
## property, through the editor example's real source writer.
##
## isonim-pm issue 2026-10-14-property-copy-paste-is-unreachable-row-more-
## menu-is-inert-and-right-click-offers-no-copy (Progress: Reset remains).
## Editor spec "Universal Patterns": "Reset to default -- right-click ->
## Reset; reverts to the token/class/inherited value"; "Saving": a refusal
## the editor can know at the act is made at the act.
##
## Also the inspector-controls review notes queued with this group: Cmd/Ctrl+F
## (browser-only, covered by the consumer GUI case), right-click inside a
## row's text field keeps the browser's own menu, a deliberate Alpha of 0% is
## kept, and an asynchronously committed Enter moves the picker's Cancel
## point.
##
## The writer suites use no mocks: the editor example's production adapter
## (`demo_workspace.demoVectorEditAdapter`) writes the example's real
## foundation source held in memory, exactly as `main.nim` mounts it, and a
## real EditorVM plans, journals, writes and undoes through it.
##
## Mock justification (view suites only): MockRenderer stands in for the
## browser DOM so the production property row, property actions menu, Fill
## section and colour popup run natively and under strict Node JS with real
## signals and owners. Events are dispatched to the listeners the views
## registered. The Reset row is wired to the real EditorVM and the example's
## real writer through `inspectorRowWiring`, so its Reset is validated,
## journaled, written and undone for real. The picker tests that need an
## asynchronous source confirmation use the Fill section's
## `inspectorSourceCommit` boundary as a recording callback completed by the
## test; it stands for the native source bridge, which these views call and do
## not own, and no file write is claimed by those cases. The property-row
## colour cases likewise give the row an `onAsyncCommitValue` recording
## callback that confirms at once (as every non-native project's wiring does)
## or later (as the native bridge does); they test the picker's reporting and
## Cancel point, not a write. The Fill Delete cases use the example's real
## writer with one more source-map entry (a card rule's background colour). The browser, the
## write bridge and the consumer writer are exercised by the consumer GUI case
## metacraft_property_reset_removes_the_declaration_and_undo_restores_it.

import std/[options, strutils, tables, unittest]

import isonim/core/[computation, owner, signals]
import isonim/testing/mock_dom
import isonim/editor
import isonim/editor/demo_workspace
import isonim/editor/views/widgets/color_popover
import isonim/editor/views/widgets/property_actions
import isonim/editor/views/widgets/property_commit
import isonim/editor/views/widgets/property_row
import isonim/editor/views/widgets/section_fill

const DestinationRule = ".destination-card { padding: 18px; }\n"

proc demoVm(foundation: ref string): EditorVM =
  let vector = new(string)
  vector[] = "<svg/>"
  result = createEditorVM(newEditorWorkspace(
    title = "Wanderlust reset fixture",
    storyGroups = @[StoryGroup(name: "DestinationCard", kind: skComponent,
      expanded: true, items: @[StoryItem(name: "Default", kind: skComponent,
        group: "DestinationCard")])],
    initialStory = some(StoryRef(group: "DestinationCard", name: "Default",
      kind: skComponent, index: 0)),
    foundationTokens = demoFoundationTokens(),
    designSystemSchema = demoDesignSystemSchema(),
    permissions = EditorWorkspacePermissions(readSource: true,
      writeSource: true),
    editAdapter = demoVectorEditAdapter(vector, foundation)))
  check result.selectInspectorElement(demoInspectorElement())

proc paddingEntry(adapter: WorkspaceEditAdapter): WorkspaceEditableSchemaEntry =
  for entry in adapter.schema:
    if entry.key == "classes.destination-card.padding": return entry

proc removalPlan(expected = "18px"): SourceEditPlan =
  SourceEditPlan(file: DemoFoundationSource, line: 9, property: "padding",
    oldValue: expected, newValue: "", planKind: cspPropertyRemoval,
    schemaKey: "classes.destination-card.padding",
    expectedOldValue: expected, sourceScope: sskSharedClass,
    scope: pesShared)

suite "editor example writer: removal":
  test "a removal plan removes exactly the declaration that owns the property":
    let foundation = new(string)
    foundation[] = DemoFoundationInitialSource
    let adapter = demoVectorEditAdapter(new(string), foundation)
    let patched = adapter.patchFile(removalPlan(), foundation[],
      adapter.paddingEntry)
    check patched.ok
    check patched.patch.afterContent ==
      DemoFoundationInitialSource.replace(DestinationRule,
        ".destination-card { }\n")
    check "padding: ;" notin patched.patch.afterContent

  test "an ambiguous, absent or changed declaration is refused unchanged":
    let foundation = new(string)
    foundation[] = DemoFoundationInitialSource
    let adapter = demoVectorEditAdapter(new(string), foundation)
    let entry = adapter.paddingEntry
    let twice = DemoFoundationInitialSource & ".hero { padding: 18px; }\n"
    let ambiguous = adapter.patchFile(removalPlan(), twice, entry)
    check not ambiguous.ok
    check ambiguous.diagnostics.len == 1 and
      ambiguous.diagnostics[0].message.contains("2 padding declarations")
    check ambiguous.patch.afterContent.len == 0
    let none = DemoFoundationInitialSource.replace(DestinationRule,
      ".destination-card { }\n")
    let absent = adapter.patchFile(removalPlan(), none, entry)
    check not absent.ok
    check absent.diagnostics.len == 1 and
      absent.diagnostics[0].message.contains("no padding declaration")
    let changed = adapter.patchFile(removalPlan("24px"),
      DemoFoundationInitialSource, entry)
    check not changed.ok
    check changed.diagnostics.len == 1 and
      changed.diagnostics[0].kind == wedSourceConflict

  test "an empty commit at the shared class scope is written as a removal and undone exactly":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      let edit = vm.editSharedDesignProperty("padding", "", sskSharedClass)
      check edit.status == pesAccepted
      check edit.sourceEdit.planKind == cspPropertyRemoval
      let saved = vm.applyWorkspaceFileEdits()
      check saved.ok
      check foundation[] == DemoFoundationInitialSource.replace(
        DestinationRule, ".destination-card { }\n")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.applyWorkspaceFileEdits().ok
      check foundation[] == DemoFoundationInitialSource
      dispose()

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(name) == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil: return found

proc findTag(node: MockNode; tag: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.tag == tag: return node
  for child in node.children:
    let found = findTag(child, tag)
    if found != nil: return found

proc press(node: MockNode; key: string) =
  node.fireEventWith("keydown", MockEvent(`type`: "keydown", target: node,
    currentTarget: node, key: key))

template need(node: MockNode) {.dirty.} =
  check node != nil
  if node == nil:
    dispose()
    return

suite "editor example writer: re-set after Reset":
  # isonim-pm issue 2026-10-16-editor-example-writer-re-sets-a-reset-
  # property-outside-any-rule. Editor spec "Universal Patterns": Reset is
  # "written and undoable like any edit"; setting the property again writes
  # a declaration inside the rule that owns it, so the value applies to the
  # element. The writer appended `padding: 20px;` at the end of the file,
  # outside any rule.
  test "a value set after Reset is written inside the owning rule":
    let adapter = demoVectorEditAdapter(new(string), new(string))
    let entry = adapter.paddingEntry
    let reset = DemoFoundationInitialSource.replace(DestinationRule,
      ".destination-card { }\n")
    proc setPlan(value: string; expected = ""): SourceEditPlan =
      SourceEditPlan(file: DemoFoundationSource, line: 9, property: "padding",
        oldValue: expected, newValue: value, planKind: cspPropertyAddition,
        schemaKey: "classes.destination-card.padding",
        expectedOldValue: expected, sourceScope: sskSharedClass,
        scope: pesShared)
    let again = adapter.patchFile(setPlan("20px"), reset, entry)
    check again.ok
    check again.patch.afterContent == DemoFoundationInitialSource.replace(
      DestinationRule, ".destination-card { padding: 20px; }\n")
    # Setting back the removed value gives back the original bytes.
    let same = adapter.patchFile(setPlan("18px"), reset, entry)
    check same.ok
    check same.patch.afterContent == DemoFoundationInitialSource
    # With the declaration present, the value is replaced in that rule only:
    # an equal value elsewhere in the file is not touched.
    let elsewhere = DemoFoundationInitialSource & ".hero { margin: 18px; }\n"
    let replaced = adapter.patchFile(setPlan("24px", "18px"), elsewhere, entry)
    check replaced.ok
    check replaced.patch.afterContent == elsewhere.replace(DestinationRule,
      ".destination-card { padding: 24px; }\n")
    # No owning rule, or a value the rule no longer declares: refused, with
    # nothing written.
    let noRule = adapter.patchFile(setPlan("20px"),
      DemoFoundationInitialSource.replace(DestinationRule, ""), entry)
    check not noRule.ok
    check noRule.diagnostics.len == 1 and
      noRule.diagnostics[0].message.contains("no .destination-card rule")
    check noRule.patch.afterContent.len == 0
    let stale = adapter.patchFile(setPlan("20px", "24px"),
      DemoFoundationInitialSource, entry)
    check not stale.ok
    check stale.diagnostics.len == 1 and
      stale.diagnostics[0].kind == wedSourceConflict
    # Two rules for the class, or two declarations in its rule: which one
    # owns the property cannot be identified, so nothing is written.
    let twoRules = adapter.patchFile(setPlan("20px"),
      reset & ".destination-card { margin: 0; }\n", entry)
    check not twoRules.ok
    check twoRules.diagnostics.len == 1 and twoRules.diagnostics[0].message.contains(
      "has 2 .destination-card rules")
    check twoRules.patch.afterContent.len == 0
    let twoDeclarations = adapter.patchFile(setPlan("20px", "18px"),
      DemoFoundationInitialSource.replace(DestinationRule,
        ".destination-card { padding: 18px; padding: 24px; }\n"), entry)
    check not twoDeclarations.ok
    check twoDeclarations.diagnostics.len == 1 and
      twoDeclarations.diagnostics[0].message.contains("has 2 padding declarations")
    check twoDeclarations.patch.afterContent.len == 0
    # Reset removes only from the class's own rule: a padding declared by
    # another rule is not this entry's to remove.
    let elsewhereOnly = reset & ".hero { padding: 18px; }\n"
    let notOwned = adapter.patchFile(removalPlan(), elsewhereOnly, entry)
    check not notOwned.ok
    check notOwned.diagnostics.len == 1 and notOwned.diagnostics[0].message.contains(
      "not in the .destination-card rule")
    check notOwned.patch.afterContent.len == 0

  test "a selector-list rule is refused for set and Reset with the reason":
    # isonim-pm issue 2026-10-16-selector-list-rules-are-admitted-for-edit-
    # and-removal. Editor spec "Saving": an edit changes exactly the one
    # owning declaration; a rule shared by a selector list also styles the
    # other selectors, so it is refused with that reason.
    let adapter = demoVectorEditAdapter(new(string), new(string))
    let entry = adapter.paddingEntry
    let listed = DemoFoundationInitialSource.replace(DestinationRule,
      ".destination-card, .hero { padding: 18px; }\n")
    let set = adapter.patchFile(SourceEditPlan(file: DemoFoundationSource,
      line: 9, property: "padding", oldValue: "18px", newValue: "20px",
      planKind: cspStructuredSchemaUpdate,
      schemaKey: "classes.destination-card.padding",
      expectedOldValue: "18px", sourceScope: sskSharedClass,
      scope: pesShared), listed, entry)
    check not set.ok
    check set.diagnostics.len == 1 and set.diagnostics[0].message.contains(
      "shared by the selector list `.destination-card, .hero`")
    check set.patch.afterContent.len == 0
    let removed = adapter.patchFile(removalPlan(), listed, entry)
    check not removed.ok
    check removed.diagnostics.len == 1 and removed.diagnostics[0].message.contains(
      "shared by the selector list `.destination-card, .hero`")
    check removed.patch.afterContent.len == 0
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = listed
      let vm = demoVm(foundation)
      # Reset says why before the act, and an empty commit is refused there.
      let reason = vm.propertyResetRefusal("padding", sskSharedClass)
      check reason.contains("shared by the selector list")
      let refused = vm.editSharedDesignProperty("padding", "", sskSharedClass)
      check refused.status == pesRejected
      check vm.inspector.undoStack.val.len == 0
      # A value is refused at the act too, with the same reason (the
      # writer's statement, asked at the commit): nothing is previewed,
      # journaled, pending or written.
      let value = vm.editSharedDesignProperty("padding", "20px", sskSharedClass)
      check value.status == pesRejected
      check value.diagnostics.len == 1 and value.diagnostics[0].message.contains(
        "shared by the selector list `.destination-card, .hero`")
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == 0
      let local = vm.editCssProperty("padding", "20px", pesShared)
      check local.status == pesRejected
      check vm.inspector.pendingSourceEdits.val.len == 0
      check foundation[] == listed
      dispose()
    # The mounted row: a typed value is refused at the commit with the
    # reason, and nothing is staged.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let host = r.createElement("div")
      let foundation = new(string)
      foundation[] = listed
      let vm = demoVm(foundation)
      let wiring = vm.inspectorRowWiring("padding")
      let row = r.mountPropertyRow(host, propertyRowText("Padding",
        createSignal("18px"), wiring = wiring))
      let field = findTag(row, "input")
      need(field)
      r.setInputValue(field, "20px")
      field.fireEvent("change")
      check wiring.commitMessage.val.contains("shared by the selector list")
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == 0
      check foundation[] == listed
      dispose()

  test "Reset, set, undo, undo through the editor writes exact bytes":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      let reset = DemoFoundationInitialSource.replace(DestinationRule,
        ".destination-card { }\n")
      check vm.editSharedDesignProperty("padding", "",
        sskSharedClass).status == pesAccepted
      check vm.applyWorkspaceFileEdits().ok
      check foundation[] == reset
      let set = vm.editSharedDesignProperty("padding", "20px", sskSharedClass)
      check set.status == pesAccepted
      check set.diagnostics.len == 0
      check vm.applyWorkspaceFileEdits().ok
      check foundation[] == DemoFoundationInitialSource.replace(
        DestinationRule, ".destination-card { padding: 20px; }\n")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.applyWorkspaceFileEdits().ok
      check foundation[] == reset
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.applyWorkspaceFileEdits().ok
      check foundation[] == DemoFoundationInitialSource
      dispose()

suite "removal is admitted per schema entry and refused at the act":
  test "each example schema entry states whether its writer can remove":
    let adapter = demoVectorEditAdapter(new(string), new(string))
    var classEntries, tokenEntries, svgEntries = 0
    for entry in adapter.schema:
      case entry.kind
      of wskSourceMap:
        check entry.removable
        inc classEntries
      of wskToken:
        check not entry.removable
        inc tokenEntries
      of wskSvgSymbol:
        check not entry.removable
        inc svgEntries
      else: discard
    check (classEntries, tokenEntries, svgEntries) == (1, 8, 1)

  test "a removal the entry does not support is refused when committed":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      let reason = vm.propertyResetRefusal("border-radius", sskComponentToken)
      check reason.contains("cannot remove the border-radius declaration")
      let refused = vm.editSharedDesignProperty("border-radius", "",
        sskComponentToken)
      check refused.status == pesRejected
      check refused.diagnostics.len == 1 and
        refused.diagnostics[0].message == reason & " Nothing was changed."
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == 0
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "Reset is available only where the write would find one declaration":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      check vm.propertyResetRefusal("padding", sskSharedClass) == ""
      # The declaration is gone from the file (another writer): the write
      # it would join refuses (the framework's stale-source check answers
      # before the writer is asked), so Reset says so and a removal is
      # refused at the commit, before preview, journal or history move.
      foundation[] = DemoFoundationInitialSource.replace(DestinationRule,
        ".destination-card { }\n")
      let reason = vm.propertyResetRefusal("padding", sskSharedClass)
      check reason.contains("Source changed before the pending edit")
      let refused = vm.editSharedDesignProperty("padding", "", sskSharedClass)
      check refused.status == pesRejected
      check refused.diagnostics.len == 1 and
        refused.diagnostics[0].message == reason & " Nothing was changed."
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == 0
      # Two declarations: which one Reset means is unknowable.
      foundation[] = DemoFoundationInitialSource & ".hero { padding: 18px; }\n"
      check vm.propertyResetRefusal("padding", sskSharedClass).contains(
        "2 padding declarations")
      # A read-only workspace refuses Reset like every other edit.
      foundation[] = DemoFoundationInitialSource
      vm.workspacePermissions.val = EditorWorkspacePermissions(readSource: true)
      check vm.propertyResetRefusal("padding", sskSharedClass) ==
        "This workspace is read-only for source changes."
      dispose()

  test "a removal replacing a pending edit is checked against the file":
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      check vm.editSharedDesignProperty("padding", "24px",
        sskSharedClass).status == pesAccepted
      # Still pending: the file still declares 18px, which the removal (that
      # replaces the pending edit and inherits its expectation) removes.
      check vm.propertyResetRefusal("padding", sskSharedClass) == ""
      check vm.editSharedDesignProperty("padding", "",
        sskSharedClass).status == pesAccepted
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.applyWorkspaceFileEdits().ok
      check foundation[] == DemoFoundationInitialSource.replace(
        DestinationRule, ".destination-card { }\n")
      dispose()

suite "Reset through the mounted property row":
  test "Reset commits the removal through the row's commit; undo restores the line":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let host = r.createElement("div")
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      let row = r.mountPropertyRow(host, propertyRowText("Padding",
        createSignal("18px"), wiring = vm.inspectorRowWiring("padding")))
      row.fireEvent("contextmenu")
      let menu = findByAttr(row, "data-property-actions-menu", "true")
      need(menu)
      let reset = findByAttr(menu, "data-property-action", "reset")
      need(reset)
      check reset.attributes.getOrDefault("aria-disabled") == "false"
      check reset.attributes.getOrDefault("title") == ""
      reset.fireEvent("click")
      check menu.attributes.getOrDefault("data-property-actions-open") == "false"
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.inspector.pendingSourceEdits.val[0].planKind == cspPropertyRemoval
      check vm.inspector.undoStack.val.len == 1
      check vm.applyWorkspaceFileEdits().ok
      check foundation[] == DemoFoundationInitialSource.replace(
        DestinationRule, ".destination-card { }\n")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.applyWorkspaceFileEdits().ok
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "after Reset the row sets the property again inside its rule; undo, undo":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let host = r.createElement("div")
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      let shown = createSignal("18px")
      let row = r.mountPropertyRow(host, propertyRowText("Padding", shown,
        wiring = vm.inspectorRowWiring("padding")))
      row.fireEvent("contextmenu")
      let menu = findByAttr(row, "data-property-actions-menu", "true")
      need(menu)
      let reset = findByAttr(menu, "data-property-action", "reset")
      need(reset)
      reset.fireEvent("click")
      check vm.applyWorkspaceFileEdits().ok
      let afterReset = DemoFoundationInitialSource.replace(DestinationRule,
        ".destination-card { }\n")
      check foundation[] == afterReset
      let field = findTag(row, "input")
      need(field)
      r.setInputValue(field, "20px")
      field.fireEvent("change")
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.inspector.undoStack.val.len == 2
      check vm.applyWorkspaceFileEdits().ok
      check foundation[] == DemoFoundationInitialSource.replace(
        DestinationRule, ".destination-card { padding: 20px; }\n")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.applyWorkspaceFileEdits().ok
      check foundation[] == afterReset
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.applyWorkspaceFileEdits().ok
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "Reset where the writer cannot remove is disabled with the reason and stages nothing":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let host = r.createElement("div")
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      let wiring = vm.inspectorRowWiring("border-radius")
      let row = r.mountPropertyRow(host, propertyRowText("Radius",
        createSignal("14px"), wiring = wiring))
      row.fireEvent("contextmenu")
      let menu = findByAttr(row, "data-property-actions-menu", "true")
      need(menu)
      let reset = findByAttr(menu, "data-property-action", "reset")
      need(reset)
      check reset.attributes.getOrDefault("aria-disabled") == "true"
      let reason = reset.attributes.getOrDefault("title")
      check reason == wiring.resetReason()
      check reason.contains("cannot remove the border-radius declaration")
      reset.fireEvent("click")
      check findByAttr(menu, "data-property-actions-message", "true").textContent ==
        reason
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == 0
      check foundation[] == DemoFoundationInitialSource
      dispose()

suite "inspector-controls review notes":
  test "right-click inside a row's text field keeps the browser's menu":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let host = r.createElement("div")
      var cfg = propertyRowText("Label", createSignal("Active"))
      cfg.cssProperty = "content"
      cfg.clipboard = createSignal(PropertyClipboardEntry())
      let row = r.mountPropertyRow(host, cfg)
      let field = findTag(row, "input")
      need(field)
      let inField = MockEvent(`type`: "contextmenu", target: field,
        currentTarget: row)
      row.fireEventWith("contextmenu", inField)
      check not inField.defaultPrevented
      check findByAttr(row, "data-property-actions-menu", "true") == nil
      # Outside the field the property menu opens and the native one does not.
      let onRow = MockEvent(`type`: "contextmenu", target: row, currentTarget: row)
      row.fireEventWith("contextmenu", onRow)
      check onRow.defaultPrevented
      let menu = findByAttr(row, "data-property-actions-menu", "true")
      need(menu)
      check menu.attributes.getOrDefault("data-property-actions-open") == "true"
      dispose()

  test "right-click in a Fill entry's hex field keeps the browser's menu":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.inspector.selectedElement.val = ElementRef(id: "card", tag: "div",
        properties: @[PropertyInfo(name: "background-color", value: "#112233")])
      mountSectionFill[MockRenderer, MockNode](r, root, vm)
      let row = findByAttr(root, "data-fill-row", "0")
      need(row)
      let hex = findByAttr(row, "data-fill-row-hex", "0")
      need(hex)
      let inField = MockEvent(`type`: "contextmenu", target: hex,
        currentTarget: row)
      row.fireEventWith("contextmenu", inField)
      check not inField.defaultPrevented
      check findByAttr(row, "data-property-actions-menu", "true") == nil
      row.fireEvent("contextmenu")
      check findByAttr(row, "data-property-actions-menu", "true") != nil
      dispose()

  test "a deliberate Alpha of 0% is kept when a channel is typed":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let parent = r.createElement("div")
      let invoker = r.createElement("div")
      let state = createColorPopoverState()
      var value = "#112233"
      var commits: seq[string]
      discard mountColorPopover(r, parent, invoker, state,
        proc(): string = value,
        proc(next: string): bool =
          commits.add next
          value = next
          true)
      invoker.fireEvent("click")
      let red = findByAttr(parent, "data-color-channel", "Red")
      need(red)
      let alpha = findByAttr(parent, "data-color-channel", "Alpha %")
      need(alpha)
      # Opaque colour, the user sets Alpha 0%, then types a channel.
      r.setInputValue(alpha, "0")
      alpha.fireEvent("change")
      check state.draft.val == "#11223300"
      r.setInputValue(red, "255")
      red.press("Enter")
      check commits == @["#FF223300"]
      # A transparent colour, Alpha 0% chosen explicitly: also kept.
      value = "#00000000"
      findByAttr(parent, "data-color-popover-cancel", "true").fireEvent("click")
      invoker.fireEvent("click")
      r.setInputValue(alpha, "0")
      alpha.fireEvent("change")
      r.setInputValue(red, "59")
      red.press("Enter")
      check commits[^1] == "#3B000000"
      # A transparent colour with no opacity chosen: a typed channel is opaque.
      findByAttr(parent, "data-color-popover-cancel", "true").fireEvent("click")
      value = "#00000000"
      invoker.fireEvent("click")
      r.setInputValue(red, "59")
      red.press("Enter")
      check commits[^1] == "#3B0000"
      dispose()

  test "an asynchronously committed Enter moves the picker's Cancel point":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      var permissions = vm.workspacePermissions.val
      permissions.writeSource = true
      vm.workspacePermissions.val = permissions
      vm.inspector.selectedElement.val = ElementRef(id: "card", tag: "div",
        properties: @[PropertyInfo(name: "background-color", value: "#112233",
          authoredValue: "#112233", directStyleAllowed: true)])
      var confirm: proc(ok: bool; diagnostic: string) {.closure.}
      var requests: seq[string]
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind;
          done: proc(ok: bool; diagnostic: string) {.closure.}) =
        requests.add value
        confirm = done
      mountSectionFill[MockRenderer, MockNode](r, root, vm)
      let swatch = findByAttr(root, "data-fill-row-swatch", "0")
      need(swatch)
      swatch.fireEvent("click")
      let popup = findByAttr(root, "data-color-popover", "true")
      need(popup)
      let blue = findByAttr(popup, "data-color-channel", "Blue")
      need(blue)
      r.setInputValue(blue, "255")
      blue.press("Enter")
      check requests == @["#1122FF"]
      check confirm != nil
      if confirm == nil:
        dispose()
        return
      # Confirmed later, as the native source bridge does.
      confirm(true, "")
      check popup.attributes.getOrDefault("data-color-popover-open") == "true"
      # Cancel returns to the committed colour, not the opening one.
      findByAttr(popup, "data-color-popover-cancel", "true").fireEvent("click")
      check popup.attributes.getOrDefault("data-color-popover-open") == "false"
      check r.inputValue(findByAttr(popup, "data-color-popover-input", "true")) ==
        "#1122FF"
      check requests == @["#1122FF"]
      dispose()

suite "Fill delete removes the fill's declaration, as Reset does":
  # The example's real writer, given one more source-map entry: the card
  # rule's background colour. Its removal path is the one the example's
  # class padding uses (`removeDemoDeclaration`).
  const CardRule = ".card { background-color: #112233; }\n"
  proc fillVm(foundation: ref string; reads: ref int = nil): EditorVM =
    let adapter = demoVectorEditAdapter(new(string), foundation)
    if reads != nil:
      # Counts the project's source reads: in a consumer each one is a
      # synchronous bridge request.
      let read = adapter.readFile
      adapter.readFile = proc(file: string): WorkspaceReadResult =
        inc reads[]
        read(file)
    adapter.schema.add WorkspaceEditableSchemaEntry(
      key: "classes.card.background-color", kind: wskSourceMap,
      file: DemoFoundationSource, path: "classes.card.background-color",
      property: "background-color", removable: true)
    result = createEditorVM(newEditorWorkspace(
      title = "Fill delete fixture",
      storyGroups = @[StoryGroup(name: "Card", kind: skComponent,
        expanded: true, items: @[StoryItem(name: "Default", kind: skComponent,
          group: "Card")])],
      initialStory = some(StoryRef(group: "Card", name: "Default",
        kind: skComponent, index: 0)),
      permissions = EditorWorkspacePermissions(readSource: true,
        writeSource: true),
      editAdapter = adapter))
    check result.selectInspectorElement(ElementRef(id: "card", tag: "div",
      sourceKey: "card", sourceFile: DemoFoundationSource, sourceLine: 10,
      properties: @[PropertyInfo(name: "background-color", value: "#112233",
        origin: poTailwindClass, originDetail: "class:card",
        sourceFile: DemoFoundationSource, sourceLine: 10,
        schemaKey: "classes.card.background-color",
        directStyleAllowed: true)]))

  test "Delete is enabled where Reset is, commits the removal and undo restores it":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let root = r.createElement("div")
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource & CardRule
      let vm = fillVm(foundation)
      mountSectionFill[MockRenderer, MockNode](r, root, vm)
      let row = findByAttr(root, "data-fill-row", "0")
      need(row)
      let delete = findByAttr(row, "data-fill-row-delete", "0")
      need(delete)
      check vm.propertyResetRefusal("background-color", sskLocalInstance) == ""
      check delete.attributes.getOrDefault("aria-disabled") == "false"
      # Reset in the same entry's menu is enabled too.
      row.fireEvent("contextmenu")
      let menu = findByAttr(row, "data-property-actions-menu", "true")
      need(menu)
      check findByAttr(menu, "data-property-action", "reset").attributes.getOrDefault(
        "aria-disabled") == "false"
      delete.fireEvent("click")
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.inspector.pendingSourceEdits.val[0].planKind == cspPropertyRemoval
      check vm.inspector.undoStack.val.len == 1
      check vm.applyWorkspaceFileEdits().ok
      check foundation[] == DemoFoundationInitialSource & ".card { }\n"
      check findByAttr(root, "data-fill-row", "0") == nil
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.applyWorkspaceFileEdits().ok
      check foundation[] == DemoFoundationInitialSource & CardRule
      dispose()

  test "Delete is disabled with Reset's reason where Reset is, and changes nothing":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let root = r.createElement("div")
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource & CardRule & CardRule
      let vm = fillVm(foundation)
      mountSectionFill[MockRenderer, MockNode](r, root, vm)
      let row = findByAttr(root, "data-fill-row", "0")
      need(row)
      let delete = findByAttr(row, "data-fill-row-delete", "0")
      need(delete)
      # Two declarations own the fill: neither Reset nor Delete can remove it.
      # That depends on the file, which is read when the user reaches for
      # the button.
      let reason = vm.propertyResetRefusal("background-color", sskLocalInstance)
      check reason.contains("2 background-color declarations")
      delete.fireEvent("pointerenter")
      check delete.attributes.getOrDefault("aria-disabled") == "true"
      check delete.attributes.getOrDefault("title") == reason
      row.fireEvent("contextmenu")
      let menu = findByAttr(row, "data-property-actions-menu", "true")
      need(menu)
      check findByAttr(menu, "data-property-action", "reset").attributes.getOrDefault(
        "title") == reason
      delete.fireEvent("click")
      check findByAttr(root, "data-fill-message", "true").textContent == reason
      check findByAttr(root, "data-fill-row", "0") == row
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == 0
      check foundation[] == DemoFoundationInitialSource & CardRule & CardRule
      dispose()

  test "Delete reads the source only when the user reaches for it":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let root = r.createElement("div")
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource & CardRule
      let reads = new(int)
      let vm = fillVm(foundation, reads)
      let mounted = reads[]
      mountSectionFill[MockRenderer, MockNode](r, root, vm)
      let delete = findByAttr(root, "data-fill-row-delete", "0")
      need(delete)
      check reads[] == mounted
      check delete.attributes.getOrDefault("aria-disabled") == "false"
      # Viewport changes and a staged (unwritten) edit re-evaluate the
      # button's state without a single source read.
      for width in [375, 768, 1024, 1280, 1440]:
        var viewport = vm.viewport.val
        viewport.width = width
        vm.viewport.val = viewport
      check reads[] == mounted
      check vm.editCssProperty("background-color", "#445566",
        pesLocal).status == pesAccepted
      check reads[] == mounted
      # Reaching for the button asks the full question: one read each.
      delete.fireEvent("pointerenter")
      check reads[] == mounted + 1
      delete.fireEvent("focus")
      check reads[] == mounted + 2
      check delete.attributes.getOrDefault("aria-disabled") == "false"
      dispose()

suite "property-row colour picker with an asynchronous commit":
  proc colourRow(r: MockRenderer; host: MockNode;
      commit: proc(value: string; done: proc(ok: bool) {.closure.})): MockNode =
    var cfg = propertyRowColor("Color", createSignal("#112233"), createSignal(1.0))
    cfg.cssProperty = "border-color"
    cfg.commitMessage = createSignal("")
    cfg.commitRejected = createSignal(0)
    cfg.onAsyncCommitValue = commit
    r.mountPropertyRow(host, cfg)

  test "a commit confirmed before returning is not reported as refused":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let host = r.createElement("div")
      var commits: seq[string]
      # Every non-native project: the row's async commit completes at once.
      let row = r.colourRow(host, proc(value: string; done: proc(ok: bool) {.closure.}) =
        commits.add value
        done(true))
      let swatch = findByAttr(row, "data-property-row-swatch", "true")
      need(swatch)
      swatch.fireEvent("click")
      let popup = findByAttr(row, "data-color-popover", "true")
      need(popup)
      let red = findByAttr(popup, "data-color-channel", "Red")
      need(red)
      r.setInputValue(red, "255")
      red.press("Enter")
      check commits == @["#FF2233"]
      check popup.attributes.getOrDefault("data-color-popover-open") == "true"
      check findByAttr(popup, "data-color-popover-error", "true").textContent == ""
      findByAttr(popup, "data-color-popover-cancel", "true").fireEvent("click")
      check r.inputValue(findByAttr(popup, "data-color-popover-input", "true")) ==
        "#FF2233"
      dispose()

  test "a commit confirmed later moves Cancel to the committed colour":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let host = r.createElement("div")
      var commits: seq[string]
      var confirm: proc(ok: bool) {.closure.}
      # The native source bridge: confirmation arrives after the call returns.
      let row = r.colourRow(host, proc(value: string; done: proc(ok: bool) {.closure.}) =
        commits.add value
        confirm = done)
      let swatch = findByAttr(row, "data-property-row-swatch", "true")
      need(swatch)
      swatch.fireEvent("click")
      let popup = findByAttr(row, "data-color-popover", "true")
      need(popup)
      let red = findByAttr(popup, "data-color-channel", "Red")
      need(red)
      r.setInputValue(red, "255")
      red.press("Enter")
      check commits == @["#FF2233"]
      check confirm != nil
      if confirm == nil:
        dispose()
        return
      confirm(true)
      check popup.attributes.getOrDefault("data-color-popover-open") == "true"
      check findByAttr(popup, "data-color-popover-error", "true").textContent == ""
      findByAttr(popup, "data-color-popover-cancel", "true").fireEvent("click")
      check popup.attributes.getOrDefault("data-color-popover-open") == "false"
      check r.inputValue(findByAttr(popup, "data-color-popover-input", "true")) ==
        "#FF2233"
      dispose()

suite "native source projects: Reset and Fill Delete follow each entry's removal statement":
  # Mock justification: the native bridge (`source_browser.nim`, JS only)
  # installs two boundaries on the EditorVM -- `inspectorSourceCommit` (the
  # asynchronous write) and `inspectorSourceRemovalRefusal` (each editable
  # declaration's removal statement, shipped by the native worker with the
  # editable-style metadata). Here both are recording stand-ins, so the
  # production property row, actions menu and Fill section are tested
  # against what the bridge states; no write is claimed. The real worker's
  # statement, single-match removal and receipt undo are exercised on real
  # files by tests/test_editor_inspector_source.py
  # (NativeDeclarationRemovalTests), and the mounted bridge by the c2/c3
  # source GUI suites (test_editor_fill_readonly_gui.mjs,
  # test_editor_color_picker_gui.mjs).
  proc nativeVm(statement: Signal[string]; commits: ref seq[string];
      states = true): EditorVM =
    result = createEditorVM()
    var permissions = result.workspacePermissions.val
    permissions.writeSource = true
    result.workspacePermissions.val = permissions
    result.hasAsyncSourceProject = true
    result.sourceAdapterReady.val = true
    result.inspector.selectedElement.val = ElementRef(id: "card", tag: "div",
      properties: @[
        PropertyInfo(name: "background-color", value: "#112233",
          authoredValue: "#112233", directStyleAllowed: true),
        PropertyInfo(name: "width", value: "120px", authoredValue: "120px",
          directStyleAllowed: true)])
    result.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
        scope: SourceScopeChoiceKind;
        done: proc(ok: bool; diagnostic: string) {.closure.}) =
      commits[].add property & "=" & value
      done(true, "")
    if states:
      result.inspectorSourceRemovalRefusal = proc(element: ElementRef;
          property: string; scope: SourceScopeChoiceKind): string =
        statement.val

  test "an entry that states removal enables Reset and Delete, which commit the empty value":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let root = r.createElement("div")
      let commits = new(seq[string])
      let vm = nativeVm(createSignal(""), commits)
      check vm.propertyResetRefusal("background-color", sskLocalInstance) == ""
      mountSectionFill[MockRenderer, MockNode](r, root, vm)
      let row = findByAttr(root, "data-fill-row", "0")
      need(row)
      let delete = findByAttr(row, "data-fill-row-delete", "0")
      need(delete)
      check delete.attributes.getOrDefault("aria-disabled") == "false"
      row.fireEvent("contextmenu")
      let menu = findByAttr(row, "data-property-actions-menu", "true")
      need(menu)
      check findByAttr(menu, "data-property-action", "reset").attributes.getOrDefault(
        "aria-disabled") == "false"
      delete.fireEvent("click")
      check commits[] == @["background-color="]
      # The property row's Reset commits through the same native boundary.
      let host = r.createElement("div")
      let widthRow = r.mountPropertyRow(host, propertyRowText("Width",
        createSignal("120px"), wiring = vm.inspectorRowWiring("width")))
      widthRow.fireEvent("contextmenu")
      let widthMenu = findByAttr(widthRow, "data-property-actions-menu", "true")
      need(widthMenu)
      let reset = findByAttr(widthMenu, "data-property-action", "reset")
      need(reset)
      check reset.attributes.getOrDefault("aria-disabled") == "false"
      reset.fireEvent("click")
      check commits[] == @["background-color=", "width="]
      dispose()

  test "an entry that cannot remove shows its own reason and nothing is requested":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let root = r.createElement("div")
      let commits = new(seq[string])
      const reason = "2 declarations set `background-color` for `#card`. " &
        "Reset removes exactly one owning declaration and cannot tell which " &
        "of them is meant; edit the stylesheet directly."
      let statement = createSignal(reason)
      let vm = nativeVm(statement, commits)
      check vm.propertyResetRefusal("background-color", sskLocalInstance) == reason
      mountSectionFill[MockRenderer, MockNode](r, root, vm)
      let row = findByAttr(root, "data-fill-row", "0")
      need(row)
      let delete = findByAttr(row, "data-fill-row-delete", "0")
      need(delete)
      # The statement reads no source file, so the tracked state shows it
      # before the user reaches for the button.
      check delete.attributes.getOrDefault("aria-disabled") == "true"
      check delete.attributes.getOrDefault("title") == reason
      delete.fireEvent("click")
      check findByAttr(root, "data-fill-message", "true").textContent == reason
      row.fireEvent("contextmenu")
      let menu = findByAttr(row, "data-property-actions-menu", "true")
      need(menu)
      let reset = findByAttr(menu, "data-property-action", "reset")
      need(reset)
      check reset.attributes.getOrDefault("aria-disabled") == "true"
      check reset.attributes.getOrDefault("title") == reason
      reset.fireEvent("click")
      check commits[].len == 0
      check vm.inspector.undoStack.val.len == 0
      check vm.inspector.pendingSourceEdits.val.len == 0
      # A refreshed statement (the worker re-describes after every write)
      # re-enables both, without the user reaching for them.
      statement.val = ""
      check delete.attributes.getOrDefault("aria-disabled") == "false"
      check delete.attributes.getOrDefault("title") == "Delete fill"
      dispose()

  test "a native connection that states nothing about removal refuses it":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let root = r.createElement("div")
      let commits = new(seq[string])
      let vm = nativeVm(createSignal(""), commits, states = false)
      let reason = vm.propertyResetRefusal("background-color", sskLocalInstance)
      check reason == "This source connection does not state whether it can " &
        "remove the background-color declaration."
      mountSectionFill[MockRenderer, MockNode](r, root, vm)
      let delete = findByAttr(root, "data-fill-row-delete", "0")
      need(delete)
      check delete.attributes.getOrDefault("aria-disabled") == "true"
      check delete.attributes.getOrDefault("title") == reason
      delete.fireEvent("click")
      check findByAttr(root, "data-fill-message", "true").textContent == reason
      check commits[].len == 0
      dispose()
