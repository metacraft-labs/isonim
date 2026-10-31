## Thin native CLI for the daemon's JSON-RPC editor command surface. Credentials
## come from the launch environment and are never printed in help/state/errors.
import std/[asyncdispatch, httpclient, json, os, strutils, times, monotimes]

const EditorUsage* = """
isonim editor <operation> [options]
Operations:
  instances | state | capabilities | stories | elements
  open-story <story-id> | viewport <slug> | open-panel <name>
  select <element-id> [--focus] [--highlight] | highlight <element-id> | focus <target>
  command <view|edit|comment|save|revert|undo|redo>
  create-story <component> --variant <key> --state <key>
  build | capture-preview (returns mounted HTML, viewport and readiness)
  wait <operation-id>
Options:
  --endpoint <url> --workspace <id> --instance <id> --epoch <connection-id>
  --command-id <id> --expected-revision <integer> --wait --timeout-ms <1..120000>
  --json
Defaults use ISONIM_EDITOR_ENDPOINT, ISONIM_EDITOR_WORKSPACE,
ISONIM_EDITOR_INSTANCE, ISONIM_EDITOR_EPOCH and ISONIM_EDITOR_TOKEN.
Mutations require a command ID. Default waits are bounded to 5000 ms.
Exit codes: 0 applied/observable operation, 2 usage, 3 transport/RPC,
4 denied/unsupported, 5 timeout, 6 revision or command-ID conflict.
"""

proc exchange(url, token: string; body: JsonNode; timeout: int): Future[JsonNode] {.async.} =
  let client = newAsyncHttpClient(headers = newHttpHeaders([
    ("Content-Type", "application/json"), ("X-IsoNim-Control", token)]))
  defer: client.close()
  proc deliver(): Future[string] {.async.} =
    let response = await client.request(url & "/api/editor/rpc", HttpPost, $body)
    if response.code != Http200: raise newException(IOError, "Editor endpoint returned HTTP " & $response.code)
    return await response.body
  let delivery = deliver()
  if not await withTimeout(delivery, timeout):
    client.close()
    raise newException(IOError, "control_timeout")
  return parseJson(await delivery)

