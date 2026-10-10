## Native worker for an explicitly opted-in project. Runs the production typed
## dispatcher and WorkspaceEditAdapter transaction against actual source files.
## The manifest belongs to the project, never to an RPC caller. Build stdout is
## a rendered catalog JSON document; failed builds never publish a new catalog.
import std/[json, os, osproc, strutils, tempfiles, sha1]
import source_project_lock
import isonim/core/[signals, owner]
import isonim/editor/[control, source_catalog, workspace, css_patch, viewmodels, source_style_bindings, source_style_values]

proc safePath(root, relative: string): string =
  if relative.len == 0 or relative.isAbsolute:
    raise newException(ValueError, "Project path must be relative.")
  let candidate = absolutePath(relative, root).normalizedPath
  if not candidate.startsWith(root & DirSep):
    raise newException(ValueError, "Project path escapes workspace.")
  var current = root
  for part in relative.split(DirSep):
    current = current / part
    if symlinkExists(current): raise newException(ValueError, "Source paths must not traverse symlinks.")
  candidate

proc atomicSourceWrite(target, content: string) =
  let permissions = if fileExists(target): getFilePermissions(target) else: {fpUserRead, fpUserWrite}
  let (file, temporary) = createTempFile(".isonim-", ".tmp", target.parentDir)
  try:
    file.write(content)
    file.close()
    setFilePermissions(temporary, permissions)
    moveFile(temporary, target)
  finally:
    if fileExists(temporary): removeFile(temporary)

proc recoverSourceTransaction(root: string) =
  let journal = safePath(root, ".isonim/source-transaction.json")
  if not fileExists(journal): return
  for row in parseFile(journal):
    let target = safePath(root, row["file"].getStr())
    let current = readFile(target)
    if current == row["after"].getStr():
      atomicSourceWrite(target, row["before"].getStr())
    elif current != row["before"].getStr():
      raise newException(ValueError,
        "Interrupted source transaction conflicts with a later edit: " & row["file"].getStr())
  removeFile(journal)

proc describeEditableStyles(root: string; manifest: JsonNode): JsonNode =
  result = compiledStyleBindings(parseFile(safePath(root, manifest{"catalog"}.getStr())),
    manifest, proc(file: string): string = readFile(safePath(root, file)))
  if manifest{"editableStyles"} == nil: return
  if manifest["editableStyles"].kind != JArray:
    raise newException(ValueError, "Editable source declarations must be an array.")
  for entry in manifest{"editableStyles"}:
    let source = readFile(safePath(root, entry{"file"}.getStr()))
    var values = newJObject()
    for property in entry{"properties"}:
      let probe = patchCssInNimConstAt(source, entry{"const"}.getStr(),
        entry{"selector"}.getStr(), property.getStr(), "0", 0)
      if probe.ok: values[property.getStr()] = %probe.oldValue
    result.add(%* {"key": entry{"key"}.getStr(), "elementId": entry{"elementId"}.getStr(),
      "storyId": entry{"storyId"}.getStr(), "file": entry{"file"}.getStr(),
      "const": entry{"const"}, "selector": entry{"selector"}, "properties": entry{"properties"},
      "sourceHash": $secureHash(source), "values": values})

proc bindingSnapshot(root: string): JsonNode =
  let file = safePath(root, bindingSidecarRelPath)
  let raw = if fileExists(file): readFile(file) else: ""
  %* {"bindingSidecar": raw, "bindingHash": $secureHash(raw)}

