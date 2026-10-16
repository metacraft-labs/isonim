## Undo/redo of written inspector edits restores exactly the lines each edit
## wrote (isonim-specs issue 2026-10-13-undo-of-an-appended-edit-expects-the-
## bare-value).
##
## Mock justification: the workspace adapter below keeps the project file in
## memory instead of on disk. IsoNim cannot depend on the consumer that owns
## the real writer (metacraft-web), and this test must also execute under the
## strict Node JS backend, which has no filesystem. The adapter implements the
## consumer writer's documented contract and nothing more: an edit with no
## expected old value appends one `# isonim-editor <key> <prop>=<value>` line;
## an expected old value is replaced only where it occurs exactly once, and is
## otherwise refused (whole-value matching is the consumer's own and is
## tested in metacraft-web). Every other part -- EditorVM, the inspector history, the
## journal and the workspace transaction -- is the production code. The real
## consumer writer is exercised by metacraft-web's
## test_backoffice_editor_workspace.nim, and the real browser/bridge round
## trip by the consumer GUI case
## `metacraft_topbar_sibling_padding_undo_restores_only_its_own_marker`.

import std/[options, sequtils, strutils, unittest]

import isonim/core/[owner, signals]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/workspace

const SourceFile = "components.nim"
const Original = "proc topbar() = discard\n"

type MemoryProject = ref object
  content: string
  writes: int
  patchCalls: seq[SourceEditPlan]

proc memoryAdapter(project: MemoryProject): WorkspaceEditAdapter =
  result = WorkspaceEditAdapter(bridgeLabel: "in-memory consumer writer",
    allowMissingExpectedOldValue: true,
    schema: @[WorkspaceEditableSchemaEntry(key: "fixture.components",
      kind: wskSourceMap, file: SourceFile, path: "components", property: "")])
  result.readFile = proc(file: string): WorkspaceReadResult =
    WorkspaceReadResult(ok: file == SourceFile, content: project.content)
  result.writeFile = proc(file, content: string): WorkspaceOperationResult =
    project.content = content
    inc project.writes
    WorkspaceOperationResult(ok: true)
  result.patchFile = proc(plan: SourceEditPlan; content: string;
      schema: WorkspaceEditableSchemaEntry): WorkspacePatchResult =
    project.patchCalls.add plan
    var next = ""
    let hits = if plan.expectedOldValue.len > 0:
        content.count(plan.expectedOldValue) else: 0
    if hits > 1:
      return WorkspacePatchResult(ok: false, diagnostics: @[
        WorkspaceEditDiagnostic(kind: wedPatchFailed,
          message: "ambiguous expected value", file: SourceFile)])
    elif hits == 1:
      # Never reached by these cases (their plans carry no expected value);
      # whole-value matching is the consumer writer's own, tested there.
      next = content.replace(plan.expectedOldValue, plan.newValue)
    else:
      next = content.strip(leading = false) & "\n# isonim-editor " &
        plan.schemaKey & " " & plan.property & "=" & plan.newValue & "\n"
    WorkspacePatchResult(ok: true, patch: WorkspaceFilePatch(file: SourceFile,
      beforeContent: content, afterContent: next))

func marker(edge, value: string): string =
  "# isonim-editor dom.component-topbar.padding-" & edge & " padding-" & edge &
    "=" & value & "\n"

func pad(edge, value: string): PropertyInfo =
  PropertyInfo(name: "padding-" & edge, value: value, origin: poConstant,
    originDetail: "computed:padding-" & edge, sourceFile: SourceFile,
    sourceLine: 1, schemaKey: "dom.component-topbar.padding-" & edge,
    directStyleAllowed: true)

proc newTopbarEditor(project: MemoryProject): EditorVM =
  let story = StoryRef(group: "Operational components", name: "Topbar",
    kind: skComponent)
  let vm = createEditorVM(newEditorWorkspace(
    title = "sibling undo",
    storyGroups = @[StoryGroup(name: story.group, kind: story.kind,
      expanded: true, items: @[StoryItem(name: story.name, kind: story.kind,
        group: story.group)])],
    permissions = EditorWorkspacePermissions(readSource: true,
      writeSource: true),
    editAdapter = memoryAdapter(project),
    initialStory = some(story)))
  check vm.selectInspectorElement(ElementRef(id: "topbar", tag: "header",
    sourceKey: "dom.component-topbar", schemaKey: "dom.component-topbar",
    sourceFile: SourceFile, sourceLine: 1,
    properties: @[pad("top", "0px"), pad("right", "0px"),
      pad("bottom", "0px"), pad("left", "0px")]))
  vm

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

