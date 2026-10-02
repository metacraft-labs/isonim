## Shared typed editor command/control host. Owns validation, revision tracking,
## deduplication and user approval; renderer and HTTP layers only deliver requests.
## No browser script evaluation and no synthetic source-operation success.
import std/[json, options, tables]
import isonim/core/signals
import isonim/editor/[types, viewmodels]
import isonim/editor/streaming_preview

export types

proc hasDurableSourceControl(vm: EditorVM): bool =
  vm.controlAsyncCommandAdapter != nil or
    (vm.workspaceEditAdapter != nil and vm.workspaceEditAdapter.durableSourceControl and
      vm.workspaceEditAdapter.compile != nil and vm.workspaceEditAdapter.reloadPreview != nil)

proc controlStoryId*(story: StoryRef): string =
  storyIdFor(story)

proc controlState*(vm: EditorVM): JsonNode =
  var stories = newJArray()
  for group in vm.sidebar.groups.val:
    for index, item in group.items:
      let story = StoryRef(group: item.group, name: item.name, kind: item.kind, index: index)
      stories.add(%* {"id": controlStoryId(story), "group": story.group,
        "name": story.name, "kind": $story.kind})
  var elements = newJArray()
  for row in vm.inspector.layers.val:
    elements.add(%* {"id": row.id, "parentId": row.parentId, "label": row.label,
      "tag": row.tag, "sourceFile": row.sourceFile, "sourceLine": row.sourceLine})
  var capabilities = %*["state", "stories", "elements", "open-story", "viewport",
    "open-panel", "select", "command", "wait"]
  if vm.controlFocusAdapter != nil: capabilities.add %"focus"
  if vm.controlHighlightAdapter != nil: capabilities.add %"highlight"
  # Typed source creation/build require an explicitly durable host boundary.
  if vm.workspacePermissions.val.writeSource and vm.workspaceEditAdapter != nil:
    capabilities.add %"save"
    capabilities.add %"revert"
    capabilities.add %"undo"
    capabilities.add %"redo"
  if vm.hasDurableSourceControl() and vm.workspacePermissions.val.writeSource:
    capabilities.add %"build"
    if vm.workspacePermissions.val.createStory: capabilities.add %"create-story"
  if vm.controlCaptureAdapter != nil and vm.platform.val == pbWeb: capabilities.add %"capture-preview"
  var fixtures = newJArray()
  for variant in vm.controlSourceFixtures:
    for state in variant.stateControls:
      fixtures.add(%* {"component": variant.component, "variant": variant.variantKey, "state": state.key, "sourceFile": state.sourceFile})
  var conversations = newJArray()
  for session in vm.chats.val:
    conversations.add(%* {"id": session.id, "title": session.title.val,
      "backendSessionId": session.vm.controlConversationId.val,
      "active": session.id == vm.activeChatId.val,
      "state": session.vm.connectionState.val})
  %* {"workspace": vm.workspaceId, "permissions": %vm.workspacePermissions.val, "instance": vm.controlInstanceId,
    "revision": vm.controlRevision, "storyId": controlStoryId(vm.selectedStory.val),
    "view": $vm.activeView.val, "mode": $vm.editMode.val,
    "panels": %vm.panels.val, "surface": $vm.surfaceSig.val,
    "rightSidebarTab": $vm.rightSidebarTab.val,
    "selection": vm.inspector.selectedElement.val.id,
    "focus": vm.controlFocusTarget.val, "highlight": vm.controlHighlightTarget.val,
    "viewport": vm.viewport.val.slug, "approvalRequired": vm.agentControlApproval.val,
    "buildStage": $vm.workspaceEditStage.val,
    "previewGeneration": vm.livePreviewReloadGeneration.val,
    "fixtures": fixtures, "buildDiagnostics": %vm.workspaceEditDiagnostics.val,
    "conversations": conversations, "capabilities": capabilities, "stories": stories, "elements": elements}

