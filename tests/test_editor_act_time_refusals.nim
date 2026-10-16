## A refusal happens when the user acts, never only when the edit is written.
##
## isonim-pm issues
## 2026-10-14-consumer-corner-radius-edit-is-previewed-then-refused-only-at-save
## and 2026-10-13-unsafe-undo-with-a-pending-same-file-edit-is-refused-only-at-save,
## and the Foundations-page Undo button that bypassed the shared undo timeline
## and its keystroke-time refusal. Editor spec "Saving" and "Planned
## interaction parity and popup containment" ("A refused source edit restores
## the control and preview and explains the refusal").
##
## Mock justification: the workspace adapter below keeps the project files in
## memory instead of on disk. IsoNim cannot depend on the consumer that owns
## the real writer (metacraft-web), and this test must also execute under the
## strict Node JS backend, which has no filesystem. The adapter implements the
## consumer writer's contract the framework relies on and nothing more: its
## schema owns whole files (`property: ""`) or single named declarations, an
## edit with no expected old value appends one `# isonim-editor <key>
## <prop>=<value>` line, and an expected old value is replaced only where it
## occurs exactly once (more than once is refused as ambiguous). Every other
## part -- EditorVM, the inspector row commit (`commitInspectorValue`,
## `inspectorRowWiring`), the four histories, the journal, the workspace
## transaction and the mounted Foundations page -- is the production code. The
## real browser, write bridge and consumer writer are exercised by the
## consumer GUI case
## `metacraft_unwritable_corner_radius_scope_is_refused_when_chosen_not_at_save`.

import std/[options, strutils, tables, unittest]

import isonim/core/[computation, owner, signals]
import isonim/testing/mock_dom
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/workspace
import isonim/editor/views/foundations_page
import isonim/editor/views/widgets/property_commit

const ComponentFile = "components.nim"
const ThemeFile = "theme.nim"
const TokenFile = "tokens.schema"
const ComponentOriginal = "proc topbar() = discard\ntopbar.gap=4px\n"
const ThemeOriginal = "--radius-md: 8px;\n"
const TokenOriginal = "space.card=16px\n"
const PanelRadiusKey = "fixture.components.panel.radius"

type MemoryProject = ref object
  files: Table[string, string]
  writes: int

proc memoryAdapter(project: MemoryProject): WorkspaceEditAdapter =
  result = WorkspaceEditAdapter(bridgeLabel: "in-memory consumer writer",
    allowMissingExpectedOldValue: true,
    schema: @[
      WorkspaceEditableSchemaEntry(key: "fixture.components",
        kind: wskSourceMap, file: ComponentFile, path: "components",
        property: ""),
      # The theme file is owned one named declaration at a time, like the
      # consumer's token entries: nothing in it owns `border-radius`.
      WorkspaceEditableSchemaEntry(key: "tokens.radius.md", kind: wskToken,
        file: ThemeFile, path: "radius.md", property: "--radius-md"),
      WorkspaceEditableSchemaEntry(key: "fixture.tokens", kind: wskToken,
        file: TokenFile, path: "tokens", property: "")])
  result.readFile = proc(file: string): WorkspaceReadResult =
    WorkspaceReadResult(ok: file in project.files,
      content: project.files.getOrDefault(file))
  result.writeFile = proc(file, content: string): WorkspaceOperationResult =
    project.files[file] = content
    inc project.writes
    WorkspaceOperationResult(ok: true)
  result.patchFile = proc(plan: SourceEditPlan; content: string;
      schema: WorkspaceEditableSchemaEntry): WorkspacePatchResult =
    let file = schema.file
    let hits = if plan.expectedOldValue.len > 0:
        content.count(plan.expectedOldValue) else: 0
    var next = ""
    if hits > 1:
      return WorkspacePatchResult(ok: false, diagnostics: @[
        WorkspaceEditDiagnostic(kind: wedPatchFailed,
          message: "ambiguous expected value in " & file, file: file)])
    elif hits == 1:
      next = content.replace(plan.expectedOldValue, plan.newValue)
    else:
      next = content.strip(leading = false) & "\n# isonim-editor " &
        plan.schemaKey & " " & plan.property & "=" & plan.newValue & "\n"
    WorkspacePatchResult(ok: true, patch: WorkspaceFilePatch(file: file,
      beforeContent: content, afterContent: next))

