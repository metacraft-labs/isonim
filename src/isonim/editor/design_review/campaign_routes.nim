## CMP-M2 — daemon HTTP routes for the campaign system.
##
## Six handlers exposed by the editor daemon:
##
##   * ``POST /api/campaign/start``  — open an ACP session, INSERT a
##     campaign row + ``'started'`` event, send the first prompt to the
##     orchestrator and stream the agent's ``session/update`` events back
##     to the caller as an SSE response.  Closes with ``event: end`` +
##     a ``round_complete`` event written into the DB.
##   * ``POST /api/campaign/tick``   — send a continuation prompt to the
##     bound ACP session and stream the resulting ``session/update``
##     events.  Writes a ``round_started`` event before the prompt and a
##     ``round_complete`` event after.
##   * ``POST /api/campaign/stop``   — terminate the bound session and
##     transition the campaign to ``stopped``.
##   * ``GET  /api/campaign/list``   — paginated list, optionally
##     status-filtered, of campaigns in the DB.
##   * ``GET  /api/campaign/fetch``  — full campaign row + most-recent
##     ``eventLimit`` events as JSON.
##   * ``GET  /api/campaign/events`` — paginated event-log fetch (NOT
##     streaming for CMP-M2 — the CLI's ``campaign tail`` polls this
##     endpoint).
##
## The SSE stream-on-prompt machinery mirrors the Phase B
## ``handlePrompts`` in :mod:`agent_routes` — same worker-thread +
## buffered-callback pattern; we duplicate it here rather than
## refactoring agent_routes to share more code with us, because the
## campaign path needs to inject the orchestrator's system prompt + the
## campaign doc + the referenced briefs ahead of the user's text and
## that splice would muddy the ``/api/agent/prompts`` route's contract
## with a campaign-only dependency.

import std/[asyncdispatch, asyncnet, asynchttpserver, json, locks,
            options, os, parseutils, strutils, tables, uri]

import db_connector/db_postgres
import nim_acp
import nim_agents

import ./agent_routes
import ./db as dr_db
import ./log_setup

logScope:
  topics = "campaign"

const
  CampaignStartRoute* = "/api/campaign/start"
  CampaignTickRoute*  = "/api/campaign/tick"
  CampaignStopRoute*  = "/api/campaign/stop"
  CampaignListRoute*  = "/api/campaign/list"
  CampaignFetchRoute* = "/api/campaign/fetch"
  CampaignEventsRoute* = "/api/campaign/events"

  OrchestratorPromptRelPath* = "prompts/campaign-orchestrator.md"

type
  CampaignRegistry* = ref object
    ## Holds the live ACP session for each active campaign and the
    ## handle on the design-review DB.  Single-tenant — there is one
    ## entry per ``campaign_id`` and the daemon binds to ``127.0.0.1``
    ## only.
    lock: Lock
    sessions: Table[string, string]   ## campaign_id → acp session id
    agents: AgentRegistry
    db: ReviewDb
    promptPath*: string
    promptText: string                 ## cached orchestrator prompt body

  CampaignSchedulerError* = object of CatchableError

# ---------------------------------------------------------------------------
# Registry helpers.
# ---------------------------------------------------------------------------

proc newCampaignRegistry*(agents: AgentRegistry; db: ReviewDb;
                          promptPath: string): CampaignRegistry =
  result = CampaignRegistry(
    sessions: initTable[string, string](),
    agents: agents,
    db: db,
    promptPath: promptPath,
  )
  initLock(result.lock)
  if fileExists(promptPath):
    try:
      result.promptText = readFile(promptPath)
    except IOError as e:
      warn "campaign orchestrator prompt unreadable",
        path = promptPath, reason = e.msg
  else:
    warn "campaign orchestrator prompt missing", path = promptPath