proc refreshControlRevision*(vm: EditorVM): int =
  ## Read production signals on every admission/application/approval. Human UI
  ## actions share these signals, so a request cannot rely on an old RPC-only counter.
  var state = vm.controlState()
  state.delete("revision")
  # Session activity is observable but is not a change to the target view/project.
  state.delete("conversations")
  state["permissions"] = %vm.workspacePermissions.val
  state["adapterReady"] = %vm.sourceAdapterReady.val
  state["pendingEdits"] = %vm.inspector.pendingSourceEdits.val
  state["selectedElement"] = %vm.inspector.selectedElement.val
  let fingerprint = $state
  if vm.controlFingerprint.len == 0:
    vm.controlFingerprint = fingerprint
  elif vm.controlFingerprint != fingerprint:
    inc vm.controlRevision
    vm.controlFingerprint = fingerprint
  vm.controlRevision

proc controlSnapshot*(vm: EditorVM): JsonNode =
  discard vm.refreshControlRevision()
  vm.controlState()

proc validateCommandPayload(node: JsonNode) =
  if node == nil or node.kind != JObject:
    raise newException(ValueError, "Command object required.")
  for key, value in node:
    if key notin ["workspace", "instance", "epoch", "conversation", "commandId", "command", "storyId", "target", "viewport", "select", "focus", "highlight", "component", "variantKey", "stateKey", "expectedRevision"]:
      raise newException(ValueError, "Unknown command field: " & key)
    if key in ["select", "focus", "highlight"] and value.kind != JBool:
      raise newException(ValueError, "Boolean command field required: " & key)
    if key == "expectedRevision" and value.kind != JInt:
      raise newException(ValueError, "Integer revision required.")
    if key notin ["select", "focus", "highlight", "expectedRevision"] and value.kind != JString:
      raise newException(ValueError, "String command field required: " & key)

proc commandRequest*(node: JsonNode): EditorCommandRequest =
  validateCommandPayload(node)
  let operation = node{"command"}.getStr()
  case operation
  of "create-story": result.kind = eckCreateStory
  of "build": result.kind = eckBuildProject
  of "capture-preview": result.kind = eckCapturePreview
  of "open-story": result.kind = eckOpenStory
  of "viewport": result.kind = eckSetViewport
  of "open-panel": result.kind = eckOpenPanel
  of "select": result.kind = eckSelectItem
  of "focus": result.kind = eckFocusTarget
  of "highlight": result.kind = eckHighlightItem
  of "save": result.kind = eckSave
  of "revert": result.kind = eckRevert
  of "undo": result.kind = eckUndo
  of "redo": result.kind = eckRedo
  of "view": result.kind = eckInspect
  of "edit": result.kind = eckEdit
  of "comment": result.kind = eckComment
  else: raise newException(ValueError, "Unsupported editor command: " & operation)
  result.component = node{"component"}.getStr()
  result.variantKey = node{"variantKey"}.getStr()
  result.stateKey = node{"stateKey"}.getStr()
  result.storyId = node{"storyId"}.getStr()
  result.target = node{"target"}.getStr()
  result.viewportSlug = node{"viewport"}.getStr()
  result.select = node{"select"}.getBool(operation == "select")
  result.focus = node{"focus"}.getBool(operation == "focus")
  result.highlight = node{"highlight"}.getBool(operation == "highlight")

proc findControlStory(vm: EditorVM; id: string): Option[StoryRef] =
  for group in vm.sidebar.groups.val:
    for index, item in group.items:
      let story = StoryRef(group: item.group, name: item.name, kind: item.kind, index: index)
      if controlStoryId(story) == id: return some(story)

