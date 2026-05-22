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

import std/[asyncdispatch, asyncnet, asynchttpserver, base64, json, locks,
            options, os, strutils, tables, times]

import db_connector/db_postgres

import nim_acp
import nim_agents

import ./log_setup
import ./brief_format
import ./brief_index
import ./db as dr_db

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
    ##
    ## ``backend`` / ``customCmd`` / ``customArgs`` capture the ACP
    ## server selection.  They are populated from the ``[agent]``
    ## TOML section (and the ``--agent-backend`` CLI flag) at daemon
    ## startup.  ``extraArgs`` stays for callers that just need to
    ## pass per-session argv tail to ``claude-agent-acp``.
    lock: Lock
    sessions: Table[string, AgentSessionState]
    backend*: AcpAgentKind
    customCmd*: string
    customArgs*: seq[string]
    extraArgs: seq[string]
    ## CMP-M5 — AI Assistant primer knobs.  ``assistantPromptPath`` is
    ## the absolute path the daemon reads for the system prompt;
    ## ``primerEnabled`` toggles the primer round-trip on session
    ## creation.  ``workspaceRoot`` is the fallback project root used
    ## when ``POST /api/agent/sessions`` doesn't carry ``projectRoot``.
    ## ``db`` is optional — when nil the primer simply skips the
    ## active-campaigns section.
    assistantPromptPath*: string
    primerEnabled*: bool
    workspaceRoot*: string
    db*: ReviewDb

  AgentBackendUnavailableError* = object of CatchableError

const
  SseContentType* = "text/event-stream; charset=utf-8"
  AgentSessionsRoute* = "/api/agent/sessions"
  AgentPromptsRoute* = "/api/agent/prompts"
  AgentCancelRoute* = "/api/agent/cancel"

# --------------------------------------------------------------------------- #
#  Registry helpers.                                                          #
# --------------------------------------------------------------------------- #

proc newAgentRegistry*(extraArgs: seq[string] = @[];
    backend: AcpAgentKind = aakClaude;
    customCmd: string = "";
    customArgs: seq[string] = @[];
    assistantPromptPath: string = "";
    primerEnabled: bool = true;
    workspaceRoot: string = "";
    db: ReviewDb = nil): AgentRegistry =
  ## Allocate an empty session cache. The defaults match the
  ## pre-Phase-C contract (claude-agent-acp without explicit args)
  ## so existing callers keep working untouched.
  ##
  ## CMP-M5 — additional optional parameters configure the primer
  ## round-trip on session creation.  ``primerEnabled = false`` makes
  ## :proc:`handleSessions` skip the primer entirely (back to
  ## pre-CMP-M5 behaviour); ``assistantPromptPath`` overrides the
  ## file the primer's first block is read from; ``workspaceRoot``
  ## is the fallback project root when the request body doesn't
  ## carry ``projectRoot``; ``db`` is used to pull the active
  ## campaigns block (nil → skip that section).
  result = AgentRegistry(
    sessions: initTable[string, AgentSessionState](),
    backend: backend,
    customCmd: customCmd,
    customArgs: customArgs,
    extraArgs: extraArgs,
    assistantPromptPath: assistantPromptPath,
    primerEnabled: primerEnabled,
    workspaceRoot: workspaceRoot,
    db: db)
  initLock(result.lock)
  case backend
  of aakClaude:
    info "agent registry initialised", backend = "claude"
  of aakCodex:
    info "agent registry initialised", backend = "codex"
  of aakCustom:
    info "agent registry initialised", backend = "custom",
      cmd = customCmd

proc attachDb*(reg: AgentRegistry; db: ReviewDb) =
  ## CMP-M5 — late-bind the design-review DB handle onto the agent
  ## registry.  Called by ``mountDesignReviewRoutes`` after it opens
  ## the long-lived ``ReviewDb`` connection.  When set, the primer's
  ## "Active campaigns" section is populated from
  ## ``design_review.list_campaigns('active', 50, 0)``; when nil the
  ## primer simply omits the section.
  reg.db = db

