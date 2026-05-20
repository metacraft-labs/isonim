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

type
  CampaignRegistry* = ref object
    ## Holds the live ACP session for each active campaign and the
    ## handle on the design-review DB.  Single-tenant — there is one
    ## entry per ``campaign_id`` and the daemon binds to ``127.0.0.1``
    ## only.
    ##
    ## CMP-M2.1: also tracks per-campaign consecutive error counts (so
    ## three successive ``stopReason=error`` rounds auto-escalate the
    ## campaign) and a generation counter (so a ``campaign stop`` can
    ## invalidate any pending auto-tick task without depending on a
    ## ``Future.cancel`` we can't safely cross-thread).
    lock: Lock
    sessions: Table[string, string]   ## campaign_id → acp session id
    consecutiveErrors: Table[string, int]
    autoTickGen: Table[string, int]   ## bumped on stop/escalation to cancel
                                      ## any pending scheduleAutoTick that
                                      ## hasn't fired yet
    # CMP-M4 — per-campaign pending operator-injection event id queue.
    # ``injectionEventIds[cid]`` is the ordered list of ``campaign_events``
    # uuids written by ``handleInject`` whose corresponding ACP-queued
    # text is still waiting to be folded into the next tick prompt.  The
    # tick path drains both ACP texts and these ids atomically (under
    # ``lock``) and, after a successful prompt-send, calls
    # ``acknowledge_campaign_events`` with the LAST entry of the drained
    # list as the upto bound.
    injectionEventIds: Table[string, seq[string]]
    agents: AgentRegistry
    db: ReviewDb
    promptPath*: string
    promptText: string                 ## cached orchestrator prompt body
    idleTimeoutMs*: int
    autoTickDelayMs*: int
    autoTickDisabled*: bool

  CampaignSchedulerError* = object of CatchableError

  OrchestratorStatus* = object
    ## Parsed shape of the ``<<<ORCHESTRATOR_STATUS ...>>>`` marker the
    ## orchestrator emits at the end of every turn (see prompts/
    ## campaign-orchestrator.md § J.5).  ``present = false`` means the
    ## marker was absent or malformed; callers should treat that as a
    ## soft warning, not a failure.
    present*: bool
    reason*: string             ## tick_ready | converged | escalated |
                                ## stopped | needs_human | "unknown"
    round*: int                 ## 0 when missing / unparseable
    hasRound*: bool
    defectsAddressed*: int
    hasDefectsAddressed*: bool
    blockerSummary*: string
    rawMarker*: string          ## the full ``<<<...>>>`` substring

# ---------------------------------------------------------------------------
# Registry helpers.
# ---------------------------------------------------------------------------

