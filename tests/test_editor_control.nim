## Production headless editor-control acceptance. No mocked dispatcher or workspace;
## this suite exercises real EditorVM signal state and
## command implementation. One focus-renderer invocation counter substitutes DOM
## solely to detect repeated side effects under duplicate approval delivery; an
## unchanged viewport alone would not detect that bug. Controlled async job
## completion callbacks additionally prove immediate/deferred/closure races and
## a throwing scheduler proves transport setup failure. Legacy source callback
## traps model a success-only interactive adapter solely to verify unsupported
## typed admission calls none of its callbacks; they never stand in for a build;
## real source/compiler coverage lives in the registered source suite.
## Build completion callbacks deliberately substitute compiler/publication outcomes
## to isolate compile versus publication failure and exception ordering. They do
## not prove filesystem/compiler behavior; registered source tests use the actual
## Nim producer and a real unwritable output directory for that boundary.
## Full GUI acceptance separately proves actual DOM focus/highlight and CLI/HTTP.
## A small capture callback isolates renderer capability discovery and readiness
## admission; it does not prove mounted HTML. The registered GUI suite compares
## captures from the advertised operation with the actual iframe document.
import std/[json, unittest, tables, strutils]
import isonim/core/[signals, owner]
import isonim/editor/[control, viewmodels, workspace]

