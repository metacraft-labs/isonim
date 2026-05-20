## REV-M6 — agent dispatcher.
##
## Glues the reviewer pipeline together end-to-end:
##
##   1. Load the run + captures + brief content from the DB / git.
##   2. Resolve the brief markdown body at the run's manifest pin
##      (``brief_at_revision.nim``).
##   3. Assemble a prompt from the
##      ``prompts/design_review/reviewer_prompt.template`` file (with
##      ``$brief``, ``$captures``, ``$scoring_rubric`` placeholders).
##   4. Invoke the configured ``AgentBackend`` to get the reviewer
##      output (a markdown file with YAML frontmatter on top).
##   5. Persist the raw output under
##      ``<reviewStorePath>/reports/<runId>/<agentName>.md``.
##   6. Parse the frontmatter and project it via
##      ``toParsedScoresJsonb``.
##   7. Call ``design_review.record_agent_report`` (idempotent on the
##      ``(run_id, agent_name, agent_version)`` natural key) then
##      ``design_review.finish_run``.
##
## *Backends.*  Two are shipped: ``claudeCodeBackend`` (spawns
## ``claude-code`` on PATH and feeds the prompt + PNGs as args) and
## ``cannedBackend`` (reads a fixture file verbatim — used by every
## CI test so the agent invocation is deterministic).

import std/[httpclient, json, os, osproc, sequtils, streams, strformat,
            strutils]

import db_connector/db_postgres

import ./brief_format
import ./brief_at_revision
import ./log_setup
import ./reviewer_output
import ./db

logScope:
  topics = "agent"

type
  AgentBackend* = proc(prompt: string; pngPaths: seq[string]): string {.gcsafe.}

  ReviewConfigLite* = object
    ## Minimal config view the dispatcher needs.  Mirrors fields the
    ## CLI loads from ``~/.isonim/config.toml`` but is passed in
    ## directly so the dispatcher stays decoupled from the CLI module.
    workspaceRoot*: string
    reviewStorePath*: string
    promptTemplatePath*: string
      ## Path to ``prompts/design_review/reviewer_prompt.template``.
      ## When empty the dispatcher falls back to the on-disk template
      ## under the current working dir.

  RunNotReadyForReviewError* = object of CatchableError
  AgentDispatchError* = object of CatchableError

# --------------------------------------------------------------------------- #
#  Backends.
# --------------------------------------------------------------------------- #

proc legacyClaudeCodeSubprocessBackend*(): AgentBackend
    {.deprecated: "prefer daemonBackend(daemonUrl) — Phase B routed claude-code through the daemon's /api/agent/* endpoints".} =
  ## Spawn whatever ``claude-code`` binary is on PATH.  Feeds the
  ## prompt as a positional arg and every PNG path as ``--image
  ## <path>``.  Kept as a fallback for callers that explicitly want to
  ## bypass the daemon (e.g. an offline CI box).  Phase B made
  ## ``daemonBackend`` the default; this proc only stays because removing
  ## it would break ``run-review --agent-backend claude-code`` users
  ## who haven't migrated yet.
  result = proc(prompt: string; pngPaths: seq[string]): string {.gcsafe.} =
    let bin = findExe("claude-code")
    if bin.len == 0:
      raise newException(AgentDispatchError,
        "legacyClaudeCodeSubprocessBackend: 'claude-code' not on PATH; install or use --agent-backend daemon|canned")
    var args: seq[string] = @[]
    for p in pngPaths:
      args.add "--image"
      args.add p
    args.add prompt
    let p = startProcess(bin, args = args, options = {poUsePath})
    defer: p.close()
    let stdoutRead = p.outputStream.readAll()
    let exitCode = p.waitForExit()
    if exitCode != 0:
      raise newException(AgentDispatchError,
        "legacyClaudeCodeSubprocessBackend: claude-code failed (" & $exitCode & ")")
    return stdoutRead

proc claudeCodeBackend*(): AgentBackend
    {.deprecated: "renamed to legacyClaudeCodeSubprocessBackend; prefer daemonBackend(daemonUrl)".} =
  legacyClaudeCodeSubprocessBackend()