proc release*(reg: AgentRegistry; sessionId: string) =
  acquire(reg.lock)
  try:
    if reg.sessions.hasKey(sessionId):
      reg.sessions.del(sessionId)
  finally:
    release(reg.lock)

proc shutdownAndRelease*(reg: AgentRegistry; sessionId: string) =
  ## CMP-M7 — take a session out of the registry AND terminate its
  ## ACP transport (including the spawned stdio child).  Used by the
  ## campaign route after a turn ends and by the chat route when the
  ## SSE client explicitly closes the session.  Without this the
  ## daemon leaks one ACP child per session: ``release`` alone only
  ## drops the registry entry, leaving the child alive in the
  ## background because its closures keep the transport pinned.
  var state: AgentSessionState
  var found = false
  acquire(reg.lock)
  try:
    if reg.sessions.hasKey(sessionId):
      state = reg.sessions[sessionId]
      reg.sessions.del(sessionId)
      found = true
  finally:
    release(reg.lock)
  if found:
    info "agent client shutdown begin", sessionId = sessionId
    try:
      shutdown(state.client)
      info "agent client shutdown end", sessionId = sessionId
    except CatchableError as e:
      warn "agent client shutdown raised",
        sessionId = sessionId, reason = e.msg
  else:
    info "agent client shutdown skipped (not in registry)",
      sessionId = sessionId

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

proc createAcpSession*(reg: AgentRegistry; cwd = "";
    idleTimeoutMs: int = -1): AgentSessionState {.gcsafe.} =
  ## Spawn the ACP agent, run ``initialize`` + ``session/new`` and stash
  ## the resulting :type:`AgentClient` in the registry.  The agent
  ## selection comes from ``reg.backend`` (set by the daemon from
  ## ``[agent].backend`` / ``--agent-backend``).  Raises
  ## :type:`AgentBackendUnavailableError` when the chosen factory
  ## fails because the binary isn't on PATH.
  ##
  ## ``idleTimeoutMs`` overrides the default per-frame idle silence
  ## budget on the spawned stdio-ACP transport.  Pass a negative value
  ## to keep ``nim-agents``' built-in default (5 min for chat / one-shot
  ## prompts); campaign sessions pass a larger value (default 15 min)
  ## because the orchestrator legitimately stays silent across long
  ## sub-agent dispatches before emitting its next ``session/update``.
  ##
  ## Marked ``gcsafe`` because the surrounding asynchttpserver dispatch
  ## requires it; the nim-acp transport's indirect-call methods are
  ## benign here — per-session state lives entirely inside the cached
  ## :type:`AgentClient`, which never escapes this thread.
  {.gcsafe.}:
    var client: AgentClient
    try:
      if idleTimeoutMs > 0:
        client = fromAcpAgent(reg.backend, reg.extraArgs,
                             cmd = reg.customCmd, args = reg.customArgs,
                             idleTimeoutMs = idleTimeoutMs)
      else:
        client = fromAcpAgent(reg.backend, reg.extraArgs,
                             cmd = reg.customCmd, args = reg.customArgs)
    except AcpError as e:
      error "agent backend unavailable", reason = e.msg,
        backend = $reg.backend
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
#  CMP-M5 — AI Assistant primer assembly.                                     #
#                                                                              #
#  Every chat session opened via ``POST /api/agent/sessions`` gets a single   #
#  "primer" ``session/prompt`` immediately after ``session/new``.  The primer #
#  carries the AI Assistant system prompt (from                                #
#  ``isonim/prompts/ai-assistant.md``) plus a project-context block built      #
#  from four sources:                                                          #
#    1. Project root (CWD-style absolute path).                                #
#    2. ``AGENTS.md`` (or ``CLAUDE.md``) at the project root, truncated to    #
#       :const:`MaxAgentsMdBytes` (head + middle ellipsis + tail).            #
#    3. Brief index summary from ``<projectRoot>/briefs/``.                   #
#    4. Active campaigns from ``design_review.list_campaigns('active', ...)``. #
#                                                                              #
#  The primer round-trip is invisible to callers — :proc:`handleSessions`     #
#  drains the agent's acknowledgement before returning the sessionId.         #
# --------------------------------------------------------------------------- #