suite "Editor control":
  test "disconnected approval cannot apply a pending request":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "test"
      vm.controlInstanceId = "one"
      vm.agentControlApproval.val = true
      let before = vm.controlSnapshot()
      let request = %* {"workspace": "test", "instance": "one", "commandId": "disconnectedApproval",
        "command": "viewport", "viewport": "phone", "expectedRevision": before["revision"]}
      let pending = vm.admitControlOperation(request)
      check pending["status"].getStr() == "pending"
      vm.controlConnected = false
      for approve in [true, false]:
        check vm.resolveControlApproval("disconnectedApproval", approve)["error"].getStr() == "disconnected_instance"
        check vm.controlOperations["disconnectedApproval"] == pending
        check vm.controlSnapshot() == before
      vm.controlConnected = true
      check vm.resolveControlApproval("disconnectedApproval", true)["status"].getStr() == "applied"
      check vm.viewport.val.slug == "phone"
      dispose()

  test "advertised preview capture executes and disabled renderers reject it":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "test"
      vm.controlInstanceId = "one"
      var captures = 0
      var ready = true
      vm.controlCaptureAdapter = proc(): JsonNode =
        inc captures
        %* {"ready": ready, "format": "text/html", "documentHtml": "<html><body>Capture</body></html>"}
      let before = vm.controlSnapshot()
      var advertisedCapture = ""
      for capability in before["capabilities"]:
        if capability.getStr().startsWith("capture-"):
          check advertisedCapture.len == 0
          advertisedCapture = capability.getStr()
      check advertisedCapture == "capture-preview"
      let request = %* {"workspace": "test", "instance": "one", "commandId": "captureReady",
        "command": advertisedCapture, "expectedRevision": before["revision"]}
      let applied = vm.admitControlOperation(request)
      check applied["status"].getStr() == "applied"
      check applied{"result", "ready"}.getBool()
      check applied{"result", "format"}.getStr() == "text/html"
      check captures == 1
      check vm.admitControlOperation(request) == applied
      check captures == 1
      ready = false
      var unready = request.copy()
      unready["commandId"] = %"captureUnready"
      unready["expectedRevision"] = vm.controlSnapshot()["revision"]
      let notReady = vm.admitControlOperation(unready)
      check notReady["status"].getStr() == "failed"
      check notReady["error"].getStr() == "preview_not_ready"
      check notReady{"result", "ready"}.getBool(true) == false
      check captures == 2
      for platform in [pbTui, pbWeb]:
        vm.platform.val = platform
        if platform == pbWeb: vm.controlCaptureAdapter = nil
        let disabled = vm.controlSnapshot()
        check %"capture-preview" notin disabled["capabilities"].elems
        check %"capture-preview-html" notin disabled["capabilities"].elems
        var unavailable = request.copy()
        unavailable["commandId"] = %($platform)
        unavailable["expectedRevision"] = disabled["revision"]
        let failed = vm.admitControlOperation(unavailable)
        check failed["status"].getStr() == "failed"
        check failed["error"].getStr() == "capability_or_permission"
        check captures == 2
        check vm.controlState() == disabled
      dispose()

  test "duplicate recovered approval invokes the renderer exactly once":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "test"
      vm.controlInstanceId = "one"
      vm.agentControlApproval.val = true
      var rendererInvocations = 0
      vm.controlFocusAdapter = proc(target: string): bool =
        check target == "composer"
        inc rendererInvocations
        true
      let request = %* {"workspace": "test", "instance": "one", "commandId": "focusRecovery",
        "command": "focus", "target": "composer", "expectedRevision": vm.controlSnapshot()["revision"]}
      check vm.admitControlOperation(request)["status"].getStr == "pending"
      check rendererInvocations == 0
      let delivery = %* {"status": "approved", "approvalDecision": true, "request": request}
      let applied = vm.deliverControlOperation(delivery)
      check applied["status"].getStr == "applied"
      check vm.deliverControlOperation(delivery) == applied
      check vm.admitControlOperation(request) == applied
      check rendererInvocations == 1
      dispose()

  test "durable approval delivery applies once and does not bypass a human revision":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "test"
      vm.controlInstanceId = "one"
      vm.agentControlApproval.val = true
      let request = %* {"workspace": "test", "instance": "one", "commandId": "recovered",
        "command": "viewport", "viewport": "phone", "expectedRevision": vm.controlSnapshot()["revision"]}
      check vm.admitControlOperation(request)["status"].getStr == "pending"
      let delivery = %* {"status": "approved", "approvalDecision": true, "request": request}
      let applied = vm.deliverControlOperation(delivery)
      check applied["status"].getStr == "applied"
      check vm.viewport.val.slug == "phone"
      check vm.deliverControlOperation(delivery) == applied
      check vm.controlActivity.val.len == 1
      var stale = request.copy()
      stale["commandId"] = %"staleRecovery"
      stale["viewport"] = %"tablet"
      stale["expectedRevision"] = vm.controlSnapshot()["revision"]
      check vm.admitControlOperation(stale)["status"].getStr == "pending"
      vm.controlFocusTarget.val = "human-other-control"
      check vm.deliverControlOperation(%* {"status": "approved", "approvalDecision": true, "request": stale})["error"].getStr == "revision_conflict"
      check vm.viewport.val.slug == "phone"
      dispose()

  test "recovery preserves revoked and denied decisions without applying":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "test"
      vm.controlInstanceId = "one"
      vm.agentControlApproval.val = true
      let request = %* {"workspace": "test", "instance": "one", "commandId": "revokedRecovery",
        "conversation": "chat", "command": "viewport", "viewport": "phone", "expectedRevision": vm.controlSnapshot()["revision"]}
      check vm.admitControlOperation(request)["status"].getStr == "pending"
      var wrongTab = request.copy()
      wrongTab["instance"] = %"other-instance"
      check vm.deliverControlOperation(%* {"status": "rejected", "error": "conversation_closed", "request": wrongTab})["error"].getStr == "stale_target"
      check vm.controlOperations["revokedRecovery"]["status"].getStr == "pending"
      let closed = vm.deliverControlOperation(%* {"status": "rejected", "error": "conversation_closed", "request": request})
      check closed["error"].getStr == "conversation_closed"
      check vm.deliverControlOperation(%* {"status": "approved", "approvalDecision": true, "request": request}) == closed
      var deniedRequest = request.copy()
      deniedRequest["commandId"] = %"deniedRecovery"
      check vm.admitControlOperation(deniedRequest)["status"].getStr == "pending"
      let denied = vm.deliverControlOperation(%* {"status": "rejected", "approvalDecision": false, "request": deniedRequest})
      check denied["error"].getStr == "denied"
      check vm.viewport.val.slug == "desktop"
      check vm.deliverControlOperation(%* {"status": "approved", "approvalDecision": true, "request": deniedRequest}) == denied
      dispose()
  test "terminal first delivery cannot execute under automatic policy":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "test"
      vm.controlInstanceId = "one"
      var rendererInvocations = 0
      vm.controlFocusAdapter = proc(target: string): bool =
        inc rendererInvocations
        true
      let before = vm.controlSnapshot()
      for error in ["conversation_closed", "denied", "capability_or_permission"]:
        let request = %* {"workspace": "test", "instance": "one", "commandId": error,
          "conversation": "closed-chat", "command": "focus", "target": "composer",
          "expectedRevision": before["revision"]}
        let delivery = %* {"status": "rejected", "error": error, "request": request}
        let denied = vm.deliverControlOperation(delivery)
        check denied["error"].getStr == error
        check vm.deliverControlOperation(delivery) == denied
        check vm.admitControlOperation(request) == denied
        check vm.deliverControlOperation(%* {"status": "approved", "approvalDecision": true, "request": request}) == denied
        check rendererInvocations == 0
        check vm.controlState() == before
        var collision = request.copy()
        collision["target"] = %"preview"
        check vm.deliverControlOperation(%* {"status": "rejected", "error": error, "request": collision})["error"].getStr == "command_id_collision"
      dispose()

  test "denial first delivery survives approval preference changes and stale revisions":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "test"
      vm.controlInstanceId = "one"
      vm.agentControlApproval.val = true
      let request = %* {"workspace": "test", "instance": "one", "commandId": "deny-unseen",
        "command": "viewport", "viewport": "phone", "expectedRevision": vm.controlSnapshot()["revision"]}
      vm.agentControlApproval.val = false
      let before = vm.controlSnapshot()
      let denial = vm.deliverControlOperation(%* {"status": "rejected", "approvalDecision": false,
        "error": "denied", "request": request})
      check denial["error"].getStr == "denied"
      check vm.controlState() == before
      check vm.viewport.val.slug == "desktop"
      check vm.admitControlOperation(request) == denial
      dispose()

  test "typed navigation has actual shared state":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM(newEditorWorkspace("Test", @[
        StoryGroup(name: "Pages", kind: skPage, items: @[
          StoryItem(name: "Home", group: "Pages", kind: skPage),
          StoryItem(name: "Next", group: "Pages", kind: skPage)])], id = "test"))
      vm.controlInstanceId = "one"
      let state = vm.controlSnapshot()
      let request = %* {"workspace": "test", "instance": "one", "commandId": "open1",
        "command": "open-story", "storyId": state["stories"][1]["id"], "expectedRevision": state["revision"]}
      let result = vm.admitControlOperation(request)
      check result["status"].getStr == "applied"
      check vm.selectedStory.val.name == "Next"
      check vm.admitControlOperation(request) == result
      dispose()

  test "human selection invalidates a queued revision":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM(newEditorWorkspace("Test", @[
        StoryGroup(name: "Pages", kind: skPage, items: @[
          StoryItem(name: "Home", group: "Pages", kind: skPage),
          StoryItem(name: "Next", group: "Pages", kind: skPage)])], id = "test"))
      vm.controlInstanceId = "one"
      let revision = vm.controlSnapshot()["revision"]
      discard vm.selectStory(StoryRef(group: "Pages", name: "Home", kind: skPage))
      let request = %* {"workspace": "test", "instance": "one", "commandId": "stale",
        "command": "open-story", "storyId": vm.controlState()["stories"][1]["id"], "expectedRevision": revision}
      check vm.admitControlOperation(request)["error"].getStr == "revision_conflict"
      check vm.selectedStory.val.name == "Home"
      dispose()

  test "approval remains pending and rejection preserves all view state":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "test"
      vm.controlInstanceId = "one"
      vm.agentControlApproval.val = true
      let state = vm.controlSnapshot()
      let request = %* {"workspace": "test", "instance": "one", "commandId": "reject1",
        "command": "viewport", "viewport": "phone", "expectedRevision": state["revision"]}
      check vm.admitControlOperation(request)["status"].getStr == "pending"
      check vm.controlState() == state
      check vm.resolveControlApproval("reject1", false)["status"].getStr == "rejected"
      check vm.controlState() == state
      check vm.admitControlOperation(request)["status"].getStr == "rejected"
      dispose()

  test "approved operation applies exactly once":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "test"
      vm.controlInstanceId = "one"
      vm.agentControlApproval.val = true
      let request = %* {"workspace": "test", "instance": "one", "commandId": "approved1",
        "command": "viewport", "viewport": "phone", "expectedRevision": vm.controlSnapshot()["revision"]}
      check vm.admitControlOperation(request)["status"].getStr == "pending"
      let applied = vm.resolveControlApproval("approved1", true)
      check applied["status"].getStr == "applied"
      check vm.viewport.val.slug == "phone"
      check vm.resolveControlApproval("approved1", true) == applied
      check vm.admitControlOperation(request) == applied
      check vm.controlActivity.val.len == 1
      dispose()

  test "approval rechecks real human panel changes":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "test"
      vm.controlInstanceId = "one"
      vm.agentControlApproval.val = true
      let request = %* {"workspace": "test", "instance": "one", "commandId": "staleApproval",
        "command": "viewport", "viewport": "phone", "expectedRevision": vm.controlSnapshot()["revision"]}
      check vm.admitControlOperation(request)["status"].getStr == "pending"
      vm.togglePanel(epSidebar)
      check vm.resolveControlApproval("staleApproval", true)["error"].getStr == "revision_conflict"
      check vm.viewport.val.slug == "desktop"
      check not vm.panels.val.sidebar
      dispose()

  test "same mutation ID with changed payload is a collision":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "test"
      vm.controlInstanceId = "one"
      var request = %* {"workspace": "test", "instance": "one", "commandId": "duplicate",
        "command": "viewport", "viewport": "phone", "expectedRevision": vm.controlSnapshot()["revision"]}
      check vm.admitControlOperation(request)["status"].getStr == "applied"
      request["viewport"] = %"tablet"
      check vm.admitControlOperation(request)["error"].getStr == "command_id_collision"
      check vm.viewport.val.slug == "phone"
      dispose()

  test "closed conversation revokes approval without applying it":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "test"
      vm.controlInstanceId = "one"
      vm.agentControlApproval.val = true
      let request = %* {"workspace": "test", "instance": "one", "conversation": "chatA",
        "commandId": "closed1", "command": "viewport", "viewport": "phone",
        "expectedRevision": vm.controlSnapshot()["revision"]}
      check vm.admitControlOperation(request)["status"].getStr == "pending"
      vm.revokeControlConversation("chatA")
      check vm.resolveControlApproval("closed1", true)["error"].getStr == "conversation_closed"
      check vm.viewport.val.slug == "desktop"
      dispose()

  test "unsupported renderer and durable source operations cannot claim success":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "test"
      vm.controlInstanceId = "one"
      let state = vm.controlSnapshot()
      check %"focus" notin state["capabilities"].elems
      check %"highlight" notin state["capabilities"].elems
      check %"create-story" notin state["capabilities"].elems
      for command in ["focus", "highlight", "create-story", "save"]:
        let request = %* {"workspace": "test", "instance": "one", "commandId": command,
          "command": command, "target": "composer", "expectedRevision": state["revision"]}
        check vm.admitControlOperation(request)["status"].getStr == "failed"
        check vm.controlState() == state
      dispose()

  test "legacy success-only source callbacks cannot admit typed durable commands":
    createRoot proc(dispose: proc()) =
      var invocations = 0
      let adapter = WorkspaceEditAdapter()
      adapter.readFile = proc(file: string): WorkspaceReadResult =
        inc invocations
        WorkspaceReadResult(ok: true, content: "legacy source")
      adapter.writeFile = proc(file, content: string): WorkspaceOperationResult =
        inc invocations
        WorkspaceOperationResult(ok: true)
      adapter.compile = proc(stories: seq[StoryRef]): WorkspaceOperationResult =
        inc invocations
        WorkspaceOperationResult(ok: true)
      adapter.reloadPreview = proc(stories: seq[StoryRef]; fullReload: bool): WorkspaceOperationResult =
        inc invocations
        WorkspaceOperationResult(ok: true)
      let vm = createEditorVM(newEditorWorkspace("Legacy", @[], id = "test", editAdapter = adapter,
        permissions = EditorWorkspacePermissions(readSource: true, writeSource: true, createStory: true)))
      vm.controlInstanceId = "one"
      let before = vm.controlSnapshot()
      check %"build" notin before["capabilities"].elems
      check %"create-story" notin before["capabilities"].elems
      for command in ["build", "create-story"]:
        let request = %* {"workspace":"test", "instance":"one", "commandId":command,
          "command":command, "component":"Card", "variantKey":"default", "stateKey":"busy",
          "expectedRevision": before["revision"]}
        let failed = vm.admitControlOperation(request)
        check failed["status"].getStr() == "failed"
        check failed["diagnostic"].getStr().contains("explicitly durable")
        check vm.controlState() == before
      check invocations == 0
      adapter.durableSourceControl = true
      check %"build" in vm.controlSnapshot()["capabilities"].elems
      check vm.evaluateCommand(EditorCommandRequest(kind: eckBuildProject)).status == ecsAvailable
      adapter.compile = nil
      check %"build" notin vm.controlSnapshot()["capabilities"].elems
      check vm.evaluateCommand(EditorCommandRequest(kind: eckBuildProject)).status == ecsDisabled
      dispose()

  test "selection is independent from focus and highlight":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "test"
      vm.controlInstanceId = "one"
      vm.inspector.setSelectionTree(@[
        ElementLayerRow(id: "first", tag: "button", label: "First"),
        ElementLayerRow(id: "second", tag: "div", label: "Second")])
      let request = %* {"workspace": "test", "instance": "one", "commandId": "select1",
        "command": "select", "target": "second", "expectedRevision": vm.controlSnapshot()["revision"]}
      check vm.admitControlOperation(request)["status"].getStr == "applied"
      check vm.inspector.selectedElement.val.id == "second"
      check vm.controlFocusTarget.val == ""
      check vm.controlHighlightTarget.val == ""
      dispose()

  test "wrong workspace and instance cannot mutate this host":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "test"
      vm.controlInstanceId = "one"
      for target in [("other", "one"), ("test", "two")]:
        let request = %* {"workspace": target[0], "instance": target[1], "commandId": "wrong",
          "command": "viewport", "viewport": "phone", "expectedRevision": vm.controlSnapshot()["revision"]}
        check vm.admitControlOperation(request)["error"].getStr == "stale_target"
        check vm.viewport.val.slug == "desktop"
      dispose()

  test "payload validation rejects secret-shaped fields and invalid types":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "test"
      vm.controlInstanceId = "one"
      var request = %* {"workspace": "test", "instance": "one", "commandId": "malformed",
        "command": "viewport", "viewport": "phone", "expectedRevision": vm.controlSnapshot()["revision"]}
      request["token"] = %"must-not-enter-activity"
      expect ValueError: discard commandRequest(request)
      request.delete("token")
      request["highlight"] = %"true"
      expect ValueError: discard commandRequest(request)
      dispose()