const DefaultDaemonBackendHttpTimeoutMs* = 1_800_000
  ## Default HTTP read timeout (ms) for :proc:`daemonBackend` when the
  ## caller doesn't override it.  Matches the nim-acp transport's
  ## ``DefaultNativeStdioHardDeadlineMs`` so the CLI ➝ daemon HTTP layer
  ## and the daemon ➝ ACP agent stdio layer fail at the same overall
  ## wall-clock budget (30 min).  See follow-up: the historical
  ## hard-coded 60_000 ms here was the second of two stacked timeouts
  ## that killed image-heavy real-codex reviews mid-stream.

proc daemonBackend*(daemonUrl: string;
                    sessionId = "";
                    httpTimeoutMs: int = DefaultDaemonBackendHttpTimeoutMs):
                      AgentBackend =
  ## Phase B — route reviewer prompts through the editor daemon.
  ##
  ## The returned backend POSTs the prompt at
  ## ``<daemonUrl>/api/agent/prompts`` and consumes the SSE stream until
  ## ``event: end``.  All ``agent_message_chunk`` text payloads are
  ## concatenated into one string and returned — REV-M6's reviewer
  ## pipeline still expects one whole markdown blob, not a stream.
  ##
  ## When ``sessionId`` is empty the backend mints a fresh session via
  ## ``POST /api/agent/sessions`` first; otherwise the caller's session
  ## id is reused (useful for stateful reviewer flows).
  ##
  ## ``httpTimeoutMs`` bounds the per-request read budget.  Default is
  ## :const:`DefaultDaemonBackendHttpTimeoutMs` (30 min), matching the
  ## nim-acp transport's hard wall-clock cap so the two layers fail at
  ## the same overall budget instead of stacking two short timeouts
  ## that abort legitimate image-heavy review prompts before the agent
  ## emits its first byte.
  ##
  ## PNG attachments ride alongside the text prompt as a ``pngPaths``
  ## array of absolute filesystem paths.  The daemon (which runs on the
  ## same host) reads each file, base64-encodes the bytes, and forwards
  ## them as ACP ``image`` content blocks.  Sending paths rather than
  ## inline base64 keeps HTTP request bodies lean even when a review
  ## carries 7+ PNG attachments (~1.7 MB encoded).
  let url = daemonUrl
  let pinnedSession = sessionId
  let timeout = httpTimeoutMs
  result = proc(prompt: string; pngPaths: seq[string]):
      string {.gcsafe.} =
    var resolvedSession = pinnedSession
    let httpClient = newHttpClient(timeout = timeout)
    defer: httpClient.close()
    if resolvedSession.len == 0:
      let headers = newHttpHeaders([("Content-Type", "application/json")])
      let resp = httpClient.request(url & "/api/agent/sessions",
                                    httpMethod = HttpPost,
                                    body = "{}", headers = headers)
      let status = parseInt(resp.status.split(' ')[0])
      if status != 200:
        raise newException(AgentDispatchError,
          "daemonBackend: POST /api/agent/sessions returned " &
          $status & ": " & resp.body)
      resolvedSession = parseJson(resp.body){"sessionId"}.getStr("")
      if resolvedSession.len == 0:
        raise newException(AgentDispatchError,
          "daemonBackend: daemon returned empty sessionId; body=" &
          resp.body)
    var pngPathsJson = newJArray()
    for p in pngPaths:
      pngPathsJson.add(%p)
    let body = $(%* {
      "sessionId": resolvedSession,
      "messages": [{
        "role": "user",
        "content": [{"type": "text", "text": prompt}],
      }],
      "pngPaths": pngPathsJson,
    })
    let headers = newHttpHeaders([
      ("Content-Type", "application/json"),
      ("Accept", "text/event-stream"),
    ])
    let resp = httpClient.request(url & "/api/agent/prompts",
                                  httpMethod = HttpPost,
                                  body = body, headers = headers)
    let status = parseInt(resp.status.split(' ')[0])
    if status != 200:
      raise newException(AgentDispatchError,
        "daemonBackend: POST /api/agent/prompts returned " &
        $status & ": " & resp.body)
    var collected = ""
    for rawEvent in resp.body.split("\n\n"):
      if rawEvent.len == 0: continue
      var eventType = "session/update"
      var dataPayload = ""
      for line in rawEvent.split('\n'):
        if line.startsWith("event:"):
          eventType = line[6 .. ^1].strip()
        elif line.startsWith("data:"):
          if dataPayload.len > 0: dataPayload.add "\n"
          dataPayload.add line[5 .. ^1].strip(leading = true,
                                              trailing = false)
      if eventType == "end" or eventType == "error":
        continue
      if dataPayload.len == 0: continue
      try:
        let node = parseJson(dataPayload)
        let update = node{"update"}
        if update{"sessionUpdate"}.getStr("") == "agent_message_chunk":
          let content = update{"content"}
          if content != nil and content{"type"}.getStr("") == "text":
            collected.add content{"text"}.getStr("")
      except JsonParsingError:
        debug "daemonBackend: skipping malformed SSE data frame"
    info "daemonBackend collected reply", session = resolvedSession,
      bytes = collected.len
    return collected

