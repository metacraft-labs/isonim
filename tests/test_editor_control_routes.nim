## Production JSON-RPC registry contract tests. No mocked registry/dispatcher:
## actual credentials, instance leases, scoped conversation tokens, queues and ACK
## state are exercised directly. Test-authored JSON acknowledgements isolate the
## transport registry; they do not prove browser application. The separately
## registered full GUI/CLI acceptance supplies that real application boundary.
import std/[json, os, unittest]
import isonim/editor/design_review/control_routes
import isonim/core/[signals, owner]
import isonim/editor/[control, viewmodels]

proc rpc(reg: EditorControlRegistry; name: string; params: JsonNode; token: string): JsonNode =
  reg.rpcDispatch(%* {"jsonrpc": "2.0", "id": 1, "method": name, "params": params}, token)
proc register(reg: EditorControlRegistry; workspace = "work"): JsonNode =
  rpc(reg, "editor.register", %* {"workspace": workspace, "state": {"revision": 0}}, "browser-bootstrap")["result"]
proc target(registration: JsonNode): JsonNode =
  %* {"workspace": registration["workspace"], "instance": registration["instance"], "epoch": registration["epoch"]}
proc command(registration: JsonNode; id = "op1"): JsonNode =
  result = target(registration)
  result["command"] = %"viewport"
  result["viewport"] = %"phone"
  result["commandId"] = %id
  result["expectedRevision"] = %0

