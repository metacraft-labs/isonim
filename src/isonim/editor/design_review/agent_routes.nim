## Phase B — HTTP routes that bridge the editor daemon to an ACP agent.
##
## Three endpoints are exposed:
##
##   * ``POST /api/agent/sessions`` — initialise an ACP backend, allocate a
##     fresh session id, cache the client + session id server-side.  The
##     response carries the session id and the agent's capability bag from
##     the ACP ``initialize`` reply.
##   * ``POST /api/agent/prompts``  — submit a prompt for the cached
##     session.  The server emits a ``text/event-stream`` response, one
##     ``session/update`` per SSE event, terminated by an ``event: end``
##     with the stop reason.
##   * ``POST /api/agent/cancel``  — fire-and-forget ``session/cancel``.
##
## The transport itself is Phase A's :type:`NativeStdioAcpTransport`
## wrapped by :proc:`fromClaudeCodeAcp` from ``nim-agents``.  Concurrency
## is single-tenant (one client per session id) — the daemon binds to
## ``127.0.0.1`` only and serves a single user.  REV-M11+ may revisit
## once multi-user editing lands.
##
## Cancellation: when the SSE client disconnects mid-stream, the daemon
## sends ``session/cancel`` to the agent and reaps the session entry.
## See the ``test_post_cancel_signals_agent`` test for verification.

import std/[asyncdispatch, asyncnet, asynchttpserver, json, locks,
            options, os, strutils, tables]

import nim_acp
import nim_agents

import ./log_setup

logScope:
  topics = "agent"

type
  AgentSessionState* = object
    sessionId*: string
    client*: AgentClient
    session*: AgentSession
    capabilities*: AgentCapabilities

  AgentRegistry* = ref object
    ## Cache of active ACP sessions, keyed by the session id returned to
    ## the caller of ``POST /api/agent/sessions``.  We don't try to
    ## reconcile against the agent's view — if the agent forgets a
    ## session, the next ``POST /api/agent/prompts`` will get an ACP
    ## error and we surface it to the caller untouched.
    lock: Lock
    sessions: Table[string, AgentSessionState]
    extraArgs: seq[string]

  AgentBackendUnavailableError* = object of CatchableError

const
  SseContentType* = "text/event-stream; charset=utf-8"
  AgentSessionsRoute* = "/api/agent/sessions"
  AgentPromptsRoute* = "/api/agent/prompts"
  AgentCancelRoute* = "/api/agent/cancel"

# --------------------------------------------------------------------------- #
#  Registry helpers.                                                          #
# --------------------------------------------------------------------------- #

proc newAgentRegistry*(extraArgs: seq[string] = @[]): AgentRegistry =
  result = AgentRegistry(
    sessions: initTable[string, AgentSessionState](),
    extraArgs: extraArgs)
  initLock(result.lock)

proc release*(reg: AgentRegistry; sessionId: string) =
  acquire(reg.lock)
  try:
    if reg.sessions.hasKey(sessionId):
      reg.sessions.del(sessionId)
  finally:
    release(reg.lock)

proc getState*(reg: AgentRegistry; sessionId: string): Option[AgentSessionState] =
  acquire(reg.lock)
  try:
    if reg.sessions.hasKey(sessionId):
      return some(reg.sessions[sessionId])
    else:
      return none(AgentSessionState)
  finally:
    release(reg.lock)

proc storeSession(reg: AgentRegistry; state: AgentSessionState) =
  acquire(reg.lock)
  try:
    reg.sessions[state.sessionId] = state
  finally:
    release(reg.lock)

# --------------------------------------------------------------------------- #
#  Session creation.                                                          #
# --------------------------------------------------------------------------- #

