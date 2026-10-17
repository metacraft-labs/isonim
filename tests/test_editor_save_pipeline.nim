## Every commit path schedules the automatic write, and a write keeps the
## component-property, foundation-token and vector undo history.
##
## isonim-pm issues 2026-10-14-only-inspector-row-commits-schedule-automatic-
## saving and 2026-10-14-a-successful-save-clears-component-foundation-and-
## vector-undo-history; editor spec "Saving" and "Universal Patterns".
##
## Mock justification: the workspace adapter below keeps the project files in
## memory instead of on disk. IsoNim cannot depend on the consumer that owns
## the real writer (metacraft-web), and this test must also execute under the
## strict Node JS backend, which has no filesystem. The adapter implements the
## writer contract the framework relies on and nothing more: a plan with an
## expected old value has that value replaced where it occurs exactly once
## (otherwise the patch is refused), and a plan without one is refused, since
## none of these paths produce one. Every other part -- EditorVM, the four
## histories, the journal, the scheduling generation and the workspace
## transaction -- is the production code. The real browser debounce, write
## bridge and consumer writer are exercised by the consumer GUI cases
## `e2e_component_variant_matrix_state_controls_write_real_schema_files`,
## `e2e_component_text_property_updates_panel_header_live_preview`,
## `e2e_canvas_resize_spacing_reorder_and_inline_text` and
## `e2e_canvas_context_menu_commands_are_selection_safe`.

import std/[options, strutils, tables, unittest]

import isonim/core/[computation, owner, signals]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/workspace

const ComponentFile = "components.schema"
const TokenFile = "tokens.schema"
const SymbolFile = "symbols.schema"
const ComponentOriginal =
  "badge.tone=neutral\nbadge.label=Customers\nbadge.loading=false\n" &
  "badge.gap=4px\n"
const TokenOriginal = "space.card=16px\n"

type MemoryProject = ref object
  files: Table[string, string]
  writes: int

proc memoryAdapter(project: MemoryProject): WorkspaceEditAdapter =
  result = WorkspaceEditAdapter(bridgeLabel: "in-memory project writer",
    schema: @[
      WorkspaceEditableSchemaEntry(key: "fixture.components",
        kind: wskComponentVariant, file: ComponentFile, path: "components",
        property: ""),
      WorkspaceEditableSchemaEntry(key: "fixture.tokens", kind: wskToken,
        file: TokenFile, path: "tokens", property: ""),
      WorkspaceEditableSchemaEntry(key: "symbols.safe.svg",
        kind: wskSvgSymbol, file: SymbolFile, path: "symbols.safe.svg",
        property: "svgContent")])
  result.readFile = proc(file: string): WorkspaceReadResult =
    WorkspaceReadResult(ok: file in project.files,
      content: project.files.getOrDefault(file))
  result.writeFile = proc(file, content: string): WorkspaceOperationResult =
    project.files[file] = content
    inc project.writes
    WorkspaceOperationResult(ok: true)
  result.patchFile = proc(plan: SourceEditPlan; content: string;
      schema: WorkspaceEditableSchemaEntry): WorkspacePatchResult =
    let file = if plan.file.len > 0: plan.file else: schema.file
    if plan.expectedOldValue.len == 0 or
        content.count(plan.expectedOldValue) != 1:
      return WorkspacePatchResult(ok: false, diagnostics: @[
        WorkspaceEditDiagnostic(kind: wedSourceConflict,
          message: "expected value is not unique in " & file, file: file)])
    WorkspacePatchResult(ok: true, patch: WorkspaceFilePatch(file: file,
      beforeContent: content,
      afterContent: content.replace(plan.expectedOldValue, plan.newValue)))

let badgeStory = StoryRef(group: "Operational components",
  name: "Status badge", kind: skComponent)

