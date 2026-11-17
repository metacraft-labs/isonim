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
## tested in metacraft-web). A case can make it refuse writes
## (`refuseWrites`), standing for a project whose write fails, so that an
## accepted agent proposal's plan stays pending. Every other part -- EditorVM, the inspector history, the
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
  refuseWrites: bool

proc memoryAdapter(project: MemoryProject): WorkspaceEditAdapter =
  result = WorkspaceEditAdapter(bridgeLabel: "in-memory consumer writer",
    allowMissingExpectedOldValue: true,
    schema: @[WorkspaceEditableSchemaEntry(key: "fixture.components",
      kind: wskSourceMap, file: SourceFile, path: "components", property: "")])
  result.readFile = proc(file: string): WorkspaceReadResult =
    WorkspaceReadResult(ok: file == SourceFile, content: project.content)
  result.writeFile = proc(file, content: string): WorkspaceOperationResult =
    if project.refuseWrites:
      return WorkspaceOperationResult(ok: false, diagnostics: @[
        WorkspaceEditDiagnostic(kind: wedWriteFailed,
          message: "write refused", file: file)])
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
      # Each edit is written in history order, as two separate writes would
      # write them (isonim-pm issue 2026-10-23-undo-is-refused-after-a-
      # batched-write-to-a-single-line-rule).
      check project.content == Original & marker("left", "6px") &
        marker("left", "8px")
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

  test "a restore is refused wherever only the declaration text identifies it":
    # The review of isonim-pm issue 2026-10-23-undo-is-refused-after-a-
    # batched-write-to-a-single-line-rule probed a declaration-granular
    # fallback (since removed) with edits made outside the editor. Every one
    # of these is identifiable only by its text, out of its rule or its
    # line, so the restore is refused and the file is left as it is.
    proc refusedUnchanged(now: string; receipt: SourceWriteReceipt) =
      let restored = restoreSourceWrite(now, receipt)
      check not restored.ok
      check restored.content == now
      check restored.message.startsWith("Undo refused")
    # The written declaration's text is now only in another rule.
    let a1Before = ".a { gap: 4px; color: red; }\n.b { gap: 2px; color: green; }\n"
    let a1After = a1Before.replace("color: red", "color: blue")
    refusedUnchanged(a1After.replace(".a { gap: 4px; color: blue;",
      ".a { gap: 4px; color: black;").replace("color: green", "color: blue"),
      sourceWriteReceipt(SourceFile, a1Before, a1After))
    # A removal whose neighbour now sits only in another rule.
    let a3Before = ".a { gap: 4px; overflow: visible; color: red; }\n.b { gap: 2px; }\n"
    let a3After = a3Before.replace(" overflow: visible;", "")
    refusedUnchanged(".a { gap: 8px; color: black; }\n.b { gap: 2px; color: red; }\n",
      sourceWriteReceipt(SourceFile, a3Before, a3After))
    # The written declaration's text survives only inside a comment.
    let a4Before = ".a { gap: 4px; color: red; }\n"
    let a4After = a4Before.replace("color: red", "color: blue")
    refusedUnchanged(".a { gap: 8px; color: black; /* was; color: blue; */ }\n",
      sourceWriteReceipt(SourceFile, a4Before, a4After))
    # Minified: the text is now only in another rule.
    let a7Before = ".a{gap:4px;color:red}.b{gap:4px;color:green}"
    let a7After = a7Before.replace("color:red", "color:blue")
    refusedUnchanged(a7After.replace(".b{gap:4px;color:green}",
      ".b{gap:4px;color:green;color:blue}").replace(".a{gap:4px;color:blue}",
      ".a{gap:4px;color:x}"), sourceWriteReceipt(SourceFile, a7Before, a7After))
    # A whole-line removal whose only anchor left is a lone closing brace,
    # in a rule since replaced by another.
    let a9Before = ".a {\n  gap: 4px;\n  overflow: visible;\n}\n"
    let a9After = a9Before.replace("  overflow: visible;\n", "")
    refusedUnchanged(".z {\n  gap: 9px;\n}\n",
      sourceWriteReceipt(SourceFile, a9Before, a9After))
    # A key=value schema file: a removed line, the line after it changed.
    let a12Before = "badge.tone=neutral\nbadge.label=Customers\n" &
      "badge.loading=false\nbadge.gap=4px\n"
    let a12After = a12Before.replace("badge.loading=false\n", "")
    refusedUnchanged(a12After.replace("badge.gap=4px", "badge.gap=8px"),
      sourceWriteReceipt(SourceFile, a12Before, a12After))
    # A one-line rule whose line another edit changed: the line is what
    # identifies the write, so this is refused too. The editor's own batched
    # writes never produce it: each entry is written in history order, so an
    # undo in history order always finds the file exactly as its write left
    # it (tests/test_editor_save_pipeline.nim, the one-line-rule suites).
    let lineBefore = ".card { gap: 4px; wrap: nowrap; overflow: visible; }\n"
    let lineAfter = ".card { gap: 4px; wrap: wrap; overflow: visible; }\n"
    refusedUnchanged(lineAfter.replace("overflow: visible", "overflow: hidden"),
      sourceWriteReceipt(SourceFile, lineBefore, lineAfter))