proc evaluateCommand*(vm: EditorVM; request: EditorCommandRequest): EditorCommandState =
  var failure = ""
  case request.kind
  of eckCreateStory, eckBuildProject:
    if not vm.workspacePermissions.val.writeSource or
        (request.kind == eckCreateStory and not vm.workspacePermissions.val.createStory):
      failure = "This workspace does not permit source creation/build."
    elif not vm.hasDurableSourceControl():
      failure = "No explicitly durable source/build adapter is available."
    elif request.kind == eckCreateStory and (request.component.len == 0 or request.variantKey.len == 0 or request.stateKey.len == 0):
      failure = "Component, variant and state are required."
  of eckCapturePreview:
    if vm.controlCaptureAdapter == nil or vm.platform.val != pbWeb: failure = "This renderer cannot capture an HTML preview."
  of eckOpenStory:
    if vm.findControlStory(request.storyId).isNone: failure = "Unknown story ID."
  of eckSetViewport:
    var found = false
    for viewport in allBuiltinViewports():
      if viewport.slug == request.viewportSlug: found = true
    if not found: failure = "Unknown viewport."
  of eckOpenPanel:
    if request.target notin ["assistant", "inspector", "sidebar", "preview"]:
      failure = "Unknown panel."
  of eckFocusTarget:
    if vm.controlFocusAdapter == nil: failure = "This host has no focus renderer."
    elif request.target notin ["composer", "sidebar-search", "preview", "inspector-search"]:
      failure = "Unknown focus target."
  of eckSelectItem, eckHighlightItem:
    var found = false
    for row in vm.inspector.layers.val:
      if row.id == request.target: found = true
    if not found: failure = "Unknown element ID."
    if request.highlight and vm.controlHighlightAdapter == nil:
      failure = "This host has no highlight renderer."
    if request.focus and vm.controlSelectionAdapter == nil:
      failure = "This host has no element focus renderer."
  of eckSave, eckRevert, eckUndo, eckRedo:
    if not vm.workspacePermissions.val.writeSource:
      failure = "This workspace is read-only for source changes."
    elif vm.workspaceEditAdapter == nil:
      failure = "No durable workspace edit adapter is available."
    else: return vm.evaluateCommand(request.kind)
  of eckEdit, eckComment, eckInspect:
    return vm.evaluateCommand(request.kind)
  else: failure = "Unsupported capability."
  EditorCommandState(kind: request.kind, label: commandLabel(request.kind),
    status: if failure.len == 0: ecsAvailable else: ecsDisabled, diagnostic: failure)