proc createAcpSession*(reg: AgentRegistry; cwd = ""):
    AgentSessionState {.gcsafe.} =
  ## Spawn the ACP agent, run ``initialize`` + ``session/new`` and stash
  ## the resulting :type:`AgentClient` in the registry.  Raises
  ## :type:`AgentBackendUnavailableError` when ``fromClaudeCodeAcp``
  ## fails because the binary isn't on PATH.
  ##
  ## Marked ``gcsafe`` because the surrounding asynchttpserver dispatch
  ## requires it; the nim-acp transport's indirect-call methods are
  ## benign here — per-session state lives entirely inside the cached
  ## :type:`AgentClient`, which never escapes this thread.
  {.gcsafe.}:
    var client: AgentClient
    try:
      client = fromClaudeCodeAcp(reg.extraArgs)
    except AcpError as e:
      error "agent backend unavailable", reason = e.msg
      raise newException(AgentBackendUnavailableError, e.msg)
    let initResp = client.acp.initialize(InitializeRequest(
      protocolVersion: 1,
      clientInfo: ClientInfo(name: "isonim-review", version: "0.1"),
      clientCapabilities: ClientCapabilities(streaming: true)))
    let resolvedCwd = if cwd.len > 0: cwd else: getCurrentDir()
    let session = client.startSession(resolvedCwd)
    result = AgentSessionState(
      sessionId: session.id,
      client: client,
      session: session,
      capabilities: initResp.agentCapabilities)
    reg.storeSession(result)
    info "agent session created", sessionId = session.id,
      cwd = resolvedCwd

# --------------------------------------------------------------------------- #
#  JSON shapes the routes serialise to / from.                                #
# --------------------------------------------------------------------------- #

proc capabilityJson*(c: AgentCapabilities): JsonNode =
  result = %* {
    "streaming": c.streaming,
    "text": c.text,
    "images": c.images,
    "audio": c.audio,
    "resources": c.resources,
    "permissions": c.permissions,
    "terminal": c.terminal,
    "filesystem": {
      "readTextFile": c.filesystemRead,
      "writeTextFile": c.filesystemWrite,
    },
  }

proc parsePromptFromBody*(body: string):
    tuple[sessionId: string; prompt: seq[ContentBlock]] =
  ## Body shape:
  ##   {"sessionId": "...", "messages": [{"role":"user","content":[...]}]}
  ## We accept ``messages[].content[]`` items of the form
  ## ``{"type":"text", "text": "..."}`` and ignore anything else for
  ## Phase B; richer payloads land with REV-M11+.
  let node = parseJson(body)
  result.sessionId = node{"sessionId"}.getStr("")
  let messages = node{"messages"}
  if messages != nil and messages.kind == JArray:
    for msg in messages.items:
      let content = msg{"content"}
      if content == nil or content.kind != JArray:
        continue
      for item in content.items:
        if item{"type"}.getStr("text") != "text":
          continue
        result.prompt.add textBlock(item{"text"}.getStr(""))
  if result.prompt.len == 0 and node.hasKey("text"):
    result.prompt.add textBlock(node["text"].getStr(""))

proc sessionUpdateJson*(update: SessionUpdate): JsonNode =
  ## Encode an ACP ``SessionUpdate`` back into JSON for the SSE wire
  ## format.  Mirror of :proc:`updateFromJson` in ``nim_acp/client``;
  ## we re-serialise the raw fields we actually filled in to keep the
  ## stream stable across protocol minor bumps.
  if update.raw != nil:
    return update.raw
  result = %* {
    "sessionId": update.sessionId,
    "update": {
      "sessionUpdate": $update.kind,
    },
  }
  case update.kind
  of sukAgentMessageChunk, sukAgentThoughtChunk:
    result["update"]["content"] = contentBlockToJson(update.content)
  of sukToolCall:
    result["update"]["toolCallId"] = %update.toolCallId
    result["update"]["title"] = %update.title
  of sukToolCallUpdate:
    result["update"]["toolCallId"] = %update.toolCallId
    result["update"]["status"] = %update.status
  of sukStatus:
    result["update"]["status"] = %update.status
  else:
    discard

proc isTextChunk*(update: SessionUpdate): bool =
  update.kind == sukAgentMessageChunk and
    update.content.kind == cbText and
    update.content.text.len > 0

# --------------------------------------------------------------------------- #
#  SSE framing.                                                                #
# --------------------------------------------------------------------------- #

proc sseHeaderBlock(): string =
  ## Headers + a blank line — the prelude every SSE response sends
  ## before the first event.
  result = "HTTP/1.1 200 OK\c\L"
  result.add "Content-Type: " & SseContentType & "\c\L"
  result.add "Cache-Control: no-store\c\L"
  result.add "Connection: close\c\L"
  result.add "X-Accel-Buffering: no\c\L"
  result.add "\c\L"