proc reloadOrchestratorPrompt(reg: CampaignRegistry): string =
  ## Re-read the orchestrator prompt off disk if the file exists; fall
  ## back to the cached copy otherwise.  Operators iterate the prompt
  ## across daemon restarts, but a single restart in the middle of a
  ## test run shouldn't blank it.
  if fileExists(reg.promptPath):
    try:
      reg.promptText = readFile(reg.promptPath)
    except IOError as e:
      warn "campaign orchestrator prompt re-read failed",
        path = reg.promptPath, reason = e.msg
  return reg.promptText

proc storeSession(reg: CampaignRegistry; campaignId, sessionId: string) =
  acquire(reg.lock)
  try:
    reg.sessions[campaignId] = sessionId
  finally:
    release(reg.lock)

proc lookupSession(reg: CampaignRegistry; campaignId: string): string =
  acquire(reg.lock)
  try:
    if reg.sessions.hasKey(campaignId):
      return reg.sessions[campaignId]
  finally:
    release(reg.lock)
  return ""

proc dropSession(reg: CampaignRegistry; campaignId: string) =
  acquire(reg.lock)
  try:
    if reg.sessions.hasKey(campaignId):
      reg.sessions.del(campaignId)
  finally:
    release(reg.lock)

# ---------------------------------------------------------------------------
# DB helpers — wrappers around the design_review routines via plain
# parameterless SELECTs.  The app role can only EXECUTE routines, never
# touch the base tables directly, so this is the correct boundary.
# ---------------------------------------------------------------------------

proc escSql(s: string): string =
  s.replace("'", "''")

proc dbStartCampaign(reg: CampaignRegistry;
    docPath, docSha: string;
    briefRefs: seq[string];
    targetScore: float; hasTargetScore: bool;
    maxIterations: int; manifestHash: string;
    agentBackend, agentModel, startedBy: string): string =
  reg.db.asApp()
  var arrLit = "ARRAY["
  for i, b in briefRefs:
    if i > 0: arrLit.add ", "
    arrLit.add "'" & escSql(b) & "'"
  arrLit.add "]::text[]"
  let scoreLit =
    if hasTargetScore: $targetScore else: "NULL"
  let modelLit =
    if agentModel.len == 0: "NULL" else: "'" & escSql(agentModel) & "'"
  let stmt = "SELECT design_review.start_campaign(" &
    "'" & escSql(docPath) & "', " &
    "'" & escSql(docSha) & "', " &
    arrLit & ", " &
    scoreLit & "::real, " &
    $maxIterations & ", " &
    "'" & escSql(manifestHash) & "', " &
    "'" & escSql(agentBackend) & "', " &
    modelLit & ", " &
    "'" & escSql(startedBy) & "')::text"
  result = reg.db.conn.getValue(sql(stmt))
  if result.len == 0:
    raise newException(CampaignSchedulerError,
      "start_campaign returned empty id")

proc dbBindAcpSession(reg: CampaignRegistry; campaignId, sessionId: string) =
  reg.db.asApp()
  let stmt = "SELECT design_review.update_campaign_session('" &
    escSql(campaignId) & "'::uuid, '" & escSql(sessionId) & "')"
  discard reg.db.conn.getValue(sql(stmt))

proc dbRecordEvent(reg: CampaignRegistry;
    campaignId, eventKind: string; payload: JsonNode): string =
  reg.db.asApp()
  let payloadStr =
    if payload == nil: "{}" else: $payload
  let stmt = "SELECT design_review.record_campaign_event('" &
    escSql(campaignId) & "'::uuid, '" & escSql(eventKind) &
    "', '" & escSql(payloadStr) & "'::jsonb)::text"
  result = reg.db.conn.getValue(sql(stmt))

proc dbTransition(reg: CampaignRegistry;
    campaignId, status, reason: string) =
  reg.db.asApp()
  let reasonLit =
    if reason.len == 0: "NULL" else: "'" & escSql(reason) & "'"
  let stmt = "SELECT design_review.transition_campaign('" &
    escSql(campaignId) & "'::uuid, '" & escSql(status) & "', " &
    reasonLit & ")"
  discard reg.db.conn.getValue(sql(stmt))