suite "Editor JSON-RPC scopes and acknowledgement":
  test "real queued command revoked before first VM delivery has no effects":
    createRoot proc(dispose: proc()) =
      let reg = newEditorControlRegistry("browser-bootstrap")
      let vm = createEditorVM()
      vm.workspaceId = "work"
      let browser = register(reg)
      vm.controlInstanceId = browser["instance"].getStr()
      let scope = reg.bindConversation(reg.validateBrowserScope(target(browser), browser["browserToken"].getStr()), "undelivered-chat")
      var queuedCommand = command(browser, "closed-before-delivery")
      queuedCommand["expectedRevision"] = vm.controlSnapshot()["revision"]
      check rpc(reg, "editor.command", queuedCommand, scope.token)["result"]["status"].getStr == "queued"
      let before = vm.controlState()
      reg.revokeConversation("undelivered-chat")
      let notification = rpc(reg, "editor.poll", target(browser), browser["browserToken"].getStr())["result"]["commands"][0]
      let closed = vm.deliverControlOperation(notification)
      check closed["error"].getStr == "conversation_closed"
      check vm.controlState() == before
      check vm.viewport.val.slug == "desktop"
      check vm.deliverControlOperation(notification) == closed
      var ack = target(browser)
      var contradictory = closed.copy()
      contradictory["status"] = %"applied"
      contradictory.delete("error")
      ack["operation"] = contradictory
      check rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())["result"]["error"].getStr == "conversation_closed"
      check rpc(reg, "editor.poll", target(browser), browser["browserToken"].getStr())["result"]["commands"].len == 1
      ack["operation"] = closed
      check rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())["result"]["error"].getStr == "conversation_closed"
      check rpc(reg, "editor.poll", target(browser), browser["browserToken"].getStr())["result"]["commands"].len == 0
      check rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())["result"]["error"].getStr == "conversation_closed"
      ack["operation"] = contradictory
      check rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())["result"]["error"].getStr == "conversation_closed"
      check rpc(reg, "editor.poll", target(browser), browser["browserToken"].getStr())["result"]["commands"].len == 0
      check vm.controlState() == before
      dispose()

  test "approval survives response loss until application ACK and decisions are idempotent":
    let reg = newEditorControlRegistry("browser-bootstrap")
    let browser = register(reg)
    let queued = rpc(reg, "editor.command", command(browser), browser["controlToken"].getStr())["result"]
    var pending = queued.copy()
    pending["status"] = %"pending"
    var ack = target(browser)
    ack["operation"] = pending
    discard rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())
    var decision = target(browser)
    decision["operationId"] = %"op1"
    decision["approve"] = %true
    let approved = rpc(reg, "editor.approve", decision, browser["browserToken"].getStr())["result"]
    check approved["status"].getStr == "approved"
    check rpc(reg, "editor.approve", decision, browser["browserToken"].getStr())["result"] == approved
    for index in 0 .. 1:
      let delivery = rpc(reg, "editor.poll", target(browser), browser["browserToken"].getStr())["result"]["commands"]
      check delivery.len == 1
      check delivery[0] == approved
    decision["approve"] = %false
    check rpc(reg, "editor.approve", decision, browser["browserToken"].getStr())["error"]["message"].getStr == "approval_decision_conflict"
    var applied = pending.copy()
    applied["status"] = %"applied"
    ack["operation"] = applied
    let completed = rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())["result"]
    check completed["status"].getStr == "applied"
    check completed["approvalDecision"].getBool()
    check rpc(reg, "editor.poll", target(browser), browser["browserToken"].getStr())["result"]["commands"].len == 0
    decision["approve"] = %true
    check rpc(reg, "editor.approve", decision, browser["browserToken"].getStr())["result"] == completed
    check rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())["result"] == completed

  test "rejected decisions redeliver and revoked approval cannot recover into application":
    let reg = newEditorControlRegistry("browser-bootstrap")
    let browser = register(reg)
    let scope = reg.bindConversation(reg.validateBrowserScope(target(browser), browser["browserToken"].getStr()), "chat")
    for id in ["deny", "close"]:
      let queued = rpc(reg, "editor.command", command(browser, id), scope.token)["result"]
      var pending = queued.copy()
      pending["status"] = %"pending"
      var ack = target(browser)
      ack["operation"] = pending
      discard rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())
      var decision = target(browser)
      decision["operationId"] = %id
      decision["approve"] = %(id == "close")
      let decided = rpc(reg, "editor.approve", decision, browser["browserToken"].getStr())["result"]
      check rpc(reg, "editor.approve", decision, browser["browserToken"].getStr())["result"] == decided
      if id == "deny":
        check decided["error"].getStr == "denied"
        let delivery = rpc(reg, "editor.poll", target(browser), browser["browserToken"].getStr())["result"]["commands"]
        check delivery.len == 1
        check delivery[0] == decided
        decision["approve"] = %true
        check rpc(reg, "editor.approve", decision, browser["browserToken"].getStr())["error"]["message"].getStr == "approval_decision_conflict"
        pending["status"] = %"rejected"
        pending["error"] = %"denied"
        ack["operation"] = pending
        discard rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())
      else:
        reg.revokeConversation("chat")
        check rpc(reg, "editor.approve", decision, browser["browserToken"].getStr())["result"]["error"].getStr == "conversation_closed"
        let delivered = rpc(reg, "editor.poll", target(browser), browser["browserToken"].getStr())["result"]["commands"]
        check delivered.len == 1
        check delivered[0]["status"].getStr == "rejected"
        check delivered[0]["error"].getStr == "conversation_closed"
        pending["status"] = %"applied"
        ack["operation"] = pending
        check rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())["result"]["error"].getStr == "conversation_closed"
        # The late applied ACK cannot suppress a closure notification it did
        # not consume. A matching browser rejection ACK terminates redelivery.
        check rpc(reg, "editor.poll", target(browser), browser["browserToken"].getStr())["result"]["commands"].len == 1
        ack["operation"] = delivered[0]
        let acknowledged = rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())["result"]
        check acknowledged["status"].getStr == "rejected"
        check acknowledged["error"].getStr == "conversation_closed"
        check rpc(reg, "editor.poll", target(browser), browser["browserToken"].getStr())["result"]["commands"].len == 0
  test "agent and absent credentials cannot register or gain browser authority":
    let reg = newEditorControlRegistry("browser-bootstrap")
    let browser = register(reg)
    for token in ["", browser["controlToken"].getStr(), "bad"]:
      check rpc(reg, "editor.register", %* {"workspace": "work"}, token)["error"]["message"].getStr == "browser_bootstrap_required"
    for methodName in ["editor.poll", "editor.ack", "editor.disconnect", "editor.approve", "editor.preference"]:
      check rpc(reg, methodName, target(browser), browser["controlToken"].getStr())["error"]["message"].getStr == "browser_credential_required"

  test "queue is observable without being applied and lost ACK retry deduplicates":
    let reg = newEditorControlRegistry("browser-bootstrap")
    let browser = register(reg)
    let request = command(browser)
    let queued = rpc(reg, "editor.command", request, browser["controlToken"].getStr())["result"]
    check queued["status"].getStr == "queued"
    check rpc(reg, "editor.command", request, browser["controlToken"].getStr())["result"] == queued
    var poll = target(browser)
    poll["state"] = %* {"revision": 0}
    let delivery = rpc(reg, "editor.poll", poll, browser["browserToken"].getStr())["result"]["commands"]
    check delivery.len == 1
    var completed = delivery[0].copy()
    completed["status"] = %"applied"
    completed["revision"] = %1
    var ack = target(browser)
    ack["operation"] = completed
    ack["state"] = %* {"revision": 1}
    check rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())["result"] == completed
    check rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())["result"] == completed
    check rpc(reg, "editor.command", request, browser["controlToken"].getStr())["result"] == completed
    check rpc(reg, "editor.state", target(browser), browser["controlToken"].getStr())["result"]["revision"].getInt == 1
    # A poll sent before the ACK may arrive afterwards; its older snapshot must
    # not make the next CLI command target a superseded revision.
    discard rpc(reg, "editor.poll", poll, browser["browserToken"].getStr())
    check rpc(reg, "editor.state", target(browser), browser["controlToken"].getStr())["result"]["revision"].getInt == 1

  test "changed duplicate payload and forged ACK are rejected":
    let reg = newEditorControlRegistry("browser-bootstrap")
    let browser = register(reg)
    var request = command(browser)
    let queued = rpc(reg, "editor.command", request, browser["controlToken"].getStr())["result"]
    request["viewport"] = %"tablet"
    check rpc(reg, "editor.command", request, browser["controlToken"].getStr())["error"]["message"].getStr == "command_id_collision"
    var ack = target(browser)
    var bad = queued.copy()
    bad["request"]["viewport"] = %"tablet"
    bad["status"] = %"applied"
    ack["operation"] = bad
    check rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())["error"]["message"].getStr == "acknowledgement_request_mismatch"

  test "instance identity epoch and credentials cannot cross tabs":
    let reg = newEditorControlRegistry("browser-bootstrap")
    let first = register(reg)
    let second = register(reg)
    check first["instance"] != second["instance"]
    check rpc(reg, "editor.command", command(second), first["controlToken"].getStr())["error"]["message"].getStr == "credential_scope_mismatch"
    var stale = command(first)
    stale["epoch"] = second["epoch"]
    check rpc(reg, "editor.command", stale, first["controlToken"].getStr())["error"]["message"].getStr == "stale_connection_epoch"
    stale = command(first)
    stale["workspace"] = %"other"
    check rpc(reg, "editor.command", stale, first["controlToken"].getStr())["error"]["message"].getStr == "wrong_workspace"
    stale.delete("instance")
    check rpc(reg, "editor.command", stale, first["controlToken"].getStr())["error"]["message"].getStr == "ambiguous_target: explicit instance required"

  test "conversation credentials cannot observe another chat operation":
    let reg = newEditorControlRegistry("browser-bootstrap")
    let browser = register(reg)
    let scope = reg.validateBrowserScope(target(browser), browser["browserToken"].getStr())
    let chatA = reg.bindConversation(scope, "chatA")
    let chatB = reg.bindConversation(scope, "chatB")
    check rpc(reg, "editor.command", command(browser), chatA.token)["result"]["status"].getStr == "queued"
    var wait = target(browser)
    wait["operationId"] = %"op1"
    check rpc(reg, "editor.wait", wait, chatA.token)["result"]["request"]["conversation"].getStr == "chatA"
    check rpc(reg, "editor.wait", wait, chatB.token)["error"]["message"].getStr == "operation_scope_mismatch"
    reg.revokeConversation("chatA")
    check rpc(reg, "editor.command", command(browser, "later"), chatA.token)["error"]["message"].getStr == "invalid_control_credential"

  test "disconnection revokes old epoch and does not target replacement tab":
    let reg = newEditorControlRegistry("browser-bootstrap")
    let old = register(reg)
    check rpc(reg, "editor.disconnect", target(old), old["browserToken"].getStr())["result"]["disconnected"].getBool
    check rpc(reg, "editor.poll", target(old), old["browserToken"].getStr())["error"]["message"].getStr == "disconnected_instance"
    let replacement = register(reg)
    check rpc(reg, "editor.command", command(old), old["controlToken"].getStr())["error"]["message"].getStr == "disconnected_instance"
    check rpc(reg, "editor.poll", target(replacement), replacement["browserToken"].getStr())["result"]["commands"].len == 0

  test "real lease timeout denies agents and only exact mounted browser can resume":
    let reg = newEditorControlRegistry("browser-bootstrap")
    let browser = register(reg)
    sleep(int(BrowserLeaseSeconds * 1000) + 100)
    check rpc(reg, "editor.command", command(browser), browser["controlToken"].getStr())["error"]["message"].getStr == "disconnected_instance"
    check rpc(reg, "editor.poll", target(browser), browser["controlToken"].getStr())["error"]["message"].getStr == "browser_credential_required"
    check rpc(reg, "editor.command", command(browser), browser["controlToken"].getStr())["error"]["message"].getStr == "disconnected_instance"
    check rpc(reg, "editor.poll", target(browser), browser["browserToken"].getStr())["result"]["commands"].len == 0
    check rpc(reg, "editor.command", command(browser), browser["controlToken"].getStr())["result"]["status"].getStr == "queued"

  test "unknown request fields never enter stored operation activity":
    let reg = newEditorControlRegistry("browser-bootstrap")
    let browser = register(reg)
    var bad = command(browser)
    bad["credential"] = %"private-marker"
    check rpc(reg, "editor.command", bad, browser["controlToken"].getStr())["error"]["message"].getStr == "unknown_command_field"
    check rpc(reg, "editor.poll", target(browser), browser["browserToken"].getStr())["result"]["commands"].len == 0

  test "malformed envelopes never raise native defects":
    let reg = newEditorControlRegistry("browser-bootstrap")
    for request in [newJNull(), %1, %"scalar", newJArray(), newJObject(),
        %* {"jsonrpc": "2.0", "id": 1},
        %* {"jsonrpc": "2.0", "id": 1, "method": nil, "params": {}},
        %* {"jsonrpc": "2.0", "id": 1, "method": "editor.register", "params": nil},
        %* {"jsonrpc": "2.0", "id": [], "method": "editor.register", "params": {}},
        %* {"jsonrpc": "2.0", "id": 1, "method": 4, "params": {}},
        %* {"jsonrpc": "2.0", "id": 1, "method": "editor.register", "params": []}]:
      check reg.rpcDispatch(request, "browser-bootstrap")["error"]["code"].getInt == -32600
    let browser = register(reg)
    for key in ["workspace", "instance", "epoch", "commandId", "command", "viewport", "target", "expectedRevision", "focus", "highlight", "select"]:
      var bad = command(browser)
      bad[key] = newJArray()
      check rpc(reg, "editor.command", bad, browser["controlToken"].getStr()).hasKey("error")
    check rpc(reg, "editor.state", target(browser), browser["controlToken"].getStr()).hasKey("result")

  test "closed pending approval cannot obtain application authorization":
    let reg = newEditorControlRegistry("browser-bootstrap")
    let browser = register(reg)
    let scope = reg.validateBrowserScope(target(browser), browser["browserToken"].getStr())
    let chat = reg.bindConversation(scope, "chat")
    var operation = rpc(reg, "editor.command", command(browser), chat.token)["result"]
    operation["status"] = %"pending"
    var ack = target(browser)
    ack["operation"] = operation
    check rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())["result"]["status"].getStr == "pending"
    reg.revokeConversation("chat")
    var approve = target(browser)
    approve["operationId"] = %"op1"
    approve["approve"] = %true
    check rpc(reg, "editor.approve", approve, browser["browserToken"].getStr())["error"]["message"].getStr == "operation_not_pending"
    check rpc(reg, "editor.poll", target(browser), browser["browserToken"].getStr())["result"]["commands"][0]["error"].getStr == "conversation_closed"

