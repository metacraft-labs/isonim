## CMP-M6 — daemon HTTP routes for the campaign system.
##
## The orchestrator is now a single long-running agent turn: the
## daemon opens an ACP session at ``/api/campaign/start``, sends ONE
## prompt carrying the orchestrator system prompt + campaign doc +
## briefs + latest report, and streams the agent's ``session/update``
## events back to the caller as an SSE response until the turn ends
## naturally (stopReason returned by the agent) OR the campaign is
## stopped.  There is no daemon-driven "tick" mechanism — codex / the
## orchestrator drives its own internal iteration via its native tool
## loop.
##
## Routes:
##
##   * ``POST /api/campaign/start``  — open an ACP session, INSERT a
##     campaign row + ``'started'`` event, send the single composite
##     prompt to the orchestrator and stream the agent's
##     ``session/update`` events back to the caller as an SSE
##     response.  Closes with ``event: end`` + a ``round_complete``
##     event written into the DB.  After the agent's turn ends the
##     daemon re-reads the campaign doc's frontmatter ``status:``
##     field and transitions the campaign row accordingly (see
##     :proc:`applyCampaignDocStatusAfterTurn`).
##   * ``POST /api/campaign/tick``   — DEPRECATED.  The single-turn
##     model has no daemon-driven tick concept; the route now returns
##     HTTP 410 with an explanatory body.
##   * ``POST /api/campaign/stop``   — terminate the bound session and
##     transition the campaign to ``stopped``.
##   * ``POST /api/campaign/inject`` — push an operator-injection text
##     onto the per-session ACP queue.  In the single-turn model the
##     queued text is only visible to a subsequent campaign turn;
##     during a running turn the queued text remains queued.
##   * ``POST /api/campaign/refresh-doc`` — re-read the campaign doc
##     from disk, update the row's SHA, emit a ``doc_refreshed`` note.
##   * ``GET  /api/campaign/list``   — paginated list, optionally
##     status-filtered, of campaigns in the DB.
##   * ``GET  /api/campaign/fetch``  — full campaign row + most-recent
##     ``eventLimit`` events as JSON.
##   * ``GET  /api/campaign/events`` — paginated event-log fetch.
##
## The SSE stream-on-prompt machinery mirrors the Phase B
## ``handlePrompts`` in :mod:`agent_routes`.

import std/[asyncdispatch, asyncnet, asynchttpserver, json, locks,
            options, os, osproc, parseutils, streams, strutils,
            tables, times, uri]

import db_connector/db_postgres
import nim_acp
import nim_agents

import ./agent_routes
import ./campaign_format
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
  CampaignInjectRoute* = "/api/campaign/inject"
  CampaignRefreshDocRoute* = "/api/campaign/refresh-doc"

  OrchestratorPromptRelPath* = "prompts/campaign-orchestrator.md"

  # CMP-M6 vestigial-routines note:
  #   ``design_review.next_campaign_round`` and
  #   ``design_review.count_campaign_round_complete`` (defined by
  #   migration ``007_design_review_campaign_round_counter.sql``) were
  #   used by the now-removed ``handleTick`` route.  The single-turn
  #   campaign model does not track discrete rounds and the daemon no
  #   longer calls these routines.  Migration 007 is retained because
  #   migrations are immutable history; the routines remain in the
  #   database schema as dead code.

  TerminalDocStatuses = ["converged", "escalated", "stopped",
                         "needs_human"]
    ## CMP-M6 — the set of frontmatter ``status:`` values the
    ## orchestrator is allowed to set as its terminal signal.  Anything
    ## else (e.g. the agent ended its turn with ``status: active``
    ## still in the doc) is treated as the orchestrator failing to
    ## signal terminal status; the daemon transitions the campaign to
    ## ``failed`` in that case.