proc validateBindingMetadata(raw: string) =
  let document = parseJson(raw)
  if document.kind != JObject or document{"version"}.getInt() != 1:
    raise newException(ValueError, "Invalid binding metadata version.")
  for key, value in document:
    if key notin ["version", "variableBindings", "variableBindingHistory"]:
      raise newException(ValueError, "Invalid binding metadata field.")
  for field in ["variableBindings", "variableBindingHistory"]:
    if document{field} == nil or document[field].kind != JArray:
      raise newException(ValueError, "Invalid binding metadata collection.")
    for row in document[field]:
      if row.kind != JObject or row{"elementId"} == nil or row["elementId"].kind != JString or
          row["elementId"].getStr().len == 0 or row{"propertyName"} == nil or
          row["propertyName"].kind != JString or row["propertyName"].getStr().len == 0:
        raise newException(ValueError, "Invalid binding metadata owner.")
      if field == "variableBindings":
        if row{"variableKey"} == nil or row["variableKey"].kind != JString or row["variableKey"].getStr().len == 0:
          raise newException(ValueError, "Invalid binding metadata variable.")
      else:
        if row{"variableKeys"} == nil or row["variableKeys"].kind != JArray:
          raise newException(ValueError, "Invalid binding metadata history.")
        for key in row["variableKeys"]:
          if key.kind != JString or key.getStr().len == 0:
            raise newException(ValueError, "Invalid binding metadata history key.")

