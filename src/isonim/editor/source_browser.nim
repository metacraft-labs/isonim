## Opt-in thin view over a project's native source/build adapter. No compiler or
## filesystem work runs on the browser thread. Only successful compiled catalogs
## replace preview data; build-start acknowledgement is never completion.
when not defined(js): {.error: "Source browser bridge requires JS".}
import std/json
import isonim/core/signals
import isonim/editor/[viewmodels, workspace, source_catalog]

proc attachSourceProject*(vm: EditorVM; base: EditorWorkspace) =
  proc applyCatalog(reply: JsonNode) =
    let manifest = reply{"manifest"}
    if manifest == nil or manifest{"workspace"}.getStr() != vm.workspaceId:
      raise newException(ValueError, "Source project workspace mismatch.")
    let compiled = sourceCatalogWorkspace(reply["catalog"], manifest, base)
    vm.refreshWorkspaceCatalog(compiled)
    vm.controlSourceFixtures = sourceFixtures(manifest)
    vm.sourceAdapterReady.val = true
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
              done(true, data)
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