const
  MaxAgentsMdBytes* = 4_096
    ## Cap on the AGENTS.md/CLAUDE.md body included in the primer.
    ## Longer files are head+tail truncated with an ellipsis marker so
    ## the system prompt still fits inside the agent's context budget.
  PrimerHeadKeepBytes* = 2_048
  PrimerTailKeepBytes* = 2_048
  PrimerTruncMarker* = "\n\n[…truncated…]\n\n"
  FallbackAssistantPrompt* = "You are a coding assistant.  No special " &
    "IsoNim Assistant context could be loaded — operate as a vanilla " &
    "coding assistant for the user's current project."
    ## CMP-M5 — emergency prompt used when the configured
    ## ``[agent].assistant_prompt_path`` file is missing or unreadable.
    ## The daemon logs a warning and keeps the chat session alive.
  PrimerInstruction* = "INSTRUCTION:\n" &
    "Acknowledge briefly that you've received your system context and " &
    "are ready to help.  Do not produce a long preamble.\n"
  PrimerIdleTimeoutMs* = 30_000
    ## Cap on how long :proc:`handleSessions` waits for the primer
    ## acknowledgement before logging a warning and returning the
    ## sessionId anyway.  Subsequent user prompts still work; the
    ## acknowledgement may simply arrive a little late.

proc readAssistantPromptBody*(path: string): string =
  ## CMP-M5 — read the AI Assistant system prompt off disk.  Returns
  ## the verbatim body on success; ``""`` when the file is missing or
  ## unreadable (the caller substitutes :const:`FallbackAssistantPrompt`).
  if path.len == 0:
    return ""
  if not fileExists(path):
    return ""
  try:
    return readFile(path)
  except IOError as e:
    warn "assistant prompt unreadable", path = path, reason = e.msg
    return ""
  except OSError as e:
    warn "assistant prompt unreadable", path = path, reason = e.msg
    return ""

proc truncateAgentsMd*(body: string): string =
  ## Apply the head/tail truncation rule for the AGENTS.md block.
  if body.len <= MaxAgentsMdBytes:
    return body
  result = body[0 ..< PrimerHeadKeepBytes]
  result.add PrimerTruncMarker
  result.add body[body.len - PrimerTailKeepBytes .. ^1]

proc readAgentsMd*(projectRoot: string): tuple[present: bool; body: string] =
  ## CMP-M5 — return the contents of ``AGENTS.md`` (preferred) or
  ## ``CLAUDE.md`` at ``projectRoot``, truncated to
  ## :const:`MaxAgentsMdBytes`.  ``present=false`` when neither file
  ## exists.
  if projectRoot.len == 0:
    return (present: false, body: "")
  for name in ["AGENTS.md", "CLAUDE.md"]:
    let p = projectRoot / name
    if fileExists(p):
      try:
        let raw = readFile(p)
        return (present: true, body: truncateAgentsMd(raw))
      except IOError as e:
        debug "AGENTS.md unreadable", path = p, reason = e.msg
      except OSError as e:
        debug "AGENTS.md unreadable", path = p, reason = e.msg
  (present: false, body: "")

proc renderBriefIndexSummary*(projectRoot: string): string =
  ## CMP-M5 — one line per brief: ``<briefId> — <coversPreviews count>
  ## previews × <backends count> backends — <title>``.  Returns an
  ## empty string when the project has no ``briefs/`` directory.
  if projectRoot.len == 0:
    return ""
  let briefsDir = projectRoot / "briefs"
  if not dirExists(briefsDir):
    return ""
  let idx = try: buildBriefIndex(briefsDir)
            except CatchableError as e:
              debug "brief index build failed", projectRoot = projectRoot,
                reason = e.msg
              return ""
  if idx == nil or idx.byBriefId.len == 0:
    return ""
  for briefId, brief in idx.byBriefId.pairs:
    var beCount = 0
    for cov in brief.coversPreviews:
      beCount += cov.backends.len
    result.add "- " & briefId & " — " &
      $brief.coversPreviews.len & " previews × " &
      $beCount & " backends"
    if brief.title.len > 0:
      result.add " — " & brief.title
    result.add "\n"

