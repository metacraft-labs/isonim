## isonim/server/rpc.nim
##
## RPC infrastructure for server functions.
## On C target: maintains a registry of server function handlers.
## On JS target: provides an rpcFetch proc that calls the server via XHR.

import std/json

when not defined(js):
  import std/tables

type
  RpcHandler* = proc(args: JsonNode): JsonNode

when not defined(js):
  var rpcRegistry*: Table[string, RpcHandler]
    ## Maps endpoint paths to handler procs.
    ## Populated on C target during module init.

  proc registerRpc*(path: string; handler: RpcHandler) =
    ## Register a server function handler at the given endpoint path.
    rpcRegistry[path] = handler

  proc handleRpc*(path: string; argsJson: string): string =
    ## Called by nginx module to dispatch an RPC request.
    ## Returns JSON response string.
    if rpcRegistry.hasKey(path):
      let handler = rpcRegistry[path]
      let args = parseJson(argsJson)
      let res = handler(args)
      return $res
    else:
      return """{"error": "unknown endpoint", "path": """ & escapeJson(path) & "}"

  proc lookupRpc*(path: string): RpcHandler =
    ## Look up a registered RPC handler by path. Returns nil if not found.
    rpcRegistry.getOrDefault(path, nil)

else:
  # JS target: RPC client via synchronous XMLHttpRequest.
  # Synchronous XHR is deprecated in browsers but works for M3 simplicity.
  # M6 will add async variant with createResource integration.

  proc rpcFetchSync*(endpoint: string; args: JsonNode): JsonNode =
    ## Synchronous RPC call to the server.
    ## Sends a POST with JSON body, returns parsed JSON response.
    let body = $args
    var responseText: cstring
    {.emit: """
    var xhr = new XMLHttpRequest();
    xhr.open("POST", `endpoint`, false);
    xhr.setRequestHeader("Content-Type", "application/json");
    xhr.send(`body`);
    if (xhr.status === 200) {
      `responseText` = xhr.responseText;
    } else {
      `responseText` = '{"error": "RPC call failed with status ' + xhr.status + '"}';
    }
    """.}
    result = parseJson($responseText)