proc cmdEditor*(args: seq[string]): int =
  if args.len == 0 or args[0] in ["--help", "-h"]:
    echo EditorUsage
    return 0
  var endpoint = getEnv("ISONIM_EDITOR_ENDPOINT")
  var workspace = getEnv("ISONIM_EDITOR_WORKSPACE")
  var instance = getEnv("ISONIM_EDITOR_INSTANCE")
  var epoch = getEnv("ISONIM_EDITOR_EPOCH")
  let token = getEnv("ISONIM_EDITOR_TOKEN")
  var commandId, operand, variantKey, stateKey: string
  var expectedRevision = -1
  var timeout = 5000
  var waitRequested, highlight, focus: bool
  var observedOperation: JsonNode
  var index = 1
  try:
    while index < args.len:
      let flag = args[index]
      if flag in ["--wait", "--highlight", "--focus", "--json"]:
        if flag == "--wait": waitRequested = true
        if flag == "--highlight": highlight = true
        if flag == "--focus": focus = true
      elif flag.startsWith("--"):
        inc index
        if index >= args.len: raise newException(ValueError, "Missing option value.")
        let value = args[index]
        case flag
        of "--endpoint": endpoint = value
        of "--workspace": workspace = value
        of "--instance": instance = value
        of "--epoch": epoch = value
        of "--variant": variantKey = value
        of "--state": stateKey = value
        of "--command-id": commandId = value
        of "--expected-revision": expectedRevision = parseInt(value)
        of "--timeout-ms": timeout = parseInt(value)
        else: raise newException(ValueError, "Unknown option.")
      elif operand.len == 0: operand = flag
      else: raise newException(ValueError, "Unexpected argument.")
      inc index
    if endpoint.len == 0 or workspace.len == 0 or instance.len == 0 or epoch.len == 0 or token.len == 0:
      raise newException(ValueError, "Explicit endpoint, workspace, instance, epoch and environment credential are required.")
    if timeout < 1 or timeout > 120000: raise newException(ValueError, "Invalid timeout.")
    var params = %* {"workspace": workspace, "instance": instance, "epoch": epoch}
    var methodName: string
    let operation = args[0]
    case operation
    of "instances", "state", "capabilities", "stories", "elements":
      methodName = "editor." & operation
      if operand.len > 0: raise newException(ValueError, "This operation has no positional argument.")
    of "wait":
      if operand.len == 0: raise newException(ValueError, "Operation ID required.")
      params["operationId"] = %operand
      methodName = "editor.wait"
      waitRequested = true
    of "create-story", "build", "capture-preview", "open-story", "viewport", "open-panel", "select", "highlight", "focus", "command":
      if commandId.len == 0 or (operand.len == 0 and operation notin ["build", "capture-preview"]):
        raise newException(ValueError, "Mutation requires a target and --command-id.")
      methodName = "editor.command"
      params["commandId"] = %commandId
      params["command"] = %(if operation == "command": operand else: operation)
      case operation
      of "create-story":
        params["component"] = %operand
        params["variantKey"] = %variantKey
        params["stateKey"] = %stateKey
      of "open-story": params["storyId"] = %operand
      of "viewport": params["viewport"] = %operand
      of "open-panel", "select", "highlight", "focus": params["target"] = %operand
      else: discard
      if highlight: params["highlight"] = %true
      if focus: params["focus"] = %true
    else: raise newException(ValueError, "Unknown operation.")
    let started = getMonoTime()
    proc call(name: string; data: JsonNode): JsonNode =
      let remaining = timeout - int((getMonoTime() - started).inMilliseconds)
      if remaining <= 0: raise newException(IOError, "control_timeout")
      let reply = waitFor exchange(endpoint.strip(chars={'/'}), token,
        %* {"jsonrpc": "2.0", "id": "isonim-cli", "method": name, "params": data}, min(3000, remaining))
      if reply{"error"} != nil:
        raise newException(IOError, reply{"error", "message"}.getStr("rpc_error"))
      if reply{"result"} == nil: raise newException(IOError, "invalid_rpc_response")
      reply["result"]
    if methodName == "editor.command":
      if expectedRevision < 0: expectedRevision = call("editor.state", %* {
        "workspace": workspace, "instance": instance, "epoch": epoch}){"revision"}.getInt(-1)
      params["expectedRevision"] = %expectedRevision
    var output = call(methodName, params)
    if methodName == "editor.command" and waitRequested:
      params = %* {"workspace": workspace, "instance": instance, "epoch": epoch,
        "operationId": output{"operationId"}.getStr()}
    if waitRequested and methodName in ["editor.command", "editor.wait"]:
      observedOperation = output
      while output{"status"}.getStr() in ["queued", "pending", "approved", "running"]:
        if int((getMonoTime() - started).inMilliseconds) >= timeout:
          echo $(%* {"error": "control_timeout", "operation": output})
          return 5
        sleep(min(100, max(1, timeout - int((getMonoTime() - started).inMilliseconds))))
        if int((getMonoTime() - started).inMilliseconds) >= timeout:
          echo $(%* {"error": "control_timeout", "operation": output})
          return 5
        output = call("editor.wait", params)
        observedOperation = output
    echo $output
    if output{"status"}.getStr() in ["failed", "rejected"]:
      if output{"error"}.getStr() in ["revision_conflict", "command_id_collision"]: return 6
      return 4
    return 0
  except ValueError as error:
    echo $(%* {"error": "usage", "message": error.msg})
    return 2
  except CatchableError as error:
    # Exceptions never contain request headers or environment values.
    let message = error.msg
    if message == "control_timeout":
      var failure = %* {"error": message}
      if observedOperation != nil: failure["operation"] = observedOperation
      echo $failure
      return 5
    echo $(%* {"error": message})
    if "revision_conflict" in message or "command_id_collision" in message: return 6
    return 3