proc dbListCampaigns(reg: CampaignRegistry;
    status: string; limit, offset: int): JsonNode =
  reg.db.asApp()
  let statusLit =
    if status.len == 0: "NULL" else: "'" & escSql(status) & "'"
  let stmt = "SELECT design_review.list_campaigns(" & statusLit & ", " &
    $limit & ", " & $offset & ")::text"
  let rows = reg.db.conn.getAllRows(sql(stmt))
  result = newJArray()
  for row in rows:
    if row.len == 0 or row[0].len == 0: continue
    try:
      result.add parseJson(row[0])
    except JsonParsingError:
      discard

proc dbFetchCampaign(reg: CampaignRegistry;
    campaignId: string; eventLimit: int): JsonNode =
  reg.db.asApp()
  let stmt = "SELECT design_review.fetch_campaign('" &
    escSql(campaignId) & "'::uuid, " & $eventLimit & ")::text"
  let raw = reg.db.conn.getValue(sql(stmt))
  if raw.len == 0:
    return nil
  try:
    return parseJson(raw)
  except JsonParsingError:
    return nil

proc dbRecentEvents(reg: CampaignRegistry;
    campaignId, since: string; limit: int): JsonNode =
  reg.db.asApp()
  let sinceLit =
    if since.len == 0: "NULL" else: "'" & escSql(since) & "'::timestamptz"
  let stmt = "SELECT design_review.recent_campaign_events('" &
    escSql(campaignId) & "'::uuid, " & sinceLit & ", " &
    $limit & ")::text"
  let rows = reg.db.conn.getAllRows(sql(stmt))
  result = newJArray()
  for row in rows:
    if row.len == 0 or row[0].len == 0: continue
    try:
      result.add parseJson(row[0])
    except JsonParsingError:
      discard

# ---------------------------------------------------------------------------
# Prompt assembly.  The first user message we send to the orchestrator
# carries the system prompt verbatim, the campaign doc, every referenced
# brief, and a closing instruction that explicitly bans sub-agent
# dispatch (the CMP-M2 milestone intentionally defers that wiring).
# ---------------------------------------------------------------------------

type
  CampaignPromptInputs* = object
    docPath*:     string
    docBody*:     string
    briefs*:      seq[tuple[briefId: string; body: string]]
    latestReport*: string
    round*:       int

proc assembleFirstPrompt*(orchestratorPrompt: string;
                          inputs: CampaignPromptInputs): string =
  ## Build the first-turn prompt sent to the orchestrator ACP session.
  ## See the task plan's "First-prompt assembly" section.
  result = "SYSTEM CONTEXT — orchestrator system prompt:\n"
  result.add orchestratorPrompt
  result.add "\n\nCAMPAIGN DOCUMENT (" & inputs.docPath & "):\n"
  result.add inputs.docBody
  result.add "\n\nBRIEFS REFERENCED:\n"
  if inputs.briefs.len == 0:
    result.add "  (none — campaign doc references no resolvable briefs)\n"
  else:
    for b in inputs.briefs:
      result.add "- " & b.briefId & ":\n"
      result.add b.body
      result.add "\n"
  result.add "\nLATEST AGENT REPORT (if any prior agent_report exists for any of the briefs):\n"
  if inputs.latestReport.len == 0:
    result.add "  (no prior agent report available)\n"
  else:
    result.add inputs.latestReport
    result.add "\n"
  result.add "\nINSTRUCTION:\n"
  result.add "Begin round 1. Read the inputs above and produce an analysis of the current state plus a plan\n"
  result.add "for what to address first. Do not yet dispatch sub-agents — sub-agent dispatch is wired in a\n"
  result.add "subsequent milestone. Output your plan as structured markdown.\n"
  result.add "\n"
  result.add "Sub-agent dispatch is not yet wired; produce a plan, do not attempt to dispatch.\n"

proc assembleTickPrompt*(round: int): string =
  ## Continuation prompt for ``campaign tick``.
  result = "INSTRUCTION:\n"
  result.add "Continue with round " & $round & ". Re-read the campaign doc and the latest agent report,\n"
  result.add "produce an updated plan for what to address next. Output as structured markdown.\n"
  result.add "Sub-agent dispatch is not yet wired; produce a plan, do not attempt to dispatch.\n"