suite "Source transaction authorization":
  test "only matching browser operation with current source permissions can run a producer":
    let reg = newEditorControlRegistry("browser-bootstrap")
    let browser = register(reg)
    var build = target(browser)
    build["commandId"] = %"source-build"
    build["command"] = %"build"
    build["expectedRevision"] = %0
    let queued = rpc(reg, "editor.command", build, browser["controlToken"].getStr())["result"]
    var authorization = target(browser)
    authorization["operationId"] = %"source-build"
    check rpc(reg, "editor.source-authorize", authorization, browser["controlToken"].getStr())["error"]["message"].getStr() == "browser_credential_required"
    check rpc(reg, "editor.source-authorize", authorization, browser["browserToken"].getStr())["error"]["message"].getStr() == "source_permission_denied"
    var ack = target(browser)
    var running = queued.copy()
    running["status"] = %"running"
    ack["operation"] = running
    ack["state"] = %* {"revision":1, "permissions":{"writeSource":true,"createStory":true}}
    check rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())["result"]["status"].getStr() == "running"
    check rpc(reg, "editor.source-authorize", authorization, browser["browserToken"].getStr())["result"] == queued["request"]
    var query = target(browser)
    query["operationId"] = %"source-build"
    check rpc(reg, "editor.wait", query, browser["controlToken"].getStr())["result"]["sourcePhase"].getStr() == "waiting"
    authorization["admit"] = %true
    check rpc(reg, "editor.source-authorize", authorization, browser["browserToken"].getStr())["result"] == queued["request"]
    check rpc(reg, "editor.wait", query, browser["controlToken"].getStr())["result"]["sourcePhase"].getStr() == "admitted"
    discard rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())
    check rpc(reg, "editor.wait", query, browser["controlToken"].getStr())["result"]["sourcePhase"].getStr() == "admitted"
    running["status"] = %"failed"
    ack["operation"] = running
    discard rpc(reg, "editor.ack", ack, browser["browserToken"].getStr())
    check rpc(reg, "editor.source-authorize", authorization, browser["browserToken"].getStr())["error"]["message"].getStr() == "source_operation_not_running"

  test "typed creation fields cannot carry scalar or null values":
    let reg = newEditorControlRegistry("browser-bootstrap")
    let browser = register(reg)
    for invalid in [%42, newJNull(), %true]:
      var request = command(browser, "bad-creation")
      request["command"] = %"create-story"
      request["component"] = invalid
      check rpc(reg, "editor.command", request, browser["controlToken"].getStr())["error"]["message"].getStr() == "invalid_command_field_type"