func marker(edge, value: string): string =
  "# isonim-editor dom.component-topbar.padding-" & edge & " padding-" & edge &
    "=" & value & "\n"

func pad(edge, value: string): PropertyInfo =
  PropertyInfo(name: "padding-" & edge, value: value, origin: poConstant,
    originDetail: "computed:padding-" & edge, sourceFile: ComponentFile,
    sourceLine: 1, schemaKey: "dom.component-topbar.padding-" & edge,
    directStyleAllowed: true)

func radius(value: string): PropertyInfo =
  ## Shaped like the consumer's captured topbar corner radius: mapped to a
  ## component-token schema node, which is therefore the default scope while
  ## it is considered writable.
  PropertyInfo(name: "border-radius", value: value, origin: poThemeToken,
    originDetail: "panel radius capped for operational UI",
    sourceFile: ComponentFile, sourceLine: 1,
    schemaKey: PanelRadiusKey, directStyleAllowed: true)

func gap(value: string): PropertyInfo =
  ## A value-verified inspector property: authored in the file, so its plan
  ## carries the old value as its expectation.
  PropertyInfo(name: "gap", value: value, origin: poConstant,
    originDetail: "class:topbar", sourceFile: ComponentFile, sourceLine: 2,
    schemaKey: "topbar.gap", directStyleAllowed: true)

func corner(name: string): PropertyInfo =
  ## A corner captured off the rendered DOM, as the consumer's are.
  PropertyInfo(name: "border-" & name & "-radius", value: "8px",
    origin: poConstant, originDetail: "computed:border-" & name & "-radius",
    sourceFile: ComponentFile, sourceLine: 1,
    schemaKey: "dom.component-topbar.border-" & name & "-radius",
    directStyleAllowed: true)

let topbarStory = StoryRef(group: "Operational components", name: "Topbar",
  kind: skComponent)

proc themeSchema(): DesignSystemSchema =
  DesignSystemSchema(schemaVersion: 1, projectId: "act-time-refusals",
    ownerPackage: "fixture", nodes: @[
      DesignSchemaNode(key: PanelRadiusKey, kind: dsnComponentToken,
        name: "Panel radius", component: "Panel", property: "border-radius",
        value: "8px", sourceSpan: SourceSpan(file: ThemeFile, line: 1,
          column: 1, endLine: 1, endColumn: 20),
        stories: @[topbarStory], components: @["Panel"], usageCount: 6)])

proc newEditor(project: MemoryProject): EditorVM =
  project.files[ComponentFile] = ComponentOriginal
  project.files[ThemeFile] = ThemeOriginal
  project.files[TokenFile] = TokenOriginal
  result = createEditorVM(newEditorWorkspace(
    title = "act-time refusals",
    storyGroups = @[StoryGroup(name: topbarStory.group,
      kind: topbarStory.kind, expanded: true, items: @[StoryItem(
        name: topbarStory.name, kind: topbarStory.kind,
        group: topbarStory.group)])],
    foundationTokens = @[FoundationTokenEntry(key: "space.card",
      kind: ftkSpacingScale, value: "16px", sourceFile: TokenFile,
      sourceLine: 1, schemaKey: "tokens.space.card", property: "space.card",
      affectedStories: @[topbarStory])],
    designSystemSchema = themeSchema(),
    permissions = EditorWorkspacePermissions(readSource: true,
      writeSource: true),
    editAdapter = memoryAdapter(project),
    initialStory = some(topbarStory)))
  check result.selectInspectorElement(ElementRef(id: "topbar", tag: "header",
    sourceKey: "dom.component-topbar", schemaKey: "dom.component-topbar",
    sourceFile: ComponentFile, sourceLine: 1,
    properties: @[pad("top", "0px"), pad("right", "0px"),
      pad("bottom", "0px"), pad("left", "0px"), radius("8px"),
      corner("top-left"), corner("top-right"), corner("bottom-right"),
      corner("bottom-left"), gap("4px")]))

proc editPad(vm: EditorVM; edge, value: string) =
  let edited = vm.editCssProperty("padding-" & edge, value, pesLocal)
  check edited.status == pesAccepted
  check edited.sourceEdit.expectedOldValue == ""

