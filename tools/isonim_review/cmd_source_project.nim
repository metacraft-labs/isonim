## Native worker for an explicitly opted-in project. Runs the production typed
## dispatcher and WorkspaceEditAdapter transaction against actual source files.
## The manifest belongs to the project, never to an RPC caller. Build stdout is
## a rendered catalog JSON document; failed builds never publish a new catalog.
import std/[json, os, osproc, strutils, tempfiles]
import isonim/core/[signals, owner]
import isonim/editor/[control, source_catalog, workspace]

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

proc cmdSourceProject*(args: seq[string]): int =
  if args.len != 2:
    echo $(%* {"ok": false, "diagnostic": "source-project requires root and request file"})
    return 2
  try:
    let root = args[0].absolutePath.normalizedPath
    recoverSourceTransaction(root)
    if args[1] == "--recover":
      echo $(%* {"ok": true})
      return 0
    let manifest = parseFile(safePath(root, ".isonim/source-project.json"))
    let request = parseFile(args[1])
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
      let typed = commandRequest(request)
      let outcome = vm.runEditorCommand(typed)
      if outcome.status != ecsSucceeded:
        recoverSourceTransaction(root)
        echo $(%* {"ok": false, "diagnostic": outcome.diagnostic, "stage": $vm.workspaceEditStage.val, "variants": %vm.variants.variants.val, "pendingEdits": %vm.inspector.pendingSourceEdits.val})
        exitCode = 4
      else:
        if fileExists(journalFile): removeFile(journalFile)
        echo $(%* {"ok": true, "catalog": built, "manifest": manifest,
          "storyId": if typed.kind == eckCreateStory: request{"component"}.getStr() & " / " & request{"variantKey"}.getStr() & " " & request{"stateKey"}.getStr() else: ""})
      dispose()
    return exitCode
  except CatchableError as error:
    echo $(%* {"ok": false, "diagnostic": error.msg})
    return 4