suite "Editor source operation completion":
  # Controlled completion callbacks substitute only the asynchronous project
  # job scheduler to cover callback races deterministically. They never claim
  # filesystem/compiler coverage; test_editor_source_project.py and the GUI suite
  # exercise the actual native producer and production transport separately.
  test "immediate and deferred completion share deduplication and terminal state":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "project"
      vm.controlInstanceId = "one"
      vm.workspacePermissions.val = EditorWorkspacePermissions(writeSource: true, createStory: true)
      var invocations = 0
      vm.controlAsyncCommandAdapter = proc(request: JsonNode; done: proc(ok: bool; data: JsonNode) {.closure.}) =
        inc invocations
        done(true, %* {"boundary": "durable"})
      let request = %* {"workspace":"project", "instance":"one", "commandId":"immediate",
        "command":"build", "expectedRevision":vm.controlSnapshot()["revision"]}
      check vm.admitControlOperation(request)["status"].getStr() == "applied"
      check vm.admitControlOperation(request)["status"].getStr() == "applied"
      check invocations == 1
      var finish: proc(ok: bool; data: JsonNode) {.closure.}
      vm.controlAsyncCommandAdapter = proc(request: JsonNode; done: proc(ok: bool; data: JsonNode) {.closure.}) =
        inc invocations
        finish = done
      var deferred = request.copy()
      deferred["commandId"] = %"deferred"
      deferred["expectedRevision"] = vm.controlSnapshot()["revision"]
      check vm.admitControlOperation(deferred)["status"].getStr() == "running"
      check vm.admitControlOperation(deferred)["status"].getStr() == "running"
      check invocations == 2
      finish(false, %* {"diagnostic":"actual worker failure"})
      check vm.controlOperations["deferred"]["status"].getStr() == "failed"
      check vm.controlOperations["deferred"]["diagnostic"].getStr() == "actual worker failure"
      finish(true, %* {"boundary":"late"})
      check vm.controlOperations["deferred"]["status"].getStr() == "failed"
      dispose()

  test "closure revokes running operation and late completion cannot resurrect it":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "project"
      vm.controlInstanceId = "one"
      vm.workspacePermissions.val = EditorWorkspacePermissions(writeSource: true)
      var invocations = 0
      var finish: proc(ok: bool; data: JsonNode) {.closure.}
      vm.controlAsyncCommandAdapter = proc(request: JsonNode; done: proc(ok: bool; data: JsonNode) {.closure.}) =
        inc invocations
        finish = done
      let request = %* {"workspace":"project", "instance":"one", "conversation":"chat",
        "commandId":"closed-build", "command":"build", "expectedRevision":vm.controlSnapshot()["revision"]}
      check vm.admitControlOperation(request)["status"].getStr() == "running"
      let closed = vm.deliverControlOperation(%* {"status":"rejected", "error":"conversation_closed", "request":request})
      check closed["error"].getStr() == "conversation_closed"
      finish(true, %* {"boundary":"durable"})
      check vm.controlOperations["closed-build"]["status"].getStr() == "rejected"
      check vm.deliverControlOperation(%* {"status":"running", "request":request}) == closed
      check invocations == 1
      dispose()