proc inspectorSource(browser: JsonNode; id = "inspector-1"; revision = 4): JsonNode =
  result = target(browser)
  result["state"] = %* {"revision": revision, "storyId": "Card / ready", "selection": "action", "viewportWidth":1440, "permissions": {"writeSource": true}}
  result["request"] = %* {"commandId": id, "command": "inspector-edit", "storyId": "Card / ready",
    "target": "action", "schemaKey": "style.action", "property": "width", "value": "150px",
    "expectedValue": "120px", "expectedSourceHash": "0123456789012345678901234567890123456789",
    "expectedRevision": revision, "viewportWidth": 1440}

suite "browser-origin inspector source admission":
  test "only the current browser credential can submit; exact replay is idempotent":
    let registry = newEditorControlRegistry("browser-bootstrap")
    let browser = register(registry)
    let submission = inspectorSource(browser)
    for invalid in ["", "wrong", browser["controlToken"].getStr()]:
      check rpc(registry,"editor.inspector-source",submission,invalid)["error"]["message"].getStr() == "browser_credential_required"
    let accepted = rpc(registry,"editor.inspector-source",submission,browser["browserToken"].getStr())["result"]
    check accepted["status"].getStr() == "running"
    check rpc(registry,"editor.inspector-source",submission,browser["browserToken"].getStr())["result"] == accepted
    check rpc(registry,"editor.poll",target(browser),browser["browserToken"].getStr())["result"]["commands"].len == 0
    let collision = submission.copy()
    collision["request"]["value"] = %"160px"
    check rpc(registry,"editor.inspector-source",collision,browser["browserToken"].getStr())["error"]["message"].getStr() == "command_id_collision"

  test "unknown paths, missing fields and malformed field types cannot be admitted":
    let registry = newEditorControlRegistry("browser-bootstrap")
    let browser = register(registry)
    let unknown = inspectorSource(browser)
    unknown["request"]["file"] = %"../other.nim"
    check rpc(registry,"editor.inspector-source",unknown,browser["browserToken"].getStr())["error"]["message"].getStr() == "unknown_inspector_source_field"
    for key in ["commandId","command","storyId","target","schemaKey","property","value","expectedValue","expectedSourceHash","expectedRevision","viewportWidth"]:
      let missing = inspectorSource(browser)
      missing["request"].delete(key)
      check rpc(registry,"editor.inspector-source",missing,browser["browserToken"].getStr())["error"]["message"].getStr() == "missing_inspector_source_field"
      for malformed in [newJNull(), %true, newJArray(), newJObject()]:
        let request = inspectorSource(browser)
        request["request"][key] = malformed
        check rpc(registry,"editor.inspector-source",request,browser["browserToken"].getStr())["error"]["message"].getStr() == "invalid_inspector_source_field_type"
    let viewport = inspectorSource(browser)
    viewport["request"]["viewportWidth"] = %0
    check rpc(registry,"editor.inspector-source",viewport,browser["browserToken"].getStr())["error"]["message"].getStr() == "invalid_inspector_viewport"

  test "selection, story and revision changes prevent admission":
    let registry = newEditorControlRegistry("browser-bootstrap")
    let browser = register(registry)
    for (key, value) in [("target", "other"), ("storyId", "Other / story")]:
      let request = inspectorSource(browser)
      request["request"][key] = %value
      check rpc(registry,"editor.inspector-source",request,browser["browserToken"].getStr())["error"]["message"].getStr() == "stale_inspector_source_target"
    let request = inspectorSource(browser)
    request["request"]["expectedRevision"] = %3
    check rpc(registry,"editor.inspector-source",request,browser["browserToken"].getStr())["error"]["message"].getStr() == "stale_inspector_source_target"

  test "waiting viewport changes refuse admission while admitted work keeps original viewport":
    let registry = newEditorControlRegistry("browser-bootstrap")
    let browser = register(registry)
    let credential = browser["browserToken"].getStr()
    let submitted = inspectorSource(browser)
    discard rpc(registry,"editor.inspector-source",submitted,credential)
    let authorization = target(browser)
    authorization["operationId"] = %"inspector-1"
    authorization["admit"] = %false
    check rpc(registry,"editor.source-authorize",authorization,credential)["result"] == submitted["request"]
    let poll = target(browser)
    poll["state"] = submitted["state"].copy()
    poll["state"]["viewportWidth"] = %720
    discard rpc(registry,"editor.poll",poll,credential)
    authorization["admit"] = %true
    check rpc(registry,"editor.source-authorize",authorization,credential)["error"]["message"].getStr() == "stale_inspector_source_target"
    poll["state"]["viewportWidth"] = %1440
    discard rpc(registry,"editor.poll",poll,credential)
    check rpc(registry,"editor.source-authorize",authorization,credential)["result"] == submitted["request"]
    poll["state"]["viewportWidth"] = %720
    discard rpc(registry,"editor.poll",poll,credential)
    check rpc(registry,"editor.source-authorize",authorization,credential)["result"]["viewportWidth"].getInt() == 1440

  test "waiting source work rechecks selection; admitted work retains its captured original target":
    let registry = newEditorControlRegistry("browser-bootstrap")
    let browser = register(registry)
    let credential = browser["browserToken"].getStr()
    let submitted = inspectorSource(browser)
    discard rpc(registry,"editor.inspector-source",submitted,credential)
    let authorization = target(browser)
    authorization["operationId"] = %"inspector-1"
    authorization["admit"] = %false
    check rpc(registry,"editor.source-authorize",authorization,credential)["result"] == submitted["request"]
    let poll = target(browser)
    poll["state"] = %* {"revision":5,"storyId":"Card / ready","selection":"other","permissions":{"writeSource":true}}
    discard rpc(registry,"editor.poll",poll,credential)
    authorization["admit"] = %true
    check rpc(registry,"editor.source-authorize",authorization,credential)["error"]["message"].getStr() == "stale_inspector_source_target"
    let second = inspectorSource(browser,"inspector-2",6)
    discard rpc(registry,"editor.inspector-source",second,credential)
    authorization["operationId"] = %"inspector-2"
    check rpc(registry,"editor.source-authorize",authorization,credential)["result"] == second["request"]
    poll["state"]["revision"] = %7
    discard rpc(registry,"editor.poll",poll,credential)
    check rpc(registry,"editor.source-authorize",authorization,credential)["result"]["target"].getStr() == "action"
    authorization["operationId"] = %"unregistered"
    check rpc(registry,"editor.source-authorize",authorization,credential)["error"]["message"].getStr() == "unknown_operation"