proc badgeVariant(): ComponentVariantDefinition =
  proc prop(name: string; kind: ComponentPropertyKind; value: string;
      options: seq[string]; line: int): ComponentPropertyDefinition =
    ComponentPropertyDefinition(name: name, kind: kind, value: value,
      options: options, sourceFile: ComponentFile, sourceLine: line,
      schemaKey: "badge." & name, constructor: "badgeSchema",
      documentation: "Badge " & name & ".", usageGuidance: "Schema-backed.")
  ComponentVariantDefinition(component: "StatusBadge", variantKey: "default",
    story: badgeStory, fixtureName: "badge.default", metadataName: "Default",
    properties: @[
      prop("tone", cpkEnum, "neutral",
        @["neutral", "success", "warning", "danger"], 1),
      prop("label", cpkText, "Customers", @[], 2)],
    stateControls: @[ComponentStateControl(key: "loading", kind: cskLoading,
      label: "loading", value: "false", options: @["false", "true"],
      story: badgeStory, fixtureName: "badge.loading",
      sourceFile: ComponentFile, sourceLine: 3,
      schemaKey: "badge.states.loading")])

const SafeSvg =
  "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 32 32\"><rect id=\"box\" x=\"4\" y=\"4\" width=\"12\" height=\"12\" fill=\"#111827\" /></svg>"

proc newEditor(project: MemoryProject): EditorVM =
  project.files[ComponentFile] = ComponentOriginal
  project.files[TokenFile] = TokenOriginal
  result = createEditorVM(newEditorWorkspace(
    title = "save pipeline",
    storyGroups = @[StoryGroup(name: badgeStory.group, kind: badgeStory.kind,
      expanded: true, items: @[StoryItem(name: badgeStory.name,
        kind: badgeStory.kind, group: badgeStory.group)])],
    componentVariants = @[badgeVariant()],
    foundationTokens = @[FoundationTokenEntry(key: "space.card",
      kind: ftkSpacingScale, value: "16px", sourceFile: TokenFile,
      sourceLine: 1, schemaKey: "tokens.space.card", property: "space.card",
      affectedStories: @[badgeStory])],
    vectorSymbols = @[VectorSymbol(name: "Safe", category: "Icons",
      svgContent: SafeSvg, width: 32, height: 32)],
    permissions = EditorWorkspacePermissions(readSource: true,
      writeSource: true),
    editAdapter = memoryAdapter(project),
    initialStory = some(badgeStory)))

proc openVector(vm: EditorVM; project: MemoryProject) =
  check vm.selectVectorSymbol(0)
  project.files[SymbolFile] =
    vm.vectorEditor.document.val.exportVectorDocumentSvg.optimizeVectorSvg

proc save(vm: EditorVM) =
  ## What the browser layer's debounce does when it fires: `eckSave`.
  check vm.inspector.pendingSourceEdits.val.len > 0
  check vm.runEditorCommand(eckSave).status == ecsSucceeded
  check vm.inspector.pendingSourceEdits.val.len == 0
  check vm.workspaceEditDiagnostics.val.len == 0

proc tone(vm: EditorVM): string =
  for prop in vm.variants.variants.val[0].properties:
    if prop.name == "tone":
      return prop.value

proc token(vm: EditorVM): string =
  for t in vm.foundations.tokens.val:
    if t.key == "space.card":
      return t.value

func badgeGap(value: string): PropertyInfo =
  ## A value-verified inspector property: authored in the file, so its plan
  ## carries the old value as its expectation.
  PropertyInfo(name: "gap", value: value, origin: poConstant,
    originDetail: "class:badge", sourceFile: ComponentFile, sourceLine: 4,
    schemaKey: "badge.gap", directStyleAllowed: true)

proc selectBadge(vm: EditorVM) =
  check vm.selectInspectorElement(ElementRef(id: "badge", tag: "span",
    sourceKey: "badge", schemaKey: "badge", sourceFile: ComponentFile,
    sourceLine: 4, properties: @[badgeGap("4px")]))

proc gap(vm: EditorVM): string =
  for prop in vm.inspector.selectedElement.val.properties:
    if prop.name == "gap":
      return prop.value

proc editGap(vm: EditorVM; value: string) =
  let edited = vm.editCssProperty("gap", value, pesLocal)
  check edited.status == pesAccepted
  check edited.sourceEdit.expectedOldValue.len > 0