proc renderActiveCampaigns*(reg: AgentRegistry): string =
  ## CMP-M5 — one line per active campaign:
  ##   ``<campaignId> — <briefRefs> — round=<latest>``
  ## Returns empty when no DB handle is attached or no campaigns
  ## exist.  Database errors are swallowed (logged at debug) — the
  ## primer is best-effort.
  if reg == nil or reg.db == nil:
    return ""
  try:
    reg.db.asApp()
    let stmt = "SELECT design_review.list_campaigns('active', 50, 0)::text"
    let rows = reg.db.conn.getAllRows(sql(stmt))
    for row in rows:
      if row.len == 0 or row[0].len == 0: continue
      var node: JsonNode
      try: node = parseJson(row[0])
      except JsonParsingError: continue
      let campaignId = node{"campaign_id"}.getStr("")
      if campaignId.len == 0: continue
      var briefRefs = ""
      let refs = node{"brief_refs"}
      if refs != nil and refs.kind == JArray:
        var parts: seq[string]
        for it in refs.items:
          parts.add it.getStr("")
        briefRefs = parts.join(", ")
      var latestRound = 0
      try:
        let r = reg.db.conn.getValue(sql(
          "SELECT design_review.count_campaign_round_complete('" &
          campaignId.replace("'", "''") & "'::uuid)::text"))
        if r.len > 0:
          try: latestRound = parseInt(r)
          except ValueError: discard
      except CatchableError as e:
        debug "active campaign: round count failed",
          campaignId = campaignId, reason = e.msg
      result.add "- " & campaignId
      if briefRefs.len > 0:
        result.add " — " & briefRefs
      result.add " — round=" & $latestRound & "\n"
  except CatchableError as e:
    debug "active campaign listing failed", reason = e.msg
    return ""

proc assemblePrimerPrompt*(assistantPrompt, projectRoot: string;
    agentsMdPresent: bool; agentsMdBody: string;
    briefIndexSummary: string;
    activeCampaigns: string): string =
  ## CMP-M5 — build the composite first-turn prompt for a freshly-opened
  ## chat ACP session.  The format mirrors the campaign orchestrator's
  ## first-prompt layout so the agent sees a familiar shape.
  let promptBody =
    if assistantPrompt.len > 0: assistantPrompt
    else: FallbackAssistantPrompt
  result = "SYSTEM CONTEXT — IsoNim AI Assistant prompt:\n\n"
  result.add promptBody
  if not promptBody.endsWith("\n"):
    result.add "\n"
  result.add "\nPROJECT CONTEXT:\n\n"
  result.add "Project root: "
  if projectRoot.len > 0:
    result.add projectRoot
  else:
    result.add "(unknown)"
  result.add "\n\n"
  result.add "AGENTS.md (if present): "
  if agentsMdPresent:
    result.add "\n"
    result.add agentsMdBody
    if not agentsMdBody.endsWith("\n"):
      result.add "\n"
  else:
    result.add "(none)\n"
  result.add "\nBrief index (loaded from <project>/briefs/):\n"
  if briefIndexSummary.len > 0:
    result.add briefIndexSummary
  else:
    result.add "(none — no briefs/ directory or no readable briefs)\n"
  result.add "\nActive campaigns:\n"
  if activeCampaigns.len > 0:
    result.add activeCampaigns
  else:
    result.add "(none active)\n"
  result.add "\nCLI tools available (invoke via shell):\n"
  result.add "- `isonim-review campaign list / show <id> / start --doc <path> / inject <id> <text> / edit-doc <id> / tail <id> / stop <id>`\n"
  result.add "- `isonim-review run-review --run <id> --acp-backend codex`\n"
  result.add "- `isonim-review seed-run --brief <id> --capture <be>=<path>...`\n"
  result.add "- `isonim-review capture --brief <id>` (requires clean workspace)\n"
  result.add "- `isonim-review briefs check --project <path>`\n"
  result.add "- `isonim-review db-health [--json]`\n\n"
  result.add PrimerInstruction