type
  CampaignRegistry* = ref object
    ## Holds the live ACP session for each active campaign and the
    ## handle on the design-review DB.  Single-tenant — there is one
    ## entry per ``campaign_id`` and the daemon binds to ``127.0.0.1``
    ## only.
    lock: Lock
    sessions: Table[string, string]   ## campaign_id → acp session id
    # CMP-M4 — per-campaign pending operator-injection event id queue.
    # ``injectionEventIds[cid]`` is the ordered list of ``campaign_events``
    # uuids written by ``handleInject`` whose corresponding ACP-queued
    # text is still waiting to be folded into a subsequent campaign
    # turn's prompt.  In the single-turn model this list accumulates
    # but is not drained during a running turn — a future milestone
    # could surface the queued items via ``takeQueuedInjections`` when
    # the next ``campaign start`` runs against the same campaign.
    injectionEventIds: Table[string, seq[string]]
    agents: AgentRegistry
    db: ReviewDb
    promptPath*: string
    promptText: string                 ## cached orchestrator prompt body
    idleTimeoutMs*: int
    hardDeadlineMs*: int

  CampaignSchedulerError* = object of CatchableError

# ---------------------------------------------------------------------------
# Registry helpers.
# ---------------------------------------------------------------------------

proc newCampaignRegistry*(agents: AgentRegistry; db: ReviewDb;
                          promptPath: string;
                          idleTimeoutMs: int = 3_600_000;
                          hardDeadlineMs: int = 14_400_000): CampaignRegistry =
  result = CampaignRegistry(
    sessions: initTable[string, string](),
    injectionEventIds: initTable[string, seq[string]](),
    agents: agents,
    db: db,
    promptPath: promptPath,
    idleTimeoutMs: idleTimeoutMs,
    hardDeadlineMs: hardDeadlineMs,
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

proc appendInjectionEventId*(reg: CampaignRegistry;
                              campaignId, eventId: string) =
  ## CMP-M4 — push ``eventId`` onto the per-campaign pending-injection
  ## list.  Called by ``handleInject`` after the ``note`` event has been
  ## recorded but before the ACP-queue text has been drained.
  acquire(reg.lock)
  try:
    if not reg.injectionEventIds.hasKey(campaignId):
      reg.injectionEventIds[campaignId] = @[]
    reg.injectionEventIds[campaignId].add eventId
  finally:
    release(reg.lock)

proc peekPendingInjectionEventIds*(reg: CampaignRegistry;
                                    campaignId: string): seq[string] =
  ## Test/debug-only read-only inspection of the pending-injection ids
  ## queue for ``campaignId``.
  acquire(reg.lock)
  try:
    if reg.injectionEventIds.hasKey(campaignId):
      result = reg.injectionEventIds[campaignId]
    else:
      result = @[]
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

proc dbCampaignStatus(reg: CampaignRegistry; campaignId: string): string =
  ## Read the campaign's current status so transitions can short-circuit
  ## on a terminal state without trying a transition that would fail.
  let fetched = dbFetchCampaign(reg, campaignId, 1)
  if fetched == nil: return ""
  return fetched{"status"}.getStr("")

proc dbCampaignDocPath(reg: CampaignRegistry; campaignId: string): string =
  ## CMP-M4 — read ``campaigns.doc_path`` so the daemon can re-read the
  ## campaign doc body from disk (the operator may edit the file at any
  ## point — re-reading is the cost of live-edit friendliness).
  let fetched = dbFetchCampaign(reg, campaignId, 1)
  if fetched == nil: return ""
  return fetched{"doc_path"}.getStr("")

proc dbCampaignAcpSessionId(reg: CampaignRegistry;
    campaignId: string): string =
  ## CMP-M4 — read ``campaigns.acp_session_id``.  The inject route uses
  ## this to verify that a campaign has an active session.
  let fetched = dbFetchCampaign(reg, campaignId, 1)
  if fetched == nil: return ""
  return fetched{"acp_session_id"}.getStr("")

proc readCampaignDocBody*(reg: CampaignRegistry; campaignId: string): string =
  ## CMP-M4 — re-read the campaign doc off disk and return its raw
  ## bytes.  Returns ``""`` if the path is missing or the read fails.
  let docPath = dbCampaignDocPath(reg, campaignId)
  if docPath.len == 0 or not fileExists(docPath):
    return ""
  result =
    try: readFile(docPath)
    except IOError as e:
      warn "campaign doc re-read failed",
        campaignId = campaignId, path = docPath, reason = e.msg
      ""

proc readCampaignDocBodyParsed*(reg: CampaignRegistry;
    campaignId: string): string {.gcsafe.} =
  ## Variant of :proc:`readCampaignDocBody` that runs the raw bytes
  ## through ``parseCampaignDoc`` to strip the YAML frontmatter, so the
  ## prompt only carries the human-readable body.  Falls back to the
  ## raw bytes on parse failure.
  {.cast(gcsafe).}:
    let docPath = dbCampaignDocPath(reg, campaignId)
    if docPath.len == 0 or not fileExists(docPath):
      return ""
    let raw =
      try: readFile(docPath)
      except IOError as e:
        warn "campaign doc re-read failed",
          campaignId = campaignId, path = docPath, reason = e.msg
        return ""
    try:
      let parsed = parseCampaignDoc(docPath, raw)
      return parsed.bodyMarkdown
    except CampaignDocParseError as e:
      warn "campaign doc parse failed — passing raw bytes",
        campaignId = campaignId, path = docPath, reason = e.msg
      return raw

proc readCampaignDocStatus*(reg: CampaignRegistry;
    campaignId: string): string {.gcsafe.} =
  ## CMP-M6 — re-read the campaign doc off disk and parse its
  ## frontmatter ``status:`` field.  Returns ``""`` if the doc is
  ## missing or unparseable — the caller treats that as "no terminal
  ## status set" and falls back to the ``failed`` transition.
  {.cast(gcsafe).}:
    let docPath = dbCampaignDocPath(reg, campaignId)
    if docPath.len == 0 or not fileExists(docPath):
      return ""
    let raw =
      try: readFile(docPath)
      except IOError as e:
        warn "campaign doc status re-read failed",
          campaignId = campaignId, path = docPath, reason = e.msg
        return ""
    try:
      let parsed = parseCampaignDoc(docPath, raw)
      return parsed.status
    except CampaignDocParseError as e:
      warn "campaign doc status parse failed",
        campaignId = campaignId, path = docPath, reason = e.msg
      return ""

proc dbUpdateDocSha(reg: CampaignRegistry;
    campaignId, newSha: string): string =
  ## CMP-M4 — call ``design_review.update_campaign_doc_sha`` (migration
  ## 008) and return the previous ``doc_sha`` so the route handler can
  ## decide whether content actually changed.
  reg.db.asApp()
  let stmt = "SELECT design_review.update_campaign_doc_sha('" &
    escSql(campaignId) & "'::uuid, '" & escSql(newSha) & "')::text"
  return reg.db.conn.getValue(sql(stmt))

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
# Prompt assembly.  The single user message we send to the orchestrator
# carries the system prompt verbatim, the campaign doc, every referenced
# brief, and the latest report.  After this prompt the daemon does NOT
# send a second one — the orchestrator drives any further work itself
# inside this same ACP turn.
# ---------------------------------------------------------------------------

type
  CampaignPromptInputs* = object
    docPath*:     string
    docBody*:     string
    briefs*:      seq[tuple[briefId: string; body: string]]
    latestReport*: string

proc assembleFirstPrompt*(orchestratorPrompt: string;
                          inputs: CampaignPromptInputs): string =
  ## Build the single composite prompt sent to the orchestrator ACP
  ## session.  This is the ONLY prompt the daemon emits to the
  ## orchestrator for this campaign turn; everything the orchestrator
  ## does afterwards is driven by its own tool-call loop.
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
  result.add "You are now driving this campaign autonomously inside this single ACP turn.\n"
  result.add "Use your tool-call loop to read files, run `isonim-review` subcommands, edit\n"
  result.add "source files, run tests, and commit verified fixes. Drive internal iterations\n"
  result.add "until the campaign reaches a terminal status. Before ending your turn, update\n"
  result.add "the campaign doc's frontmatter `status:` field to one of `converged`,\n"
  result.add "`escalated`, `needs_human`, or `stopped`, plus set `finishedAt`.\n"
  result.add "The daemon reads that status after your turn ends and transitions the\n"
  result.add "campaign row accordingly. If you end your turn without a terminal status,\n"
  result.add "the campaign is recorded as `failed`.\n"

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
# Shared prompt + stream procedure.  ``handleStart`` is the only caller
# now (the tick path is gone) but we keep the proc factored out for the
# sake of clarity + because future milestones may want a second caller
# (e.g. a "resume" route that re-opens a stopped campaign with a fresh
# prompt).
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

type
  StreamPromptResult* = object
    ## Returned by :proc:`streamPromptToSocket` so the route handler
    ## (``handleStart``) can act on the agent's stopReason and the
    ## campaign doc's frontmatter status without re-reading the
    ## just-written ``round_complete`` row from the DB.
    alive*: bool                  ## SSE socket still writable
    stopReason*: string           ## stringified StopReason (or "error")
    isError*: bool                ## convenience: stopReason == "error"
    eventId*: string              ## the round_complete row's event_id

proc logCampaignPrompt(campaignId, sessionId, promptText: string;
                       source: string) =
  ## CMP-M4 test hook — when ``$FAKE_ACP_CONTENT_LOG`` is set, append one
  ## JSON-summary line per outgoing campaign prompt so tests can assert
  ## the prompt body contents.  Mirrors the shape the agent_routes
  ## handler writes.
  let contentLog = getEnv("FAKE_ACP_CONTENT_LOG")
  if contentLog.len == 0: return
  let summary = %* {
    "campaignId": campaignId,
    "sessionId":  sessionId,
    "source":     source,
    "promptText": promptText,
    "promptLen":  promptText.len,
  }
  try:
    let f = open(contentLog, fmAppend)
    defer: f.close()
    f.write($summary & "\n")
  except IOError:
    discard

proc streamPromptToSocket(reg: CampaignRegistry;
    sessionId, campaignId, eventKindOnDone, promptText: string;
    extraPayload: JsonNode;
    sock: AsyncSocket): Future[StreamPromptResult] {.async, gcsafe.} =
  ## Sends ``promptText`` to the cached ACP client for ``sessionId``,
  ## forwards session/update events to ``sock``, and writes a
  ## ``eventKindOnDone`` (typically ``round_complete``) row whose
  ## payload carries ``stopReason``, ``text``, and any caller-supplied
  ## extras.
  let stateOpt = reg.agents.getState(sessionId)
  if not stateOpt.isSome:
    let evt = encodeSseEvent("error",
      $(%* {"sessionId": sessionId, "reason": "unknown_session"}))
    discard await trySend(sock, evt)
    result.alive = false
    result.stopReason = "error"
    result.isError = true
    return result
  var state = stateOpt.get
  let prompt = @[textBlock(promptText)]
  logCampaignPrompt(campaignId, sessionId, promptText, "stream")

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
    result.alive = false
    result.stopReason = "error"
    result.isError = true
    return result

  # Final flush of any frames that landed alongside the prompt response.
  let trailing = popFrames()
  for frame in trailing:
    if not await trySend(sock, frame):
      result.alive = false
      result.stopReason = "error"
      result.isError = true
      return result

  # Drain the transport-level buffer once so it doesn't grow unbounded.
  {.gcsafe.}:
    let stOpt = reg.agents.getState(sessionId)
    if stOpt.isSome:
      var s = stOpt.get
      discard s.client.acp.drainUpdates()

  let stopReason =
    if args.error.len > 0: "error"
    else: $args.response.stopReason
  result.stopReason = stopReason
  result.isError = (stopReason == "error")

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
    result.eventId = dbRecordEvent(reg, campaignId, eventKindOnDone, payload)
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
  result.alive = true
  return result

# ---------------------------------------------------------------------------
# Post-turn status routing — the orchestrator signals terminal status by
# editing the campaign doc's frontmatter ``status:`` field before ending
# its turn.  After the SSE stream closes we re-read the doc, parse the
# status, and call ``transition_campaign`` accordingly.  If the status
# is still ``active`` / ``pending`` the daemon transitions the campaign
# to ``failed`` with a reason that flags the orchestrator's omission.
# ---------------------------------------------------------------------------

proc applyCampaignDocStatusAfterTurn*(reg: CampaignRegistry;
    campaignId: string; res: StreamPromptResult): Future[void]
    {.async, gcsafe.} =
  ## Re-read the campaign doc, parse the frontmatter ``status:`` field,
  ## and transition the campaign row accordingly.  Called from
  ## ``handleStart`` after the SSE stream closes.
  ##
  ## Order of operations:
  ##   1. If the agent returned ``stopReason=error`` and the campaign
  ##      is still active, transition to ``failed`` with the error
  ##      reason; skip the doc-status read.
  ##   2. Otherwise, re-read the doc.  If the frontmatter ``status:``
  ##      is one of the terminal values (``converged``, ``escalated``,
  ##      ``stopped``, ``needs_human``), transition accordingly.
  ##   3. If the status is still ``active`` / ``pending`` (or the doc
  ##      didn't parse), transition to ``failed`` with reason
  ##      ``"agent ended turn without setting terminal status"``.
  let currentStatus = dbCampaignStatus(reg, campaignId)
  info "applyCampaignDocStatusAfterTurn",
    campaignId = campaignId,
    stopReason = res.stopReason,
    currentStatus = currentStatus

  if currentStatus notin ["active", "pending"]:
    debug "applyCampaignDocStatusAfterTurn: campaign already terminal",
      campaignId = campaignId, status = currentStatus
    return

  if res.isError:
    try:
      dbTransition(reg, campaignId, "failed", "agent turn ended with stopReason=error")
    except DbError as e:
      error "transition to failed (stopReason=error) failed",
        campaignId = campaignId, reason = e.msg
    return

  let docStatus = readCampaignDocStatus(reg, campaignId)
  if docStatus in TerminalDocStatuses:
    # ``needs_human`` is a doc-level value the orchestrator uses to
    # signal "a human decision is required"; the DB schema only knows
    # the four sticky terminals (converged/escalated/stopped/failed),
    # so we map ``needs_human`` onto ``escalated`` with a reason that
    # preserves the original intent for downstream surfaces (the
    # campaigns tab, the AI Assistant's escalation surfacing, etc.).
    let dbStatus =
      if docStatus == "needs_human": "escalated" else: docStatus
    let reason =
      if docStatus == "needs_human": "needs_human" else: ""
    try:
      dbTransition(reg, campaignId, dbStatus, reason)
    except DbError as e:
      error "transition to doc-supplied status failed",
        campaignId = campaignId, status = dbStatus, reason = e.msg
  else:
    try:
      dbTransition(reg, campaignId, "failed",
                   "agent ended turn without setting terminal status")
    except DbError as e:
      error "transition to failed (no terminal status) failed",
        campaignId = campaignId, reason = e.msg

# ---------------------------------------------------------------------------
# Route handlers.
# ---------------------------------------------------------------------------

proc handleStart*(reg: CampaignRegistry; req: Request) {.async, gcsafe.} =
  if req.reqMethod != HttpPost:
    await respondJson(req, Http405,
      $(%* {"error": "method_not_allowed"}))
    return
  type
    CampaignStartBody = object
      docPath:   string
      docSha:    string
      briefRefs: seq[string]
      targetScore: float
      hasTargetScore: bool
      maxIterations: int
      body:      string
      briefs:    seq[tuple[briefId: string; body: string]]
      latestReport: string
      manifestHash: string
      startedBy: string
      notesToOrchestrator: string
  var body: CampaignStartBody
  try:
    let node = parseJson(req.body)
    body.docPath = node{"docPath"}.getStr("")
    body.docSha = node{"docSha"}.getStr("")
    body.body = node{"body"}.getStr("")
    body.manifestHash = node{"manifestHash"}.getStr("local")
    body.startedBy = node{"startedBy"}.getStr("cli")
    body.maxIterations = node{"maxIterations"}.getInt(30)
    body.latestReport = node{"latestReport"}.getStr("")
    body.notesToOrchestrator = node{"notesToOrchestrator"}.getStr("")
    let ts = node{"targetScore"}
    if ts != nil and ts.kind in {JFloat, JInt}:
      body.targetScore = ts.getFloat(0.0)
      body.hasTargetScore = true
    let briefRefs = node{"briefRefs"}
    if briefRefs != nil and briefRefs.kind == JArray:
      for it in briefRefs.items:
        let s = it.getStr("").strip()
        if s.len > 0: body.briefRefs.add s
    let briefs = node{"briefs"}
    if briefs != nil and briefs.kind == JArray:
      for it in briefs.items:
        let id = it{"briefId"}.getStr("")
        let b = it{"body"}.getStr("")
        if id.len > 0:
          body.briefs.add (briefId: id, body: b)
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
      state = createAcpSession(reg.agents,
                               idleTimeoutMs = reg.idleTimeoutMs)
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

  # Phase 3: assemble and emit the composite prompt.  Stream SSE.
  let prelude = cmpSseHeader()
  if not await trySend(req.client, prelude):
    return

  let orchestratorPrompt = reloadOrchestratorPrompt(reg)
  let promptInputs = CampaignPromptInputs(
    docPath: body.docPath,
    docBody: body.body,
    briefs: body.briefs,
    latestReport: body.latestReport,
  )
  let firstPrompt = assembleFirstPrompt(orchestratorPrompt, promptInputs)
  info "campaign start streaming",
    campaignId = campaignId, sessionId = sessionId,
    promptBytes = firstPrompt.len

  let extra = %* {"campaignId": campaignId}
  let res = await streamPromptToSocket(reg, sessionId, campaignId,
    "round_complete", firstPrompt, extra, req.client)
  try: req.client.close() except CatchableError: discard
  await applyCampaignDocStatusAfterTurn(reg, campaignId, res)
  # CMP-M7 — the single-turn model ends the campaign here; tear down
  # the ACP transport so we don't leak one codex-acp child per turn.
  # ``shutdownAndRelease`` is idempotent and safe to call even if the
  # session was already evicted elsewhere.
  reg.dropSession(campaignId)
  reg.agents.shutdownAndRelease(sessionId)

proc handleTick*(reg: CampaignRegistry; req: Request) {.async, gcsafe.} =
  ## CMP-M6 — the single-turn model has no daemon-driven tick concept.
  ## Return HTTP 410 Gone with an explanatory body so any out-of-date
  ## caller (e.g. an old CLI build) sees a clear deprecation message
  ## rather than a 404.
  await respondJson(req, Http410,
    $(%* {"error": "tick_deprecated",
          "reason": "campaign tick is no longer supported; the orchestrator " &
                    "runs as one long-lived ACP turn started by " &
                    "POST /api/campaign/start"}))

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
    # Best-effort: cancel + shut down the ACP transport.  ``cancel``
    # is the ACP-level signal so the agent sees the stop politely;
    # ``shutdownAndRelease`` then terminates the spawned stdio child
    # so we don't leak a codex-acp process per stopped campaign.
    {.gcsafe.}:
      let stateOpt = reg.agents.getState(sessionId)
      if stateOpt.isSome:
        var state = stateOpt.get
        try:
          state.client.acp.cancel(sessionId)
        except CatchableError as e:
          warn "campaign stop: acp.cancel failed",
            sessionId = sessionId, reason = e.msg
      reg.agents.shutdownAndRelease(sessionId)
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

proc sha256OfStringShellOut(s: string): string =
  ## Stream ``s`` through ``shasum -a 256`` / ``sha256sum`` and return
  ## the lowercase-hex digest.  Mirrors the pattern used by
  ## :proc:`manifest_hash.sha256Hex` so refreshed doc shas have the same
  ## format as the doc_sha the CLI's ``campaign start`` writes.
  let exe = findExe("shasum")
  let cmd =
    if exe.len > 0: "shasum -a 256"
    else: "sha256sum"
  let parts = cmd.split()
  let p = startProcess(parts[0], args = parts[1 .. ^1],
                       options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  let stdin = p.inputStream
  stdin.write(s)
  stdin.close()
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  if code != 0:
    raise newException(IOError,
      "sha256OfStringShellOut: " & cmd & " failed (" & $code & "): " & output)
  let words = output.splitWhitespace()
  if words.len == 0:
    raise newException(IOError,
      "sha256OfStringShellOut: " & cmd & " returned empty output")
  words[0].toLowerAscii()

proc handleInject*(reg: CampaignRegistry; req: Request) {.async, gcsafe.} =
  ## CMP-M4 / CMP-M6 — POST /api/campaign/inject {campaignId, text}
  ##
  ## Push an operator-injection text onto the per-session ACP queue
  ## via the AgentClient wrapper, and append a ``note`` event tagged
  ## ``kind=operator_injection`` so the audit log keeps the user's
  ## intent durable.
  ##
  ## CMP-M6 note: in the single-turn model the queued text is NOT
  ## delivered to a running campaign turn.  It accumulates in the
  ## per-session queue and is observable via ``takeQueuedInjections``.
  ## A subsequent campaign turn (e.g. opened by re-running
  ## ``campaign start`` against the same doc, in a future milestone)
  ## could fold these into its initial prompt; for now the route
  ## remains for forward-compatibility and audit-trail purposes.
  ##
  ## 202 Accepted on success with ``{campaignId, status, queuedAt}``.
  ## 404 ``no_active_session`` when the campaign doesn't have a live
  ## session bound (stopped/escalated/converged campaigns, or the
  ## daemon was restarted since the campaign was last active).
  if req.reqMethod != HttpPost:
    await respondJson(req, Http405,
      $(%* {"error": "method_not_allowed"}))
    return
  var campaignId = ""
  var text = ""
  try:
    let node = parseJson(req.body)
    campaignId = node{"campaignId"}.getStr("")
    text = node{"text"}.getStr("")
  except JsonParsingError:
    await respondJson(req, Http400, $(%* {"error": "invalid_json"}))
    return
  if campaignId.len == 0:
    await respondJson(req, Http400, $(%* {"error": "missing_campaignId"}))
    return
  if text.strip().len == 0:
    await respondJson(req, Http400, $(%* {"error": "missing_text"}))
    return

  let sessionId = reg.lookupSession(campaignId)
  let dbSession =
    try: dbCampaignAcpSessionId(reg, campaignId)
    except DbError: ""
  if sessionId.len == 0 or dbSession.len == 0:
    await respondJson(req, Http404,
      $(%* {"error": "no_active_session", "campaignId": campaignId}))
    return

  # Push onto the ACP queue.
  let stateOpt = reg.agents.getState(sessionId)
  if not stateOpt.isSome:
    await respondJson(req, Http404,
      $(%* {"error": "no_active_session", "campaignId": campaignId}))
    return
  var state = stateOpt.get
  try:
    {.gcsafe.}:
      injectPrompt(state.client, sessionId, text)
  except CatchableError as e:
    error "campaign inject: injectPrompt failed",
      campaignId = campaignId, reason = e.msg
    await respondJson(req, Http500,
      $(%* {"error": "inject_failed", "reason": e.msg}))
    return

  # Record the operator's intent in the event log so the audit trail
  # captures it before we return.
  var eventId = ""
  let payload = %* {"kind": "operator_injection", "text": text}
  try:
    eventId = dbRecordEvent(reg, campaignId, "note", payload)
  except DbError as e:
    error "campaign inject: note event insert failed",
      campaignId = campaignId, reason = e.msg
    await respondJson(req, Http500,
      $(%* {"error": "db_error", "reason": e.msg}))
    return
  reg.appendInjectionEventId(campaignId, eventId)
  info "handleInject: queued",
    campaignId = campaignId, eventId = eventId,
    sessionId = sessionId

  let queuedAt = $now()
  let respBody = %* {"campaignId": campaignId, "status": "queued",
                     "queuedAt": queuedAt, "eventId": eventId}
  await respondJson(req, Http202, $respBody)

proc handleRefreshDoc*(reg: CampaignRegistry; req: Request)
    {.async, gcsafe.} =
  ## CMP-M4 — POST /api/campaign/refresh-doc {campaignId}
  ##
  ## Re-read the campaign doc from disk (path from ``campaigns.doc_path``),
  ## hash the new bytes, call ``update_campaign_doc_sha`` to update the
  ## row, and append a ``note`` event tagged ``kind=doc_refreshed``.
  ## Returns ``{campaignId, oldSha, newSha, contentChanged}``.
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

  let docPath = dbCampaignDocPath(reg, campaignId)
  if docPath.len == 0:
    await respondJson(req, Http404,
      $(%* {"error": "campaign_not_found", "campaignId": campaignId}))
    return
  if not fileExists(docPath):
    await respondJson(req, Http400,
      $(%* {"error": "doc_missing_on_disk",
            "campaignId": campaignId, "docPath": docPath}))
    return

  let raw =
    try: readFile(docPath)
    except IOError as e:
      await respondJson(req, Http500,
        $(%* {"error": "doc_read_failed", "reason": e.msg}))
      return
  var newSha = ""
  try:
    newSha = sha256OfStringShellOut(raw)
  except IOError as e:
    await respondJson(req, Http500,
      $(%* {"error": "sha256_failed", "reason": e.msg}))
    return

  var oldSha = ""
  try:
    oldSha = dbUpdateDocSha(reg, campaignId, newSha)
  except DbError as e:
    error "campaign refresh-doc: update_campaign_doc_sha failed",
      campaignId = campaignId, reason = e.msg
    await respondJson(req, Http500,
      $(%* {"error": "db_error", "reason": e.msg}))
    return
  let changed = (oldSha != newSha)

  let evtPayload = %* {"kind": "doc_refreshed",
                       "oldSha": oldSha, "newSha": newSha,
                       "contentChanged": changed}
  try:
    discard dbRecordEvent(reg, campaignId, "note", evtPayload)
  except DbError as e:
    warn "campaign refresh-doc: note event insert failed (non-fatal)",
      campaignId = campaignId, reason = e.msg

  let respBody = %* {"campaignId": campaignId, "oldSha": oldSha,
                     "newSha": newSha, "contentChanged": changed}
  await respondJson(req, Http200, $respBody)

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

proc makeInjectHandler*(reg: CampaignRegistry): CampaignHandlerProc =
  result = proc(req: Request): Future[void] {.async, gcsafe.} =
    await handleInject(reg, req)

proc makeRefreshDocHandler*(reg: CampaignRegistry): CampaignHandlerProc =
  result = proc(req: Request): Future[void] {.async, gcsafe.} =
    await handleRefreshDoc(reg, req)