proc save(vm: EditorVM) =
  let saved = vm.applyWorkspaceFileEdits()
  check saved.ok
  check vm.inspector.pendingSourceEdits.val.len == 0

proc stacks(vm: EditorVM): (int, int) =
  (vm.inspector.undoStack.val.len, vm.inspector.redoStack.val.len)

proc value(vm: EditorVM; name: string): string =
  for prop in vm.inspector.selectedElement.val.properties:
    if prop.name == name:
      return prop.value

proc token(vm: EditorVM): string =
  for t in vm.foundations.tokens.val:
    if t.key == "space.card":
      return t.value

proc choice(vm: EditorVM; kind: SourceScopeChoiceKind): SourceScopeChoice =
  for prop in vm.inspector.selectedElement.val.properties:
    if prop.name == "border-radius":
      for candidate in vm.sourceScopeChoices(prop):
        if candidate.kind == kind:
          return candidate

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node.kind == mnkElement and name in node.attributes and
      node.attributes[name] == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil:
      return found

suite "An edit the project cannot write is refused when it is committed":
  test "the unwritable component-token scope is disabled, with its reason, and is not the default":
    ## The consumer's Corner radius row defaulted to a component token its
    ## writer has no entry for; the edit was previewed, journaled and put in
    ## history, then refused by the automatic write.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      let token = vm.choice(sskComponentToken)
      check token.kind == sskComponentToken
      check not token.editable
      check "safely represent" in token.reason
      let local = vm.choice(sskLocalInstance)
      check local.editable
      let wiring = vm.inspectorRowWiring("border-radius")
      # The default is a scope the project can write, not the refused one.
      check wiring.selectedSourceScope().isSome
      check wiring.selectedSourceScope().get.kind != sskComponentToken
      check wiring.selectedSourceScope().get.editable
      dispose()

  test "committing at the unwritable scope is refused before anything moves":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      let generation = vm.autoSaveGeneration.val
      let outcome = vm.commitInspectorValue("border-radius", "12px", sskComponentToken)
      check not outcome.ok
      check "safely represent" in outcome.message
      check vm.value("border-radius") == "8px"
      check vm.stacks == (0, 0)
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.autoSaveGeneration.val == generation
      check vm.workspaceEditStage.val != wesFailed
      check project.files[ThemeFile] == ThemeOriginal
      check project.writes == 0
      dispose()

  test "a local edit whose source no schema entry owns is refused at the commit":
    ## Same rule for the local route: a plan naming a file the project does
    ## not own (and not captured off the DOM) can never be written.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      var element = vm.inspector.selectedElement.val
      for prop in element.properties.mitems:
        if prop.name == "padding-top":
          prop.sourceFile = "vendor/unowned.css"
          prop.originDetail = "class:vendor"
      check vm.selectInspectorElement(element)
      let edited = vm.editCssProperty("padding-top", "6px", pesLocal)
      check edited.status != pesAccepted
      check edited.diagnostics.len == 1
      check "safely represent" in edited.diagnostics[0].message
      check vm.value("padding-top") == "0px"
      check vm.stacks == (0, 0)
      check vm.inspector.pendingSourceEdits.val.len == 0
      dispose()

  test "the writable local route commits, writes and keeps one history entry":
    ## Positive control for the three refusals above.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      let generation = vm.autoSaveGeneration.val
      let outcome = vm.commitInspectorValue("border-radius", "12px", sskLocalInstance)
      check outcome.ok
      check vm.value("border-radius") == "12px"
      check vm.stacks == (1, 0)
      check vm.autoSaveGeneration.val == generation + 1
      vm.save()
      check "border-radius=12px" in project.files[ComponentFile]
      dispose()

  test "a shared scope is re-checked with the value actually committed":
    ## Review R2. The semantic-token scope is admitted on the current value
    ## (its token resolves), but a token reference in the committed value
    ## changes the plan's identity to a token no schema entry owns. That plan
    ## used to be journaled and refused by the write.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      var element = vm.inspector.selectedElement.val
      for prop in element.properties.mitems:
        if prop.name == "border-radius":
          prop.tokenName = "tokens.radius.md"
          prop.sourceFile = ThemeFile
      check vm.selectInspectorElement(element)
      check vm.choice(sskSemanticToken).editable
      let refused = vm.commitInspectorValue("border-radius", "var(--nope)",
        sskSemanticToken)
      check not refused.ok
      check "safely represent" in refused.message
      check vm.value("border-radius") == "8px"
      check vm.stacks == (0, 0)
      check vm.inspector.pendingSourceEdits.val.len == 0
      # The same scope with a value its plan can carry is written.
      check vm.commitInspectorValue("border-radius", "10px", sskSemanticToken).ok
      vm.save()
      dispose()

  test "the corner rows follow a committed corner-radius shorthand":
    ## Same issue, second half: after Corner radius 12 the TL/TR/BR/BL rows
    ## still read the captured 8px (0 in the consumer) while the shorthand
    ## and the preview said 12px, before and after the write.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.commitInspectorValue("border-radius", "12px", sskLocalInstance).ok
      for name in ["top-left", "top-right", "bottom-right", "bottom-left"]:
        check vm.value("border-" & name & "-radius") == "12px"
      vm.save()
      check vm.value("border-top-left-radius") == "12px"
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      for name in ["top-left", "top-right", "bottom-right", "bottom-left"]:
        check vm.value("border-" & name & "-radius") == "8px"
      dispose()

