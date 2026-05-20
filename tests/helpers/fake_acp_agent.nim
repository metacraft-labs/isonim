## Phase B — minimal ACP server used by Phase B daemon/CLI tests.
##
## Speaks the JSON-RPC dialect over stdio that ``NativeStdioAcpTransport``
## expects.  Implements just enough of the protocol for our routes:
##
##   * ``initialize`` — responds with a fixed protocol version and the
##     ``streaming + text`` capability bits set.
##   * ``session/new`` — mints a deterministic session id based on the
##     command-line argument (or a counter if none is supplied).
##   * ``session/prompt`` — first emits one or more
##     ``session/update`` notifications with canned text chunks, then
##     returns a ``stopReason`` of ``end_turn``.  The canned text is
##     read from ``$FAKE_ACP_REPLY`` or the literal string
##     ``PHASE_B_OK``.
##   * ``session/cancel`` — recorded into ``$FAKE_ACP_CANCEL_FILE`` so
##     the test that drives cancellation can assert it actually
##     propagated.  Triggers an immediate ``stopReason: cancelled``
##     response on the in-flight prompt by signalling a guard flag.
##
## The binary is intentionally minimal — REV-M11 will swap it for a
## richer mock once the ACP capability surface grows.

import std/[json, os, strutils, times]

proc readFrame(): string =
  ## Read one ``\n``-delimited JSON-RPC frame from stdin.  Returns an
  ## empty string on EOF so the main loop can exit cleanly.
  var line = ""
  try:
    line = stdin.readLine()
  except IOError, EOFError:
    return ""
  return line

proc emit(node: JsonNode) =
  stdout.write($node & "\n")
  flushFile(stdout)

proc emitResponse(id: JsonNode; payload: JsonNode) =
  emit(%*{"jsonrpc": "2.0", "id": id, "result": payload})

proc emitErrorResponse(id: JsonNode; code: int; message: string) =
  emit(%*{"jsonrpc": "2.0", "id": id,
          "error": {"code": code, "message": message}})

proc emitUpdate(sessionId, text: string) =
  emit(%*{"jsonrpc": "2.0", "method": "session/update",
          "params": {
            "sessionId": sessionId,
            "update": {
              "sessionUpdate": "agent_message_chunk",
              "content": {"type": "text", "text": text},
            }
          }})

proc recordCancel(sessionId: string) =
  let path = getEnv("FAKE_ACP_CANCEL_FILE")
  if path.len == 0: return
  let line = $epochTime() & " " & sessionId & "\n"
  try:
    let f = open(path, fmAppend)
    defer: f.close()
    f.write(line)
  except IOError:
    discard

proc main() =
  let cannedReply = getEnv("FAKE_ACP_REPLY", "PHASE_B_OK")
  let slowPromptMs =
    try: parseInt(getEnv("FAKE_ACP_SLOW_PROMPT_MS", "0"))
    except ValueError: 0
  var sessionCounter = 0
  var nextSessionId = ""
  var cancelRequested = false
  while true:
    let frame = readFrame()
    if frame.len == 0:
      break
    var node: JsonNode
    try:
      node = parseJson(frame)
    except JsonParsingError:
      continue
    let idNode = node{"id"}
    let rpcMethod = node{"method"}.getStr("")
    case rpcMethod
    of "initialize":
      emitResponse(idNode, %*{
        "protocolVersion": 1,
        "agentCapabilities": {
          "streaming": true,
          "text": true,
          "images": false,
          "audio": false,
          "resources": false,
          "permissions": false,
        }
      })
    of "session/new":
      inc sessionCounter
      nextSessionId = getEnv("FAKE_ACP_SESSION_ID",
        "fake-session-" & $sessionCounter)
      emitResponse(idNode, %*{"sessionId": nextSessionId})
    of "session/prompt":
      let params = node{"params"}
      let sid = params{"sessionId"}.getStr(nextSessionId)
      # Emit a single text chunk so the SSE stream has something to
      # forward.  When ``cancelRequested`` is set (from a prior
      # ``session/cancel`` notification), short-circuit with cancelled.
      if slowPromptMs > 0:
        let deadline = epochTime() + (slowPromptMs / 1000)
        while epochTime() < deadline:
          # Cooperative sleep — tests fire cancel mid-prompt and we
          # need to notice it.
          sleep(20)
          if cancelRequested:
            break
      if cancelRequested:
        cancelRequested = false
        emitResponse(idNode, %*{"sessionId": sid,
                                "stopReason": "cancelled"})
      else:
        emitUpdate(sid, cannedReply)
        emitResponse(idNode, %*{"sessionId": sid,
                                "stopReason": "end_turn"})
    of "session/cancel":
      let params = node{"params"}
      let sid = params{"sessionId"}.getStr(nextSessionId)
      cancelRequested = true
      recordCancel(sid)
    of "":
      discard
    else:
      if idNode != nil:
        emitErrorResponse(idNode, -32_601, "method not found: " & rpcMethod)

when isMainModule:
  main()