proc newCampaignRegistry*(agents: AgentRegistry; db: ReviewDb;
                          promptPath: string;
                          idleTimeoutMs: int = 900_000;
                          autoTickDelayMs: int = 2_000;
                          autoTickDisabled: bool = false): CampaignRegistry =
  result = CampaignRegistry(
    sessions: initTable[string, string](),
    consecutiveErrors: initTable[string, int](),
    autoTickGen: initTable[string, int](),
    injectionEventIds: initTable[string, seq[string]](),
    agents: agents,
    db: db,
    promptPath: promptPath,
    idleTimeoutMs: idleTimeoutMs,
    autoTickDelayMs: autoTickDelayMs,
    autoTickDisabled: autoTickDisabled,
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

proc bumpAutoTickGen*(reg: CampaignRegistry; campaignId: string): int =
  ## Atomically increment and return the generation counter for
  ## ``campaignId``.  Any pending ``scheduleAutoTick`` task closes over
  ## the previous value, so on wake-up it can compare and abort if the
  ## counter has moved (e.g. ``campaign stop`` was called).
  acquire(reg.lock)
  try:
    let cur = reg.autoTickGen.getOrDefault(campaignId, 0)
    let nxt = cur + 1
    reg.autoTickGen[campaignId] = nxt
    return nxt
  finally:
    release(reg.lock)

proc currentAutoTickGen*(reg: CampaignRegistry; campaignId: string): int =
  acquire(reg.lock)
  try:
    return reg.autoTickGen.getOrDefault(campaignId, 0)
  finally:
    release(reg.lock)

proc recordErrorRound*(reg: CampaignRegistry;
    campaignId: string; isError: bool): int =
  ## Bump the per-campaign consecutive-error counter when ``isError``
  ## is true; reset it to 0 on any non-error round.  Returns the new
  ## counter value.  CMP-M2.1: after three consecutive errors the tick
  ## handler escalates the campaign.
  acquire(reg.lock)
  try:
    let cur = reg.consecutiveErrors.getOrDefault(campaignId, 0)
    let nxt = if isError: cur + 1 else: 0
    reg.consecutiveErrors[campaignId] = nxt
    return nxt
  finally:
    release(reg.lock)

proc resetConsecutiveErrors*(reg: CampaignRegistry; campaignId: string) =
  acquire(reg.lock)
  try:
    reg.consecutiveErrors[campaignId] = 0
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

proc takePendingInjectionEventIds*(reg: CampaignRegistry;
                                    campaignId: string): seq[string] =
  ## Atomically drain and return the pending-injection event-id list for
  ## ``campaignId`` (FIFO).  Returns ``@[]`` when no entries exist.
  acquire(reg.lock)
  try:
    if reg.injectionEventIds.hasKey(campaignId):
      result = reg.injectionEventIds[campaignId]
      reg.injectionEventIds[campaignId] = @[]
    else:
      result = @[]
  finally:
    release(reg.lock)

proc restorePendingInjectionEventIds*(reg: CampaignRegistry;
                                       campaignId: string;
                                       eventIds: seq[string]) =
  ## Re-queue ``eventIds`` at the FRONT of the per-campaign pending list.
  ## Used by the tick path when the prompt-send fails after the ACP queue
  ## was drained — we put the texts back in the ACP queue AND the event
  ## ids back here so the next tick replays the same injections in the
  ## same order.
  if eventIds.len == 0: return
  acquire(reg.lock)
  try:
    if not reg.injectionEventIds.hasKey(campaignId):
      reg.injectionEventIds[campaignId] = @[]
    reg.injectionEventIds[campaignId] =
      eventIds & reg.injectionEventIds[campaignId]
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

proc dbNextRound(reg: CampaignRegistry; campaignId: string): int =
  ## CMP-M2.1 — return the round number to assign for the next
  ## ``round_started`` event for ``campaignId``.  Delegates to the
  ## SECURITY-DEFINER routine ``design_review.next_campaign_round``
  ## (migration 007).  The routine counts ``round_complete`` events
  ## and returns count + 1, so:
  ##
  ##   * After ``handleStart`` writes its baseline ``round_complete``,
  ##     ``dbNextRound`` returns 2 — the first ``campaign tick`` claims
  ##     round 2, not the round-1 the CMP-M2 experiment mistakenly
  ##     reused for both turns.
  ##   * Before any ``round_complete`` exists, the routine returns 1.
  reg.db.asApp()
  let stmt = "SELECT design_review.next_campaign_round('" &
    escSql(campaignId) & "'::uuid)::text"
  let raw = reg.db.conn.getValue(sql(stmt))
  if raw.len == 0:
    return 1
  try:
    return parseInt(raw)
  except ValueError:
    return 1

proc dbCountRoundComplete(reg: CampaignRegistry; campaignId: string): int =
  ## CMP-M2.1 — count completed rounds for ``max_iterations`` enforcement.
  ## Delegates to the SECURITY-DEFINER routine
  ## ``design_review.count_campaign_round_complete`` (migration 007) so
  ## the app role doesn't need direct SELECT on the base table.
  reg.db.asApp()
  let stmt = "SELECT design_review.count_campaign_round_complete('" &
    escSql(campaignId) & "'::uuid)::text"
  let raw = reg.db.conn.getValue(sql(stmt))
  try:
    return parseInt(raw)
  except ValueError:
    return 0

proc dbCampaignMaxIterations(reg: CampaignRegistry;
    campaignId: string): int =
  ## Read ``campaigns.max_iterations`` so auto-tick can bound itself.
  let fetched = dbFetchCampaign(reg, campaignId, 1)
  if fetched == nil: return 0
  return fetched{"max_iterations"}.getInt(0)

proc dbCampaignStatus(reg: CampaignRegistry; campaignId: string): string =
  ## Read the campaign's current status so auto-tick can short-circuit
  ## on a terminal state without trying a transition that would fail.
  let fetched = dbFetchCampaign(reg, campaignId, 1)
  if fetched == nil: return ""
  return fetched{"status"}.getStr("")

proc dbCampaignDocPath(reg: CampaignRegistry; campaignId: string): string =
  ## CMP-M4 — read ``campaigns.doc_path`` so the tick path can re-read
  ## the campaign doc body from disk every turn (the operator may edit
  ## the file at any point — re-reading is the cost of live-edit
  ## friendliness).
  let fetched = dbFetchCampaign(reg, campaignId, 1)
  if fetched == nil: return ""
  return fetched{"doc_path"}.getStr("")

proc dbCampaignAcpSessionId(reg: CampaignRegistry;
    campaignId: string): string =
  ## CMP-M4 — read ``campaigns.acp_session_id``.  The inject route uses
  ## this to verify that a campaign has an active session: even if the
  ## in-memory ``reg.sessions`` map says yes, the row's
  ## ``acp_session_id`` is the source of truth for "the campaign was
  ## ever started" and "this isn't a stopped/escalated campaign".
  let fetched = dbFetchCampaign(reg, campaignId, 1)
  if fetched == nil: return ""
  return fetched{"acp_session_id"}.getStr("")

proc readCampaignDocBody*(reg: CampaignRegistry; campaignId: string): string =
  ## CMP-M4 — re-read the campaign doc off disk and return its
  ## ``bodyMarkdown`` (the frontmatter is stripped via
  ## ``parseCampaignDoc``).  Falls back to the raw bytes if the doc
  ## fails to parse — the next round still gets the operator's edit
  ## even if it broke the frontmatter; the orchestrator can flag the
  ## breakage in its response.
  ##
  ## *Perf note.* Each tick re-reads + re-parses the doc.  For a
  ## kilobyte-sized markdown file this is sub-millisecond; the
  ## operator-edit-friendly behaviour is worth the cost.  If campaign
  ## docs ever grow into the MB range we'd want a content-hash short-
  ## circuit (compare disk SHA against the registry-cached SHA and
  ## skip the parse if unchanged), but at MD-document scale that's
  ## premature optimisation.
  let docPath = dbCampaignDocPath(reg, campaignId)
  if docPath.len == 0 or not fileExists(docPath):
    return ""
  let raw =
    try: readFile(docPath)
    except IOError as e:
      warn "campaign doc re-read failed",
        campaignId = campaignId, path = docPath, reason = e.msg
      return ""
  result = raw

proc readCampaignDocBodyParsed*(reg: CampaignRegistry;
    campaignId: string): string {.gcsafe.} =
  ## Variant of :proc:`readCampaignDocBody` that runs the raw bytes
  ## through ``parseCampaignDoc`` to strip the YAML frontmatter, so the
  ## tick prompt only carries the human-readable body.  Falls back to
  ## the raw bytes on parse failure (see the note in
  ## :proc:`readCampaignDocBody`).
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
      warn "campaign doc parse failed during tick — passing raw bytes",
        campaignId = campaignId, path = docPath, reason = e.msg
      return raw

proc dbAcknowledgeEvents(reg: CampaignRegistry;
    campaignId, uptoEventId: string): int =
  ## CMP-M4 — call the SECURITY-DEFINER routine
  ## ``design_review.acknowledge_campaign_events`` and return the number
  ## of rows it flipped to ``acknowledged = TRUE``.
  reg.db.asApp()
  let stmt = "SELECT design_review.acknowledge_campaign_events('" &
    escSql(campaignId) & "'::uuid, '" & escSql(uptoEventId) &
    "'::uuid)::text"
  let raw = reg.db.conn.getValue(sql(stmt))
  if raw.len == 0: return 0
  try:
    return parseInt(raw)
  except ValueError:
    return 0

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
  ## Continuation prompt for ``campaign tick`` (legacy / no-injection
  ## variant kept for tests that exercise the marker parser without
  ## also exercising the operator-injection plumbing).
  result = "INSTRUCTION:\n"
  result.add "Continue with round " & $round & ". Re-read the campaign doc and the latest agent report,\n"
  result.add "produce an updated plan for what to address next. Output as structured markdown.\n"
  result.add "Sub-agent dispatch is not yet wired; produce a plan, do not attempt to dispatch.\n"

proc assembleTickPromptWithInjections*(campaignId: string; round: int;
    injections: seq[string]; docBody: string): string =
  ## CMP-M4 — composite tick prompt that folds two operator-intervention
  ## surfaces into a single user message:
  ##
  ##   1. **Operator injections** (``handleInject``):  zero or more
  ##      free-form text blocks the user (or AI Assistant) queued via
  ##      ``POST /api/campaign/inject`` since the previous turn.  Each
  ##      lands as one block separated by ``---``.  The orchestrator's
  ##      prompt (see ``prompts/campaign-orchestrator.md`` § L) teaches
  ##      it to acknowledge and act on these.
  ##   2. **Current campaign doc** (``handleRefreshDoc`` OR an in-place
  ##      edit the daemon picks up at tick time):  the entire body of
  ##      the doc as it exists on disk RIGHT NOW.  This is the
  ##      authoritative state-of-record — the orchestrator must treat
  ##      the rest of its working memory as advisory if it disagrees
  ##      with what the doc says.
  ##
  ## The shape is intentionally close to the start-prompt's section
  ## headers so the orchestrator sees a familiar layout.  We do NOT
  ## re-embed the briefs on every tick — those don't change inside a
  ## single campaign and were already loaded at start time; embedding
  ## them on every continuation would balloon the token budget.
  result = ""
  if injections.len > 0:
    result.add "## OPERATOR INJECTION (received since previous turn)\n\n"
    for i, text in injections:
      if i > 0:
        result.add "\n---\n\n"
      result.add text
      if not text.endsWith("\n"):
        result.add "\n"
    result.add "\n"
  result.add "## CAMPAIGN DOCUMENT (current revision)\n\n"
  if docBody.len > 0:
    result.add docBody
    if not docBody.endsWith("\n"):
      result.add "\n"
  else:
    result.add "(campaign document body unavailable on disk)\n"
  result.add "\n## CONTINUE ROUND\n\n"
  result.add "You are continuing campaign " & campaignId & " round " &
    $round & ". The campaign doc above\n"
  result.add "is the authoritative current state. Apply any operator " &
    "injections from\n"
  result.add "this turn before proceeding with the round's planned work.\n"

# ---------------------------------------------------------------------------
# ORCHESTRATOR_STATUS marker parser.
#
# The orchestrator emits, as the last line of every turn:
#
#   <<<ORCHESTRATOR_STATUS reason=<r> round=<n>
#                          defects_addressed=<n|empty>
#                          blocker_summary="<short string>">>>
#
# This is the structured signal the daemon's auto-tick / convergence /
# escalation routing acts on.  We scan the accumulated text for the
# *last* such marker (defensive: if a sub-agent ever echoes the marker
# verbatim in its captured output, we still want the orchestrator's own
# closing marker to win) and pull out the four named fields.
#
# Robustness:
#   * Tolerate whitespace and newlines between fields.
#   * Field order is fixed in the spec (reason, round, defects_addressed,
#     blocker_summary) but the parser is order-agnostic so a future
#     orchestrator that reorders fields stays compatible.
#   * Unknown reasons collapse to ``"unknown"`` and ``present=false``
#     so the daemon takes the soft-fail branch.
# ---------------------------------------------------------------------------

const
  OrchestratorStatusOpenTag = "<<<ORCHESTRATOR_STATUS"
  OrchestratorStatusCloseTag = ">>>"
  ValidOrchestratorReasons = ["tick_ready", "converged", "escalated",
                              "stopped", "needs_human"]

proc isValidReason(r: string): bool =
  for v in ValidOrchestratorReasons:
    if r == v: return true
  false

proc extractField(body: string; name: string): tuple[present: bool; raw: string] =
  ## Locate ``name=`` in ``body`` and return the field's raw value.
  ## Stops at the first whitespace for unquoted fields; for fields whose
  ## value opens with ``"`` consumes the matching closing ``"`` (honouring
  ## ``\"`` escapes).  Returns ``present=false`` when the field is
  ## absent.
  let needle = name & "="
  let idx = body.find(needle)
  if idx < 0:
    return (present: false, raw: "")
  var i = idx + needle.len
  if i >= body.len:
    return (present: true, raw: "")
  if body[i] == '"':
    inc i
    var buf = ""
    while i < body.len:
      let ch = body[i]
      if ch == '\\' and i + 1 < body.len:
        case body[i + 1]
        of '"': buf.add '"'; inc i, 2; continue
        of '\\': buf.add '\\'; inc i, 2; continue
        of 'n': buf.add '\n'; inc i, 2; continue
        of 't': buf.add '\t'; inc i, 2; continue
        else: discard
      if ch == '"':
        return (present: true, raw: buf)
      buf.add ch
      inc i
    return (present: true, raw: buf)
  var buf = ""
  while i < body.len:
    let ch = body[i]
    if ch in {' ', '\t', '\n', '\r'}: break
    if ch == '>' and i + 2 < body.len and body[i .. i + 2] == ">>>": break
    if ch == '>' and i + 1 < body.len and body[i + 1] == '>': break
    buf.add ch
    inc i
  (present: true, raw: buf)

proc parseOrchestratorStatus*(text: string): OrchestratorStatus =
  ## Scan ``text`` for the last ``<<<ORCHESTRATOR_STATUS ...>>>``
  ## marker and return its parsed fields.  ``present = false`` when
  ## the marker is absent or malformed; callers treat that as a soft
  ## warning (record a ``note`` event, don't auto-tick).
  result.reason = "unknown"
  var searchFrom = 0
  var openIdx = -1
  while true:
    let nxt = text.find(OrchestratorStatusOpenTag, searchFrom)
    if nxt < 0: break
    openIdx = nxt
    searchFrom = nxt + OrchestratorStatusOpenTag.len
  if openIdx < 0:
    return
  let closeIdx = text.find(OrchestratorStatusCloseTag,
                           openIdx + OrchestratorStatusOpenTag.len)
  if closeIdx < 0:
    return
  let body = text[openIdx + OrchestratorStatusOpenTag.len ..< closeIdx]
  result.rawMarker = text[openIdx .. closeIdx + 2]

  let reasonField = extractField(body, "reason")
  let roundField = extractField(body, "round")
  let defectsField = extractField(body, "defects_addressed")
  let blockerField = extractField(body, "blocker_summary")

  if reasonField.present and isValidReason(reasonField.raw):
    result.reason = reasonField.raw
    result.present = true
  else:
    result.reason = "unknown"
    return
  if roundField.present and roundField.raw.len > 0:
    var n: int
    if parseInt(roundField.raw, n, 0) > 0:
      result.round = n
      result.hasRound = true
  if defectsField.present and defectsField.raw.len > 0:
    var n: int
    if parseInt(defectsField.raw, n, 0) > 0:
      result.defectsAddressed = n
      result.hasDefectsAddressed = true
  if blockerField.present:
    result.blockerSummary = blockerField.raw

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

type
  StreamPromptResult* = object
    ## Returned by :proc:`streamPromptToSocket` so the route handlers
    ## (``handleStart`` / ``handleTick``) can act on the parsed
    ## ORCHESTRATOR_STATUS marker without re-reading the just-written
    ## ``round_complete`` row from the DB.
    alive*: bool                  ## SSE socket still writable
    stopReason*: string           ## stringified StopReason (or "error")
    isError*: bool                ## convenience: stopReason == "error"
    status*: OrchestratorStatus   ## parsed marker (present=false on miss)
    eventId*: string              ## the round_complete row's event_id

proc logCampaignPrompt(campaignId, sessionId, promptText: string;
                       source: string) =
  ## CMP-M4 test hook — when ``$FAKE_ACP_CONTENT_LOG`` is set, append one
  ## JSON-summary line per outgoing campaign prompt so tests can assert
  ## the prompt body actually contains the operator-injection block and
  ## the current campaign-doc body.  Mirrors the shape the agent_routes
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
  ## forwards session/update events to ``sock``, parses the trailing
  ## ``<<<ORCHESTRATOR_STATUS ...>>>`` marker, and writes a
  ## ``eventKindOnDone`` (typically ``round_complete``) row whose
  ## payload carries ``stopReason``, ``text``, ``orchestrator_status``,
  ## and any caller-supplied extras.  Returns the parsed marker so the
  ## caller can drive auto-tick / convergence / escalation routing.
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
  result.stopReason = stopReason
  result.isError = (stopReason == "error")

  # Record the campaign_event in the DB before emitting ``end`` so any
  # client that GETs ``/api/campaign/events`` immediately after the SSE
  # close will see the row.
  let accumulated = snapshotText()
  let parsedStatus = parseOrchestratorStatus(accumulated)
  result.status = parsedStatus

  var payload = newJObject()
  payload["stopReason"] = %stopReason
  payload["text"] = %accumulated
  # CMP-M2.1 — embed the parsed ORCHESTRATOR_STATUS fields on the
  # ``round_complete`` event payload so downstream tooling (the
  # ``campaign tail`` CLI, the Gallery overlay, future analytics) can
  # see the orchestrator's structured signal without re-scanning the
  # raw text.
  var statusJson = newJObject()
  statusJson["present"] = %parsedStatus.present
  statusJson["reason"] = %parsedStatus.reason
  if parsedStatus.hasRound:
    statusJson["round"] = %parsedStatus.round
  if parsedStatus.hasDefectsAddressed:
    statusJson["defectsAddressed"] = %parsedStatus.defectsAddressed
  statusJson["blockerSummary"] = %parsedStatus.blockerSummary
  payload["orchestrator_status"] = statusJson
  if not parsedStatus.present:
    payload["orchestrator_status_missing"] = %true
    payload["reason"] = %"unknown"
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

proc runPromptHeadless(reg: CampaignRegistry;
    sessionId, campaignId, eventKindOnDone, promptText: string;
    extraPayload: JsonNode): Future[StreamPromptResult] {.async, gcsafe.} =
  ## Same shape as :proc:`streamPromptToSocket` but with no SSE socket —
  ## used by the auto-tick path which drives the orchestrator without a
  ## live HTTP client.  Discards session/update frames (the chunks are
  ## still recoverable from the ``round_complete`` row's accumulated
  ## ``text`` field) and records the same ``round_complete`` payload.
  let stateOpt = reg.agents.getState(sessionId)
  if not stateOpt.isSome:
    result.alive = false
    result.stopReason = "error"
    result.isError = true
    return result
  var state = stateOpt.get
  let prompt = @[textBlock(promptText)]
  logCampaignPrompt(campaignId, sessionId, promptText, "headless")

  type StreamBuf = ref object
    lock: Lock
    accumulatedText: string
  let streamBuf = new StreamBuf
  initLock(streamBuf.lock)
  defer: deinitLock(streamBuf.lock)
  proc pushText(t: string) {.gcsafe.} =
    {.cast(gcsafe).}:
      acquire(streamBuf.lock)
      streamBuf.accumulatedText.add t
      release(streamBuf.lock)
  proc snapshotText(): string {.gcsafe.} =
    {.cast(gcsafe).}:
      acquire(streamBuf.lock)
      result = streamBuf.accumulatedText
      release(streamBuf.lock)

  let onEvent: AgentEventCallback = proc(ev: AgentEvent) {.gcsafe.} =
    {.cast(gcsafe).}:
      if ev.kind == aekMessageChunk and ev.text.len > 0:
        pushText(ev.text)

  var args = PromptArgs(sessionId: sessionId, prompt: prompt,
                        client: state.client, callback: onEvent)
  var worker: Thread[PromptArgs]
  createThread(worker, runPromptThread, args)
  while not args.done:
    await sleepAsync(20)
  joinThread(worker)

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
  let accumulated = snapshotText()
  let parsedStatus = parseOrchestratorStatus(accumulated)
  result.status = parsedStatus

  var payload = newJObject()
  payload["stopReason"] = %stopReason
  payload["text"] = %accumulated
  var statusJson = newJObject()
  statusJson["present"] = %parsedStatus.present
  statusJson["reason"] = %parsedStatus.reason
  if parsedStatus.hasRound:
    statusJson["round"] = %parsedStatus.round
  if parsedStatus.hasDefectsAddressed:
    statusJson["defectsAddressed"] = %parsedStatus.defectsAddressed
  statusJson["blockerSummary"] = %parsedStatus.blockerSummary
  payload["orchestrator_status"] = statusJson
  if not parsedStatus.present:
    payload["orchestrator_status_missing"] = %true
    payload["reason"] = %"unknown"
  if extraPayload != nil:
    for k, v in extraPayload.pairs:
      payload[k] = v
  try:
    result.eventId = dbRecordEvent(reg, campaignId, eventKindOnDone, payload)
  except DbError as e:
    error "campaign_event insert failed (auto-tick)",
      campaignId = campaignId, kind = eventKindOnDone, reason = e.msg
  result.alive = true
  return result

# ---------------------------------------------------------------------------
# Auto-tick / convergence / escalation routing.
#
# After a ``round_complete`` lands, the parsed ORCHESTRATOR_STATUS marker
# tells us what to do:
#
#   tick_ready   → schedule another tick after autoTickDelayMs.  Bounded
#                  by the campaign's max_iterations: if the cap is hit,
#                  transition to ``escalated`` instead.
#   converged    → call transition_campaign(..., 'converged', ...).
#   escalated    → call transition_campaign(..., 'escalated', summary).
#   needs_human  → record an escalation event; don't auto-tick; leave
#                  the status alone for the AI Assistant to surface.
#   stopped      → call transition_campaign(..., 'stopped', summary).
#   unknown      → record a ``note`` event; soft warning, no auto-tick.
#
# A pending auto-tick can be cancelled by ``handleStop`` (or by any
# auto-escalation in ``handleErrorEscalation``) bumping the campaign's
# generation counter; the scheduled coroutine compares on wake-up and
# bails if the generation has moved.
# ---------------------------------------------------------------------------

proc scheduleAutoTick(reg: CampaignRegistry; campaignId: string;
                      delayMs: int): Future[void] {.async, gcsafe.}

proc applyOrchestratorStatusAfterRound*(reg: CampaignRegistry;
    campaignId: string; res: StreamPromptResult):
    Future[void] {.async, gcsafe.}

proc drainCampaignSessionInjections(reg: CampaignRegistry;
    campaignId, sessionId: string): seq[string] {.gcsafe.} =
  ## CMP-M4 — drain the per-session ACP injection queue and return the
  ## texts in FIFO order.  ``@[]`` when the underlying client has none
  ## or the session has gone away.  Always-safe (the queue is a no-op
  ## on JS and lock-protected on native; an absent session yields an
  ## empty list).
  {.gcsafe.}:
    let stateOpt = reg.agents.getState(sessionId)
    if not stateOpt.isSome: return @[]
    var s = stateOpt.get
    try:
      return takeQueuedInjections(s.client, sessionId)
    except CatchableError as e:
      warn "drain injections failed",
        campaignId = campaignId, sessionId = sessionId, reason = e.msg
      return @[]

proc reinjectCampaignSession(reg: CampaignRegistry;
    campaignId, sessionId: string; texts: seq[string]) {.gcsafe.} =
  ## CMP-M4 — restore ``texts`` to the front of the per-session ACP
  ## queue when the tick prompt-send failed after we drained.  The ACP
  ## queue exposes append-only ``injectPrompt`` — there is no
  ## "prepend" method — so we re-queue in order.  In practice this is
  ## still FIFO because a concurrent ``handleInject`` between drain and
  ## reinject is exceptional (the daemon holds at most one tick in
  ## flight per campaign).
  {.gcsafe.}:
    let stateOpt = reg.agents.getState(sessionId)
    if not stateOpt.isSome: return
    var s = stateOpt.get
    for text in texts:
      try:
        injectPrompt(s.client, sessionId, text)
      except CatchableError as e:
        warn "reinject after failed tick prompt-send failed",
          campaignId = campaignId, sessionId = sessionId, reason = e.msg

proc runAutoTickOnce(reg: CampaignRegistry; campaignId: string;
                     expectedGen: int): Future[void] {.async, gcsafe.} =
  ## Body of one auto-tick: claim the round number, write the
  ## ``round_started`` event, send the orchestrator's continuation
  ## prompt headless, parse the marker, route on the result.
  if reg.currentAutoTickGen(campaignId) != expectedGen:
    debug "auto-tick aborted: generation mismatch",
      campaignId = campaignId
    return
  let status = dbCampaignStatus(reg, campaignId)
  if status notin ["active", "pending"]:
    debug "auto-tick aborted: campaign terminal",
      campaignId = campaignId, status = status
    return
  let sessionId = reg.lookupSession(campaignId)
  if sessionId.len == 0:
    debug "auto-tick aborted: no active session",
      campaignId = campaignId
    return

  # Max-iterations bound.
  let completed = dbCountRoundComplete(reg, campaignId)
  let cap = dbCampaignMaxIterations(reg, campaignId)
  if cap > 0 and completed >= cap:
    try:
      discard dbRecordEvent(reg, campaignId, "escalation",
        %* {"reason": "iteration cap reached", "completedRounds": completed,
            "maxIterations": cap})
      dbTransition(reg, campaignId, "escalated", "iteration cap reached")
    except DbError as e:
      error "auto-tick: iteration-cap escalation failed",
        campaignId = campaignId, reason = e.msg
    return

  let round = dbNextRound(reg, campaignId)
  try:
    discard dbRecordEvent(reg, campaignId, "round_started",
      %* {"round": round, "source": "auto_tick"})
  except DbError as e:
    error "auto-tick: round_started event insert failed",
      campaignId = campaignId, reason = e.msg
    return

  # CMP-M4 — drain operator-injection queue + re-read doc body before
  # building the auto-tick prompt; same shape as the manual ``tick``
  # path so injections submitted between rounds get folded into the
  # very next continuation regardless of whether it was operator- or
  # auto-driven.
  let injectionTexts = drainCampaignSessionInjections(reg, campaignId, sessionId)
  let injectionEventIds = reg.takePendingInjectionEventIds(campaignId)
  let docBody = readCampaignDocBodyParsed(reg, campaignId)

  let extra = %* {"campaignId": campaignId, "round": round,
                  "source": "auto_tick"}
  let promptText = assembleTickPromptWithInjections(
    campaignId, round, injectionTexts, docBody)
  let res = await runPromptHeadless(reg, sessionId, campaignId,
    "round_complete", promptText, extra)

  if res.isError:
    reinjectCampaignSession(reg, campaignId, sessionId, injectionTexts)
    reg.restorePendingInjectionEventIds(campaignId, injectionEventIds)
  elif injectionEventIds.len > 0:
    let upto = injectionEventIds[injectionEventIds.high]
    try:
      discard dbAcknowledgeEvents(reg, campaignId, upto)
    except DbError as e:
      warn "auto-tick: ack injection events failed",
        campaignId = campaignId, reason = e.msg

  # Apply the marker — recursively or terminally.
  await applyOrchestratorStatusAfterRound(reg, campaignId, res)

proc scheduleAutoTick(reg: CampaignRegistry; campaignId: string;
                      delayMs: int): Future[void] {.async, gcsafe.} =
  ## Sleep ``delayMs`` then invoke :proc:`runAutoTickOnce`.  Closes
  ## over the current generation counter so a subsequent ``campaign
  ## stop`` (which bumps the counter) effectively cancels this task —
  ## ``runAutoTickOnce`` compares and bails on mismatch.
  let gen = reg.currentAutoTickGen(campaignId)
  try:
    discard dbRecordEvent(reg, campaignId, "auto_tick_scheduled",
      %* {"delayMs": delayMs, "scheduledAt": $now(),
          "generation": gen})
  except DbError as e:
    warn "auto-tick: scheduled event insert failed (non-fatal)",
      campaignId = campaignId, reason = e.msg
  if delayMs > 0:
    await sleepAsync(delayMs)
  if reg.currentAutoTickGen(campaignId) != gen:
    debug "auto-tick: cancelled before fire", campaignId = campaignId
    return
  try:
    await runAutoTickOnce(reg, campaignId, gen)
  except CatchableError as e:
    error "auto-tick: runAutoTickOnce failed",
      campaignId = campaignId, reason = e.msg

proc applyOrchestratorStatusAfterRound*(reg: CampaignRegistry;
    campaignId: string; res: StreamPromptResult):
    Future[void] {.async, gcsafe.} =
  ## Decide what to do based on the orchestrator's structured signal
  ## (and the stopReason).  Called from ``handleStart``, ``handleTick``,
  ## and ``runAutoTickOnce`` after the corresponding ``round_complete``
  ## row has been written.
  ##
  ## Order of operations:
  ##   1. Error escalation: three consecutive ``stopReason=error``
  ##      rounds auto-escalate the campaign and short-circuit.
  ##   2. Marker routing: tick_ready → schedule auto-tick (bounded by
  ##      max_iterations); converged/escalated/stopped → transition;
  ##      needs_human → record escalation event, no transition;
  ##      unknown → record note event.

  info "applyOrchestratorStatusAfterRound",
    campaignId = campaignId,
    reasonParsed = res.status.reason,
    markerPresent = res.status.present,
    stopReason = res.stopReason,
    autoTickDisabled = reg.autoTickDisabled
  let errorCount = reg.recordErrorRound(campaignId, res.isError)
  if res.isError and errorCount >= 3:
    # Cancel any pending auto-tick + transition to escalated.
    discard reg.bumpAutoTickGen(campaignId)
    try:
      discard dbRecordEvent(reg, campaignId, "escalation",
        %* {"consecutiveErrors": errorCount,
            "lastErrorRound": (if res.status.hasRound: res.status.round else: 0),
            "reason": "three consecutive error rounds"})
      let status = dbCampaignStatus(reg, campaignId)
      if status in ["active", "pending"]:
        dbTransition(reg, campaignId, "escalated",
                     "three consecutive error rounds")
    except DbError as e:
      error "auto-escalation on consecutive errors failed",
        campaignId = campaignId, reason = e.msg
    return

  let marker = res.status
  case marker.reason
  of "tick_ready":
    if reg.autoTickDisabled:
      debug "auto-tick disabled by config", campaignId = campaignId
      return
    # Iteration cap check before scheduling.
    var completed = 0
    var cap = 0
    try:
      completed = dbCountRoundComplete(reg, campaignId)
      cap = dbCampaignMaxIterations(reg, campaignId)
    except CatchableError as e:
      warn "auto-tick: max-iterations lookup failed (non-fatal)",
        campaignId = campaignId, reason = e.msg
    if cap > 0 and completed >= cap:
      try:
        discard dbRecordEvent(reg, campaignId, "escalation",
          %* {"reason": "iteration cap reached",
              "completedRounds": completed, "maxIterations": cap})
        let status = dbCampaignStatus(reg, campaignId)
        if status in ["active", "pending"]:
          dbTransition(reg, campaignId, "escalated",
                       "iteration cap reached")
      except DbError as e:
        error "iteration-cap escalation failed (tick_ready path)",
          campaignId = campaignId, reason = e.msg
      return
    let delay = reg.autoTickDelayMs
    info "auto-tick: scheduling", campaignId = campaignId, delayMs = delay
    asyncCheck scheduleAutoTick(reg, campaignId, delay)
  of "converged":
    try:
      let status = dbCampaignStatus(reg, campaignId)
      if status in ["active", "pending"]:
        dbTransition(reg, campaignId, "converged",
                     marker.blockerSummary)
    except DbError as e:
      error "transition to converged failed",
        campaignId = campaignId, reason = e.msg
  of "escalated":
    try:
      let status = dbCampaignStatus(reg, campaignId)
      if status in ["active", "pending"]:
        dbTransition(reg, campaignId, "escalated",
                     marker.blockerSummary)
    except DbError as e:
      error "transition to escalated failed",
        campaignId = campaignId, reason = e.msg
  of "stopped":
    try:
      let status = dbCampaignStatus(reg, campaignId)
      if status in ["active", "pending"]:
        dbTransition(reg, campaignId, "stopped",
                     marker.blockerSummary)
    except DbError as e:
      error "transition to stopped failed",
        campaignId = campaignId, reason = e.msg
  of "needs_human":
    try:
      discard dbRecordEvent(reg, campaignId, "escalation",
        %* {"reason": "needs_human",
            "blockerSummary": marker.blockerSummary})
    except DbError as e:
      warn "needs_human escalation event insert failed",
        campaignId = campaignId, reason = e.msg
  else:
    # Unknown / missing marker — soft warning.
    try:
      discard dbRecordEvent(reg, campaignId, "note",
        %* {"reason": "orchestrator_status_missing",
            "rawMarker": marker.rawMarker})
    except DbError as e:
      warn "orchestrator_status missing-marker note insert failed",
        campaignId = campaignId, reason = e.msg

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

  # Phase 3: assemble and emit the first prompt.  Stream SSE.
  let prelude = cmpSseHeader()
  if not await trySend(req.client, prelude):
    return

  # CMP-M2.1 — assign the baseline round number via the routine so we
  # don't hard-code ``round=1`` (which would collide with the first
  # ``campaign tick`` if a start/tick race ever happens).  For a fresh
  # campaign this returns 1; for an idempotent re-start of an existing
  # campaign it returns ``count(round_complete) + 1``.
  let baseRound = dbNextRound(reg, campaignId)

  let orchestratorPrompt = reloadOrchestratorPrompt(reg)
  let promptInputs = CampaignPromptInputs(
    docPath: body.docPath,
    docBody: body.body,
    briefs: body.briefs,
    latestReport: body.latestReport,
    round: baseRound,
  )
  let firstPrompt = assembleFirstPrompt(orchestratorPrompt, promptInputs)
  info "campaign start streaming",
    campaignId = campaignId, sessionId = sessionId,
    promptBytes = firstPrompt.len, round = baseRound

  let extra = %* {"campaignId": campaignId, "round": baseRound}
  let res = await streamPromptToSocket(reg, sessionId, campaignId,
    "round_complete", firstPrompt, extra, req.client)
  try: req.client.close() except CatchableError: discard
  await applyOrchestratorStatusAfterRound(reg, campaignId, res)

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

  # CMP-M2.1 — claim the next round number via the
  # ``next_campaign_round`` routine (migration 007).  The routine
  # counts ``round_complete`` events server-side so concurrent ticks
  # can't double-claim a round number.
  var round = 1
  try:
    round = dbNextRound(reg, campaignId)
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

  # CMP-M4 — drain the operator-intervention surfaces atomically before
  # assembling the prompt: ACP-queue texts + tracked event-id list.  If
  # the prompt-send fails we re-queue both so the next tick replays the
  # injections in their original order.
  let injectionTexts = drainCampaignSessionInjections(reg, campaignId, sessionId)
  let injectionEventIds = reg.takePendingInjectionEventIds(campaignId)
  let docBody = readCampaignDocBodyParsed(reg, campaignId)
  info "handleTick: drained injections", campaignId = campaignId,
    textsCount = injectionTexts.len,
    eventIdsCount = injectionEventIds.len,
    sessionId = sessionId

  let prelude = cmpSseHeader()
  if not await trySend(req.client, prelude):
    # The HTTP socket died before we could even send the SSE prelude.
    # Re-queue the drained injections — the next tick is going to want
    # them, and an interrupted prompt-send must not silently lose user
    # text.
    reinjectCampaignSession(reg, campaignId, sessionId, injectionTexts)
    reg.restorePendingInjectionEventIds(campaignId, injectionEventIds)
    return
  let promptText = assembleTickPromptWithInjections(
    campaignId, round, injectionTexts, docBody)
  let res = await streamPromptToSocket(reg, sessionId, campaignId,
    "round_complete", promptText, extra, req.client)
  try: req.client.close() except CatchableError: discard

  if res.isError:
    # Prompt-send failed past the prelude.  Re-queue so the next tick
    # picks up the same injections — we already published a
    # ``round_started`` row carrying ``round``, but the orchestrator
    # never saw the injection block, so treating it as consumed would
    # silently lose operator intent.
    reinjectCampaignSession(reg, campaignId, sessionId, injectionTexts)
    reg.restorePendingInjectionEventIds(campaignId, injectionEventIds)
  elif injectionEventIds.len > 0:
    # Successful tick → ack the drained operator-injection events up to
    # the last one.  ``acknowledge_campaign_events`` flips every
    # ``acknowledged=FALSE`` row whose ``occurred_at`` is at or before
    # the anchor event's ``occurred_at``, so passing the last (newest)
    # id catches every injection in the drained batch.
    let upto = injectionEventIds[injectionEventIds.high]
    try:
      let n = dbAcknowledgeEvents(reg, campaignId, upto)
      info "campaign tick: ack rows flipped", campaignId = campaignId,
        uptoEventId = upto, flipped = n
    except DbError as e:
      warn "campaign tick: ack injection events failed",
        campaignId = campaignId, reason = e.msg

  await applyOrchestratorStatusAfterRound(reg, campaignId, res)

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
  # CMP-M2.1 — cancel any pending auto-tick before tearing down the
  # session.  We bump the generation counter; the sleeping
  # ``scheduleAutoTick`` coroutine compares it on wake-up and bails.
  discard reg.bumpAutoTickGen(campaignId)

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

proc sha256OfStringShellOut(s: string): string =
  ## Stream ``s`` through ``shasum -a 256`` / ``sha256sum`` and return
  ## the lowercase-hex digest.  Mirrors the pattern used by
  ## :proc:`manifest_hash.sha256Hex` so refreshed doc shas have the same
  ## format as the doc_sha the CLI's ``campaign start`` writes
  ## (``isonim-review campaign start`` uses ``shasum -a 256`` over the
  ## file bytes).
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
  ## CMP-M4 — POST /api/campaign/inject {campaignId, text}
  ##
  ## Push an operator-injection text onto the per-session ACP queue
  ## via the AgentClient wrapper, append a ``note`` event tagged
  ## ``kind=operator_injection`` so the audit log keeps the user's
  ## intent durable, and register the event id with the in-memory
  ## per-campaign pending-injection list so the next tick can ack it
  ## after a successful prompt-send.
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

  # Push onto the ACP queue.  The ``AgentClient`` injection closure was
  # wired by ``newAcpClient`` at session creation time (see
  # ``nim-acp/src/nim_acp/client.nim::newAcpClient``); ``injectPrompt``
  # is the public surface in ``nim-agents``.
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
  # captures it before we return.  ``acknowledged`` stays FALSE until
  # the next round's tick prompt actually drains and folds it in.
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
  ##
  ## The doc body itself flows into the next tick's prompt via
  ## :proc:`readCampaignDocBodyParsed`, not this route — this route is
  ## the bookkeeping side (so the audit log records the SHA bump and
  ## the orchestrator's tick prompt knows when the operator edited the
  ## file).
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