# ---------------------------------------------------------------------------
# JSON body parsing.
# ---------------------------------------------------------------------------

type
  CampaignStartBody* = object
    docPath*:   string
    docSha*:    string
    briefRefs*: seq[string]
    targetScore*: float
    hasTargetScore*: bool
    maxIterations*: int
    body*:      string
    briefs*:    seq[tuple[briefId: string; body: string]]
    latestReport*: string
    manifestHash*: string
    startedBy*: string
    notesToOrchestrator*: string

proc parseStartBody*(raw: string): CampaignStartBody =
  let node = parseJson(raw)
  result.docPath = node{"docPath"}.getStr("")
  result.docSha = node{"docSha"}.getStr("")
  result.body = node{"body"}.getStr("")
  result.manifestHash = node{"manifestHash"}.getStr("local")
  result.startedBy = node{"startedBy"}.getStr("cli")
  result.maxIterations = node{"maxIterations"}.getInt(30)
  result.latestReport = node{"latestReport"}.getStr("")
  result.notesToOrchestrator = node{"notesToOrchestrator"}.getStr("")
  let ts = node{"targetScore"}
  if ts != nil and ts.kind in {JFloat, JInt}:
    result.targetScore = ts.getFloat(0.0)
    result.hasTargetScore = true
  let briefRefs = node{"briefRefs"}
  if briefRefs != nil and briefRefs.kind == JArray:
    for it in briefRefs.items:
      let s = it.getStr("").strip()
      if s.len > 0: result.briefRefs.add s
  let briefs = node{"briefs"}
  if briefs != nil and briefs.kind == JArray:
    for it in briefs.items:
      let id = it{"briefId"}.getStr("")
      let b = it{"body"}.getStr("")
      if id.len > 0:
        result.briefs.add (briefId: id, body: b)

# ---------------------------------------------------------------------------
# SSE helpers — sendSseLine + encodeSseEvent live in agent_routes; we
# import them via the dot-call syntax (they're exported).  The CORS
# prelude is identical to the agent route's prelude.
# ---------------------------------------------------------------------------

proc cmpSseHeader(): string =
  result = "HTTP/1.1 200 OK\c\L"
  result.add "Content-Type: " & SseContentType & "\c\L"
  result.add "Cache-Control: no-store\c\L"
  result.add "Connection: close\c\L"
  result.add "X-Accel-Buffering: no\c\L"
  result.add "Access-Control-Allow-Origin: *\c\L"
  result.add "Access-Control-Allow-Methods: GET, POST, OPTIONS\c\L"
  result.add "Access-Control-Allow-Headers: Content-Type\c\L"
  result.add "\c\L"

proc trySend(sock: AsyncSocket; payload: string): Future[bool] {.async.} =
  try:
    await sock.send(payload)
    return true
  except CatchableError as e:
    debug "campaign SSE send failed", reason = e.msg
    return false

# ---------------------------------------------------------------------------
# Shared prompt + stream procedure.  ``handleStart`` and ``handleTick``
# both reduce to "send this prompt on this session, forward each
# session/update event to the SSE socket, emit a campaign_event row on
# completion".  This proc is the shared implementation.
# ---------------------------------------------------------------------------

type
  PromptArgs = ref object
    sessionId: string
    prompt: seq[ContentBlock]
    client: AgentClient
    response: PromptResponse
    error: string
    done: bool
    callback: AgentEventCallback

proc runPromptThread(args: PromptArgs) {.thread, gcsafe.} =
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

