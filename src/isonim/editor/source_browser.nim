## Opt-in thin view over a project's native source/build adapter. No compiler or
## filesystem work runs on the browser thread. Only successful compiled catalogs
## replace preview data; build-start acknowledgement is never completion.
when not defined(js): {.error: "Source browser bridge requires JS".}
import std/[json, options]
import isonim/core/[signals, computation, owner]
import isonim/editor/[viewmodels, workspace, source_catalog, control]

proc attachSourceProject*(vm: EditorVM; base: EditorWorkspace; inspectorEditing = true) =
  ## Native inspector writes are the default. Catalog-only consumers retain
  ## preview edits and native agent commands without claiming source persistence.
  ## An installed native inspector cannot be downgraded during its VM lifetime.
  if not inspectorEditing and vm.hasAsyncSourceProject:
    raise newException(ValueError, "Native inspector editing is already installed.")
  # Retained models can predate these fields. Check their stable JS slots
  # instead of RTTI, preserving every already-installed transaction's state.
  {.emit: ["""
    if (!Object.prototype.hasOwnProperty.call(""", vm, """, 'sourceProjectMappings')) """, vm, """.sourceProjectMappings = null;
    if (!Object.prototype.hasOwnProperty.call(""", vm, """, 'sourceProjectMappingDispose')) """, vm, """.sourceProjectMappingDispose = null;
    if (!Object.prototype.hasOwnProperty.call(""", vm, """, 'sourceProjectOperationSerial')) """, vm, """.sourceProjectOperationSerial = 0;
    if (!Object.prototype.hasOwnProperty.call(""", vm, """, 'sourceProjectBuildInFlight')) """, vm, """.sourceProjectBuildInFlight = false;
  """].}
  vm.hasAsyncSourceProject = inspectorEditing
  if vm.sourceProjectMappings == nil:
    vm.sourceProjectMappings = createSignal(newJArray())
  let editableStyles = vm.sourceProjectMappings
  if vm.sourceProjectMappingDispose != nil:
    vm.sourceProjectMappingDispose()
    vm.sourceProjectMappingDispose = nil
  proc applyCatalog(reply: JsonNode) =
    let manifest = reply{"manifest"}
    if manifest == nil or manifest{"workspace"}.getStr() != vm.workspaceId:
      raise newException(ValueError, "Source project workspace mismatch.")
    let compiled = sourceCatalogWorkspace(reply["catalog"], manifest, base)
    vm.refreshWorkspaceCatalog(compiled)
    vm.controlSourceFixtures = sourceFixtures(manifest)
    if reply{"editableStyles"} != nil: editableStyles.val = reply["editableStyles"]
    vm.sourceAdapterReady.val = true
  if inspectorEditing:
    createRoot proc(dispose: proc()) =
      vm.sourceProjectMappingDispose = dispose
      createRenderEffect proc() =
        let element = vm.inspector.selectedElement.val
        let storyId = controlStoryId(vm.selectedStory.val)
        var selected = element
        var changed = false
        for mapping in editableStyles.val:
          if mapping{"elementId"}.getStr() != element.id or mapping{"storyId"}.getStr() != storyId: continue
          for property in selected.properties.mitems:
            if mapping{"values", property.name} == nil: continue
            let authored = mapping["values"][property.name].getStr()
            let token = mapping{"scope"}.getStr() == "semantic-token"
            let shared = token or mapping{"scope"}.getStr() == "shared-class"
            if shared and (property.schemaKey != mapping{"key"}.getStr() or
                property.sharedCount != mapping{"sharedCount"}.getInt()):
              property.nativeSourceShared = true
              property.nativeSourceToken = token
              property.tokenName = if token: mapping{"tokenName"}.getStr() else: ""
              property.schemaKey = mapping{"key"}.getStr()
              property.sourceFile = mapping{"file"}.getStr()
              property.origin = if token: poThemeToken else: poConstant
              property.originDetail = if token: "Shared token " & property.tokenName else: "Shared rule " & mapping{"selector"}.getStr()
              property.sharedCount = mapping{"sharedCount"}.getInt()
              property.directStyleAllowed = false
              changed = true
            if property.authoredValue != authored:
              property.authoredValue = authored
              changed = true
        if changed: vm.inspector.selectedElement.val = selected

  proc transact(element: ElementRef; property, value, storyId, schemaKey: string;
      done: proc(ok: bool; diagnostic, sourceBefore, sourceAfter: string) {.closure.}; restoreLiteral = "") =
    if vm.sourceProjectBuildInFlight:
      done(false, "Wait for the current source build to complete.", "", "")
      return
    if not vm.workspacePermissions.val.writeSource:
      done(false, "This workspace is read-only for source changes.", "", "")
      return
    if vm.controlSourceTransport == nil:
      done(false, "Source connection unavailable.", "", "")
      return
    var mapping: JsonNode
    for entry in editableStyles.val:
      if entry{"elementId"}.getStr() == element.id and entry{"storyId"}.getStr() == storyId and
          (schemaKey.len == 0 or entry{"key"}.getStr() == schemaKey) and entry{"values", property} != nil:
        if mapping != nil:
          done(false, "Ambiguous editable source ownership.", "", "")
          return
        mapping = entry
    if mapping == nil or mapping{"values", property} == nil:
      done(false, "The editor cannot safely edit this value’s source.", "", "")
      return
    vm.sourceProjectBuildInFlight = true
    inc vm.sourceProjectOperationSerial
    vm.workspaceEditStage.val = wesCompiling
    let request = %* {"command": "inspector-edit",
      "commandId": vm.controlInstanceId & "-inspector-" & $vm.sourceProjectOperationSerial,
      "storyId": storyId, "target": element.id, "schemaKey": mapping{"key"}.getStr(),
      "property": property, "value": value, "expectedValue": mapping["values"][property],
      "expectedSourceHash": mapping{"sourceHash"}.getStr(),
      "viewportWidth": vm.viewport.val.width}
    if restoreLiteral.len > 0: request["sourceValue"] = %restoreLiteral
    vm.controlSourceTransport(request, proc(reply: JsonNode) =
      vm.sourceProjectBuildInFlight = false
      if reply{"ok"}.getBool():
        try:
          applyCatalog(reply)
          vm.workspaceEditStage.val = wesClean
          vm.workspaceEditDiagnostics.val = @[]
          done(true, "", reply{"sourceEdit", "before"}.getStr(), reply{"sourceEdit", "after"}.getStr())
        except CatchableError as error:
          vm.workspaceEditStage.val = wesFailed
          done(false, "Source catalog could not be applied: " & error.msg, "", "")
      else:
        let diagnostic = reply{"diagnostic"}.getStr("Source edit failed.")
        vm.workspaceEditStage.val = wesFailed
        vm.workspaceEditDiagnostics.val = @[WorkspaceEditDiagnostic(kind: wedCompileFailed, message: diagnostic)]
        done(false, diagnostic, "", ""))

  if inspectorEditing:
    vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
        scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
      var shared = false
      var token = false
      for candidate in element.properties:
        if candidate.name == property:
          shared = candidate.nativeSourceShared
          token = candidate.nativeSourceToken
      if element.id != vm.inspector.selectedElement.val.id or
          (shared and scope != (if token: sskSemanticToken else: sskSharedClass)) or (not shared and scope != sskLocalInstance):
        done(false, "The source target or ownership scope changed.")
        return
      let prepared = vm.inspector.preparePropertyEdit(PropertyEditRequest(
        property: property, newValue: value, scope: if shared: pesShared else: pesLocal, origin: peoInspector, kind: pekCss))
      if prepared.outcome.status != pesAccepted:
        done(false, if prepared.outcome.diagnostics.len > 0: prepared.outcome.diagnostics[0].message else: "Property edit rejected.")
        return
      let storyId = controlStoryId(vm.selectedStory.val)
      var authoredBefore = prepared.outcome.sourceEdit.oldValue
      for mapping in editableStyles.val:
        if mapping{"elementId"}.getStr() == element.id and mapping{"storyId"}.getStr() == storyId and mapping{"values", property} != nil:
          authoredBefore = mapping["values"][property].getStr()
      if parseCssPropertyValue(property, authoredBefore).canonical == prepared.outcome.sourceEdit.newValue:
        done(true, "")
        return
      transact(element, property, prepared.outcome.sourceEdit.newValue, storyId, "",
        proc(ok: bool; diagnostic, sourceBefore, sourceAfter: string) =
          if ok:
            var confirmed = prepared
            confirmed.transaction.sourceEdit.originDetail = storyId
            confirmed.transaction.sourceEdit.oldValue = authoredBefore
            confirmed.transaction.sourceEdit.nativeSourceBefore = sourceBefore
            confirmed.transaction.sourceEdit.nativeSourceAfter = sourceAfter
            # The refreshed catalog owns selected properties/authoring metadata.
            # A prior snapshot must never replace another story with the same ID.
            vm.inspector.acceptPreparedPropertyEdit(confirmed, saved = true, applySelection = false)
            vm.chat.accumulatedEdits.update proc(previous: seq[EditRecord]): seq[EditRecord] =
              result = previous
              result.add confirmed.outcome.record
          done(ok, diagnostic))

    vm.inspectorSourceHistory = proc(redo: bool): bool =
      let stack = if redo: vm.inspector.redoStack.val else: vm.inspector.undoStack.val
      if stack.len == 0: return false
      let transaction = stack[^1]
      if not transaction.saved: return false
      let storyId = transaction.sourceEdit.originDetail
      if storyId != controlStoryId(vm.selectedStory.val):
        vm.workspaceEditDiagnostics.val = @[WorkspaceEditDiagnostic(kind: wedSourceConflict,
          message: "Open the edited story before undoing its source change.")]
        return true
      let element = if redo: transaction.afterElement else: transaction.beforeElement
      discard vm.selectInspectorElementById(element.id)
      let value = if redo: transaction.sourceEdit.newValue else: transaction.sourceEdit.oldValue
      transact(element, transaction.sourceEdit.property, value, storyId, "",
        proc(ok: bool; diagnostic, sourceBefore, sourceAfter: string) =
          if not ok: return
          if redo:
            vm.inspector.redoStack.val = stack[0 ..< stack.len - 1]
            vm.inspector.undoStack.update proc(previous: seq[CSSPropertyEditTransaction]): seq[CSSPropertyEditTransaction] =
              result = previous
              result.add transaction
          else:
            vm.inspector.undoStack.val = stack[0 ..< stack.len - 1]
            vm.inspector.redoStack.update proc(previous: seq[CSSPropertyEditTransaction]): seq[CSSPropertyEditTransaction] =
              result = previous
              result.add transaction
          # Catalog hydration owns current selection, including cross-story IDs.
          discard, restoreLiteral = if redo: transaction.sourceEdit.nativeSourceAfter else: transaction.sourceEdit.nativeSourceBefore)
      true

  proc receiveInitial(raw: cstring) =
    try:
      let reply = parseJson($raw)
      if reply{"diagnostic"} != nil: raise newException(ValueError, reply["diagnostic"].getStr())
      applyCatalog(reply)
      vm.controlAsyncCommandAdapter = proc(request: JsonNode; done: proc(ok: bool; data: JsonNode) {.closure.}) =
        if vm.controlSourceTransport == nil:
          done(false, %* {"diagnostic": "Source transport unavailable."})
          return
        vm.workspaceEditStage.val = wesCompiling
        vm.controlSourceTransport(request, proc(data: JsonNode) =
          if data{"ok"}.getBool():
            try:
              applyCatalog(data)
              vm.workspaceEditStage.val = wesClean
              vm.workspaceEditDiagnostics.val = @[]
              # The full catalog stays in the applied preview workspace. Public
              # operation completion describes the build, without copying every
              # compiled document into the agent's tool response.
              done(true, %* {"ok": true, "storyId": data{"storyId"}.getStr(),
                "compiledStoryCount": data["catalog"]["stories"].len})
            except CatchableError as error:
              vm.workspaceEditStage.val = wesFailed
              done(false, %* {"diagnostic": error.msg})
          else:
            vm.workspaceEditStage.val = wesFailed
            vm.workspaceEditDiagnostics.val = @[WorkspaceEditDiagnostic(kind: wedCompileFailed,
              message: data{"diagnostic"}.getStr("Project build failed."))]
            done(false, data))
    except CatchableError as error:
      vm.workspaceEditStage.val = wesFailed
      vm.workspaceEditDiagnostics.val = @[WorkspaceEditDiagnostic(kind: wedMissingAdapter,
        message: "Source project unavailable: " & error.msg)]
  let initialCallback = receiveInitial
  {.emit: ["""
    fetch('/api/editor/source/catalog',{credentials:'omit'}).then(r=>{
      if(r.status===404) return null; return r.text();
    }).then(raw=>{if(raw!==null) """, initialCallback, """(raw);})
      .catch(()=>""", initialCallback, """('{"diagnostic":"Source catalog connection failed."}'));
  """].}