proc runEditorCommand*(vm: EditorVM; request: EditorCommandRequest): EditorCommandState =
  result = vm.evaluateCommand(request)
  if result.status != ecsAvailable: return
  case request.kind
  of eckCreateStory, eckBuildProject:
    if vm.controlAsyncCommandAdapter != nil:
      result.status = ecsRunning
      return
    if request.kind == eckBuildProject:
      # General authored edits are already on disk. Completion includes publication,
      # but a failed build must not undo those independent edits or the old preview.
      vm.workspaceEditDiagnostics.val = @[]
      var completed: seq[WorkspaceOperationResult]
      for stage in [wesCompiling, wesReloading]:
        vm.workspaceEditStage.val = stage
        var operation: WorkspaceOperationResult
        try:
          operation = if stage == wesCompiling: vm.workspaceEditAdapter.compile(@[])
            else: vm.workspaceEditAdapter.reloadPreview(@[], false)
        except CatchableError as error:
          operation = WorkspaceOperationResult(ok: false, message: error.msg)
        if not operation.ok:
          let kind = if stage == wesCompiling: wedCompileFailed else: wedReloadFailed
          var diagnostics = operation.diagnostics
          if operation.message.len > 0 or diagnostics.len == 0:
            diagnostics.add WorkspaceEditDiagnostic(kind: kind, message:
              if operation.message.len > 0: operation.message
              elif stage == wesCompiling: "Workspace compilation failed."
              else: "Workspace preview publication failed.")
          vm.workspaceEditStage.val = wesFailed
          vm.workspaceEditDiagnostics.val = diagnostics
          result.status = ecsFailed
          for diagnostic in diagnostics: result.diagnostic.add diagnostic.message & "\n"
          return
        completed.add operation
      vm.workspaceEditGeneratedArtifacts.val = completed[0].generatedArtifacts & completed[1].generatedArtifacts
      vm.workspaceEditRequiredTestCommands.val = completed[0].requiredTestCommands & completed[1].requiredTestCommands
      vm.workspaceEditReviewDiagnostics.val = completed[0].reviewDiagnostics & completed[1].reviewDiagnostics
      vm.workspaceEditStage.val = wesClean
      vm.livePreviewReloadGeneration.val = vm.livePreviewReloadGeneration.val + 1
      result.status = ecsSucceeded
      return
    let variants = vm.variants.variants.val
    let undo = vm.variants.undoStack.val
    let redo = vm.variants.redoStack.val
    let selected = vm.variants.selectedVariant.val
    let variantDiagnostics = vm.variants.diagnostics.val
    let stateDiagnostics = vm.variants.stateDiagnostics.val
    let accumulated = vm.chat.accumulatedEdits.val
    let sourcePreviews = vm.inspector.sourcePreviews.val
    let editDiagnostics = vm.inspector.editDiagnostics.val
    let conflicts = vm.inspector.conflicts.val
    let plans = vm.inspector.pendingSourceEdits.val
    let staged = vm.createStoryForComponentState(request.component, request.variantKey, request.stateKey)
    if staged.status != pesAccepted:
      result.status = ecsFailed
      result.diagnostic = "Unknown component/state fixture."
      return
    var applied: WorkspaceEditResult
    try:
      applied = vm.applyWorkspaceFileEdits()
    except CatchableError as error:
      applied = WorkspaceEditResult(ok: false, stage: wesFailed,
        diagnostics: @[WorkspaceEditDiagnostic(kind: wedWriteFailed, message: error.msg)])
      vm.workspaceEditStage.val = wesFailed
      vm.workspaceEditDiagnostics.val = applied.diagnostics
    if not applied.ok:
      vm.variants.variants.val = variants
      vm.variants.undoStack.val = undo
      vm.variants.redoStack.val = redo
      vm.variants.selectedVariant.val = selected
      vm.variants.diagnostics.val = variantDiagnostics
      vm.variants.stateDiagnostics.val = stateDiagnostics
      vm.chat.accumulatedEdits.val = accumulated
      vm.inspector.sourcePreviews.val = sourcePreviews
      vm.inspector.editDiagnostics.val = editDiagnostics
      vm.inspector.conflicts.val = conflicts
      vm.inspector.pendingSourceEdits.val = plans
      result.status = ecsFailed
      for diagnostic in applied.diagnostics: result.diagnostic.add diagnostic.message & "\n"
      return
  of eckCapturePreview: discard
  of eckOpenStory:
    discard vm.selectStory(vm.findControlStory(request.storyId).get)
  of eckSetViewport:
    vm.changeViewport(builtinViewportFromSlug(request.viewportSlug))
  of eckOpenPanel:
    let panels = vm.panels.val
    if request.target == "sidebar":
      vm.panels.val = PanelVisibility(sidebar: true, inspector: panels.inspector)
    elif request.target == "assistant":
      vm.panels.val = PanelVisibility(sidebar: panels.sidebar, inspector: true)
      vm.setEditMode(emView)
    elif request.target == "inspector":
      vm.panels.val = PanelVisibility(sidebar: panels.sidebar, inspector: true)
      vm.setEditMode(emEdit)
    else: vm.surfaceSig.val = sPreview
  of eckFocusTarget:
    if vm.controlFocusAdapter != nil and not vm.controlFocusAdapter(request.target):
      result.status = ecsFailed
      result.diagnostic = "The requested focus target is not mounted or visible."
      return
    vm.controlFocusTarget.val = request.target
  of eckSelectItem, eckHighlightItem:
    # Validate rendering before changing selection; failed highlighting is atomic.
    if request.focus and not vm.controlSelectionAdapter(request.target, request.focus, request.highlight):
      result.status = ecsFailed
      result.diagnostic = "The requested selection/focus target is not rendered."
      return
    if request.highlight and not request.focus and vm.controlHighlightAdapter != nil and
        not vm.controlHighlightAdapter(request.target):
      result.status = ecsFailed
      result.diagnostic = "The requested highlight target is not rendered."
      return
    if request.select and not vm.selectInspectorElementById(request.target):
      result.status = ecsFailed
      result.diagnostic = "Element selection failed."
      return
    if request.highlight: vm.controlHighlightTarget.val = request.target
    if request.focus: vm.controlFocusTarget.val = "element:" & request.target
  else:
    return vm.runEditorCommand(request.kind)
  result.status = ecsSucceeded
  discard vm.refreshControlRevision()