proc streamPromptToSocket(reg: CampaignRegistry;
    sessionId, campaignId, eventKindOnDone, promptText: string;
    extraPayload: JsonNode;
    sock: AsyncSocket): Future[bool] {.async, gcsafe.} =
  ## Sends ``promptText`` to the cached ACP client for ``sessionId``,
  ## forwards session/update events to ``sock``, writes a
  ## ``eventKindOnDone`` (defaults: ``round_complete``) row to
  ## campaign_events on completion.  Returns true if the socket is
  ## still alive at the end of the stream.
  let stateOpt = reg.agents.getState(sessionId)
  if not stateOpt.isSome:
    let evt = encodeSseEvent("error",
      $(%* {"sessionId": sessionId, "reason": "unknown_session"}))
    discard await trySend(sock, evt)
    return false
  var state = stateOpt.get
  let prompt = @[textBlock(promptText)]

  # Streaming buffer.
  type StreamBuf = ref object
    lock: Lock
    frames: seq[string]
    accumulatedText: string
  let streamBuf = new StreamBuf
  initLock(streamBuf.lock)
  defer: deinitLock(streamBuf.lock)

  proc pushFrame(frame: string) {.gcsafe.} =
    {.cast(gcsafe).}:
      acquire(streamBuf.lock)
      streamBuf.frames.add frame
      release(streamBuf.lock)

  proc pushText(t: string) {.gcsafe.} =
    {.cast(gcsafe).}:
      acquire(streamBuf.lock)
      streamBuf.accumulatedText.add t
      release(streamBuf.lock)

  proc popFrames(): seq[string] {.gcsafe.} =
    {.cast(gcsafe).}:
      acquire(streamBuf.lock)
      result = streamBuf.frames
      streamBuf.frames = @[]
      release(streamBuf.lock)

  proc snapshotText(): string {.gcsafe.} =
    {.cast(gcsafe).}:
      acquire(streamBuf.lock)
      result = streamBuf.accumulatedText
      release(streamBuf.lock)

  let onEvent: AgentEventCallback = proc(ev: AgentEvent) {.gcsafe.} =
    {.cast(gcsafe).}:
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
      pushFrame(frame)
      if ev.kind == aekMessageChunk and ev.text.len > 0:
        pushText(ev.text)

  var args = PromptArgs(sessionId: sessionId, prompt: prompt,
                        client: state.client, callback: onEvent)
  var worker: Thread[PromptArgs]
  createThread(worker, runPromptThread, args)

  var disconnected = false
  while not args.done:
    let pending = popFrames()
    for frame in pending:
      if not await trySend(sock, frame):
        disconnected = true
        break
    if disconnected: break
    await sleepAsync(10)
  joinThread(worker)

  if disconnected:
    return false

  # Final flush of any frames that landed alongside the prompt response.
  let trailing = popFrames()
  for frame in trailing:
    if not await trySend(sock, frame):
      return false

  # Drain the transport-level buffer once so it doesn't grow unbounded
  # — the events were forwarded via the streaming callback, so we MUST
  # discard the result here (otherwise we'd double-emit).
  {.gcsafe.}:
    let stOpt = reg.agents.getState(sessionId)
    if stOpt.isSome:
      var s = stOpt.get
      discard s.client.acp.drainUpdates()

  let stopReason =
    if args.error.len > 0: "error"
    else: $args.response.stopReason

  # Record the campaign_event in the DB before emitting ``end`` so any
  # client that GETs ``/api/campaign/events`` immediately after the SSE
  # close will see the row.
  let accumulated = snapshotText()
  var payload = newJObject()
  payload["stopReason"] = %stopReason
  payload["text"] = %accumulated
  if extraPayload != nil:
    for k, v in extraPayload.pairs:
      payload[k] = v
  try:
    discard dbRecordEvent(reg, campaignId, eventKindOnDone, payload)
  except DbError as e:
    error "campaign_event insert failed",
      campaignId = campaignId, kind = eventKindOnDone, reason = e.msg

  if args.error.len > 0:
    let errEvent = encodeSseEvent("error",
      $(%* {"sessionId": sessionId, "reason": args.error}))
    discard await trySend(sock, errEvent)
  let endEvent = encodeSseEvent("end",
    $(%* {"stopReason": stopReason, "campaignId": campaignId}))
  discard await trySend(sock, endEvent)
  return true

# ---------------------------------------------------------------------------
# Route handlers.
# ---------------------------------------------------------------------------

