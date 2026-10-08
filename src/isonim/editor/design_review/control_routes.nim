## JSON-RPC delivery registry. Browser leases, connection epochs and credentials
## isolate instances. Only an application acknowledgement completes an operation.
import std/[asyncdispatch, asynchttpserver, json, locks, os, strutils, sysrand, tables, times, monotimes, sets]

type
  ControlScope* = object
    workspace*, instance*, epoch*, conversation*, token*: string
  ControlInstance = ref object
    scope: ControlScope
    browserToken: string
    touched: MonoTime
    connected: bool
    snapshot: JsonNode
    operations: OrderedTable[string, JsonNode]
    acknowledgedOperations: HashSet[string]
  EditorControlRegistry* = ref object
    lock: Lock
    instances: OrderedTable[string, ControlInstance]
    tokens: Table[string, ControlScope]
    endpoint*: string
    browserBootstrap: string
  ControlError* = object of CatchableError

const ControlRoute* = "/api/editor/rpc"
const BrowserLeaseSeconds* = 10.0

proc credential(): string =
  for byte in urandom(32): result.add toHex(byte, 2)

proc newEditorControlRegistry*(browserBootstrap = getEnv("ISONIM_EDITOR_BROWSER_BOOTSTRAP")): EditorControlRegistry =
  result = EditorControlRegistry(instances: initOrderedTable[string, ControlInstance](),
    tokens: initTable[string, ControlScope](), browserBootstrap: browserBootstrap)
  initLock(result.lock)

proc rpcError(id: JsonNode; code: int; message: string): JsonNode =
  let responseId = if id == nil: newJNull() else: id
  %* {"jsonrpc": "2.0", "id": responseId, "error": {"code": code, "message": message}}

proc connected(instance: ControlInstance): bool =
  instance.connected and (getMonoTime() - instance.touched).inMilliseconds < int64(BrowserLeaseSeconds * 1000)

proc publishSnapshot(instance: ControlInstance; snapshot: JsonNode) =
  # Poll and application ACK requests can arrive in either order. Never replace
  # an acknowledged newer view with an older in-flight poll snapshot.
  if snapshot != nil and snapshot.kind == JObject and
      (instance.snapshot == nil or snapshot{"revision"}.getInt(-1) >= instance.snapshot{"revision"}.getInt(-1)):
    instance.snapshot = snapshot

proc requireInstance(reg: EditorControlRegistry; params: JsonNode;
    allowExpiredLease = false): ControlInstance =
  let id = params{"instance"}.getStr()
  if id.len == 0: raise newException(ControlError, "ambiguous_target: explicit instance required")
  if not reg.instances.hasKey(id): raise newException(ControlError, "stale_instance")
  result = reg.instances[id]
  if params{"workspace"}.getStr() != result.scope.workspace:
    raise newException(ControlError, "wrong_workspace")
  if params{"epoch"}.getStr() != result.scope.epoch:
    raise newException(ControlError, "stale_connection_epoch")
  if not result.connected or (not allowExpiredLease and not result.connected()):
    raise newException(ControlError, "disconnected_instance")

proc browserAuthorized(instance: ControlInstance; token: string) =
  if token.len == 0 or token != instance.browserToken:
    raise newException(ControlError, "browser_credential_required")

proc agentAuthorized(reg: EditorControlRegistry; instance: ControlInstance;
    token: string): ControlScope =
  if not reg.tokens.hasKey(token): raise newException(ControlError, "invalid_control_credential")
  result = reg.tokens[token]
  if result.workspace != instance.scope.workspace or result.instance != instance.scope.instance or
      result.epoch != instance.scope.epoch:
    raise newException(ControlError, "credential_scope_mismatch")

proc validateBrowserScope*(reg: EditorControlRegistry; node: JsonNode; token: string): ControlScope =
  acquire(reg.lock)
  try:
    let instance = reg.requireInstance(node)
    instance.browserAuthorized(token)
    result = instance.scope
  finally: release(reg.lock)

proc bindConversation*(reg: EditorControlRegistry; scope: ControlScope; conversation: string): ControlScope =
  acquire(reg.lock)
  try:
    if not reg.instances.hasKey(scope.instance): raise newException(ControlError, "stale_instance")
    let instance = reg.instances[scope.instance]
    if not instance.connected() or instance.scope.epoch != scope.epoch:
      raise newException(ControlError, "disconnected_instance")
    result = scope
    result.conversation = conversation
    result.token = credential()
    reg.tokens[result.token] = result
  finally: release(reg.lock)

proc rebindConversation*(reg: EditorControlRegistry; scope: ControlScope; conversation: string): ControlScope =
  acquire(reg.lock)
  try:
    if not reg.tokens.hasKey(scope.token): raise newException(ControlError, "revoked_control_scope")
    result = scope
    result.conversation = conversation
    reg.tokens[scope.token] = result
  finally: release(reg.lock)