proc recordControlOperation(vm: EditorVM; id: string; record: JsonNode) =
  vm.controlOperations[id] = record
  var activity: seq[JsonNode]
  for existing in vm.controlActivity.val:
    if existing{"operationId"}.getStr() != id: activity.add existing
  activity.add record
  vm.controlActivity.val = activity

proc applyControlOperation(vm: EditorVM; record: JsonNode): JsonNode =
  let request = record["request"]
  let revision = vm.refreshControlRevision()
  result = record.copy()
  if request{"expectedRevision"}.getInt(-1) != revision:
    result["status"] = %"failed"
    result["error"] = %"revision_conflict"
  else:
    try:
      let applied = vm.runEditorCommand(commandRequest(request))
      result["status"] = %(if applied.status == ecsSucceeded: "applied" elif applied.status == ecsRunning: "running" else: "failed")
      if applied.status == ecsRunning:
        let operation = result.copy()
        vm.recordControlOperation(record["operationId"].getStr(), operation)
        vm.controlAsyncCommandAdapter(request, proc(ok: bool; data: JsonNode) =
          let id = operation["operationId"].getStr()
          if not vm.controlOperations.hasKey(id) or vm.controlOperations[id]{"status"}.getStr() != "running": return
          var finished = operation.copy()
          finished["status"] = %(if ok: "applied" else: "failed")
          finished["result"] = data
          if not ok:
            finished["error"] = %"source_build_failed"
            finished["diagnostic"] = %data{"diagnostic"}.getStr("Source build failed.")
          finished["revision"] = %vm.refreshControlRevision()
          finished["state"] = vm.controlState()
          vm.recordControlOperation(id, finished))
        return vm.controlOperations[record["operationId"].getStr()]
      if applied.status == ecsSucceeded and commandRequest(request).kind == eckCapturePreview:
        result["result"] = vm.controlCaptureAdapter()
        if result["result"]{"ready"}.getBool() == false:
          result["status"] = %"failed"
          result["error"] = %"preview_not_ready"
      if applied.status notin {ecsSucceeded, ecsRunning}:
        result["error"] = %"capability_or_permission"
        result["diagnostic"] = %applied.diagnostic
    except ValueError as error:
      result["status"] = %"failed"
      result["error"] = %"unsupported_capability"
      result["diagnostic"] = %error.msg
    except CatchableError as error:
      result["status"] = %"failed"
      result["error"] = %"source_build_failed"
      result["diagnostic"] = %error.msg
  result["revision"] = %vm.refreshControlRevision()
  result["state"] = vm.controlState()
  vm.recordControlOperation(record["operationId"].getStr(), result)

proc validateControlRequest(vm: EditorVM; request: JsonNode): JsonNode =
  # Validate before retaining a payload in observable activity/history. Unknown
  # fields (including accidental credentials) must never be echoed or stored.
  try:
    validateCommandPayload(request)
  except ValueError as error:
    return %* {"status": "failed", "error": "unsupported_capability", "diagnostic": error.msg}
  let id = request{"commandId"}.getStr()
  if id.len == 0: return %* {"status": "failed", "error": "missing_command_id"}
  if request{"workspace"}.getStr() != vm.workspaceId or
      request{"instance"}.getStr() != vm.controlInstanceId:
    return %* {"operationId": id, "status": "failed", "error": "stale_target"}
  if vm.controlOperations.hasKey(id):
    let previous = vm.controlOperations[id]
    if previous["request"] != request:
      return %* {"operationId": id, "status": "failed", "error": "command_id_collision"}

