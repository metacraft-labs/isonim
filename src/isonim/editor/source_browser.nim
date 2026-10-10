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
    if (!Object.prototype.hasOwnProperty.call(""", vm, """, 'sourceBindingMetadataDirty')) """, vm, """.sourceBindingMetadataDirty = null;
    if (!Object.prototype.hasOwnProperty.call(""", vm, """, 'sourceBindingMetadataHash')) """, vm, """.sourceBindingMetadataHash = [];
    if (!Object.prototype.hasOwnProperty.call(""", vm, """, 'sourceBindingMetadataSaved')) """, vm, """.sourceBindingMetadataSaved = [];
    if (!Object.prototype.hasOwnProperty.call(""", vm, """, 'sourceBindingMetadataSaving')) """, vm, """.sourceBindingMetadataSaving = false;
    if (!Object.prototype.hasOwnProperty.call(""", vm, """, 'sourceBindingMetadataSaveAgain')) """, vm, """.sourceBindingMetadataSaveAgain = false;
    if (!Object.prototype.hasOwnProperty.call(""", vm, """, 'sourceBindingMetadataWaiters')) """, vm, """.sourceBindingMetadataWaiters = [];
  """].}
  vm.inspector.ensureBindingRevision()
  vm.hasAsyncSourceProject = inspectorEditing
  if vm.sourceProjectMappings == nil:
    vm.sourceProjectMappings = createSignal(newJArray())
  let editableStyles = vm.sourceProjectMappings
  if vm.sourceProjectMappingDispose != nil:
    vm.sourceProjectMappingDispose()
    vm.sourceProjectMappingDispose = nil
  if inspectorEditing and vm.sourceBindingMetadataDirty == nil:
    vm.sourceBindingMetadataDirty = createSignal(false)
  proc bindingFailure(message: string; metadata = false) =
    vm.workspaceEditStage.val = wesFailed
    var diagnostics: seq[WorkspaceEditDiagnostic] = @[]
    if metadata:
      for diagnostic in vm.workspaceEditDiagnostics.val:
        if diagnostic.file != bindingSidecarRelPath: diagnostics.add diagnostic
    diagnostics.add WorkspaceEditDiagnostic(kind: wedWriteFailed, message: message,
      file: if metadata: bindingSidecarRelPath else: "")
    vm.workspaceEditDiagnostics.val = diagnostics
  proc saveMetadata(done: proc(ok: bool; diagnostic: string) {.closure.})
  proc saveMetadata(done: proc(ok: bool; diagnostic: string) {.closure.}) =
    if done != nil: vm.sourceBindingMetadataWaiters.add done
    if vm.sourceProjectBuildInFlight or vm.sourceBindingMetadataSaving:
      vm.sourceBindingMetadataDirty.val = true
      vm.sourceBindingMetadataSaveAgain = true
      return
    let metadata = vm.collectWorkspaceBindingMetadata()
    let raw = bindingSidecarJson(metadata.bindings, metadata.history)
    if raw == vm.sourceBindingMetadataSaved:
      vm.sourceBindingMetadataDirty.val = false
      vm.sourceBindingMetadataSaveAgain = false
      var failures: seq[WorkspaceEditDiagnostic] = @[]
      for diagnostic in vm.workspaceEditDiagnostics.val:
        if diagnostic.file != bindingSidecarRelPath: failures.add diagnostic
      vm.workspaceEditDiagnostics.val = failures
      vm.workspaceEditStage.val = if failures.len > 0: wesFailed
        elif vm.inspector.pendingSourceEdits.val.len > 0: wesDirty else: wesClean
      let waiters = vm.sourceBindingMetadataWaiters
      vm.sourceBindingMetadataWaiters = @[]
      for callback in waiters: callback(true, "")
      return
    vm.sourceBindingMetadataDirty.val = true
    if not vm.workspacePermissions.val.writeSource or vm.sourceBindingMetadataHash.len == 0 or vm.controlSourceTransport == nil:
      let diagnostic = if not vm.workspacePermissions.val.writeSource:
        "This workspace is read-only for binding metadata changes."
        else: "Binding metadata connection unavailable."
      bindingFailure(diagnostic, metadata = true)
      let waiters = vm.sourceBindingMetadataWaiters
      vm.sourceBindingMetadataWaiters = @[]
      for callback in waiters: callback(false, diagnostic)
      return
    var sourceFailures: seq[WorkspaceEditDiagnostic] = @[]
    for diagnostic in vm.workspaceEditDiagnostics.val:
      if diagnostic.file != bindingSidecarRelPath: sourceFailures.add diagnostic
    vm.sourceBindingMetadataSaving = true
    vm.sourceBindingMetadataSaveAgain = false
    vm.workspaceEditStage.val = wesApplying
    inc vm.sourceProjectOperationSerial
    let selected = vm.inspector.selectedElement.val
    let request = %* {"command": "bindings-save",
      "commandId": vm.controlInstanceId & "-bindings-" & $vm.sourceProjectOperationSerial,
      "bindingSidecar": raw, "expectedBindingHash": vm.sourceBindingMetadataHash,
      "storyId": controlStoryId(vm.selectedStory.val), "target": selected.id,
      "viewportWidth": vm.viewport.val.width}
    vm.controlSourceTransport(request, proc(reply: JsonNode) =
      vm.sourceBindingMetadataSaving = false
      if reply{"ok"}.getBool():
        vm.sourceBindingMetadataSaved = raw
        vm.sourceBindingMetadataHash = reply{"bindingHash"}.getStr()
        let latest = vm.collectWorkspaceBindingMetadata()
        vm.sourceBindingMetadataDirty.val = bindingSidecarJson(latest.bindings, latest.history) != raw
        if vm.sourceBindingMetadataSaveAgain or vm.sourceBindingMetadataDirty.val:
          saveMetadata(nil)
          return
        vm.workspaceEditDiagnostics.val = sourceFailures
        vm.workspaceEditStage.val = if sourceFailures.len > 0: wesFailed
          elif vm.inspector.pendingSourceEdits.val.len > 0: wesDirty else: wesClean
      else:
        # Preserve live metadata as pending. Save retries the same guarded
        # consumer; a revision conflict requires reload rather than blind overwrite.
        bindingFailure("Binding metadata was not saved: " & reply{"diagnostic"}.getStr("Write failed."), metadata = true)
      let waiters = vm.sourceBindingMetadataWaiters
      vm.sourceBindingMetadataWaiters = @[]
      for callback in waiters:
        callback(reply{"ok"}.getBool(),
          if not reply{"ok"}.getBool(): reply{"diagnostic"}.getStr("Binding metadata was not saved.") else: ""))
  if inspectorEditing:
    vm.sourceBindingMetadataSave = saveMetadata
    vm.inspector.onBindingsChanged = proc() = saveMetadata(nil)
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
      done: proc(ok: bool; diagnostic, sourceBefore, sourceAfter: string; unchanged: bool) {.closure.}; restoreLiteral = "") =
    if vm.sourceBindingMetadataSaving or (vm.sourceBindingMetadataDirty != nil and vm.sourceBindingMetadataDirty.val):
      done(false, "Save the pending binding metadata before editing source.", "", "", false)
      return
    if vm.sourceProjectBuildInFlight:
      done(false, "Wait for the current source build to complete.", "", "", false)
      return
    if not vm.workspacePermissions.val.writeSource:
      done(false, "This workspace is read-only for source changes.", "", "", false)
      return
    if vm.controlSourceTransport == nil:
      done(false, "Source connection unavailable.", "", "", false)
      return
    var mapping: JsonNode
    for entry in editableStyles.val:
      if entry{"elementId"}.getStr() == element.id and entry{"storyId"}.getStr() == storyId and
          (schemaKey.len == 0 or entry{"key"}.getStr() == schemaKey) and entry{"values", property} != nil:
        if mapping != nil:
          done(false, "Ambiguous editable source ownership.", "", "", false)
          return
        mapping = entry
    if mapping == nil or mapping{"values", property} == nil:
      done(false, "The editor cannot safely edit this value’s source.", "", "", false)
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
          let unchanged = reply{"sourceEdit", "unchanged"}.getBool()
          if not unchanged: applyCatalog(reply)
          vm.workspaceEditStage.val = wesClean
          vm.workspaceEditDiagnostics.val = @[]
          done(true, "", reply{"sourceEdit", "before"}.getStr(), reply{"sourceEdit", "after"}.getStr(), unchanged)
          if vm.sourceBindingMetadataSaveAgain: saveMetadata(nil)
        except CatchableError as error:
          vm.workspaceEditStage.val = wesFailed
          done(false, "Source catalog could not be applied: " & error.msg, "", "", false)
          if vm.sourceBindingMetadataSaveAgain: saveMetadata(nil)
      else:
        let diagnostic = reply{"diagnostic"}.getStr("Source edit failed.")
        vm.workspaceEditStage.val = wesFailed
        vm.workspaceEditDiagnostics.val = @[WorkspaceEditDiagnostic(kind: wedCompileFailed, message: diagnostic)]
        done(false, diagnostic, "", "", false)
        if vm.sourceBindingMetadataSaveAgain: saveMetadata(nil))

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
      transact(element, property, prepared.outcome.sourceEdit.newValue, storyId, "",
        proc(ok: bool; diagnostic, sourceBefore, sourceAfter: string; unchanged: bool) =
          if ok and not unchanged:
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

    vm.inspectorSourceDetach = proc(key: PropertyBindingKey; value: string) =
      let element = vm.inspector.selectedElement.val
      let story = controlStoryId(vm.selectedStory.val)
      let revision = vm.inspector.bindingRevision
      let binding = vm.propertyBindingFor(key)
      if key.elementId != element.id or binding.isNone or value.len == 0:
        bindingFailure("The linked value is unavailable or the selected target changed; binding retained.")
        return
      if vm.sourceBindingMetadataDirty.val or vm.sourceBindingMetadataSaving:
        bindingFailure("Save the pending binding metadata before unlinking.")
        return
      let token = binding.get.variableKey
      vm.inspectorSourceCommit(element, key.propertyName, value, sskLocalInstance,
        proc(ok: bool; diagnostic: string) =
          if not ok:
            bindingFailure("Unlink was not saved; binding retained: " & diagnostic)
            return
          let current = vm.propertyBindingFor(key)
          if revision != vm.inspector.bindingRevision or key.elementId != vm.inspector.selectedElement.val.id or
              story != controlStoryId(vm.selectedStory.val) or current.isNone or current.get.variableKey != token:
            bindingFailure("Source literal was saved, but the binding target changed; current binding retained.")
            return
          vm.detachPropertyBinding(key, value, sourceConfirmed = true))

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
        proc(ok: bool; diagnostic, sourceBefore, sourceAfter: string; unchanged: bool) =
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

  let initialOperationSerial = vm.sourceProjectOperationSerial
  let initialBindingRevision = vm.inspector.bindingRevision
  proc receiveInitial(raw: cstring) =
    try:
      let reply = parseJson($raw)
      if initialOperationSerial != vm.sourceProjectOperationSerial or initialBindingRevision != vm.inspector.bindingRevision:
        return # A newer live mutation owns the catalog and metadata revision.
      if reply{"diagnostic"} != nil: raise newException(ValueError, reply["diagnostic"].getStr())
      applyCatalog(reply)
      if inspectorEditing:
        let raw = reply{"bindingSidecar"}.getStr()
        let incomingHash = reply{"bindingHash"}.getStr()
        if incomingHash.len != 40: raise newException(ValueError, "Binding metadata revision unavailable.")
        if not vm.sourceBindingMetadataDirty.val and not vm.sourceBindingMetadataSaving:
          vm.sourceBindingMetadataHash = incomingHash
          var hydrated = base
          hydrated.loadBindingSidecar(raw)
          vm.rehydratePropertyBindings(hydrated.variableBindings, hydrated.variableBindingHistory)
          let metadata = vm.collectWorkspaceBindingMetadata()
          vm.sourceBindingMetadataSaved = bindingSidecarJson(metadata.bindings, metadata.history)
      vm.controlAsyncCommandAdapter = proc(request: JsonNode; done: proc(ok: bool; data: JsonNode) {.closure.}) =
        if vm.sourceProjectBuildInFlight or vm.sourceBindingMetadataSaving or
            (vm.sourceBindingMetadataDirty != nil and vm.sourceBindingMetadataDirty.val):
          done(false, %* {"diagnostic": "Complete the pending project save before building."})
          return
        if vm.controlSourceTransport == nil:
          done(false, %* {"diagnostic": "Source transport unavailable."})
          return
        vm.sourceProjectBuildInFlight = true
        vm.workspaceEditStage.val = wesCompiling
        vm.controlSourceTransport(request, proc(data: JsonNode) =
          vm.sourceProjectBuildInFlight = false
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
            done(false, data)
          if vm.sourceBindingMetadataSaveAgain: saveMetadata(nil))
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