suite "Plans no history entry owns":
  ## An accepted agent proposal journals plans that belong to no history
  ## entry. They still replace a pending plan for the same slot, and a
  ## history entry's plan still replaces a pending plan of theirs
  ## (`replacesJournaledPlan`); only plans of two different entries are each
  ## written as their own step (isonim-pm issue 2026-10-23-undo-is-refused-
  ## after-a-batched-write-to-a-single-line-rule). The appending writer makes
  ## the difference visible: one marker line per write.
  proc proposal(vm: EditorVM; plan: SourceEditPlan): string =
    vm.chat.addAgentEditProposal(AgentEditProposal(title: "Padding",
      summary: "Set the left padding", sourceEdits: @[plan],
      selectedEditIndexes: @[0], validity: aepvCurrent))

  test "an accepted proposal replaces a pending edit's plan, and undo re-stages that edit":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      vm.editPad("left", "6px")
      check vm.inspector.pendingSourceEdits.val.len == 1
      var proposed = vm.inspector.pendingSourceEdits.val[0]
      proposed.historyId = 0
      proposed.oldValue = "6px"
      proposed.newValue = "8px"
      let accepted = vm.acceptAgentProposedEdit(vm.proposal(proposed))
      check accepted.ok
      # One write: the proposal's plan replaced the pending one.
      check project.content == Original & marker("left", "8px")
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.inspector.undoStack.val.len == 1
      check vm.inspector.undoStack.val[0].superseded
      vm.editPad("left", "10px")
      vm.save()
      check project.content == Original & marker("left", "8px") &
        marker("left", "10px")
      # Undoing the later edit makes the superseded one current again; its
      # value is not on disk, so it is staged and written again.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.padValue("left") == "6px"
      check vm.inspector.pendingSourceEdits.val.len == 2
      vm.save()
      check project.content == Original & marker("left", "8px") &
        marker("left", "6px")
      check not vm.inspector.undoStack.val[0].superseded
      # It was written now, so its own write is undone exactly; the
      # proposal's line, which no history entry owns, stays.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      check project.content == Original & marker("left", "8px")
      dispose()

  # isonim-pm issue 2026-11-15-after-an-accepted-agent-proposal-replaces-a-
  # pending-edit-the-inspector-shows-a-value-the-file-does-not-hold. Editor
  # spec "Saving": edits, their undo and redo keep the inspector, the preview
  # and the source in agreement. Each step below checks all three: the
  # inspector's value, the value the preview was last asked to show, and
  # the file's bytes.
  proc previewed(vm: EditorVM): (string, string) =
    let request = vm.inspector.previewValueRequest.val
    (request.property, request.value)

  proc leftProposal(vm: EditorVM; value: string): string =
    ## A proposal for the declaration the inspector's padding-left row
    ## writes, exactly as that row plans it but owned by no history entry.
    let plan = SourceEditPlan(file: SourceFile, line: 1,
      property: "padding-left", oldValue: vm.padValue("left"),
      newValue: value, originDetail: "computed:padding-left",
      scope: pesLocal, schemaKey: "dom.component-topbar.padding-left",
      conflictKey: SourceFile & ":1:padding-left")
    vm.proposal(plan)

  test "the model follows an accepted proposal over a pending edit, through every undo and redo":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      vm.editPad("left", "6px")
      check vm.padValue("left") == "6px"
      check project.content == Original
      check vm.acceptAgentProposedEdit(vm.leftProposal("8px")).ok
      let p8 = Original & marker("left", "8px")
      check project.content == p8
      check vm.inspector.undoStack.val[0].superseded
      check vm.padValue("left") == "8px"
      check vm.previewed == ("padding-left", "8px")
      vm.editPad("left", "10px")
      vm.save()
      check project.content == p8 & marker("left", "10px")
      check vm.padValue("left") == "10px"
      check vm.inspector.undoStack.val[1].sourceEdit.oldValue == "8px"
      # Undo the later edit: the superseded 6px is current again, staged,
      # shown and written.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.padValue("left") == "6px"
      check vm.previewed == ("padding-left", "6px")
      vm.save()
      check project.content == p8 & marker("left", "6px")
      # Undo the 6px edit: its own line goes, the proposal's stays, and the
      # model shows the proposal's value -- not the 0px it started from.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.padValue("left") == "8px"
      check vm.previewed == ("padding-left", "8px")
      vm.save()
      check project.content == p8
      check vm.stacks == (0, 2)
      # Forwards again through both.
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.padValue("left") == "6px"
      check vm.previewed == ("padding-left", "6px")
      vm.save()
      check project.content == p8 & marker("left", "6px")
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.padValue("left") == "10px"
      check vm.previewed == ("padding-left", "10px")
      vm.save()
      check project.content == p8 & marker("left", "6px") & marker("left", "10px")
      # And back to the proposal.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.padValue("left") == "6px"
      vm.save()
      check project.content == p8 & marker("left", "6px")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.padValue("left") == "8px"
      vm.save()
      check project.content == p8
      dispose()

  test "undoing the superseded edit itself withdraws nothing and keeps the proposal's value":
    # The edit's value never reached disk: the undo moves no byte, and the
    # model keeps showing what the file holds. Redo puts the edit's value
    # back, written over the proposal's.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      vm.editPad("top", "4px")
      vm.editPad("left", "6px")
      check vm.acceptAgentProposedEdit(vm.leftProposal("8px")).ok
      let accepted = Original & marker("top", "4px") & marker("left", "8px")
      check project.content == accepted
      check vm.padValue("left") == "8px"
      check vm.padValue("top") == "4px"
      let writes = project.writes
      let undone = vm.runEditorCommand(eckUndo)
      check undone.status == ecsSucceeded
      check undone.diagnostic == ""
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.padValue("left") == "8px"
      check vm.padValue("top") == "4px"
      check vm.previewed == ("padding-left", "8px")
      vm.save()
      check project.content == accepted
      check project.writes == writes
      # The padding-top edit below it still undoes exactly, and its snapshot
      # carries the proposal's padding-left.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.padValue("top") == "0px"
      check vm.padValue("left") == "8px"
      vm.save()
      check project.content == Original & marker("left", "8px")
      # Redo appends padding-top's line again, after the proposal's.
      let redoneTop = Original & marker("left", "8px") & marker("top", "4px")
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.padValue("top") == "4px"
      check vm.padValue("left") == "8px"
      vm.save()
      check project.content == redoneTop
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.padValue("left") == "6px"
      check vm.previewed == ("padding-left", "6px")
      vm.save()
      check project.content == redoneTop & marker("left", "6px")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.padValue("left") == "8px"
      check vm.padValue("top") == "4px"
      vm.save()
      check project.content == redoneTop
      dispose()

  test "one proposal supersedes two pending edits: redoing both applies each over the one beneath it":
    # Each superseded edit is checked against the value beneath it in
    # history order, so redoing both writes what two separate writes write,
    # and undoing the upper one returns to the lower one's value.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      vm.editPad("left", "6px")
      vm.editPad("left", "7px")
      check vm.inspector.pendingSourceEdits.val.len == 2
      check vm.acceptAgentProposedEdit(vm.leftProposal("8px")).ok
      let p8 = Original & marker("left", "8px")
      check project.content == p8
      check vm.inspector.undoStack.val[0].superseded
      check vm.inspector.undoStack.val[1].superseded
      check vm.padValue("left") == "8px"
      for _ in 0 .. 1:
        check vm.runEditorCommand(eckUndo).status == ecsSucceeded
        check vm.padValue("left") == "8px"
        check vm.previewed == ("padding-left", "8px")
        check vm.inspector.pendingSourceEdits.val.len == 0
      check project.content == p8
      check vm.stacks == (0, 2)
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.padValue("left") == "6px"
      check vm.previewed == ("padding-left", "6px")
      vm.save()
      check project.content == p8 & marker("left", "6px")
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.padValue("left") == "7px"
      check vm.previewed == ("padding-left", "7px")
      check vm.inspector.undoStack.val[1].sourceEdit.oldValue == "6px"
      vm.save()
      check project.content == p8 & marker("left", "6px") & marker("left", "7px")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.padValue("left") == "6px"
      check vm.previewed == ("padding-left", "6px")
      vm.save()
      check project.content == p8 & marker("left", "6px")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.padValue("left") == "8px"
      check vm.previewed == ("padding-left", "8px")
      vm.save()
      check project.content == p8
      dispose()

  test "one proposal supersedes two pending edits: undoing a later edit re-stages them one at a time":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      vm.editPad("left", "6px")
      vm.editPad("left", "7px")
      check vm.acceptAgentProposedEdit(vm.leftProposal("8px")).ok
      let p8 = Original & marker("left", "8px")
      vm.editPad("left", "10px")
      vm.save()
      check project.content == p8 & marker("left", "10px")
      # Undo 10px: only the nearest superseded edit, 7px, is current again,
      # and it is applied over the proposal's value.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.padValue("left") == "7px"
      check vm.previewed == ("padding-left", "7px")
      check vm.inspector.undoStack.val[1].sourceEdit.oldValue == "8px"
      vm.save()
      check project.content == p8 & marker("left", "7px")
      # Undo 7px: its own line goes, and 6px is current again over 8px.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.padValue("left") == "6px"
      check vm.previewed == ("padding-left", "6px")
      check vm.inspector.undoStack.val[0].sourceEdit.oldValue == "8px"
      vm.save()
      check project.content == p8 & marker("left", "6px")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.padValue("left") == "8px"
      vm.save()
      check project.content == p8
      check vm.stacks == (0, 3)
      for (want, written) in [("6px", p8 & marker("left", "6px")),
          ("7px", p8 & marker("left", "6px") & marker("left", "7px")),
          ("10px", p8 & marker("left", "6px") & marker("left", "7px") &
            marker("left", "10px"))]:
        check vm.runEditorCommand(eckRedo).status == ecsSucceeded
        check vm.padValue("left") == want
        check vm.previewed == ("padding-left", want)
        vm.save()
        check project.content == written
      dispose()

  test "while a proposal's write fails, the inspector shows the file's value, not the superseded one":
    # Review RV-5. The superseded 6px is neither on disk nor pending, and
    # the proposal is no history entry: until it is written the inspector
    # and the preview show what the file holds; the failed write is reported
    # in the status bar.
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      vm.editPad("left", "6px")
      check vm.padValue("left") == "6px"
      project.refuseWrites = true
      check not vm.acceptAgentProposedEdit(vm.leftProposal("8px")).ok
      check project.content == Original
      check vm.inspector.undoStack.val[0].superseded
      check vm.padValue("left") == "0px"
      check vm.previewed == ("padding-left", "0px")
      project.refuseWrites = false
      vm.save()
      check project.content == Original & marker("left", "8px")
      check vm.padValue("left") == "8px"
      check vm.previewed == ("padding-left", "8px")
      dispose()

  test "undoing a superseded edit says why nothing moved; other undos say nothing":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      vm.editPad("top", "4px")
      vm.save()
      vm.editPad("left", "6px")
      check vm.acceptAgentProposedEdit(vm.leftProposal("8px")).ok
      check vm.inspector.historyNotice.val == ""
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      let notice = vm.inspector.historyNotice.val
      check notice.startsWith("Undone:")
      check "padding-left" in notice
      check "accepted agent proposal" in notice
      # The next undo is an ordinary one: the note goes.
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.inspector.historyNotice.val == ""
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.inspector.historyNotice.val == ""
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.inspector.historyNotice.val == ""
      # A new edit clears it too.
      vm.save()
      vm.editPad("left", "9px")
      check vm.inspector.historyNotice.val == ""
      dispose()

  test "a pending proposal is not shown until it is written, and an edit over it undoes to the file":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      project.refuseWrites = true
      check not vm.acceptAgentProposedEdit(vm.leftProposal("8px")).ok
      check vm.inspector.pendingSourceEdits.val.len == 1
      check project.content == Original
      check vm.padValue("left") == "0px"
      project.refuseWrites = false
      vm.editPad("left", "6px")
      check vm.padValue("left") == "6px"
      vm.save()
      check project.content == Original & marker("left", "6px")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.padValue("left") == "0px"
      check vm.previewed == ("padding-left", "0px")
      vm.save()
      check project.content == Original
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      check vm.padValue("left") == "6px"
      vm.save()
      check project.content == Original & marker("left", "6px")
      dispose()

  test "a pending proposal that is written later moves the model when it is written":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      project.refuseWrites = true
      check not vm.acceptAgentProposedEdit(vm.leftProposal("8px")).ok
      check vm.padValue("left") == "0px"
      project.refuseWrites = false
      vm.save()
      check project.content == Original & marker("left", "8px")
      check vm.padValue("left") == "8px"
      check vm.previewed == ("padding-left", "8px")
      dispose()

  test "a proposal for another element's declaration leaves this element's model":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      vm.editPad("left", "6px")
      vm.save()
      let plan = SourceEditPlan(file: SourceFile, line: 1,
        property: "padding-left", oldValue: "0px", newValue: "8px",
        scope: pesLocal, schemaKey: "dom.component-sidebar.padding-left",
        conflictKey: SourceFile & ":7:padding-left")
      check vm.acceptAgentProposedEdit(vm.proposal(plan)).ok
      check vm.padValue("left") == "6px"
      check not vm.inspector.undoStack.val[0].superseded
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      check vm.padValue("left") == "0px"
      dispose()

  test "a later edit replaces a proposal's plan that is still pending":
    createRoot proc(dispose: proc()) =
      let project = MemoryProject(content: Original)
      let vm = newTopbarEditor(project)
      let plan = SourceEditPlan(file: SourceFile, line: 1,
        property: "padding-left", oldValue: "0px", newValue: "8px",
        schemaKey: "dom.component-topbar.padding-left",
        conflictKey: SourceFile & ":1:padding-left", scope: pesLocal)
      project.refuseWrites = true
      check not vm.acceptAgentProposedEdit(vm.proposal(plan)).ok
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.inspector.pendingSourceEdits.val[0].historyId == 0
      check project.content == Original
      project.refuseWrites = false
      vm.editPad("left", "6px")
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.inspector.pendingSourceEdits.val[0].historyId > 0
      check vm.inspector.pendingSourceEdits.val[0].conflictKey == plan.conflictKey
      vm.save()
      check project.content == Original & marker("left", "6px")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.save()
      check project.content == Original
      dispose()