proc admitControlOperation*(vm: EditorVM; request: JsonNode): JsonNode =
  result = vm.validateControlRequest(request)
  if result != nil: return
  let id = request["commandId"].getStr()
  if vm.controlOperations.hasKey(id): return vm.controlOperations[id]
  let revision = vm.refreshControlRevision()
  result = %* {"operationId": id, "request": request, "revision": revision,
    "status": "queued"}
  if request{"expectedRevision"}.getInt(-1) != revision:
    result["status"] = %"failed"
    result["error"] = %"revision_conflict"
    vm.recordControlOperation(id, result)
    return
  try:
    let typed = commandRequest(request)
    let evaluated = vm.evaluateCommand(typed)
    if evaluated.status != ecsAvailable:
      result["status"] = %"failed"
      result["error"] = %"capability_or_permission"
      result["diagnostic"] = %evaluated.diagnostic
    elif vm.agentControlApproval.val and typed.kind in
        {eckOpenStory, eckSetViewport, eckOpenPanel, eckFocusTarget, eckSelectItem, eckHighlightItem}:
      result["status"] = %"pending"
    else:
      return vm.applyControlOperation(result)
  except ValueError as error:
    result["status"] = %"failed"
    result["error"] = %"unsupported_capability"
    result["diagnostic"] = %error.msg
  vm.recordControlOperation(id, result)

proc resolveControlApproval*(vm: EditorVM; id: string; approve: bool): JsonNode =
  if not vm.controlOperations.hasKey(id):
    return %* {"status": "failed", "error": "unknown_operation"}
  let record = vm.controlOperations[id]
  if not vm.controlConnected:
    return %* {"status": "failed", "error": "disconnected_instance"}
  if record{"status"}.getStr() != "pending": return record
  if approve: return vm.applyControlOperation(record)
  result = record.copy()
  result["status"] = %"rejected"
  result["error"] = %"denied"
  result["revision"] = %vm.refreshControlRevision()
  vm.recordControlOperation(id, result)

proc revokeControlConversation*(vm: EditorVM; conversation: string) =
  var ids: seq[string]
  for id, record in vm.controlOperations:
    if record{"request", "conversation"}.getStr() == conversation and
        record{"status"}.getStr() in ["queued", "pending", "running"]: ids.add id
  for id in ids:
    var record = vm.controlOperations[id].copy()
    record["status"] = %"rejected"
    record["error"] = %"conversation_closed"
    vm.recordControlOperation(id, record)

proc deliverControlOperation*(vm: EditorVM; operation: JsonNode): JsonNode =
  ## Consume an authenticated browser delivery. Durable server decisions reuse
  ## normal admission/deduplication and approval-time validation; delivery is
  ## never itself proof of application. Repeated deliveries return the same final
  ## VM result without repeating effects.
  let request = operation{"request"}
  result = vm.validateControlRequest(request)
  if result != nil: return
  let id = request["commandId"].getStr()
  # Authoritative denials/revocations must never pass through admission: under
  # automatic policy, admission can execute an unseen command immediately.
  if operation{"status"}.getStr() in ["rejected", "failed"]:
    if operation{"error"}.getStr() == "conversation_closed":
      vm.revokeControlConversation(request{"conversation"}.getStr())
    let notification = operation.copy()
    if notification{"error"} == nil and notification{"approvalDecision"} != nil and
        not notification["approvalDecision"].getBool(): notification["error"] = %"denied"
    notification["operationId"] = %id
    notification["revision"] = %vm.refreshControlRevision()
    if not vm.controlOperations.hasKey(id) or
        vm.controlOperations[id]{"status"}.getStr() in ["queued", "pending", "running"]:
      vm.recordControlOperation(id, notification)
    let previous = vm.controlOperations[id]
    if previous{"status"} == notification{"status"} and previous{"error"} == notification{"error"}:
      return previous
    # A local terminal outcome may have raced revocation. Acknowledge the
    # authoritative server notification without replaying or rewriting effects.
    return notification
  result = vm.admitControlOperation(request)
  if result{"status"}.getStr() != "pending": return
  if operation{"status"}.getStr() == "approved" and operation{"approvalDecision"}.getBool():
    return vm.resolveControlApproval(id, true)
  if operation{"status"}.getStr() == "rejected" and operation{"approvalDecision"} != nil and
      not operation["approvalDecision"].getBool():
    return vm.resolveControlApproval(id, false)