proc revokeConversation*(reg: EditorControlRegistry; conversation: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    acquire(reg.lock)
    try:
      var tokens: seq[string]
      for token, scope in reg.tokens:
        if scope.conversation == conversation: tokens.add token
      for token in tokens: reg.tokens.del(token)
      for instance in reg.instances.values:
        for id, operation in instance.operations.mpairs:
          if operation{"request", "conversation"}.getStr() == conversation and
              operation{"status"}.getStr() in ["queued", "pending", "approved", "running"]:
            operation["status"] = %"rejected"
            operation["error"] = %"conversation_closed"
    finally: release(reg.lock)

proc rpcDispatch*(reg: EditorControlRegistry; request: JsonNode; token: string): JsonNode =
  if request == nil or request.kind != JObject:
    return rpcError(newJNull(), -32600, "invalid_request")
  let id = request{"id"}
  if id != nil and id.kind notin {JString, JInt, JNull}:
    return rpcError(newJNull(), -32600, "invalid_request")
  if request{"jsonrpc"}.getStr() != "2.0" or id == nil or
      (request{"method"} == nil or request{"method"}.kind != JString) or
      (request{"params"} == nil or request{"params"}.kind != JObject):
    return rpcError(id, -32600, "invalid_request")
  let methodName = request["method"].getStr()
  let params = request["params"]
  acquire(reg.lock)
  try:
    var output: JsonNode
    if methodName == "editor.register":
      if reg.browserBootstrap.len == 0 or token != reg.browserBootstrap:
        raise newException(ControlError, "browser_bootstrap_required")
      let workspace = params{"workspace"}.getStr()
      if workspace.len == 0: raise newException(ControlError, "missing_workspace")
      var scope = ControlScope(workspace: workspace, instance: credential(), epoch: credential())
      scope.token = credential()
      let browserToken = credential()
      let instance = ControlInstance(scope: scope, browserToken: browserToken,
        connected: true, touched: getMonoTime(), snapshot: params{"state"},
        operations: initOrderedTable[string, JsonNode](), acknowledgedOperations: initHashSet[string]())
      reg.instances[scope.instance] = instance
      reg.tokens[scope.token] = scope
      output = %* {"workspace": scope.workspace, "instance": scope.instance, "epoch": scope.epoch,
        "browserToken": browserToken, "controlToken": scope.token, "leaseSeconds": BrowserLeaseSeconds}
    else:
      # A still-mounted tab may renew an expired transport lease with its exact
      # browser credential. Explicit disconnect/replacement remains revoked;
      # agents cannot renew leases and remain denied until a successful poll.
      let instance = reg.requireInstance(params, allowExpiredLease = methodName == "editor.poll")
      if methodName in ["editor.poll", "editor.ack", "editor.disconnect", "editor.preference", "editor.approve", "editor.source-authorize", "editor.inspector-source"]:
        instance.browserAuthorized(token)
      else: discard reg.agentAuthorized(instance, token)
      case methodName
      of "editor.state", "editor.capabilities", "editor.stories", "editor.elements":
        if instance.snapshot == nil: raise newException(ControlError, "instance_not_ready")
        case methodName
        of "editor.capabilities": output = instance.snapshot{"capabilities"}
        of "editor.stories": output = instance.snapshot{"stories"}
        of "editor.elements": output = instance.snapshot{"elements"}
        else: output = instance.snapshot
      of "editor.instances":
        # Discovery remains credential-scoped; no other tab's state or credential leaks.
        output = %* [{"workspace": instance.scope.workspace, "instance": instance.scope.instance,
          "epoch": instance.scope.epoch, "connected": instance.connected()}]
      of "editor.poll":
        instance.touched = getMonoTime()
        instance.publishSnapshot(params{"state"})
        var commands = newJArray()
        for operation in instance.operations.values:
          if operation{"sourceKind"}.getStr() == "inspector": continue
          if operation{"status"}.getStr() in ["queued", "pending", "approved", "running"] or
              (operation{"status"}.getStr() in ["rejected", "failed"] and
                operation{"operationId"}.getStr() notin instance.acknowledgedOperations): commands.add operation
        output = %* {"commands": commands}
      of "editor.inspector-source":
        instance.browserAuthorized(token)
        instance.publishSnapshot(params{"state"})
        let request = params{"request"}
        if request == nil or request.kind != JObject:
          raise newException(ControlError, "invalid_inspector_source_request")
        for key, value in request:
          if key notin ["commandId", "command", "storyId", "target", "schemaKey", "property", "value", "expectedValue", "expectedSourceHash", "expectedRevision", "viewportWidth", "sourceValue"]:
            raise newException(ControlError, "unknown_inspector_source_field")
          if key in ["expectedRevision", "viewportWidth"]:
            if value.kind != JInt: raise newException(ControlError, "invalid_inspector_source_field_type")
          elif value.kind != JString:
            raise newException(ControlError, "invalid_inspector_source_field_type")
        for key in ["commandId", "command", "storyId", "target", "schemaKey", "property", "value", "expectedValue", "expectedSourceHash", "expectedRevision", "viewportWidth"]:
          if request{key} == nil: raise newException(ControlError, "missing_inspector_source_field")
        if request{"viewportWidth"}.getInt() < 1:
          raise newException(ControlError, "invalid_inspector_viewport")
        if request{"command"}.getStr() != "inspector-edit" or
            request{"commandId"}.getStr().len == 0 or request{"schemaKey"}.getStr().len == 0:
          raise newException(ControlError, "invalid_inspector_source_request")
        if not instance.snapshot{"permissions", "writeSource"}.getBool():
          raise newException(ControlError, "source_permission_denied")
        if request{"expectedRevision"}.getInt(-1) != instance.snapshot{"revision"}.getInt(-2) or
            request{"storyId"}.getStr() != instance.snapshot{"storyId"}.getStr() or
            request{"target"}.getStr() != instance.snapshot{"selection"}.getStr() or
            request{"viewportWidth"}.getInt() != instance.snapshot{"viewportWidth"}.getInt(-1):
          raise newException(ControlError, "stale_inspector_source_target")
        let id = request{"commandId"}.getStr()
        if instance.operations.hasKey(id):
          if instance.operations[id]["request"] != request:
            raise newException(ControlError, "command_id_collision")
          output = instance.operations[id]
        else:
          let operation = %* {"operationId": id, "status": "running", "request": request,
            "sourceKind": "inspector", "revision": instance.snapshot{"revision"}}
          instance.operations[id] = operation
          output = operation
      of "editor.source-authorize":
        instance.browserAuthorized(token)
        let id = params{"operationId"}.getStr()
        if not instance.operations.hasKey(id): raise newException(ControlError, "unknown_operation")
        let operation = instance.operations[id]
        if operation{"status"}.getStr() notin ["queued", "running"] or
            (operation{"request", "command"}.getStr() notin ["create-story", "build"] and not
              (operation{"sourceKind"}.getStr() == "inspector" and
                operation{"request", "command"}.getStr() == "inspector-edit")):
          raise newException(ControlError, "source_operation_not_running")
        if not instance.snapshot{"permissions", "writeSource"}.getBool() or
            (operation{"request", "command"}.getStr() == "create-story" and
              not instance.snapshot{"permissions", "createStory"}.getBool()):
          raise newException(ControlError, "source_permission_denied")
        if operation{"sourceKind"}.getStr() == "inspector" and operation{"sourcePhase"}.getStr() != "admitted":
          if operation{"request", "target"}.getStr() != instance.snapshot{"selection"}.getStr() or
              operation{"request", "storyId"}.getStr() != instance.snapshot{"storyId"}.getStr() or
              operation{"request", "viewportWidth"}.getInt(-1) != instance.snapshot{"viewportWidth"}.getInt(-2):
            raise newException(ControlError, "stale_inspector_source_target")
        if params{"admit"} != nil and params["admit"].kind != JBool:
          raise newException(ControlError, "invalid_source_admission")
        if params{"admit"}.getBool():
          operation["sourcePhase"] = %"admitted"
        elif operation{"sourcePhase"}.getStr() != "admitted":
          operation["sourcePhase"] = %"waiting"
        output = operation["request"]
      of "editor.command":
        let scope = reg.agentAuthorized(instance, token)
        let commandId = params{"commandId"}.getStr()
        if commandId.len == 0: raise newException(ControlError, "missing_command_id")
        for key, value in params:
          if key notin ["workspace", "instance", "epoch", "commandId", "command", "storyId", "target", "viewport", "select", "focus", "highlight", "component", "variantKey", "stateKey", "expectedRevision"]:
            raise newException(ControlError, "unknown_command_field")
          if key in ["select", "focus", "highlight"] and value.kind != JBool:
            raise newException(ControlError, "invalid_command_field_type")
          if key == "expectedRevision" and value.kind != JInt:
            raise newException(ControlError, "invalid_command_field_type")
          if key notin ["select", "focus", "highlight", "expectedRevision"] and value.kind != JString:
            raise newException(ControlError, "invalid_command_field_type")
        var command = params.copy()
        command["conversation"] = %scope.conversation
        if instance.operations.hasKey(commandId):
          let previous = instance.operations[commandId]
          if previous["request"] != command:
            raise newException(ControlError, "command_id_collision")
          output = previous
        else:
          output = %* {"operationId": commandId, "status": "queued", "request": command}
          instance.operations[commandId] = output
      of "editor.wait":
        let commandId = params{"operationId"}.getStr()
        if not instance.operations.hasKey(commandId): raise newException(ControlError, "unknown_operation")
        let scope = reg.agentAuthorized(instance, token)
        output = instance.operations[commandId]
        if output{"request", "conversation"}.getStr() != scope.conversation:
          raise newException(ControlError, "operation_scope_mismatch")
      of "editor.ack":
        let operation = params{"operation"}
        let commandId = operation{"operationId"}.getStr()
        if not instance.operations.hasKey(commandId): raise newException(ControlError, "unknown_operation")
        let previous = instance.operations[commandId]
        if previous["request"] != operation{"request"}:
          raise newException(ControlError, "acknowledgement_request_mismatch")
        if operation{"status"}.getStr() notin ["pending", "running", "applied", "failed", "rejected"]:
          raise newException(ControlError, "invalid_application_status")
        # Revocation or a previous final ack cannot be overwritten by a late browser.
        if previous{"status"}.getStr() in ["applied", "failed", "rejected"] or
            (previous{"status"}.getStr() == "approved" and operation{"status"}.getStr() == "pending"):
          output = previous
        else:
          output = operation.copy()
          if previous{"approvalDecision"} != nil:
            output["approvalDecision"] = previous["approvalDecision"]
          if previous{"sourcePhase"} != nil:
            output["sourcePhase"] = previous["sourcePhase"]
          instance.operations[commandId] = output
        # A late contradictory ACK cannot acknowledge a revocation the browser
        # has not consumed. Stop terminal redelivery only after matching the
        # authoritative stored status/error, without losing that outcome.
        if operation{"status"}.getStr() in ["applied", "failed", "rejected"] and
            operation{"status"}.getStr() == output{"status"}.getStr() and
            operation{"error"}.getStr() == output{"error"}.getStr():
          instance.acknowledgedOperations.incl(commandId)
          output = instance.operations[commandId]
        instance.touched = getMonoTime()
        instance.publishSnapshot(params{"state"})
      of "editor.disconnect":
        instance.connected = false
        var tokens: seq[string]
        for key, scope in reg.tokens:
          if scope.instance == instance.scope.instance: tokens.add key
        for key in tokens: reg.tokens.del(key)
        output = %* {"disconnected": true}
      # These methods are intentionally UI-only. Delivery of approved state still
      # goes through the same browser ACK path; an agent token cannot call either.
      of "editor.approve":
        let operationId = params{"operationId"}.getStr()
        if not instance.operations.hasKey(operationId): raise newException(ControlError, "unknown_operation")
        var operation = instance.operations[operationId]
        if params{"approve"} == nil or params{"approve"}.kind != JBool:
          raise newException(ControlError, "invalid_approval_decision")
        let decision = params["approve"].getBool()
        if operation{"approvalDecision"} != nil:
          if operation["approvalDecision"].getBool() != decision:
            raise newException(ControlError, "approval_decision_conflict")
          output = operation
          return %* {"jsonrpc": "2.0", "id": id, "result": output}
        if operation{"status"}.getStr() != "pending":
          raise newException(ControlError, "operation_not_pending")
        operation["approvalDecision"] = %decision
        if decision:
          operation["status"] = %"approved"
        else:
          operation["status"] = %"rejected"
          operation["error"] = %"denied"
        instance.operations[operationId] = operation
        output = operation
      of "editor.preference":
        raise newException(ControlError, "use_visible_editor_controls")
      else: return rpcError(id, -32601, "method_not_found")
    result = %* {"jsonrpc": "2.0", "id": id, "result": output}
  except ControlError as error:
    result = rpcError(id, -32000, error.msg)
  except CatchableError:
    result = rpcError(id, -32602, "invalid_params")
  finally: release(reg.lock)

proc makeControlHandler*(reg: EditorControlRegistry): proc(req: Request): Future[void] {.gcsafe.} =
  result = proc(req: Request): Future[void] {.async, gcsafe.} =
    if req.reqMethod != HttpPost:
      await req.respond(Http405, "{}")
      return
    var output: JsonNode
    {.cast(gcsafe).}:
      try: output = reg.rpcDispatch(parseJson(req.body), req.headers.getOrDefault("X-IsoNim-Control"))
      except CatchableError: output = rpcError(newJNull(), -32700, "parse_error")
    await req.respond(Http200, $output, newHttpHeaders([
      ("Content-Type", "application/json"), ("Cache-Control", "no-store"),
      ("Access-Control-Allow-Origin", "*"), ("Access-Control-Allow-Headers", "Content-Type, X-IsoNim-Control")]))