func topbarPad(value: string): PropertyInfo =
  PropertyInfo(name: "padding-top", value: value, origin: poConstant,
    originDetail: "computed:padding-top", sourceFile: ComponentFile,
    sourceLine: 1, schemaKey: "dom.topbar.padding-top",
    directStyleAllowed: true)

suite "Every commit path schedules the automatic write":
  test "a component property commit schedules a write":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.autoSaveGeneration.val == 0
      check vm.editComponentProperty("StatusBadge", "default", "tone",
        "success").status == pesAccepted
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.autoSaveGeneration.val == 1
      # And what it schedules writes the value.
      vm.save()
      check project.files[ComponentFile].contains("badge.tone=success")
      dispose()

  test "a component state commit schedules a write":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.editComponentStateControl("StatusBadge", "default", "loading",
        "true").status == pesAccepted
      check vm.autoSaveGeneration.val == 1
      dispose()

  test "a foundation token commit schedules a write":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.editFoundationToken("space.card", "24px").status == pesAccepted
      check vm.autoSaveGeneration.val == 1
      dispose()

  test "a vector commit schedules a write":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      vm.openVector(project)
      let before = vm.autoSaveGeneration.val
      check vm.setVectorObjectProperty(VectorPropertyEditRequest(
        objectId: "box", kind: vpkFill, value: "#22C55E")).ok
      check vm.autoSaveGeneration.val == before + 1
      dispose()

  test "a canvas command commit schedules a write":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.selectInspectorElement(ElementRef(id: "topbar", tag: "header",
        sourceKey: "dom.topbar", schemaKey: "dom.topbar",
        sourceFile: ComponentFile, sourceLine: 1,
        properties: @[topbarPad("0px")]))
      check vm.applyDirectCanvasSpacing("padding-top", "8px").ok
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.autoSaveGeneration.val == 1
      dispose()

  test "a refused component commit schedules nothing":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.editComponentProperty("StatusBadge", "default", "tone",
        "purple").status == pesRejected
      check vm.autoSaveGeneration.val == 0
      dispose()

  test "a commit staged with no adapter ready schedules nothing":
    ## Same rule as the inspector row: the edit is staged and reported where
    ## it was made; a scheduled save would only fail in the status bar.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      # A workspace with an adapter reports ready; this is the state the
      # browser host is in until its write bridge answers.
      vm.sourceAdapterReady.val = false
      check vm.editComponentProperty("StatusBadge", "default", "tone",
        "success").status == pesAccepted
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.autoSaveGeneration.val == 0
      dispose()