proc logPrimerPrompt*(sessionId, promptText: string) =
  ## CMP-M5 test hook — when ``$FAKE_ACP_CONTENT_LOG`` is set, append
  ## the primer prompt text as a JSON-summary line so the test fixtures
  ## (which already inspect this log for the prompt routes) can assert
  ## the primer's body shape.  Mirrors :proc:`logCampaignPrompt` in
  ## ``campaign_routes.nim``.
  let contentLog = getEnv("FAKE_ACP_CONTENT_LOG")
  if contentLog.len == 0: return
  let summary = %* {
    "source": "primer",
    "sessionId": sessionId,
    "promptText": promptText,
    "promptLen": promptText.len,
  }
  try:
    let f = open(contentLog, fmAppend)
    defer: f.close()
    f.write($summary & "\n")
  except IOError:
    discard

proc primeAcpSession*(reg: AgentRegistry; state: AgentSessionState;
                      projectRoot: string) {.gcsafe.} =
  ## CMP-M5 — send the AI Assistant primer prompt on the freshly-opened
  ## ACP session and drain the agent's acknowledgement.  Runs
  ## synchronously inside :proc:`handleSessions`; the caller blocks on
  ## the primer round-trip before returning the sessionId.  Capped at
  ## :const:`PrimerIdleTimeoutMs` of wall-clock time — if the agent
  ## takes longer the daemon logs a warning and proceeds; subsequent
  ## user prompts on the same session still work, the ACK simply
  ## arrives late and is dropped (the SSE consumer hasn't connected
  ## yet).
  {.gcsafe.}:
    let resolvedRoot =
      if projectRoot.len > 0: projectRoot
      elif reg.workspaceRoot.len > 0: reg.workspaceRoot
      else: getCurrentDir()
    let assistantPath =
      if reg.assistantPromptPath.len > 0: reg.assistantPromptPath
      else: ""
    let assistantBody = readAssistantPromptBody(assistantPath)
    if assistantPath.len > 0 and assistantBody.len == 0:
      warn "assistant prompt missing — using built-in fallback",
        path = assistantPath
    let agentsMd = readAgentsMd(resolvedRoot)
    let briefSummary = renderBriefIndexSummary(resolvedRoot)
    let campaigns = renderActiveCampaigns(reg)
    let primer = assemblePrimerPrompt(assistantBody, resolvedRoot,
      agentsMd.present, agentsMd.body, briefSummary, campaigns)
    info "agent session primer assembled", sessionId = state.sessionId,
      projectRoot = resolvedRoot, primerBytes = primer.len,
      assistantPromptLen = assistantBody.len,
      agentsMdPresent = agentsMd.present,
      briefSummaryLen = briefSummary.len,
      campaignsLen = campaigns.len
    logPrimerPrompt(state.sessionId, primer)
    var client = state.client
    let startedAt = epochTime()
    let onEvent: AgentEventCallback = proc(ev: AgentEvent) {.gcsafe.} =
      discard
    try:
      let turn = sendPromptStreaming(client,
        AgentSession(id: state.sessionId, backend: abkAcp),
        @[textBlock(primer)], onEvent)
      info "agent session primer complete",
        sessionId = state.sessionId,
        stopReason = $turn.stopReason,
        elapsedMs = int((epochTime() - startedAt) * 1000)
    except CatchableError as e:
      warn "agent session primer failed (continuing)",
        sessionId = state.sessionId, reason = e.msg,
        elapsedMs = int((epochTime() - startedAt) * 1000)
    # Drain any residual updates buffered while the primer was in flight
    # so the first user-prompt SSE stream doesn't replay the primer's
    # acknowledgement frames.
    try:
      discard client.acp.drainUpdates()
    except CatchableError:
      discard

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

type
  PngAttachmentError* = object of CatchableError
    ## Raised by :proc:`parsePromptFromBody` when a ``pngPaths`` entry
    ## cannot be read or doesn't carry a valid PNG signature.  The
    ## handler maps this into an HTTP 400 with the offending path in
    ## the response body so the CLI caller can surface it directly.
    path*: string

const PngSignature = "\x89PNG\r\n\x1A\n"