proc encodeSseEvent*(eventType, data: string): string =
  ## Serialise one SSE event.  Multi-line ``data`` is split on ``\n``
  ## per the SSE spec.
  if eventType.len > 0:
    result.add "event: " & eventType & "\n"
  for line in data.split('\n'):
    result.add "data: " & line & "\n"
  result.add "\n"

# --------------------------------------------------------------------------- #
#  Route handlers.                                                            #
# --------------------------------------------------------------------------- #

proc respondJson*(req: Request; code: HttpCode; body: string)
    {.async, gcsafe.} =
  let headers = newHttpHeaders([
    ("Content-Type", "application/json"),
    ("Cache-Control", "no-store"),
  ])
  await req.respond(code, body, headers)

proc respondBackendUnavailable*(req: Request; reason: string)
    {.async, gcsafe.} =
  let body = $(%* {
    "error": "agent_backend_unavailable",
    "reason": reason,
  })
  await respondJson(req, Http503, body)

proc handleSessions*(reg: AgentRegistry; req: Request)
    {.async, gcsafe.} =
  ## ``POST /api/agent/sessions`` handler.
  if req.reqMethod != HttpPost:
    await respondJson(req, Http405,
      $(%* {"error": "method_not_allowed"}))
    return
  var cwd = ""
  if req.body.len > 0:
    try:
      let node = parseJson(req.body)
      cwd = node{"cwd"}.getStr("")
    except JsonParsingError:
      await respondJson(req, Http400,
        $(%* {"error": "invalid_json"}))
      return
  try:
    let state = createAcpSession(reg, cwd)
    let body = $(%* {
      "sessionId": state.sessionId,
      "agentCapabilities": capabilityJson(state.capabilities),
    })
    await respondJson(req, Http200, body)
  except AgentBackendUnavailableError as e:
    await respondBackendUnavailable(req, e.msg)
  except CatchableError as e:
    error "agent session creation failed", reason = e.msg
    await respondJson(req, Http500,
      $(%* {"error": "agent_init_failed", "reason": e.msg}))

proc cancelSession(reg: AgentRegistry; sessionId: string) {.gcsafe.} =
  {.gcsafe.}:
    let opt = reg.getState(sessionId)
    if not opt.isSome: return
    var state = opt.get
    try:
      state.client.acp.cancel(sessionId)
      info "agent session cancelled", sessionId = sessionId
    except CatchableError as e:
      warn "agent cancel failed", sessionId = sessionId, reason = e.msg

proc handleCancel*(reg: AgentRegistry; req: Request)
    {.async, gcsafe.} =
  ## ``POST /api/agent/cancel`` handler.
  if req.reqMethod != HttpPost:
    await respondJson(req, Http405,
      $(%* {"error": "method_not_allowed"}))
    return
  var sessionId = ""
  if req.body.len > 0:
    try:
      sessionId = parseJson(req.body){"sessionId"}.getStr("")
    except JsonParsingError:
      await respondJson(req, Http400,
        $(%* {"error": "invalid_json"}))
      return
  if sessionId.len == 0:
    await respondJson(req, Http400,
      $(%* {"error": "missing_sessionId"}))
    return
  cancelSession(reg, sessionId)
  await respondJson(req, Http202, $(%* {"accepted": true}))

proc sendSseLine(sock: AsyncSocket; payload: string): Future[bool] {.async.} =
  try:
    await sock.send(payload)
    return true
  except CatchableError as e:
    debug "SSE send failed (client likely disconnected)", reason = e.msg
    return false

proc emitUpdates(reg: AgentRegistry; sessionId: string;
                 sock: AsyncSocket): Future[bool] {.async, gcsafe.} =
  ## Drain pending ``session/update`` events and forward each as an SSE
  ## frame.  Returns ``false`` when the SSE socket has gone away.
  var updates: seq[SessionUpdate]
  {.gcsafe.}:
    let stateOpt = reg.getState(sessionId)
    if not stateOpt.isSome:
      return true
    var state = stateOpt.get
    updates = state.client.acp.drainUpdates()
  for update in updates:
    let evt = encodeSseEvent("session/update",
                             $sessionUpdateJson(update))
    if not await sendSseLine(sock, evt):
      return false
  return true