suite "Source adapter failures":
  # This throwing scheduler substitutes only delivery setup failure. Registered
  # native/GUI suites retain real filesystem and compiler boundaries.
  test "an immediate source transport exception is terminal and cannot restart work":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.workspaceId = "project"
      vm.controlInstanceId = "one"
      vm.workspacePermissions.val = EditorWorkspacePermissions(writeSource: true)
      var invocations = 0
      vm.controlAsyncCommandAdapter = proc(request: JsonNode; done: proc(ok: bool; data: JsonNode) {.closure.}) =
        inc invocations
        raise newException(IOError, "Source transport could not start")
      let request = %* {"workspace":"project", "instance":"one", "commandId":"setup-failure", "command":"build",
        "expectedRevision":vm.controlSnapshot()["revision"]}
      let failed = vm.admitControlOperation(request)
      check failed["status"].getStr() == "failed"
      check failed["diagnostic"].getStr() == "Source transport could not start"
      check vm.admitControlOperation(request) == failed
      check invocations == 1
      dispose()


suite "Durable build publication":
  for fault in ["compile-false", "compile-exception", "publication-false", "publication-exception", "success"]:
    test "typed build requires publication: " & fault:
      createRoot proc(dispose: proc()) =
        let adapter = WorkspaceEditAdapter(durableSourceControl: true)
        let vm = createEditorVM(newEditorWorkspace("Build", @[], id = "build", editAdapter = adapter,
          permissions = EditorWorkspacePermissions(readSource: true, writeSource: true, createStory: true)))
        var compileCalls, publicationCalls = 0
        var published = "previous usable preview"
        let generation = vm.livePreviewReloadGeneration.val
        adapter.compile = proc(stories: seq[StoryRef]): WorkspaceOperationResult =
          inc compileCalls
          check vm.workspaceEditStage.val == wesCompiling
          check stories.len == 0
          check published == "previous usable preview"
          if fault == "compile-exception": raise newException(ValueError, "Compiler threw")
          if fault == "compile-false":
            return WorkspaceOperationResult(ok: false, message: "Compiler rejected source")
          WorkspaceOperationResult(ok: true)
        adapter.reloadPreview = proc(stories: seq[StoryRef]; fullReload: bool): WorkspaceOperationResult =
          inc publicationCalls
          check vm.workspaceEditStage.val == wesReloading
          check compileCalls == 1
          check stories.len == 0
          check not fullReload
          if fault == "publication-exception": raise newException(ValueError, "Publication threw")
          if fault == "publication-false":
            return WorkspaceOperationResult(ok: false, diagnostics: @[
              WorkspaceEditDiagnostic(kind: wedReloadFailed, message: "Publication refused")])
          published = "new usable preview"
          WorkspaceOperationResult(ok: true)
        let outcome = vm.runEditorCommand(EditorCommandRequest(kind: eckBuildProject))
        check compileCalls == 1
        check publicationCalls == (if fault in ["compile-false", "compile-exception"]: 0 else: 1)
        if fault == "success":
          check outcome.status == ecsSucceeded
          check outcome.diagnostic.len == 0
          check vm.workspaceEditStage.val == wesClean
          check vm.workspaceEditDiagnostics.val.len == 0
          check vm.livePreviewReloadGeneration.val == generation + 1
          check published == "new usable preview"
        else:
          check outcome.status == ecsFailed
          check outcome.diagnostic.contains(if fault.startsWith("compile"): "Compiler" else: "Publication")
          check vm.workspaceEditStage.val == wesFailed
          check vm.workspaceEditDiagnostics.val.len == 1
          check vm.workspaceEditDiagnostics.val[0].kind == (if fault.startsWith("compile"): wedCompileFailed else: wedReloadFailed)
          check vm.livePreviewReloadGeneration.val == generation
          check published == "previous usable preview"
        dispose()