proc handleStart*(reg: CampaignRegistry; req: Request) {.async, gcsafe.} =
  if req.reqMethod != HttpPost:
    await respondJson(req, Http405,
      $(%* {"error": "method_not_allowed"}))
    return
  var body: CampaignStartBody
  try:
    body = parseStartBody(req.body)
  except JsonParsingError:
    await respondJson(req, Http400, $(%* {"error": "invalid_json"}))
    return
  if body.docPath.len == 0:
    await respondJson(req, Http400, $(%* {"error": "missing_docPath"}))
    return
  if body.docSha.len == 0:
    await respondJson(req, Http400, $(%* {"error": "missing_docSha"}))
    return
  if body.briefRefs.len == 0:
    await respondJson(req, Http400, $(%* {"error": "missing_briefRefs"}))
    return

  # Phase 1: ensure the campaign row exists.  ``start_campaign`` is
  # idempotent on (doc_path, doc_sha) so a repeat call returns the same
  # id without writing a second 'started' event.
  var campaignId = ""
  try:
    campaignId = dbStartCampaign(reg, body.docPath, body.docSha,
      body.briefRefs, body.targetScore, body.hasTargetScore,
      body.maxIterations, body.manifestHash,
      $reg.agents.backend, "", body.startedBy)
  except DbError as e:
    error "campaign start: DB insert failed", reason = e.msg
    await respondJson(req, Http500,
      $(%* {"error": "db_error", "reason": e.msg}))
    return
  except CampaignSchedulerError as e:
    error "campaign start: scheduler error", reason = e.msg
    await respondJson(req, Http500,
      $(%* {"error": "scheduler_error", "reason": e.msg}))
    return

  # Phase 2: open or re-use the ACP session bound to the campaign.
  var sessionId = reg.lookupSession(campaignId)
  if sessionId.len == 0:
    var state: AgentSessionState
    try:
      state = createAcpSession(reg.agents)
    except AgentBackendUnavailableError as e:
      error "campaign start: agent backend unavailable", reason = e.msg
      await respondJson(req, Http503,
        $(%* {"error": "agent_backend_unavailable", "reason": e.msg}))
      return
    except CatchableError as e:
      error "campaign start: agent session creation failed", reason = e.msg
      await respondJson(req, Http500,
        $(%* {"error": "agent_init_failed", "reason": e.msg}))
      return
    sessionId = state.sessionId
    reg.storeSession(campaignId, sessionId)
    try:
      dbBindAcpSession(reg, campaignId, sessionId)
    except DbError as e:
      warn "campaign start: bind session failed (non-fatal)",
        campaignId = campaignId, reason = e.msg

  # Phase 3: assemble and emit the first prompt.  Stream SSE.
  let prelude = cmpSseHeader()
  if not await trySend(req.client, prelude):
    return

  let orchestratorPrompt = reloadOrchestratorPrompt(reg)
  let promptInputs = CampaignPromptInputs(
    docPath: body.docPath,
    docBody: body.body,
    briefs: body.briefs,
    latestReport: body.latestReport,
    round: 1,
  )
  let firstPrompt = assembleFirstPrompt(orchestratorPrompt, promptInputs)
  info "campaign start streaming",
    campaignId = campaignId, sessionId = sessionId,
    promptBytes = firstPrompt.len

  let extra = %* {"campaignId": campaignId, "round": 1}
  discard await streamPromptToSocket(reg, sessionId, campaignId,
    "round_complete", firstPrompt, extra, req.client)
  try: req.client.close() except CatchableError: discard