proc cannedBackend*(outputPath: string): AgentBackend =
  ## Fixture backend: returns ``outputPath``'s contents verbatim,
  ## ignoring the prompt and PNG list.  Every CI test uses this so the
  ## review pipeline is end-to-end deterministic.
  let path = outputPath
  result = proc(prompt: string; pngPaths: seq[string]): string {.gcsafe.} =
    if not fileExists(path):
      raise newException(AgentDispatchError,
        "cannedBackend: fixture file not found: " & path)
    return readFile(path)

# --------------------------------------------------------------------------- #
#  Prompt assembly.
# --------------------------------------------------------------------------- #

const DefaultReviewerPromptTemplate = """
You are reviewing the round of design captures listed below.

## Brief

$brief

## Captures

$captures

## Scoring rubric

$scoring_rubric

Produce a single markdown file with YAML frontmatter on top following the
reviewer-output schema (reviewerSchemaVersion: 1, briefId, runId, agentName,
agentVersion, manifestHash, capturedAt, overall, previews, notes).  The body
below the second `---` is free-form prose summarising your findings.
"""

proc loadPromptTemplate(cfg: ReviewConfigLite): string =
  if cfg.promptTemplatePath.len > 0 and fileExists(cfg.promptTemplatePath):
    return readFile(cfg.promptTemplatePath)
  let fallback = getCurrentDir() / "prompts" / "design_review" /
                 "reviewer_prompt.template"
  if fileExists(fallback):
    return readFile(fallback)
  return DefaultReviewerPromptTemplate

proc renderScoringRubric(brief: Brief): string =
  result = ""
  for d in brief.scoringDimensions:
    result.add(fmt"- **{d.id}** ({d.label}, weight {d.weight}) — score range " &
               fmt"{d.scaleMin}..{d.scaleMax}.")
    result.add("\n")

proc renderCapturesIndex(captures: seq[tuple[previewId, pngPath: string]]): string =
  result = ""
  for c in captures:
    result.add(fmt"- {c.previewId}: {c.pngPath}")
    result.add("\n")

proc renderPrompt(tpl, briefBody, capturesIdx, rubric: string): string =
  result = tpl
  result = result.replace("$brief", briefBody)
  result = result.replace("$captures", capturesIdx)
  result = result.replace("$scoring_rubric", rubric)

# --------------------------------------------------------------------------- #
#  Run + captures fetch.
# --------------------------------------------------------------------------- #

type
  RunCaptureRow = object
    previewId*: string
    backend*: string
    viewportLabel*: string
    pngSha256*: string
    pngPath*: string

  RunHeader = object
    briefId*: string
    manifestHash*: string
    status*: string

proc fetchRunJson(db: ReviewDb; runId: string): JsonNode =
  ## Goes through ``design_review.fetch_run`` (SECURITY DEFINER) so the
  ## app role can read everything without direct table SELECT grants.
  let escRun = runId.replace("'", "''")
  let raw =
    try:
      db.conn.getValue(sql(
        "SELECT design_review.fetch_run('" & escRun & "'::uuid)::text"))
    except DbError as e:
      if e.msg.contains("does not exist"):
        raise newException(AgentDispatchError,
          "dispatchReview: run not found: " & runId)
      raise
  if raw.len == 0:
    raise newException(AgentDispatchError,
      "dispatchReview: run not found: " & runId)
  parseJson(raw)