suite "An unsafe undo is refused at the keystroke while another edit is pending":
  test "a pending non-history edit to the same file does not defer the check to the write":
    ## Reviewer probe P5b (sibling-undo review, round 2). The undo used to
    ## succeed -- history (1, 1), model 0px -- and the write then refused the
    ## whole transaction with both plans left pending.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      vm.editPad("top", "6px"); vm.save()
      vm.editPad("left", "6px"); vm.save()
      project.files[ComponentFile] = project.files[ComponentFile] &
        marker("left", "6px")
      let external = project.files[ComponentFile]
      vm.inspector.journalSourceEdit(SourceEditPlan(file: ComponentFile,
        property: "padding-bottom", oldValue: "0px", newValue: "6px",
        scope: pesLocal, schemaKey: "dom.component-topbar.padding-bottom"))
      let refused = vm.runEditorCommand(eckUndo)
      check refused.status == ecsFailed
      check refused.diagnostic.contains("Undo refused")
      check vm.stacks == (2, 0)
      check vm.value("padding-left") == "6px"
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.workspaceEditDiagnostics.val.len == 1
      check project.files[ComponentFile] == external
      dispose()

  test "the same undo with nothing unsafe is staged and written with the pending edit":
    ## Positive control: the pending edit is simulated, not a reason to refuse.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      vm.editPad("top", "6px"); vm.save()
      vm.editPad("left", "6px"); vm.save()
      vm.inspector.journalSourceEdit(SourceEditPlan(file: ComponentFile,
        property: "padding-bottom", oldValue: "0px", newValue: "6px",
        scope: pesLocal, schemaKey: "dom.component-topbar.padding-bottom"))
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.value("padding-left") == "0px"
      vm.save()
      check project.files[ComponentFile] ==
        ComponentOriginal & marker("top", "6px") &
          "# isonim-editor dom.component-topbar.padding-bottom padding-bottom=6px\n"
      dispose()

  test "an undo that would join a transaction that cannot be written is refused":
    ## The write is one transaction. A pending edit that cannot be written
    ## takes the restoration down with it, so the undo is refused while that
    ## edit is pending, and says which one.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      vm.editPad("left", "6px"); vm.save()
      # A pending edit whose expected value is ambiguous in the file.
      project.files[ComponentFile] = project.files[ComponentFile] &
        "# note gap=3px\n# note gap=3px\n"
      let external = project.files[ComponentFile]
      vm.inspector.journalSourceEdit(SourceEditPlan(file: ComponentFile,
        property: "gap", oldValue: "3px", newValue: "4px",
        expectedOldValue: "gap=3px", scope: pesLocal, schemaKey: "dom.component-topbar.gap"))
      let refused = vm.runEditorCommand(eckUndo)
      check refused.status == ecsFailed
      check refused.diagnostic.contains("Undo refused")
      check refused.diagnostic.contains("gap")
      check vm.stacks == (1, 0)
      check vm.value("padding-left") == "6px"
      check vm.inspector.pendingSourceEdits.val.len == 1
      check project.files[ComponentFile] == external
      dispose()

  test "foundation: an undo whose re-staged earlier edit cannot be written is refused":
    ## Review R1. 16px -> 24px -> 32px inside the debounce: the second plan
    ## replaces the first (which is marked superseded) and inherits its
    ## expectation. After the write, undo restores the lines the 32px write
    ## replaced AND stages the superseded 24px plan again, expecting 16px. An external comment quoting 16px makes that plan ambiguous, so
    ## the write would refuse the whole transaction.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.editFoundationToken("space.card", "24px").status == pesAccepted
      check vm.editFoundationToken("space.card", "32px").status == pesAccepted
      check vm.inspector.pendingSourceEdits.val.len == 1
      vm.save()
      check project.files[TokenFile] == "space.card=32px\n"
      project.files[TokenFile] = project.files[TokenFile] & "# was space.card=16px\n"
      let external = project.files[TokenFile]
      let refused = vm.runEditorCommand(eckUndo)
      check refused.status == ecsFailed
      check refused.diagnostic.contains("Undo refused")
      check vm.token == "32px"
      check vm.foundations.undoStack.val.len == 2
      check vm.foundations.redoStack.val.len == 0
      check vm.inspector.pendingSourceEdits.val.len == 0
      check project.files[TokenFile] == external
      dispose()

  test "foundation: the same undo with nothing ambiguous is written with the re-staged edit":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.editFoundationToken("space.card", "24px").status == pesAccepted
      check vm.editFoundationToken("space.card", "32px").status == pesAccepted
      vm.save()
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.token == "24px"
      check vm.inspector.pendingSourceEdits.val.len == 2
      vm.save()
      check project.files[TokenFile] == "space.card=24px\n"
      dispose()

  test "inspector: an undo whose re-staged earlier edit cannot be written is refused":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      let first = vm.editCssProperty("gap", "8px", pesLocal)
      check first.status == pesAccepted
      check first.sourceEdit.expectedOldValue.len > 0
      check vm.editCssProperty("gap", "12px", pesLocal).status == pesAccepted
      check vm.inspector.pendingSourceEdits.val.len == 1
      vm.save()
      check "topbar.gap=12px" in project.files[ComponentFile]
      project.files[ComponentFile] = project.files[ComponentFile] &
        "# was topbar.gap=4px\n"
      let external = project.files[ComponentFile]
      let refused = vm.runEditorCommand(eckUndo)
      check refused.status == ecsFailed
      check refused.diagnostic.contains("Undo refused")
      check vm.value("gap") == "12px"
      check vm.stacks == (2, 0)
      check vm.inspector.pendingSourceEdits.val.len == 0
      check project.files[ComponentFile] == external
      dispose()

  test "inspector: the same undo with nothing ambiguous is written with the re-staged edit":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.editCssProperty("gap", "8px", pesLocal).status == pesAccepted
      check vm.editCssProperty("gap", "12px", pesLocal).status == pesAccepted
      vm.save()
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.value("gap") == "8px"
      vm.save()
      check project.files[ComponentFile] ==
        ComponentOriginal.replace("gap=4px", "gap=8px")
      dispose()

  test "a redo is checked against the journal it leaves, after what it withdraws":
    ## The check computes the journal exactly as the command changes it. A
    ## redo of a written edit withdraws the unwritten forward plan of the
    ## edit below it for the same slot; that plan is not in the write the
    ## redo joins, so it cannot be a reason to refuse the redo.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.editFoundationToken("space.card", "24px").status == pesAccepted
      vm.save()
      check vm.editFoundationToken("space.card", "32px").status == pesAccepted
      vm.save()
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      check project.files[TokenFile] == "space.card=24px\n"
      project.files[TokenFile] = project.files[TokenFile] & "# 16px 16px\n"
      # The edit below is staged again (for instance by an accepted proposal)
      # and cannot be written: its expected 16px is ambiguous now.
      vm.inspector.journalSourceEdit(vm.foundations.undoStack.val[^1].sourceEdit)
      let redone = vm.runEditorCommand(eckRedo)
      check redone.status == ecsSucceeded
      check redone.diagnostic == ""
      check vm.token == "32px"
      check vm.inspector.pendingSourceEdits.val.len == 1
      vm.save()
      check project.files[TokenFile] == "space.card=32px\n# 16px 16px\n"
      dispose()

  test "an undo that only withdraws an unwritten edit is never refused":
    ## Review round 2, probe P3. A pending edit that cannot be written does
    ## not block an undo that only withdraws another pending edit: the
    ## command adds nothing the write could refuse.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      project.files[ComponentFile] = project.files[ComponentFile] &
        "# note gap=3px\n# note gap=3px\n"
      vm.inspector.journalSourceEdit(SourceEditPlan(file: ComponentFile,
        property: "gap", oldValue: "3px", newValue: "4px",
        expectedOldValue: "gap=3px", scope: pesLocal,
        schemaKey: "dom.component-topbar.gap"))
      vm.editPad("left", "6px")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.value("padding-left") == "0px"
      check vm.inspector.pendingSourceEdits.val.len == 1
      dispose()

  test "an inspector redo is not refused by the unwritable plan it withdraws":
    ## Review round 2, probe P4. The redo of a written edit withdraws the
    ## unwritten forward plan of the edit below it for the same slot; that
    ## plan is not in the write the redo joins.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      project.files[ComponentFile] = project.files[ComponentFile] &
        "topbar.radius=8px\n"
      check vm.commitInspectorValue("border-radius", "12px", sskLocalInstance).ok
      vm.save()
      check vm.commitInspectorValue("border-radius", "16px", sskLocalInstance).ok
      vm.save()
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      project.files[ComponentFile] = project.files[ComponentFile] &
        "# dup\n# dup\n"
      var below = vm.inspector.undoStack.val[^1].sourceEdit
      below.expectedOldValue = "# dup"
      vm.inspector.journalSourceEdit(below)
      check vm.inspector.inspectorHistoryStep(redo = true).kind == ihsRestoreWrite
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.value("border-radius") == "16px"
      check vm.applyWorkspaceFileEdits().ok
      dispose()