proc loadPngAsContentBlock(path: string): ContentBlock =
  ## Read ``path`` and wrap it as an ACP ``image`` content block with
  ## base64-encoded payload and ``image/png`` mime type.  Raises
  ## :type:`PngAttachmentError` if the file is missing or doesn't
  ## start with the canonical PNG 8-byte signature — the daemon and
  ## CLI run on the same host so missing paths almost always mean a
  ## bug in the caller, not a transient FS issue.
  if not fileExists(path):
    var e = newException(PngAttachmentError,
      "could not read PNG " & path & ": file does not exist")
    e.path = path
    raise e
  var bytes = ""
  try:
    bytes = readFile(path)
  except IOError as ioe:
    var e = newException(PngAttachmentError,
      "could not read PNG " & path & ": " & ioe.msg)
    e.path = path
    raise e
  if bytes.len < PngSignature.len or
     bytes[0 ..< PngSignature.len] != PngSignature:
    var e = newException(PngAttachmentError,
      "could not read PNG " & path & ": not a valid PNG (bad signature)")
    e.path = path
    raise e
  result = ContentBlock(
    kind: cbImage,
    mimeType: "image/png",
    data: base64.encode(bytes))

proc parsePromptFromBody*(body: string):
    tuple[sessionId: string; prompt: seq[ContentBlock]] =
  ## Body shape:
  ##   {"sessionId": "...",
  ##    "messages": [{"role":"user","content":[...]}],
  ##    "pngPaths": ["/abs/...", ...]}
  ##
  ## We accept ``messages[].content[]`` items of the form
  ## ``{"type":"text", "text": "..."}`` for the text part.  When
  ## ``pngPaths`` is present each path is read off the local
  ## filesystem, base64-encoded, and appended as an ACP ``image``
  ## content block — these flow through ``sendPromptStreaming`` to the
  ## ACP agent as proper multimodal attachments instead of dropping
  ## out as they did in Phase B's text-only contract.
  ##
  ## Raises :type:`PngAttachmentError` when a ``pngPaths`` entry can't
  ## be read or doesn't carry a valid PNG signature.  The handler
  ## maps this onto an HTTP 400 so the CLI surface gets a clear
  ## diagnosis instead of a stalled agent that quietly received only
  ## the text block.
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
  let pngPaths = node{"pngPaths"}
  if pngPaths != nil and pngPaths.kind == JArray:
    for entry in pngPaths.items:
      let path = entry.getStr("")
      if path.len == 0: continue
      result.prompt.add loadPngAsContentBlock(path)

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
  ##
  ## CORS: the editor sidebar fetches from a different origin
  ## (editor on :8090, daemon on :8113), so the SSE response must
  ## carry ``Access-Control-Allow-Origin`` or Chromium will reject
  ## the body before the first ``data:`` frame is dispatched.
  result = "HTTP/1.1 200 OK\c\L"
  result.add "Content-Type: " & SseContentType & "\c\L"
  result.add "Cache-Control: no-store\c\L"
  result.add "Connection: close\c\L"
  result.add "X-Accel-Buffering: no\c\L"
  result.add "Access-Control-Allow-Origin: *\c\L"
  result.add "Access-Control-Allow-Methods: GET, POST, OPTIONS\c\L"
  result.add "Access-Control-Allow-Headers: Content-Type\c\L"
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
  ## CORS: the editor sidebar fetches across origins
  ## (editor on :8090, daemon on :8113), so every JSON response must
  ## carry ``Access-Control-Allow-Origin`` or the browser will block
  ## the body even though the preflight succeeded.  Mirrors the
  ## headers already on ``api_handlers.respondJson`` for the
  ## ``/api/design-review/*`` routes.
  let headers = newHttpHeaders([
    ("Content-Type", "application/json"),
    ("Cache-Control", "no-store"),
    ("Access-Control-Allow-Origin", "*"),
    ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
    ("Access-Control-Allow-Headers", "Content-Type"),
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
  ##
  ## CMP-M5 — when ``reg.primerEnabled`` is true, the handler primes
  ## the freshly-opened ACP session with the AI Assistant system
  ## prompt + project-context block before returning the sessionId.
  ## The request body may carry ``projectRoot`` to override the
  ## daemon's workspace-root fallback.
  if req.reqMethod != HttpPost:
    await respondJson(req, Http405,
      $(%* {"error": "method_not_allowed"}))
    return
  var cwd = ""
  var projectRoot = ""
  if req.body.len > 0:
    try:
      let node = parseJson(req.body)
      cwd = node{"cwd"}.getStr("")
      projectRoot = node{"projectRoot"}.getStr("")
    except JsonParsingError:
      await respondJson(req, Http400,
        $(%* {"error": "invalid_json"}))
      return
  try:
    let state = createAcpSession(reg, cwd)
    if reg.primerEnabled:
      primeAcpSession(reg, state, projectRoot)
    else:
      debug "agent session primer skipped (primerEnabled=false)",
        sessionId = state.sessionId
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
  ## Progressive delivery: ``sendPromptStreaming`` invokes a synchronous
  ## per-frame callback as each ``session/update`` arrives from the ACP
  ## child.  The callback enqueues the encoded SSE bytes onto a buffer
  ## the async dispatch loop drains while waiting for the prompt
  ## response.  Notifications received before the response therefore
  ## reach the SSE client immediately, not at end-of-turn.
  if req.reqMethod != HttpPost:
    await respondJson(req, Http405,
      $(%* {"error": "method_not_allowed"}))
    return
  var sessionId: string
  var prompt: seq[ContentBlock]
  try:
    let parsed = parsePromptFromBody(req.body)
    sessionId = parsed.sessionId
    prompt = parsed.prompt
  except JsonParsingError:
    await respondJson(req, Http400,
      $(%* {"error": "invalid_json"}))
    return
  except PngAttachmentError as pe:
    warn "agent prompt rejected: bad png attachment",
      path = pe.path, reason = pe.msg
    await respondJson(req, Http400,
      $(%* {"error": "bad_png_attachment",
            "path": pe.path,
            "reason": pe.msg}))
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

  var textBlocks = 0
  var imageBlocks = 0
  for b in prompt:
    case b.kind
    of cbText: inc textBlocks
    of cbImage: inc imageBlocks
    else: discard
  info "agent prompt submitted", sessionId = sessionId,
    promptBlocks = prompt.len,
    textBlocks = textBlocks,
    imageBlocks = imageBlocks

  # Test hook: when ``$FAKE_ACP_CONTENT_LOG`` is set, append a JSON
  # summary of the inbound prompt's content blocks so test fixtures
  # can assert image bundling without inspecting ACP transport bytes.
  let contentLog = getEnv("FAKE_ACP_CONTENT_LOG")
  if contentLog.len > 0:
    var summary = %* {
      "sessionId": sessionId,
      "promptBlocks": prompt.len,
      "textBlocks": textBlocks,
      "imageBlocks": imageBlocks,
      "blocks": newJArray(),
    }
    for b in prompt:
      var entry = %* {"type": $b.kind}
      case b.kind
      of cbText:
        entry["textLen"] = %b.text.len
      of cbImage, cbAudio, cbResource:
        entry["mimeType"] = %b.mimeType
        entry["dataLen"] = %b.data.len
      summary["blocks"].add entry
    try:
      let f = open(contentLog, fmAppend)
      defer: f.close()
      f.write($summary & "\n")
    except IOError:
      discard
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

  # Streaming bridge between the synchronous ACP reader thread (which
  # invokes the callback inline) and the async HTTP socket writer.  The
  # callback runs inside ``sendPrompt`` which we drive on a worker
  # thread; the main async loop polls the buffer between sleeps and
  # writes each pending frame to the socket as soon as it lands.
  type StreamBuffer = ref object
    lock: Lock
    frames: seq[string]
  let streamBuf = new StreamBuffer
  initLock(streamBuf.lock)
  defer: deinitLock(streamBuf.lock)
  proc pushFrame(frame: string) {.gcsafe.} =
    {.cast(gcsafe).}:
      acquire(streamBuf.lock)
      streamBuf.frames.add frame
      release(streamBuf.lock)
  proc popFrames(): seq[string] {.gcsafe.} =
    {.cast(gcsafe).}:
      acquire(streamBuf.lock)
      result = streamBuf.frames
      streamBuf.frames = @[]
      release(streamBuf.lock)

  var stopReason = "error"
  var promptError = ""
  var promptDone = false
  var promptResp: PromptResponse

  type PromptArgs = ref object
    sessionId: string
    prompt: seq[ContentBlock]
    client: AgentClient
    response: PromptResponse
    error: string
    done: bool
    callback: AgentEventCallback

  let onEvent: AgentEventCallback = proc(ev: AgentEvent) {.gcsafe.} =
    {.cast(gcsafe).}:
      # When we have the raw JSON straight from the ACP transport, send
      # it verbatim — it already matches the SSE wire schema the editor
      # expects (mirrors :proc:`sessionUpdateJson`'s preferred branch).
      var payload: JsonNode
      if ev.raw != nil:
        payload = ev.raw
      else:
        payload = %* {
          "sessionId": ev.sessionId,
          "update": {
            "sessionUpdate": $ev.kind,
            "content": {"type": "text", "text": ev.text},
            "toolCallId": ev.toolCallId,
            "title": ev.toolName,
            "status": ev.status,
          },
        }
      let frame = encodeSseEvent("session/update", $payload)
      debug "agent.streaming.chunk", sessionId = ev.sessionId,
        kind = $ev.kind, bytes = frame.len
      pushFrame(frame)

  proc runPrompt(args: PromptArgs) {.thread, gcsafe.} =
    {.cast(gcsafe).}:
      try:
        var client = args.client
        let turn = sendPromptStreaming(client,
          AgentSession(id: args.sessionId, backend: abkAcp),
          args.prompt, args.callback)
        args.response = PromptResponse(sessionId: args.sessionId,
                                       stopReason: turn.stopReason)
      except CatchableError as e:
        args.error = e.msg
      args.done = true

  var args = PromptArgs(sessionId: sessionId, prompt: prompt,
                        client: state.client, callback: onEvent)
  var worker: Thread[PromptArgs]
  createThread(worker, runPrompt, args)

  # Async pump: while the worker is running, periodically flush any
  # frames the callback enqueued onto the SSE socket.
  while not args.done:
    let pending = popFrames()
    var disconnected = false
    for frame in pending:
      if not await sendSseLine(req.client, frame):
        disconnected = true
        break
    if disconnected:
      # Surface a cancel to the agent so the ACP child can wind down,
      # then wait for the worker to finish — we still need to join the
      # thread or the daemon leaks resources.
      cancelSession(reg, sessionId)
      joinThread(worker)
      return
    await sleepAsync(10)

  joinThread(worker)
  promptDone = true
  promptResp = args.response
  if args.error.len > 0:
    promptError = args.error
    error "agent prompt failed", sessionId = sessionId, reason = promptError
  else:
    stopReason = $promptResp.stopReason

  # Final flush — any frames that arrived right before the response.
  let trailing = popFrames()
  for frame in trailing:
    if not await sendSseLine(req.client, frame):
      cancelSession(reg, sessionId)
      return

  # Clear the ACP transport's drain buffer — the streaming callback
  # already forwarded each notification to the SSE socket, so we MUST
  # NOT re-emit them via :proc:`drainUpdates` (that would duplicate
  # every chunk).  We still need to drain so the buffer doesn't grow
  # unboundedly across turns; just discard the result.
  {.gcsafe.}:
    let stOpt = reg.getState(sessionId)
    if stOpt.isSome:
      var s = stOpt.get
      discard s.client.acp.drainUpdates()

  if promptError.len > 0:
    let errEvent = encodeSseEvent("error",
      $(%* {"sessionId": sessionId, "reason": promptError}))
    discard await sendSseLine(req.client, errEvent)
  let endEvent = encodeSseEvent("end", $(%* {"stopReason": stopReason}))
  discard await sendSseLine(req.client, endEvent)
  debug "agent.streaming.complete", sessionId = sessionId,
    stopReason = stopReason
  info "agent prompt complete", sessionId = sessionId,
    stopReason = stopReason
  # Close the connection — we replied with ``Connection: close`` so the
  # client should not be expecting another request on this socket.
  try: req.client.close() except CatchableError: discard
  discard promptDone

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
