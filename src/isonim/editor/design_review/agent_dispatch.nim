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

import std/[json, os, osproc, sequtils, streams, strformat, strutils]

import db_connector/db_postgres

import ./brief_format
import ./brief_at_revision
import ./reviewer_output
import ./db

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

proc claudeCodeBackend*(): AgentBackend =
  ## Spawn whatever ``claude-code`` binary is on PATH.  Feeds the
  ## prompt as a positional arg and every PNG path as ``--image
  ## <path>``.  Simple enough for now — REV-M11+ can sharpen it
  ## (streaming, retries, etc.).
  result = proc(prompt: string; pngPaths: seq[string]): string {.gcsafe.} =
    let bin = findExe("claude-code")
    if bin.len == 0:
      raise newException(AgentDispatchError,
        "claudeCodeBackend: 'claude-code' not on PATH; install or use --agent-backend canned")
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
        "claudeCodeBackend: claude-code failed (" & $exitCode & ")")
    return stdoutRead

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