proc handleTick*(reg: CampaignRegistry; req: Request) {.async, gcsafe.} =
  if req.reqMethod != HttpPost:
    await respondJson(req, Http405,
      $(%* {"error": "method_not_allowed"}))
    return
  var campaignId = ""
  try:
    let node = parseJson(req.body)
    campaignId = node{"campaignId"}.getStr("")
  except JsonParsingError:
    await respondJson(req, Http400, $(%* {"error": "invalid_json"}))
    return
  if campaignId.len == 0:
    await respondJson(req, Http400, $(%* {"error": "missing_campaignId"}))
    return
  let sessionId = reg.lookupSession(campaignId)
  if sessionId.len == 0:
    await respondJson(req, Http404,
      $(%* {"error": "no_active_session", "campaignId": campaignId}))
    return

  # Count existing 'round_started' events to assign a round number.
  var round = 1
  try:
    let fetched = dbFetchCampaign(reg, campaignId, 1000)
    if fetched != nil:
      let events = fetched{"events"}
      if events != nil and events.kind == JArray:
        for e in events.items:
          if e{"event_kind"}.getStr("") == "round_started":
            inc round
  except DbError as e:
    warn "campaign tick: round counter failed", reason = e.msg

  let extra = %* {"campaignId": campaignId, "round": round}
  try:
    discard dbRecordEvent(reg, campaignId, "round_started",
      %* {"round": round})
  except DbError as e:
    error "campaign tick: round_started event insert failed",
      reason = e.msg
    await respondJson(req, Http500,
      $(%* {"error": "db_error", "reason": e.msg}))
    return

  let prelude = cmpSseHeader()
  if not await trySend(req.client, prelude):
    return
  let promptText = assembleTickPrompt(round)
  discard await streamPromptToSocket(reg, sessionId, campaignId,
    "round_complete", promptText, extra, req.client)
  try: req.client.close() except CatchableError: discard

proc handleStop*(reg: CampaignRegistry; req: Request) {.async, gcsafe.} =
  if req.reqMethod != HttpPost:
    await respondJson(req, Http405,
      $(%* {"error": "method_not_allowed"}))
    return
  var campaignId = ""
  var reason = ""
  try:
    let node = parseJson(req.body)
    campaignId = node{"campaignId"}.getStr("")
    reason = node{"reason"}.getStr("")
  except JsonParsingError:
    await respondJson(req, Http400, $(%* {"error": "invalid_json"}))
    return
  if campaignId.len == 0:
    await respondJson(req, Http400, $(%* {"error": "missing_campaignId"}))
    return
  let sessionId = reg.lookupSession(campaignId)
  if sessionId.len > 0:
    # Best-effort: cancel + drop the ACP session.
    {.gcsafe.}:
      let stateOpt = reg.agents.getState(sessionId)
      if stateOpt.isSome:
        var state = stateOpt.get
        try:
          state.client.acp.cancel(sessionId)
        except CatchableError as e:
          warn "campaign stop: acp.cancel failed",
            sessionId = sessionId, reason = e.msg
      reg.agents.release(sessionId)
      reg.dropSession(campaignId)
  try:
    dbTransition(reg, campaignId, "stopped", reason)
  except DbError as e:
    error "campaign stop: transition failed", reason = e.msg
    await respondJson(req, Http500,
      $(%* {"error": "db_error", "reason": e.msg}))
    return
  let respBody = %* {"campaignId": campaignId, "status": "stopped",
                     "reason": reason}
  await respondJson(req, Http200, $respBody)

proc handleList*(reg: CampaignRegistry; req: Request) {.async, gcsafe.} =
  if req.reqMethod != HttpGet:
    await respondJson(req, Http405,
      $(%* {"error": "method_not_allowed"}))
    return
  let q = req.url.query
  var status = ""
  var limit = 50
  var offset = 0
  for kv in q.split('&'):
    let eq = kv.find('=')
    if eq < 0: continue
    let k = decodeUrl(kv[0 ..< eq])
    let v = decodeUrl(kv[eq + 1 .. ^1])
    case k
    of "status": status = v
    of "limit":
      var n = 0
      if parseInt(v, n) > 0: limit = max(0, min(1000, n))
    of "offset":
      var n = 0
      if parseInt(v, n) > 0: offset = max(0, n)
    else: discard
  try:
    let arr = dbListCampaigns(reg, status, limit, offset)
    await respondJson(req, Http200, $arr)
  except DbError as e:
    error "campaign list: DB error", reason = e.msg
    await respondJson(req, Http500,
      $(%* {"error": "db_error", "reason": e.msg}))

