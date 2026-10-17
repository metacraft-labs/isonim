## Native worker for an explicitly opted-in project. Runs the production typed
## dispatcher and WorkspaceEditAdapter transaction against actual source files.
## The manifest belongs to the project, never to an RPC caller. Build stdout is
## a rendered catalog JSON document; failed builds never publish a new catalog.
import std/[json, os, osproc, strutils, tempfiles, sha1, tables]
import source_project_lock
import isonim/core/[signals, owner]
import isonim/editor/[control, source_catalog, workspace, css_patch, viewmodels, source_style_bindings, source_style_values, types]
from isonim/editor/design_review/control_routes import validNativeRestoreWrite

const removalReceiptsRelPath = ".isonim/removal-receipts.json"
  ## The receipts this worker issued for removals (Reset / Fill Delete) not
  ## yet undone. An undo is honoured only for a receipt recorded here, so it
  ## can put back only what a removal actually removed. The last 64
  ## receipts are kept. The store also holds one `{"offer": ...}` record per
  ## compiled rule and property a removal took and no undo has put back;
  ## those are not receipts and are never evicted with them (they keep the
  ## property offered after Reset, `describeEditableStyles`).

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
    if row["file"].getStr() == removalReceiptsRelPath and not fileExists(target):
      # A first store write that never landed: nothing to restore.
      continue
    let current = readFile(target)
    if current == row["after"].getStr():
      atomicSourceWrite(target, row["before"].getStr())
    elif current != row["before"].getStr():
      raise newException(ValueError,
        "Interrupted source transaction conflicts with a later edit: " & row["file"].getStr())
  removeFile(journal)

proc editStatement(source: string; entry: JsonNode; property: string): string =
  ## Whether this writer can change `property` for `entry` alone: "" when it
  ## can, otherwise why not. A declaration in a rule whose selector is a list
  ## (or a value that would be added to one) also styles the list's other
  ## selectors, so it is refused (editor spec "Saving": an edit changes
  ## exactly the one owning declaration). Stated per declaration, from the
  ## file as it is now, and re-derived under the project lock at the act.
  if entry{"scope"}.getStr() == "semantic-token": return ""
  let declaration = entry{"sourceDeclarations", property}
  let owner = if declaration != nil: declaration{"property"}.getStr() else: property
  nimConstBody(source, entry{"const"}.getStr()).cssSelectorListRefusal(
    entry{"selector"}.getStr(), owner)

proc removalStatement(source: string; entry: JsonNode; property: string): string =
  ## Whether this writer can remove the one declaration that owns
  ## `property` for `entry`: "" when it can, otherwise why not, in the words
  ## Reset and Fill Delete show (editor spec "Universal Patterns": each
  ## source-map entry states whether its writer can remove the declaration it
  ## owns). Stated per declaration, from the file as it is now.
  let shared = editStatement(source, entry, property)
  if shared.len > 0: return shared
  if entry{"scope"}.getStr() == "semantic-token":
    return "This value comes from the design token " & entry{"tokenName"}.getStr() &
      "; Reset cannot remove a token's definition, which every reference to it shares."
  let declaration = entry{"sourceDeclarations", property}
  if declaration != nil:
    let owner = declaration{"property"}.getStr()
    if declaration{"component"} != nil:
      return property & " comes from the " & owner & " shorthand; the native " &
        "source writer cannot remove one part of a shorthand."
    if owner != property:
      return property & " is set by the " & owner & " declaration; removing it " &
        "would also remove what it sets for other properties."
  let removed = removeCssInNimConst(source, entry{"const"}.getStr(),
    entry{"selector"}.getStr(), property)
  if removed.ok: "" else: removed.message

proc removalReceipts(root: string): JsonNode =
  ## The issued receipts, validated. Read before a removal or its undo
  ## writes anything: a store that cannot be read refuses the act with
  ## nothing written. Empty content is an empty store (a rolled-back first
  ## write leaves the journal's empty "before").
  let file = safePath(root, removalReceiptsRelPath)
  if symlinkExists(file) or dirExists(file):
    raise newException(ValueError, "The removal receipt store " & removalReceiptsRelPath &
      " is not a file. Nothing was changed.")
  if not fileExists(file): return newJArray()
  let raw = readFile(file)
  if raw.strip().len == 0: return newJArray()
  try:
    result = parseJson(raw)
  except CatchableError:
    raise newException(ValueError, "The removal receipt store " & removalReceiptsRelPath &
      " is unreadable. Nothing was changed.")
  if result.kind != JArray:
    raise newException(ValueError, "The removal receipt store " & removalReceiptsRelPath &
      " is unreadable. Nothing was changed.")