suite "The Foundations page Undo button is the shared undo command":
  test "an unsafe foundation undo from the button is refused before anything moves":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      let r = MockRenderer()
      let page = renderFoundationsPage[MockRenderer, MockNode](r, vm)
      check vm.editFoundationToken("space.card", "24px").status == pesAccepted
      vm.save()
      check project.files[TokenFile] == "space.card=24px\n"
      # Someone else duplicates the written line: the write can no longer be
      # identified, so restoring it would be a guess.
      project.files[TokenFile] = "space.card=24px\nspace.card=24px\n"
      let external = project.files[TokenFile]
      let undo = findByAttr(page, "aria-label", "Undo foundation token edit")
      check undo != nil
      check undo.attributes.getOrDefault("aria-disabled") == "false"
      undo.fireEvent("click")
      check vm.token == "24px"
      check vm.foundations.undoStack.val.len == 1
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.workspaceEditDiagnostics.val.len == 1
      check vm.workspaceEditDiagnostics.val[0].message.contains("Undo refused")
      check vm.applyWorkspaceFileEdits().ok
      check project.files[TokenFile] == external
      dispose()

  test "the button follows the one timeline: it does not reach past a newer edit":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      let r = MockRenderer()
      let page = renderFoundationsPage[MockRenderer, MockNode](r, vm)
      check vm.editFoundationToken("space.card", "24px").status == pesAccepted
      vm.editPad("top", "6px")
      let undo = findByAttr(page, "aria-label", "Undo foundation token edit")
      check undo != nil
      check undo.attributes.getOrDefault("aria-disabled") == "true"
      undo.fireEvent("click")
      check vm.token == "24px"
      check vm.value("padding-top") == "6px"
      check vm.foundations.undoStack.val.len == 1
      # Mod+Z takes the newer inspector edit; then the button is the next undo.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.value("padding-top") == "0px"
      check undo.attributes.getOrDefault("aria-disabled") == "false"
      undo.fireEvent("click")
      check vm.token == "16px"
      check vm.foundations.undoStack.val.len == 0
      check undo.attributes.getOrDefault("aria-disabled") == "true"
      dispose()