proc handleFetch*(reg: CampaignRegistry; req: Request) {.async, gcsafe.} =
  if req.reqMethod != HttpGet:
    await respondJson(req, Http405,
      $(%* {"error": "method_not_allowed"}))
    return
  let q = req.url.query
  var campaignId = ""
  var eventLimit = 20
  for kv in q.split('&'):
    let eq = kv.find('=')
    if eq < 0: continue
    let k = decodeUrl(kv[0 ..< eq])
    let v = decodeUrl(kv[eq + 1 .. ^1])
    case k
    of "campaignId": campaignId = v
    of "eventLimit":
      var n = 0
      if parseInt(v, n) > 0: eventLimit = max(0, min(1000, n))
    else: discard
  if campaignId.len == 0:
    await respondJson(req, Http400, $(%* {"error": "missing_campaignId"}))
    return
  try:
    let body = dbFetchCampaign(reg, campaignId, eventLimit)
    if body == nil:
      await respondJson(req, Http404,
        $(%* {"error": "campaign_not_found"}))
      return
    await respondJson(req, Http200, $body)
  except DbError as e:
    let msg = e.msg
    if "does not exist" in msg:
      await respondJson(req, Http404,
        $(%* {"error": "campaign_not_found"}))
    else:
      error "campaign fetch: DB error", reason = msg
      await respondJson(req, Http500,
        $(%* {"error": "db_error", "reason": msg}))

proc handleEvents*(reg: CampaignRegistry; req: Request) {.async, gcsafe.} =
  if req.reqMethod != HttpGet:
    await respondJson(req, Http405,
      $(%* {"error": "method_not_allowed"}))
    return
  let q = req.url.query
  var campaignId = ""
  var since = ""
  var limit = 100
  for kv in q.split('&'):
    let eq = kv.find('=')
    if eq < 0: continue
    let k = decodeUrl(kv[0 ..< eq])
    let v = decodeUrl(kv[eq + 1 .. ^1])
    case k
    of "campaignId": campaignId = v
    of "since":      since = v
    of "limit":
      var n = 0
      if parseInt(v, n) > 0: limit = max(0, min(5000, n))
    else: discard
  if campaignId.len == 0:
    await respondJson(req, Http400, $(%* {"error": "missing_campaignId"}))
    return
  try:
    let arr = dbRecentEvents(reg, campaignId, since, limit)
    await respondJson(req, Http200, $arr)
  except DbError as e:
    error "campaign events: DB error", reason = e.msg
    await respondJson(req, Http500,
      $(%* {"error": "db_error", "reason": e.msg}))

# ---------------------------------------------------------------------------
# Mount helpers.
# ---------------------------------------------------------------------------

type
  CampaignHandlerProc* = proc(req: Request): Future[void] {.async, gcsafe.}

proc makeStartHandler*(reg: CampaignRegistry): CampaignHandlerProc =
  result = proc(req: Request): Future[void] {.async, gcsafe.} =
    await handleStart(reg, req)

proc makeTickHandler*(reg: CampaignRegistry): CampaignHandlerProc =
  result = proc(req: Request): Future[void] {.async, gcsafe.} =
    await handleTick(reg, req)

proc makeStopHandler*(reg: CampaignRegistry): CampaignHandlerProc =
  result = proc(req: Request): Future[void] {.async, gcsafe.} =
    await handleStop(reg, req)

proc makeListHandler*(reg: CampaignRegistry): CampaignHandlerProc =
  result = proc(req: Request): Future[void] {.async, gcsafe.} =
    await handleList(reg, req)

proc makeFetchHandler*(reg: CampaignRegistry): CampaignHandlerProc =
  result = proc(req: Request): Future[void] {.async, gcsafe.} =
    await handleFetch(reg, req)

proc makeEventsHandler*(reg: CampaignRegistry): CampaignHandlerProc =
  result = proc(req: Request): Future[void] {.async, gcsafe.} =
    await handleEvents(reg, req)