proc cmdSourceProject*(args: seq[string]): int =
  if args.len != 2:
    echo $(%* {"ok": false, "diagnostic": "source-project requires root and request file"})
    return 2
  try:
    let root = args[0].absolutePath.normalizedPath
    let transactionLock = acquireSourceProjectLock(root)
    defer: transactionLock.release()
    if args[1] in ["--describe", "--snapshot"]:
      if fileExists(safePath(root, ".isonim/source-transaction.json")):
        raise newException(ValueError, "Interrupted source transaction requires explicit recovery.")
      let manifest = parseFile(safePath(root, ".isonim/source-project.json"))
      var response = %* {"ok": true, "editableStyles": describeEditableStyles(root, manifest)}
      if args[1] == "--snapshot":
        response["manifest"] = manifest
        response["catalog"] = parseFile(safePath(root, manifest{"catalog"}.getStr()))
        let bindings = bindingSnapshot(root)
        response["bindingSidecar"] = bindings["bindingSidecar"]
        response["bindingHash"] = bindings["bindingHash"]
      echo $response
      return 0
    recoverSourceTransaction(root)
    if args[1] == "--recover":
      echo $(%* {"ok": true})
      return 0
    let manifest = parseFile(safePath(root, ".isonim/source-project.json"))
    let request = parseFile(args[1])
    if request{"command"}.getStr() == "bindings-save":
      for key, value in request:
        if key notin ["command", "commandId", "bindingSidecar", "expectedBindingHash", "expectedRevision", "storyId", "target", "viewportWidth"]:
          raise newException(ValueError, "Unknown binding metadata request field.")
        if key in ["expectedRevision", "viewportWidth"]:
          if value.kind != JInt: raise newException(ValueError, "Invalid binding metadata request type.")
        elif value.kind != JString:
          raise newException(ValueError, "Invalid binding metadata request type.")
      if request{"expectedBindingHash"}.getStr().len != 40 or request{"bindingSidecar"} == nil:
        raise newException(ValueError, "Missing binding metadata revision.")
      let current = bindingSnapshot(root)
      if request["expectedBindingHash"] != current["bindingHash"]:
        raise newException(ValueError, "Binding metadata changed in another editor. Reload before retrying.")
      let raw = request["bindingSidecar"].getStr()
      validateBindingMetadata(raw)
      atomicSourceWrite(safePath(root, bindingSidecarRelPath), raw)
      var reply = bindingSnapshot(root)
      reply["ok"] = %true
      echo $reply
      return 0
    let inspectorEdit = request{"command"}.getStr() == "inspector-edit"
    var literalMap: JsonNode
    var nativeProperty, nativeBefore, nativeAfter: string
    if inspectorEdit:
      for key, value in request:
        if key notin ["commandId", "command", "storyId", "target", "schemaKey", "property", "value", "expectedValue", "expectedSourceHash", "expectedRevision", "viewportWidth", "sourceValue"]:
          raise newException(ValueError, "Unknown inspector source field.")
        if key in ["expectedRevision", "viewportWidth"]:
          if value.kind != JInt: raise newException(ValueError, "Invalid inspector source field type.")
        elif value.kind != JString:
          raise newException(ValueError, "Invalid inspector source field type.")
      for key in ["commandId", "command", "storyId", "target", "schemaKey", "property", "value", "expectedValue", "expectedSourceHash", "expectedRevision", "viewportWidth"]:
        if request{key} == nil: raise newException(ValueError, "Missing inspector source field.")
      if request{"viewportWidth"}.getInt() < 1 or request{"expectedSourceHash"}.getStr().len != 40:
        raise newException(ValueError, "Invalid inspector source revision.")
      for delimiter in [";", "{", "}", "\n", "\r", "\x00", "\"\"\""]:
        if delimiter in request{"value"}.getStr():
          raise newException(ValueError, "A property value cannot contain declaration delimiters.")
      for entry in describeEditableStyles(root, manifest):
        if entry{"key"}.getStr() == request{"schemaKey"}.getStr():
          if literalMap != nil: raise newException(ValueError, "Ambiguous editable source schema.")
          literalMap = entry
      if literalMap == nil: raise newException(ValueError, "Unsupported editable source schema.")
      if literalMap{"elementId"}.getStr() != request{"target"}.getStr() or
          literalMap{"storyId"}.getStr() != request{"storyId"}.getStr():
        raise newException(ValueError, "Editable source target mismatch.")
      var allowed = false
      for property in literalMap{"properties"}:
        if property.getStr() == request{"property"}.getStr(): allowed = true
      if not allowed: raise newException(ValueError, "Property is not owned by this source schema.")
      let source = readFile(safePath(root, literalMap{"file"}.getStr()))
      if $secureHash(source) != request{"expectedSourceHash"}.getStr():
        raise newException(ValueError, "Source changed since this inspector edit began.")
      let parsed = parseCssPropertyValue(request{"property"}.getStr(), request{"value"}.getStr())
      let validation = validateCssPropertyValue(PropertyInfo(name: request{"property"}.getStr(),
        directStyleAllowed: true), PropertyEditRequest(property: request{"property"}.getStr(),
        newValue: request{"value"}.getStr(), kind: pekCss, scope: pesLocal), parsed)
      if validation.len > 0: raise newException(ValueError, validation[0].message)
      if literalMap{"values", request["property"].getStr()} == nil or
          literalMap["values"][request["property"].getStr()].getStr() != request["expectedValue"].getStr():
        raise newException(ValueError, "Authored property changed before this edit.")
      let declaration = literalMap{"sourceDeclarations", request["property"].getStr()}
      nativeProperty = if declaration == nil: request["property"].getStr() else: declaration["property"].getStr()
      nativeBefore = if declaration == nil: request["expectedValue"].getStr() else: declaration["value"].getStr()
      if declaration != nil and declaration{"component"} != nil:
        nativeAfter = patchCssQuad(nativeProperty,nativeBefore,request["value"].getStr(),
          declaration["component"].getInt(),request{"sourceValue"}.getStr())
        if nativeAfter.len == 0: raise newException(ValueError, "Unsupported compound edit or stale sibling restoration.")
      else:
        nativeAfter = request["value"].getStr()
        if request{"sourceValue"} != nil and request["sourceValue"].getStr() != nativeAfter:
          raise newException(ValueError, "Source restoration does not match this property value.")
      # Even a canonical no-op must validate the actual declaration under the
      # project lock. An explicit restoration may still change compound siblings.
      if parseCssPropertyValue(request["property"].getStr(),
          request["expectedValue"].getStr()).canonical == parsed.canonical and
          (request{"sourceValue"} == nil or nativeAfter == nativeBefore):
        let validated = patchCssInNimConstAt(source, literalMap{"const"}.getStr(),
          literalMap{"selector"}.getStr(), nativeProperty, nativeAfter,
          request{"viewportWidth"}.getInt())
        if not validated.ok or validated.oldValue != nativeBefore:
          raise newException(ValueError, "Source declaration changed or cannot be safely patched.")
        echo $(%* {"ok": true, "sourceEdit": {"before": nativeBefore,
          "after": nativeBefore, "unchanged": true}})
        return 0
    let catalogFile = safePath(root, manifest{"catalog"}.getStr())
    let catalog = parseFile(catalogFile)
    let journalFile = safePath(root, ".isonim/source-transaction.json")
    var journal = newJArray()
    defer:
      if fileExists(journalFile): recoverSourceTransaction(root)
    var built: JsonNode
    var diagnostics = ""
    proc build(expectedStories: seq[StoryRef]): WorkspaceOperationResult =
      var command: seq[string]
      for part in manifest{"build"}: command.add part.getStr()
      if command.len == 0: return WorkspaceOperationResult(ok: false, message: "No project build command.")
      let previous = getCurrentDir()
      setCurrentDir(root)
      let execution = try: execCmdEx(command.quoteShellCommand()) finally: setCurrentDir(previous)
      if execution.exitCode != 0:
        diagnostics = execution.output
        return WorkspaceOperationResult(ok: false, message: diagnostics)
      try:
        built = parseJson(execution.output)
        if built{"stories"} == nil or built["stories"].kind != JArray:
          raise newException(ValueError, "Build did not return a story catalog.")
        discard sourceCatalogWorkspace(built, manifest, newEditorWorkspace("validation", @[]))
        for story in built["stories"]:
          if story{"group"}.getStr().len == 0 or story{"name"}.getStr().len == 0 or story{"documentHtml"}.getStr().len == 0:
            raise newException(ValueError, "Build returned an incomplete rendered story.")
        for expected in expectedStories:
          var published = false
          for story in built["stories"]:
            if story{"group"}.getStr() == expected.group and story{"name"}.getStr() == expected.name and
                sourceStoryKind(story) == expected.kind and story{"documentHtml"}.getStr().len > 0: published = true
          if not published:
            raise newException(ValueError, "Compiled catalog omits requested story: " & expected.group & " / " & expected.name)
      except CatchableError as error:
        return WorkspaceOperationResult(ok: false, message: "Invalid build catalog: " & error.msg)
      WorkspaceOperationResult(ok: true)
    let adapter = WorkspaceEditAdapter(durableSourceControl: true, bridgeLabel: "Native project source/build transaction")
    for fixture in manifest{"fixtures"}:
      adapter.schema.add WorkspaceEditableSchemaEntry(key: fixture{"schemaKey"}.getStr() & ".story",
        file: fixture{"file"}.getStr(), kind: wskStoryFixture,
        story: StoryRef(group: fixture{"component"}.getStr(), name: fixture{"variant"}.getStr() & " " & fixture{"state"}.getStr(), kind: skComponent))
    if inspectorEdit:
      adapter.schema.add WorkspaceEditableSchemaEntry(key: literalMap{"key"}.getStr(),
        file: literalMap{"file"}.getStr(), kind: wskSourceMap,
        property: request{"property"}.getStr())
    adapter.readFile = proc(file: string): WorkspaceReadResult =
      WorkspaceReadResult(ok: true, content: readFile(safePath(root, file)))
    adapter.writeFile = proc(file, content: string): WorkspaceOperationResult =
      let target = safePath(root, file)
      var original = readFile(target)
      var found = false
      for row in journal:
        if row["file"].getStr() == file:
          if content == row["before"].getStr() and original notin [row["before"].getStr(), row["after"].getStr()]:
            return WorkspaceOperationResult(ok: false,
              message: "Rollback conflicts with a later human edit: " & file)
          original = row["before"].getStr()
          row["after"] = %content
          found = true
      if not found: journal.add(%* {"file": file, "before": original, "after": content})
      atomicSourceWrite(journalFile, $journal)
      atomicSourceWrite(target, content)
      WorkspaceOperationResult(ok: true)
    adapter.patchFile = proc(plan: SourceEditPlan; content: string; schema: WorkspaceEditableSchemaEntry): WorkspacePatchResult =
      if inspectorEdit:
        let patched = patchCssInNimConstAt(content, literalMap{"const"}.getStr(),
          literalMap{"selector"}.getStr(), nativeProperty, nativeAfter,
          request{"viewportWidth"}.getInt())
        if not patched.ok or patched.oldValue != nativeBefore:
          return WorkspacePatchResult(ok: false, diagnostics: @[WorkspaceEditDiagnostic(
            kind: wedSourceConflict, message: "Source declaration changed or cannot be safely patched.")])
        return WorkspacePatchResult(ok: true, patch: WorkspaceFilePatch(file: schema.file,
          beforeContent: content, afterContent: patched.content, fullReload: true))
      for fixture in manifest{"fixtures"}:
        if fixture{"schemaKey"}.getStr() & ".story" == plan.schemaKey:
          let marker = fixture{"marker"}.getStr()
          let declaration = fixture{"declaration"}.getStr()
          if marker.len == 0 or content.count(marker) != 1:
            return WorkspacePatchResult(ok: false)
          if declaration.len == 0 or declaration in content:
            return WorkspacePatchResult(ok: false)
          return WorkspacePatchResult(ok: true, patch: WorkspaceFilePatch(file: plan.file,
            afterContent: content.replace(marker, declaration & "\n" & marker), affectedStory: schema.story))
      WorkspacePatchResult(ok: false)
    adapter.compile = proc(stories: seq[StoryRef]): WorkspaceOperationResult = build(stories)
    adapter.reloadPreview = proc(stories: seq[StoryRef]; fullReload: bool): WorkspaceOperationResult =
      try:
        adapter.writeFile(manifest{"catalog"}.getStr(), $built)
      except CatchableError as error:
        WorkspaceOperationResult(ok: false, message: "Catalog publication failed: " & error.msg)
    var exitCode = 0
    createRoot proc(dispose: proc()) =
      let base = newEditorWorkspace(manifest{"title"}.getStr(), @[], id = manifest{"workspace"}.getStr(),
        editAdapter = adapter, permissions = EditorWorkspacePermissions(readSource: true, writeSource: true, createStory: true))
      let vm = createEditorVM(sourceCatalogWorkspace(catalog, manifest, base))
      vm.controlSourceFixtures = sourceFixtures(manifest)
      var ok = false
      var diagnostic = ""
      var storyId = ""
      if inspectorEdit:
        vm.inspector.journalSourceEdit(SourceEditPlan(file: literalMap{"file"}.getStr(),
          schemaKey: literalMap{"key"}.getStr(), property: request{"property"}.getStr(),
          oldValue: request{"expectedValue"}.getStr(), expectedOldValue: nativeBefore,
          newValue: request{"value"}.getStr(), scope: pesLocal, sourceScope: sskLocalInstance,
          reversible: true))
        let outcome = vm.applyWorkspaceFileEdits()
        ok = outcome.ok
        for row in outcome.diagnostics: diagnostic.add row.message & "\n"
        storyId = request{"storyId"}.getStr()
      else:
        let typed = commandRequest(request)
        let outcome = vm.runEditorCommand(typed)
        ok = outcome.status == ecsSucceeded
        diagnostic = outcome.diagnostic
        if typed.kind == eckCreateStory:
          storyId = request{"component"}.getStr() & " / " & request{"variantKey"}.getStr() & " " & request{"stateKey"}.getStr()
      if not ok:
        recoverSourceTransaction(root)
        echo $(%* {"ok": false, "diagnostic": diagnostic, "stage": $vm.workspaceEditStage.val,
          "variants": %vm.variants.variants.val, "pendingEdits": %vm.inspector.pendingSourceEdits.val})
        exitCode = 4
      else:
        # Validate the complete response before retiring rollback state. A
        # malformed capability producer must not leave a write behind a failed ACK.
        let refreshedStyles = describeEditableStyles(root, manifest)
        var response = %* {"ok": true, "catalog": built, "manifest": manifest, "storyId": storyId,
          "editableStyles": refreshedStyles}
        if inspectorEdit: response["sourceEdit"] = %* {"before":nativeBefore,"after":nativeAfter}
        if fileExists(journalFile): removeFile(journalFile)
        echo $response
      dispose()
    return exitCode
  except CatchableError as error:
    echo $(%* {"ok": false, "diagnostic": error.msg})
    return 4