proc padValue(vm: EditorVM; edge: string): string =
  for prop in vm.inspector.selectedElement.val.properties:
    if prop.name == "padding-" & edge:
      return prop.value

suite "Inspector undo restores the lines its own write produced":
  test "undo of an appended sibling edit with an equal value keeps the other edit":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      vm.editPad("top", "6px")
      vm.save()
      let afterTop = Original & marker("top", "6px")
      check project.content == afterTop
      vm.editPad("left", "6px")
      vm.save()
      let afterBoth = afterTop & marker("left", "6px")
      check project.content == afterBoth
      check vm.stacks == (2, 0)

      # Undo once: only padding-left's own marker line goes.
      let step = vm.inspector.inspectorHistoryStep(redo = false)
      check step.kind == ihsRestoreWrite
      check step.plan.expectedOldValue == ""
      check step.plan.restoreWrite.after == marker("left", "6px")
      check step.plan.restoreWrite.before == ""
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.stacks == (1, 1)
      check vm.padValue("left") == "0px"
      check vm.padValue("top") == "6px"
      let patchesBeforeUndo = project.patchCalls.len
      vm.save()
      check project.content == afterTop
      # The restoration never asks the writer to find a value.
      check project.patchCalls.len == patchesBeforeUndo

      # Redo appends padding-left's line again; bytes equal the original edit.
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.stacks == (2, 0)
      vm.save()
      check project.content == afterBoth

      # Undo twice: back to the original bytes, one edit at a time.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      check project.content == afterTop
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      check project.content == Original
      check vm.stacks == (0, 2)
      check vm.padValue("top") == "0px"
      check vm.padValue("left") == "0px"

      # And forwards again through both.
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      vm.save()
      check project.content == afterTop
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      vm.save()
      check project.content == afterBoth
      dispose()

  test "single appended edit undo and redo regression":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      vm.editPad("top", "6px")
      vm.save()
      let afterTop = Original & marker("top", "6px")
      check project.content == afterTop
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      check project.content == Original
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      vm.save()
      check project.content == afterTop
      check vm.stacks == (1, 0)
      dispose()

  test "undo before the write lands drops the pending plan and writes nothing":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      vm.editPad("top", "6px")
      vm.save()
      vm.editPad("left", "6px")
      check vm.inspector.inspectorHistoryStep(redo = false).kind == ihsDropPending
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      vm.save()
      check project.content == Original & marker("top", "6px") &
        marker("left", "6px")
      dispose()

  test "an intervening change to the written line refuses undo without mutation":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      vm.editPad("top", "6px")
      vm.save()
      vm.editPad("left", "6px")
      vm.save()
      # Someone else rewrote padding-left's line after it was written.
      project.content = project.content.replace(marker("left", "6px"),
        marker("left", "7px"))
      let external = project.content
      let writes = project.writes
      let beforeElement = vm.inspector.selectedElement.val
      let refused = vm.runEditorCommand(eckUndo)
      check refused.status == ecsFailed
      check refused.diagnostic.startsWith("Undo refused")
      check vm.inspector.editDiagnostics.val.anyIt(
        it.kind == pedSourceConflict and it.message == refused.diagnostic)
      check vm.workspaceEditDiagnostics.val.anyIt(it.kind == wedSourceConflict)
      check vm.stacks == (2, 0)
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.selectedElement.val == beforeElement
      check project.content == external
      check project.writes == writes
      dispose()

  test "an identical pre-existing line is never restored in place of the written one":
    # Review probe P1: the third edit wrote a copy of a line the first edit
    # had already written. Someone else deletes the third edit's copy; the
    # single remaining copy is the FIRST edit's, which nobody undid.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      vm.editPad("left", "6px")
      vm.save()
      vm.editPad("left", "8px")
      vm.save()
      vm.editPad("left", "6px")
      vm.save()
      check project.content == Original & marker("left", "6px") &
        marker("left", "8px") & marker("left", "6px")
      project.content = Original & marker("left", "6px") & marker("left", "8px")
      let external = project.content
      let writes = project.writes
      let refused = vm.runEditorCommand(eckUndo)
      check refused.status == ecsFailed
      check refused.diagnostic.startsWith("Undo refused")
      check vm.stacks == (3, 0)
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.padValue("left") == "6px"
      check vm.applyWorkspaceFileEdits().ok
      check project.content == external
      check project.writes == writes
      dispose()

  test "a pending same-file restoration is simulated before the next undo moves":
    # Review probe P2: the first undo's restoration has not been written yet
    # (auto-save debounce) when the file changes and a second undo follows.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      vm.editPad("top", "6px")
      vm.save()
      vm.editPad("left", "6px")
      vm.save()
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.inspector.pendingSourceEdits.val.len == 1
      project.content = project.content & marker("top", "6px")
      let external = project.content
      let refused = vm.runEditorCommand(eckUndo)
      check refused.status == ecsFailed
      check refused.diagnostic.startsWith("Undo refused")
      check vm.stacks == (1, 1)
      check vm.padValue("top") == "6px"
      check vm.inspector.pendingSourceEdits.val.len == 1
      check project.content == external
      dispose()

  test "two edits to the same slot saved together undo one at a time":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      vm.editPad("left", "6px")
      vm.editPad("left", "8px")
      vm.save()
      # Only the later plan was written; the earlier one was superseded.
      check project.content == Original & marker("left", "8px")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.padValue("left") == "6px"
      vm.save()
      check project.content == Original & marker("left", "6px")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.padValue("left") == "0px"
      vm.save()
      check project.content == Original
      dispose()

  test "a written edit with no receipt and no verified value is refused":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let before = ElementRef(id: "topbar", properties: @[pad("left", "0px")])
      var after = before
      after.properties[0].value = "6px"
      let plan = SourceEditPlan(file: SourceFile, property: "padding-left",
        oldValue: "0px", newValue: "6px", historyId: 7,
        schemaKey: "dom.component-topbar.padding-left")
      vm.inspector.undoStack.val = @[CSSPropertyEditTransaction(
        sourceEdit: plan, beforeElement: before, afterElement: after,
        saved: true)]
      let step = vm.inspector.inspectorHistoryStep(redo = false)
      check step.kind == ihsRefuse
      check not vm.inspector.undoCssPropertyEdit()
      check vm.inspector.undoStack.val.len == 1
      check vm.inspector.redoStack.val.len == 0
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.editDiagnostics.val.len == 1
      # A value-verified forward write keeps its value-verified inverse.
      var verified = plan
      verified.expectedOldValue = "0px"
      vm.inspector.undoStack.val = @[CSSPropertyEditTransaction(
        sourceEdit: verified, beforeElement: before, afterElement: after,
        saved: true)]
      let inverse = vm.inspector.inspectorHistoryStep(redo = false)
      check inverse.kind == ihsInvertPlan
      check inverse.plan.expectedOldValue == "6px"
      check inverse.plan.newValue == "0px"
      dispose()