proc describeEditableStyles(root: string; manifest: JsonNode; overrideFile = "";
    overrideContent = ""): JsonNode =
  ## Every editable declaration with its value and its removal statement.
  ## With `overrideFile`, as the project would be if that file held
  ## `overrideContent` (an undo is checked before it is written).
  var sources = initTable[string, string]()
  proc read(file: string): string =
    if overrideFile.len > 0 and file == overrideFile: return overrideContent
    if not sources.hasKey(file): sources[file] = readFile(safePath(root, file))
    sources[file]
  # A compiled binding exists only while a declaration does; the store's
  # re-offer records (one per compiled rule and property a removal took and
  # no undo has put back, kept apart from the receipts' undo cap) keep the
  # property offered so it can be set again after Reset. An unreadable store
  # offers nothing more; a removal or undo still refuses it before writing.
  var reoffer: seq[ReofferedDeclaration] = @[]
  try:
    for row in removalReceipts(root):
      let offer = row{"offer"}
      if row{"receipt"} != nil or offer == nil or offer.kind != JObject: continue
      reoffer.add ReofferedDeclaration(file: offer{"file"}.getStr(),
        constName: offer{"const"}.getStr(), selector: offer{"selector"}.getStr(),
        property: offer{"property"}.getStr())
  except CatchableError:
    reoffer = @[]
  result = compiledStyleBindings(parseFile(safePath(root, manifest{"catalog"}.getStr())),
    manifest, proc(file: string): string = read(file), reoffer)
  for binding in result:
    var removals = newJObject()
    var edits = newJObject()
    for property, _ in binding{"values"}:
      removals[property] = %removalStatement(read(binding["file"].getStr()), binding, property)
      edits[property] = %editStatement(read(binding["file"].getStr()), binding, property)
    binding["removals"] = removals
    binding["edits"] = edits
  if manifest{"editableStyles"} == nil: return
  if manifest["editableStyles"].kind != JArray:
    raise newException(ValueError, "Editable source declarations must be an array.")
  for entry in manifest{"editableStyles"}:
    let source = read(entry{"file"}.getStr())
    var values = newJObject()
    var removals = newJObject()
    var edits = newJObject()
    for property in entry{"properties"}:
      let probe = patchCssInNimConstAt(source, entry{"const"}.getStr(),
        entry{"selector"}.getStr(), property.getStr(), "0", 0)
      if probe.ok:
        values[property.getStr()] = %probe.oldValue
        removals[property.getStr()] = %removalStatement(source, entry, property.getStr())
        edits[property.getStr()] = %editStatement(source, entry, property.getStr())
    result.add(%* {"key": entry{"key"}.getStr(), "elementId": entry{"elementId"}.getStr(),
      "storyId": entry{"storyId"}.getStr(), "file": entry{"file"}.getStr(),
      "const": entry{"const"}, "selector": entry{"selector"}, "properties": entry{"properties"},
      "sourceHash": $secureHash(source), "values": values, "removals": removals, "edits": edits})

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
    # Reset / Fill Delete send an empty value: remove the one owning
    # declaration. Their undo sends the removal's line receipt back
    # (`restoreWrite`): put back exactly the removed line.
    var removal, restore = false
    var restoreReceipt: SourceWriteReceipt
    var restoreRecord = -1
    var issuedReceipts: JsonNode
    var removalBefore, removalAfter: string
    if inspectorEdit:
      for key, value in request:
        if key notin ["commandId", "command", "storyId", "target", "schemaKey", "property", "value", "expectedValue", "expectedSourceHash", "expectedRevision", "viewportWidth", "sourceValue", "restoreWrite"]:
          raise newException(ValueError, "Unknown inspector source field.")
        if key in ["expectedRevision", "viewportWidth"]:
          if value.kind != JInt: raise newException(ValueError, "Invalid inspector source field type.")
        elif key == "restoreWrite":
          if not validNativeRestoreWrite(value): raise newException(ValueError, "Invalid inspector source field type.")
        elif value.kind != JString:
          raise newException(ValueError, "Invalid inspector source field type.")
      for key in ["commandId", "command", "storyId", "target", "schemaKey", "property", "value", "expectedValue", "expectedSourceHash", "expectedRevision", "viewportWidth"]:
        if request{key} == nil: raise newException(ValueError, "Missing inspector source field.")
      if request{"viewportWidth"}.getInt() < 1 or request{"expectedSourceHash"}.getStr().len != 40:
        raise newException(ValueError, "Invalid inspector source revision.")
      restore = request{"restoreWrite"} != nil
      removal = not restore and request["value"].getStr().len == 0
      # Validated before anything is written: the store update is part of the
      # transaction below and must not be the first thing to fail.
      if removal or restore: issuedReceipts = removalReceipts(root)
      if restore and (request["value"].getStr().len == 0 or request["expectedValue"].getStr().len > 0 or
          request{"sourceValue"} != nil):
        raise newException(ValueError, "An undone removal restores its removed value and expects none.")
      if removal and request{"sourceValue"} != nil:
        raise newException(ValueError, "A removal restores no source value.")
      for delimiter in [";", "{", "}", "\n", "\r", "\x00", "\"\"\""]:
        if delimiter in request{"value"}.getStr():
          raise newException(ValueError, "A property value cannot contain declaration delimiters.")
      let property = request["property"].getStr()
      if restore:
        # The receipt comes back from the browser, so nothing in it is
        # trusted: the file must be one the project declares editable, the
        # restoration must leave exactly the removed declaration back in the
        # entry that owned it, and removing that declaration again must give
        # back the file as it is now -- so nothing else can be written.
        let receipt = request["restoreWrite"]
        # Only a receipt this worker issued for a removal of exactly this
        # declaration and value, and not yet undone, may be restored.
        let issued = issuedReceipts
        for index in 0 ..< issued.len:
          let row = issued[index]
          if row{"receipt"} == receipt and row{"schemaKey"}.getStr() == request["schemaKey"].getStr() and
              row{"property"}.getStr() == property and row{"value"}.getStr() == request["value"].getStr():
            restoreRecord = index
        if restoreRecord < 0:
          raise newException(ValueError, "Undo refused: this receipt was not issued by a removal of " &
            property & " in this project, or that removal was already undone. No source was changed.")
        let file = receipt["file"].getStr()
        var declared = false
        for list in [manifest{"editableStyles"}, manifest{"editableStyleSources"}]:
          if list == nil or list.kind != JArray: continue
          for entry in list:
            if entry{"file"}.getStr() == file: declared = true
        if not declared:
          raise newException(ValueError, "Undo refused: " & file & " is not an editable project source. No source was changed.")
        let current = readFile(safePath(root, file))
        if $secureHash(current) != request["expectedSourceHash"].getStr():
          raise newException(ValueError, "Source changed since this inspector edit began.")
        restoreReceipt = SourceWriteReceipt(recorded: true, file: file,
          offset: receipt["offset"].getInt(), before: receipt["before"].getStr(),
          after: receipt["after"].getStr(), uniqueWhenWritten: receipt["unique"].getBool(),
          afterHash: receipt["afterHash"].getStr())
        if $secureHash(current) == restoreReceipt.afterHash:
          # The file the removal left: its lines must be where it wrote them.
          if restoreReceipt.offset + restoreReceipt.after.len > current.len or
              current[restoreReceipt.offset ..< restoreReceipt.offset + restoreReceipt.after.len] != restoreReceipt.after:
            raise newException(ValueError, "Undo refused: the removal's receipt does not describe " & file & ". No source was changed.")
          restoreReceipt.afterContent = current
        else:
          # Changed since: only the receipt's unique-lines rule may place it.
          # A NUL never equals a source file, so the exact-file path is off.
          restoreReceipt.afterContent = "\x00"
        let restored = restoreSourceWrite(current, restoreReceipt, "Undo")
        if not restored.ok: raise newException(ValueError, restored.message)
        for entry in describeEditableStyles(root, manifest, file, restored.content):
          if entry{"key"}.getStr() == request["schemaKey"].getStr():
            if literalMap != nil: raise newException(ValueError, "Ambiguous editable source schema.")
            literalMap = entry
        let refused = "Undo refused: the receipt does not put back exactly the removed " & property &
          " declaration. No source was changed."
        if literalMap == nil or literalMap{"file"}.getStr() != file or
            literalMap{"values", property} == nil or
            literalMap["values"][property].getStr() != request["value"].getStr():
          raise newException(ValueError, refused)
        let declaration = literalMap{"sourceDeclarations", property}
        if declaration != nil and (declaration{"component"} != nil or declaration{"property"}.getStr() != property):
          raise newException(ValueError, refused)
        let inverse = removeCssInNimConst(restored.content, literalMap{"const"}.getStr(),
          literalMap{"selector"}.getStr(), property)
        if not inverse.ok or inverse.content != current or inverse.oldValue != request["value"].getStr():
          raise newException(ValueError, refused)
        nativeProperty = property
        nativeAfter = request["value"].getStr()
      else:
        for entry in describeEditableStyles(root, manifest):
          if entry{"key"}.getStr() == request{"schemaKey"}.getStr():
            if literalMap != nil: raise newException(ValueError, "Ambiguous editable source schema.")
            literalMap = entry
        if literalMap == nil: raise newException(ValueError, "Unsupported editable source schema.")
      if literalMap{"elementId"}.getStr() != request{"target"}.getStr() or
          literalMap{"storyId"}.getStr() != request{"storyId"}.getStr():
        raise newException(ValueError, "Editable source target mismatch.")
      var allowed = false
      for candidate in literalMap{"properties"}:
        if candidate.getStr() == property: allowed = true
      if not allowed: raise newException(ValueError, "Property is not owned by this source schema.")
      if not restore:
        let source = readFile(safePath(root, literalMap{"file"}.getStr()))
        if $secureHash(source) != request{"expectedSourceHash"}.getStr():
          raise newException(ValueError, "Source changed since this inspector edit began.")
      var parsed: CSSPropertyValue
      if not removal:
        parsed = parseCssPropertyValue(property, request{"value"}.getStr())
        let validation = validateCssPropertyValue(PropertyInfo(name: property,
          directStyleAllowed: true), PropertyEditRequest(property: property,
          newValue: request{"value"}.getStr(), kind: pekCss, scope: pesLocal), parsed)
        if validation.len > 0: raise newException(ValueError, validation[0].message)
      if not restore:
        if literalMap{"values", property} == nil or
            literalMap["values"][property].getStr() != request["expectedValue"].getStr():
          raise newException(ValueError, "Authored property changed before this edit.")
        let declaration = literalMap{"sourceDeclarations", property}
        nativeProperty = if declaration == nil: property else: declaration["property"].getStr()
        nativeBefore = if declaration == nil: request["expectedValue"].getStr() else: declaration["value"].getStr()
        if removal:
          # Each editable declaration states whether this writer can remove
          # it (`removalStatement`); the same statement, re-derived from the
          # file under the project lock, is the act-time answer.
          let statement = literalMap{"removals", property}
          if statement == nil or statement.kind != JString:
            raise newException(ValueError, "This source entry does not state whether its writer can remove " & property & ".")
          if statement.getStr().len > 0: raise newException(ValueError, statement.getStr())
          nativeAfter = ""
        elif literalMap{"edits", property}.getStr().len > 0:
          # The same statement the metadata carries, re-derived under the
          # project lock: a declaration shared by a selector list.
          raise newException(ValueError, literalMap["edits"][property].getStr())
        elif declaration != nil and declaration{"component"} != nil:
          nativeAfter = patchCssQuad(nativeProperty,nativeBefore,request["value"].getStr(),
            declaration["component"].getInt(),request{"sourceValue"}.getStr())
          if nativeAfter.len == 0: raise newException(ValueError, "Unsupported compound edit or stale sibling restoration.")
        else:
          nativeAfter = request["value"].getStr()
          if request{"sourceValue"} != nil and request["sourceValue"].getStr() != nativeAfter:
            raise newException(ValueError, "Source restoration does not match this property value.")
      # Even a canonical no-op must validate the actual declaration under the
      # project lock. An explicit restoration may still change compound siblings.
      if not removal and not restore and parseCssPropertyValue(property,
          request["expectedValue"].getStr()).canonical == parsed.canonical and
          (request{"sourceValue"} == nil or nativeAfter == nativeBefore):
        let source = readFile(safePath(root, literalMap{"file"}.getStr()))
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
        property: request{"property"}.getStr(), removable: removal)
    adapter.readFile = proc(file: string): WorkspaceReadResult =
      WorkspaceReadResult(ok: true, content: readFile(safePath(root, file)))
    adapter.writeFile = proc(file, content: string): WorkspaceOperationResult =
      let target = safePath(root, file)
      # The receipt store is the one transaction file that may not exist yet;
      # its journaled "before" is then empty (an empty store).
      var original = if file == removalReceiptsRelPath and not fileExists(target): "" else: readFile(target)
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
      if inspectorEdit and removal:
        let removed = removeCssInNimConst(content, literalMap{"const"}.getStr(),
          literalMap{"selector"}.getStr(), nativeProperty)
        if not removed.ok or removed.oldValue != nativeBefore:
          return WorkspacePatchResult(ok: false, diagnostics: @[WorkspaceEditDiagnostic(
            kind: wedSourceConflict, message: if removed.ok:
              "Source declaration changed or cannot be safely removed." else: removed.message)])
        removalBefore = content
        removalAfter = removed.content
        return WorkspacePatchResult(ok: true, patch: WorkspaceFilePatch(file: schema.file,
          beforeContent: content, afterContent: removed.content, fullReload: true))
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
        var plan = SourceEditPlan(file: literalMap{"file"}.getStr(),
          schemaKey: literalMap{"key"}.getStr(), property: request{"property"}.getStr(),
          oldValue: request{"expectedValue"}.getStr(), expectedOldValue: nativeBefore,
          newValue: request{"value"}.getStr(), scope: pesLocal, sourceScope: sskLocalInstance,
          reversible: true)
        if removal: plan.planKind = cspPropertyRemoval
        if restore:
          # The framework puts back exactly the receipt's lines and never asks
          # `patchFile` for a value (`restoreSourceWrite`).
          plan.restoreWrite = restoreReceipt
          plan.expectedOldValue = ""
        vm.inspector.journalSourceEdit(plan)
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
        var response = %* {"ok": true, "catalog": built, "manifest": manifest, "storyId": storyId}
        if inspectorEdit:
          response["sourceEdit"] = %* {"before":nativeBefore,"after":nativeAfter}
          if removal:
            # What undo hands back: the whole lines this removal replaced.
            let receipt = sourceWriteReceipt(literalMap{"file"}.getStr(), removalBefore, removalAfter)
            response["sourceEdit"]["removed"] = %true
            response["sourceEdit"]["receipt"] = %* {"file": receipt.file, "offset": receipt.offset,
              "before": receipt.before, "after": receipt.after, "unique": receipt.uniqueWhenWritten,
              "afterHash": $secureHash(removalAfter)}
          if restore: response["sourceEdit"]["restored"] = %true
        if inspectorEdit and (removal or restore):
          # Part of the transaction: written through the journaled writer
          # before the journal is retired, so a store that cannot be written
          # rolls the source and catalog back (the `defer` recovery) and the
          # act is reported refused -- never a write behind a failed ACK.
          var issued = issuedReceipts.copy()
          if removal:
            var record = %* {"schemaKey": literalMap{"key"}.getStr(), "property": request["property"].getStr(),
              "value": nativeBefore, "receipt": response["sourceEdit"]["receipt"]}
            if literalMap{"scope"}.getStr() == "shared-class":
              # A compiled binding goes away with its last declaration. A
              # re-offer record (deduplicated, never evicted with the
              # receipts) keeps the property offered for every element the
              # rule matches until a removal of it is undone; the receipt
              # names it so its undo can drop it.
              let offer = %* {"file": literalMap{"file"}, "const": literalMap{"const"},
                "selector": literalMap{"selector"}, "property": request["property"].getStr()}
              record["offer"] = offer
              var known = false
              for row in issued:
                if row{"receipt"} == nil and row{"offer"} == offer: known = true
              if not known: issued.add(%* {"offer": offer})
            issued.add record
            # The undo cap counts receipts only; re-offer records stay.
            var receipts = 0
            for row in issued:
              if row{"receipt"} != nil: inc receipts
            var index = 0
            while receipts > 64 and index < issued.len:
              if issued[index]{"receipt"} != nil:
                issued.elems.delete(index)
                dec receipts
              else: inc index
          else:
            let offer = issued[restoreRecord]{"offer"}
            issued.elems.delete(restoreRecord)
            if offer != nil:
              # Undone: the declaration is back, and its re-offer ends.
              var index = 0
              while index < issued.len:
                if issued[index]{"receipt"} == nil and issued[index]{"offer"} == offer:
                  issued.elems.delete(index)
                else: inc index
          var stored: WorkspaceOperationResult
          try:
            stored = adapter.writeFile(removalReceiptsRelPath, $issued)
          except CatchableError as error:
            stored = WorkspaceOperationResult(ok: false, message: error.msg)
          if not stored.ok:
            raise newException(ValueError, "The removal receipt store " & removalReceiptsRelPath &
              " could not be written (" & stored.message & "); the source and catalog were restored. Nothing was changed.")
        # Described after the receipt store is written: a compiled binding
        # whose last declaration this removal took keeps offering it.
        response["editableStyles"] = describeEditableStyles(root, manifest)
        if fileExists(journalFile): removeFile(journalFile)
        echo $response
      dispose()
    return exitCode
  except CatchableError as error:
    echo $(%* {"ok": false, "diagnostic": error.msg})
    return 4