suite "A write keeps component, foundation and vector history":
  test "component property: undo after the write restores the file":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.editComponentProperty("StatusBadge", "default", "tone",
        "success").status == pesAccepted
      vm.save()
      let afterEdit = project.files[ComponentFile]
      check afterEdit == ComponentOriginal.replace("tone=neutral",
        "tone=success")
      check vm.variants.undoStack.val.len == 1
      check vm.commandAvailable(eckUndo)

      let generation = vm.autoSaveGeneration.val
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.tone == "neutral"
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.inspector.pendingSourceEdits.val[0].restoreWrite.recorded
      # Undoing after a write is itself an edit, so it saves like one.
      check vm.autoSaveGeneration.val == generation + 1
      vm.save()
      check project.files[ComponentFile] == ComponentOriginal
      check vm.variants.redoStack.val.len == 1

      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.tone == "success"
      vm.save()
      check project.files[ComponentFile] == afterEdit

      # And back again through the redone write.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      check project.files[ComponentFile] == ComponentOriginal
      dispose()

  test "component property: undo before the write lands writes nothing":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.editComponentProperty("StatusBadge", "default", "tone",
        "success").status == pesAccepted
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.tone == "neutral"
      check project.writes == 0
      dispose()

  test "two edits to one property written together undo one at a time":
    ## The second edit replaces the first's plan before it is written, so only
    ## the second reaches disk. Undoing it must not leave the model showing
    ## the first value while the file holds the original.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.editComponentProperty("StatusBadge", "default", "tone",
        "success").status == pesAccepted
      check vm.editComponentProperty("StatusBadge", "default", "tone",
        "warning").status == pesAccepted
      vm.save()
      check project.files[ComponentFile].contains("badge.tone=warning")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.tone == "success"
      vm.save()
      check project.files[ComponentFile].contains("badge.tone=success")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.tone == "neutral"
      vm.save()
      check project.files[ComponentFile] == ComponentOriginal
      dispose()

  test "undoing an unwritten edit stages and schedules the one it replaced":
    ## Two choices inside the debounce: the second replaces the first's plan.
    ## Undoing the second before anything is written makes the first current
    ## again, so its value has to be staged -- and written -- again.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.editComponentProperty("StatusBadge", "default", "tone",
        "success").status == pesAccepted
      check vm.editComponentProperty("StatusBadge", "default", "tone",
        "warning").status == pesAccepted
      check vm.inspector.pendingSourceEdits.val.len == 1
      let generation = vm.autoSaveGeneration.val
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.tone == "success"
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.inspector.pendingSourceEdits.val[0].newValue == "success"
      check vm.autoSaveGeneration.val > generation
      vm.save()
      check project.files[ComponentFile].contains("badge.tone=success")
      dispose()

  test "foundation token: undo after the write restores the file":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.editFoundationToken("space.card", "24px").status == pesAccepted
      vm.save()
      check project.files[TokenFile] == "space.card=24px\n"
      check vm.foundations.undoStack.val.len == 1
      # Kept history is not unsaved work.
      check not vm.foundations.isDirty.val
      let generation = vm.autoSaveGeneration.val
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.token == "16px"
      check vm.autoSaveGeneration.val == generation + 1
      vm.save()
      check project.files[TokenFile] == TokenOriginal
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      vm.save()
      check project.files[TokenFile] == "space.card=24px\n"
      dispose()

  test "vector: undo after the write restores the file":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      vm.openVector(project)
      let original = project.files[SymbolFile]
      check vm.setVectorObjectProperty(VectorPropertyEditRequest(
        objectId: "box", kind: vpkFill, value: "#22C55E")).ok
      vm.save()
      let edited = project.files[SymbolFile]
      check edited.contains("#22C55E")
      check vm.vectorEditor.undoStack.val.len == 1
      check not vm.vectorEditor.isDirty.val
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      check project.files[SymbolFile] == original
      check not vm.vectorEditor.document.val.exportVectorDocumentSvg.contains(
        "#22C55E")
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      vm.save()
      check project.files[SymbolFile] == edited
      dispose()

  test "revert discards only what is not written":
    ## Revert used to restore the first history entry and clear the stacks,
    ## which was right only while a write emptied them. With history kept it
    ## would put the model back past a value that is on disk.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.editComponentProperty("StatusBadge", "default", "tone",
        "success").status == pesAccepted
      vm.save()
      check vm.editComponentProperty("StatusBadge", "default", "tone",
        "warning").status == pesAccepted
      check vm.editFoundationToken("space.card", "24px").status == pesAccepted
      vm.save()
      check vm.editFoundationToken("space.card", "32px").status == pesAccepted
      check vm.runEditorCommand(eckRevert).status == ecsSucceeded
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.token == "24px"
      check vm.tone == "warning"
      check vm.foundations.undoStack.val.len == 1
      check vm.variants.undoStack.val.len == 2
      check project.files[TokenFile] == "space.card=24px\n"
      dispose()

  test "revert after an unwritten undo puts the written value back":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.editComponentProperty("StatusBadge", "default", "tone",
        "success").status == pesAccepted
      vm.save()
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.tone == "neutral"
      # The undo is staged but not written; discarding it leaves the file as
      # it is, so the model must say what the file says.
      check vm.runEditorCommand(eckRevert).status == ecsSucceeded
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.tone == "success"
      check project.files[ComponentFile].contains("badge.tone=success")
      check vm.variants.undoStack.val.len == 1
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      check project.files[ComponentFile] == ComponentOriginal
      dispose()