proc fetchRunHeader(db: ReviewDb; runId: string): RunHeader =
  let node = fetchRunJson(db, runId)
  result.briefId      = node["brief_id"].getStr
  result.manifestHash = node["manifest_hash"].getStr
  result.status       = node["status"].getStr

proc fetchCaptures(db: ReviewDb; runId: string): seq[RunCaptureRow] =
  result = @[]
  let node = fetchRunJson(db, runId)
  if "captures" notin node: return
  for c in node["captures"]:
    result.add(RunCaptureRow(
      previewId: c["preview_id"].getStr,
      backend: c["backend"].getStr,
      viewportLabel: c["viewport_label"].getStr,
      pngSha256: c["png_sha256"].getStr,
      pngPath: c["png_path"].getStr))

# --------------------------------------------------------------------------- #
#  DB write helpers.
# --------------------------------------------------------------------------- #

proc recordAgentReport(db: ReviewDb;
                       runId, agentName, agentVersion,
                       rawOutputPath: string;
                       parsedScores: JsonNode): string =
  ## Calls ``design_review.record_agent_report``.  Returns the report
  ## id.  Translates ``guard_run_status: ... not in allowed set ...``
  ## into ``RunNotReadyForReviewError`` so callers can distinguish
  ## ill-timed dispatches from other failures.
  let escRun = runId.replace("'", "''")
  let escName = agentName.replace("'", "''")
  let escVer = agentVersion.replace("'", "''")
  let escPath = rawOutputPath.replace("'", "''")
  let escScores = ($parsedScores).replace("'", "''")
  try:
    return db.conn.getValue(sql(
      "SELECT design_review.record_agent_report('" & escRun &
      "'::uuid, '" & escName & "', '" & escVer & "', '" & escPath &
      "', '" & escScores & "'::jsonb)"))
  except DbError as e:
    if e.msg.contains("not in allowed set"):
      raise newException(RunNotReadyForReviewError,
        "run_not_ready_for_review: " & e.msg)
    raise

proc finishRun(db: ReviewDb; runId: string) =
  ## Calls ``design_review.finish_run``.  Swallows ``not in allowed
  ## set`` errors so a concurrent dispatcher that already transitioned
  ## the run to ``complete`` does not crash us on the second invocation
  ## — the run is already complete, which is the post-condition we
  ## want.
  let escRun = runId.replace("'", "''")
  try:
    discard db.conn.getValue(sql(
      "SELECT design_review.finish_run('" & escRun & "'::uuid)"))
  except DbError as e:
    if e.msg.contains("not in allowed set"):
      return
    raise

# --------------------------------------------------------------------------- #
#  Top-level orchestration.
# --------------------------------------------------------------------------- #

proc reportsDirFor(reviewStorePath, runId: string): string =
  result = reviewStorePath / "reports" / runId

proc writeRawOutput(reviewStorePath, runId, agentName, agentVersion,
                    contents: string): string =
  ## Path layout: ``<reviewStorePath>/reports/<runId>/<agentName>.md``
  ## for the first writer; concurrent writers with a different
  ## ``agentVersion`` land at
  ## ``<reviewStorePath>/reports/<runId>/<agentName>@<agentVersion>.md``.
  ##
  ## Concurrency: we attempt an O_EXCL create of the primary path
  ## via a tmpfile-+-tryMoveFile dance.  If the primary path is taken
  ## by another writer, fall back to the version-disambiguated path.
  let dir = reportsDirFor(reviewStorePath, runId)
  createDir(dir)
  let primary = dir / (agentName & ".md")
  let versioned = dir / (agentName & "@" & agentVersion & ".md")
  # Write to a private tmp file first so partial reads can't see a
  # truncated reviewer output.
  let tmpPath = dir / (".tmp-" & agentName & "@" & agentVersion & "-" &
                       $getCurrentProcessId() & ".md")
  writeFile(tmpPath, contents)
  if not fileExists(primary):
    try:
      moveFile(tmpPath, primary)
      return primary
    except OSError:
      discard
  # Primary was claimed by a concurrent writer — use the versioned
  # sibling.  ``moveFile`` overwrites if necessary; two writers with
  # the same agent_version is impossible because the DB's UNIQUE
  # ``(run_id, agent_name, agent_version)`` constraint prevents it.
  moveFile(tmpPath, versioned)
  return versioned

