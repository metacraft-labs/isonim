## Production headless editor-control acceptance. No mocked dispatcher, workspace,
## filesystem or compiler: this suite exercises real EditorVM signal state and
## command implementation. One focus-renderer invocation counter substitutes DOM
## solely to detect repeated side effects under duplicate approval delivery; an
## unchanged viewport alone would not detect that bug. Other tests omit rendering.
## Full GUI acceptance separately proves actual DOM focus/highlight and CLI/HTTP.
import std/[json, unittest, tables]
import isonim/core/[signals, owner]
import isonim/editor/[control, viewmodels, workspace]

suite "Editor control":
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