suite "One undo timeline across the editor's histories":
  test "undo and redo follow recency, not the kind of edit":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      vm.selectBadge()
      check vm.editComponentProperty("StatusBadge", "default", "tone",
        "success").status == pesAccepted
      vm.save()
      vm.editGap("8px")
      vm.save()
      check vm.editFoundationToken("space.card", "24px").status == pesAccepted
      vm.save()
      # Most recent first: the token, then the inspector edit, then the tone.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.token == "16px"
      check vm.gap == "8px"
      check vm.tone == "success"
      vm.save()
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.gap == "4px"
      check vm.tone == "success"
      vm.save()
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.tone == "neutral"
      vm.save()
      check project.files[ComponentFile] == ComponentOriginal
      check project.files[TokenFile] == TokenOriginal
      # Redo replays them in the order they were made.
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.tone == "success"
      check vm.gap == "4px"
      vm.save()
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.gap == "8px"
      check vm.token == "16px"
      vm.save()
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.token == "24px"
      vm.save()
      check project.files[ComponentFile].contains("badge.tone=success")
      check project.files[ComponentFile].contains("badge.gap=8px")
      check project.files[TokenFile] == "space.card=24px\n"
      dispose()

  test "a new edit of any kind ends redo":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      vm.selectBadge()
      check vm.editComponentProperty("StatusBadge", "default", "tone",
        "success").status == pesAccepted
      vm.save()
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      check vm.commandAvailable(eckRedo)
      vm.editGap("8px")
      vm.save()
      check not vm.commandAvailable(eckRedo)
      check vm.runEditorCommand(eckRedo).status != ecsSucceeded
      check vm.tone == "neutral"
      check vm.inspector.pendingSourceEdits.val.len == 0
      # Undo still walks back the inspector edit, then nothing else redoes.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.gap == "4px"
      dispose()

suite "Redo after a write":
  test "component: two choices written together, undone, then redone":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.editComponentProperty("StatusBadge", "default", "tone",
        "success").status == pesAccepted
      check vm.editComponentProperty("StatusBadge", "default", "tone",
        "warning").status == pesAccepted
      vm.save()
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      check project.files[ComponentFile].contains("badge.tone=success")
      # The earlier choice was written after this edit's undo, so the undo's
      # receipt no longer describes the file. Redo still has to work.
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.tone == "warning"
      vm.save()
      check project.files[ComponentFile] ==
        ComponentOriginal.replace("tone=neutral", "tone=warning")
      # And the history stays walkable both ways.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      check project.files[ComponentFile].contains("badge.tone=success")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      check project.files[ComponentFile] == ComponentOriginal
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      vm.save()
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      vm.save()
      check project.files[ComponentFile] ==
        ComponentOriginal.replace("tone=neutral", "tone=warning")
      dispose()

  test "inspector: two edits written together, undone, then redone":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      vm.selectBadge()
      vm.editGap("8px")
      vm.editGap("12px")
      vm.save()
      check project.files[ComponentFile].contains("badge.gap=12px")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      check vm.gap == "8px"
      check project.files[ComponentFile].contains("badge.gap=8px")
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.gap == "12px"
      vm.save()
      check project.files[ComponentFile] ==
        ComponentOriginal.replace("gap=4px", "gap=12px")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      check project.files[ComponentFile] == ComponentOriginal
      dispose()

  test "a redo whose value is gone is refused at the keystroke":
    ## Someone else changed the line the undo restored. Nothing identifies
    ## where the redo should write, so it is refused before anything moves,
    ## and the reason is shown.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject()
      let vm = newEditor(project)
      check vm.editComponentProperty("StatusBadge", "default", "tone",
        "success").status == pesAccepted
      vm.save()
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      project.files[ComponentFile] =
        ComponentOriginal.replace("tone=neutral", "tone=danger")
      let refused = vm.runEditorCommand(eckRedo)
      check refused.status == ecsFailed
      check refused.diagnostic.contains("Redo refused")
      check vm.workspaceEditDiagnostics.val.len == 1
      check vm.tone == "neutral"
      check vm.variants.redoStack.val.len == 1
      check vm.inspector.pendingSourceEdits.val.len == 0
      check project.files[ComponentFile] ==
        ComponentOriginal.replace("tone=neutral", "tone=danger")
      dispose()