suite "Source write receipts":
  test "receipts are whole lines and restoration is exact or refused":
    let before = "a\nb\n"
    let after = "a\nb\n" & marker("left", "6px")
    let receipt = sourceWriteReceipt(SourceFile, before, after)
    check receipt.offset == before.len
    check receipt.before == ""
    check receipt.after == marker("left", "6px")
    check restoreSourceWrite(after, receipt).content == before

    let rewrite = sourceWriteReceipt(SourceFile, "x: 4px;\ny: 6px;\n",
      "x: 4px;\ny: 8px;\n")
    check rewrite.before == "y: 6px;\n"
    check rewrite.after == "y: 8px;\n"

    # The written line moved but is still unique: restored where it now is.
    let moved = "header\n" & after
    let relocated = restoreSourceWrite(moved, receipt)
    check relocated.ok
    check relocated.content == "header\n" & before
    # Duplicated by somebody else: cannot tell which one this edit wrote.
    let doubled = after & marker("left", "6px") & "z\n"
    let ambiguous = restoreSourceWrite(doubled, receipt)
    check not ambiguous.ok
    check ambiguous.content == doubled
    check "2 times" in ambiguous.message
    # Gone: refused.
    let gone = restoreSourceWrite(before & "z\n", receipt)
    check not gone.ok
    check gone.message.startsWith("Undo refused")
    # Unique now but not when written (review probe P3): refused.
    let duplicated = "x\n" & marker("left", "6px")
    let written = duplicated & marker("left", "6px")
    let notUnique = sourceWriteReceipt(SourceFile, duplicated, written)
    check not notUnique.uniqueWhenWritten
    check receipt.uniqueWhenWritten
    let preexisting = restoreSourceWrite("x\n" & marker("left", "6px") & "y\n",
      notUnique)
    check not preexisting.ok
    check "not unique when written" in preexisting.message
    # Exact (unchanged file) restoration needs no uniqueness.
    check restoreSourceWrite(written, notUnique).content == duplicated
    # A value-only match is never a line match.
    check not restoreSourceWrite("padding-left=6px\n", receipt).ok