proc handlePrompts*(reg: AgentRegistry; req: Request)
    {.async, gcsafe.} =
  ## ``POST /api/agent/prompts`` handler.  Emits the SSE stream.
  ##
  ## Phase B uses the synchronous nim-acp client: ``sendPrompt`` blocks
  ## until the ACP server returns its ``stopReason``.  Between the
  ## response and the close we drain any session/update notifications
  ## the ACP server pushed during the turn (the transport buffers them)
  ## and forward each as one SSE event.  REV-M11 will switch to an
  ## async ACP client for true incremental streaming.
  if req.reqMethod != HttpPost:
    await respondJson(req, Http405,
      $(%* {"error": "method_not_allowed"}))
    return
  let (sessionId, prompt) =
    try: parsePromptFromBody(req.body)
    except JsonParsingError:
      await respondJson(req, Http400,
        $(%* {"error": "invalid_json"}))
      return
  if sessionId.len == 0:
    await respondJson(req, Http400,
      $(%* {"error": "missing_sessionId"}))
    return
  if prompt.len == 0:
    await respondJson(req, Http400,
      $(%* {"error": "empty_prompt"}))
    return
  let stateOpt = reg.getState(sessionId)
  if not stateOpt.isSome:
    await respondJson(req, Http404,
      $(%* {"error": "unknown_session", "sessionId": sessionId}))
    return
  var state = stateOpt.get

  info "agent prompt submitted", sessionId = sessionId,
    promptBlocks = prompt.len
  let prelude = sseHeaderBlock()
  if not await sendSseLine(req.client, prelude):
    info "agent SSE client disconnected before prelude",
      sessionId = sessionId
    return
  # First drain — emit anything already buffered (e.g. greeting frames
  # the agent sent during ``initialize``).
  if not await emitUpdates(reg, sessionId, req.client):
    cancelSession(reg, sessionId)
    return

  var stopReason = "error"
  var promptError = ""
  var promptResp: PromptResponse
  {.gcsafe.}:
    try:
      promptResp = state.client.acp.sendPrompt(
        PromptRequest(sessionId: sessionId, prompt: prompt))
      stopReason = $promptResp.stopReason
    except AcpError as e:
      promptError = e.msg
      error "agent prompt failed", sessionId = sessionId, reason = e.msg
    except CatchableError as e:
      promptError = e.msg
      error "agent prompt error", sessionId = sessionId, reason = e.msg

  # Post-turn drain: emit every notification the ACP server pushed
  # during the turn.
  if not await emitUpdates(reg, sessionId, req.client):
    cancelSession(reg, sessionId)
    return

  if promptError.len > 0:
    let errEvent = encodeSseEvent("error",
      $(%* {"sessionId": sessionId, "reason": promptError}))
    discard await sendSseLine(req.client, errEvent)
  let endEvent = encodeSseEvent("end", $(%* {"stopReason": stopReason}))
  discard await sendSseLine(req.client, endEvent)
  info "agent prompt complete", sessionId = sessionId,
    stopReason = stopReason
  # Close the connection — we replied with ``Connection: close`` so the
  # client should not be expecting another request on this socket.
  try: req.client.close() except CatchableError: discard

# --------------------------------------------------------------------------- #
#  Mount helpers — the daemon binds these handlers via registerHandler.       #
# --------------------------------------------------------------------------- #

type
  AgentHandlerProc* = proc(req: Request): Future[void] {.async, gcsafe.}

proc makeSessionsHandler*(reg: AgentRegistry): AgentHandlerProc =
  result = proc(req: Request): Future[void] {.async, gcsafe.} =
    await handleSessions(reg, req)

proc makePromptsHandler*(reg: AgentRegistry): AgentHandlerProc =
  result = proc(req: Request): Future[void] {.async, gcsafe.} =
    await handlePrompts(reg, req)

proc makeCancelHandler*(reg: AgentRegistry): AgentHandlerProc =
  result = proc(req: Request): Future[void] {.async, gcsafe.} =
    await handleCancel(reg, req)