proc dispatchReview*(runId: string; cfg: ReviewConfigLite; brief: Brief;
                     db: ReviewDb;
                     backend: AgentBackend;
                     agentName, agentVersion: string;
                     dryRun: bool = false): string =
  ## End-to-end review for one run.  Returns:
  ##
  ##   * the assembled prompt string when ``dryRun = true``;
  ##   * otherwise the ``agent_reports.report_id`` UUID.
  ##
  ## Idempotency: calling this twice with the same
  ## ``(runId, agentName, agentVersion)`` is a no-op on the second
  ## call — the DB routine ``record_agent_report`` enforces the
  ## natural key and returns the existing report id.

  if backend == nil:
    raise newException(AgentDispatchError,
      "dispatchReview: backend must not be nil")
  if agentName.len == 0:
    raise newException(AgentDispatchError,
      "dispatchReview: agentName must be non-empty")
  if agentVersion.len == 0:
    raise newException(AgentDispatchError,
      "dispatchReview: agentVersion must be non-empty")

  let runJson = fetchRunJson(db, runId)
  let status = runJson["status"].getStr

  # Idempotency short-circuit: if a report already exists under our
  # natural key, return its id without re-invoking the backend.  The
  # DB routine ``record_agent_report`` would also dedup, but that
  # path requires status in (capture_complete | review_pending |
  # reviewed) — re-running against an already-``complete`` run would
  # otherwise raise ``run_not_ready_for_review`` even though the
  # report is sitting right there.
  if "reports" in runJson:
    for r in runJson["reports"]:
      if r["agent_name"].getStr == agentName and
         r["agent_version"].getStr == agentVersion:
        return r["report_id"].getStr

  if status notin ["capture_complete", "review_pending", "reviewed"]:
    raise newException(RunNotReadyForReviewError,
      "run_not_ready_for_review: run " & runId & " is in status '" &
      status & "'; review can only be dispatched against runs in " &
      "capture_complete / review_pending / reviewed")

  let header = RunHeader(briefId: runJson["brief_id"].getStr,
                         manifestHash: runJson["manifest_hash"].getStr,
                         status: status)

  let captures = fetchCaptures(db, runId)
  if captures.len == 0:
    raise newException(AgentDispatchError,
      "dispatchReview: run " & runId & " has no captures recorded")

  # Brief content at the manifest pin.
  let briefBody = briefAtRevision(
    cfg.workspaceRoot, header.manifestHash, header.briefId)

  let tpl = loadPromptTemplate(cfg)
  let capturesIdx = renderCapturesIndex(
    captures.mapIt((previewId: it.previewId, pngPath: it.pngPath)))
  let rubric = renderScoringRubric(brief)
  let prompt = renderPrompt(tpl, briefBody, capturesIdx, rubric)

  if dryRun:
    return prompt

  let pngPaths = captures.mapIt(it.pngPath)
  let rawOutput = backend(prompt, pngPaths)

  let rawPath = writeRawOutput(
    cfg.reviewStorePath, runId, agentName, agentVersion, rawOutput)

  # Parse the reviewer output and project it into JSONB.
  var parsed: ReviewerOutput
  try:
    parsed = parseReviewerOutput(rawPath, brief)
  except ReviewerOutputError as e:
    raise newException(AgentDispatchError,
      "dispatchReview: reviewer output rejected: " & e.msg)

  let parsedScores = toParsedScoresJsonb(parsed)
  let reportId = recordAgentReport(db, runId, agentName, agentVersion,
                                   rawPath, parsedScores)

  # Move the run to ``complete`` — record_agent_report itself does
  # capture_complete → review_pending, and finish_run does
  # review_pending → complete.  Both transitions are guarded by the
  # DB routines so re-invoking against an already-complete run is a
  # silent no-op (record_agent_report returns the same id, finish_run
  # is a status-transition gate that refuses already-complete runs).
  let refreshed = fetchRunHeader(db, runId)
  if refreshed.status in ["review_pending", "reviewed"]:
    finishRun(db, runId)

  return reportId
