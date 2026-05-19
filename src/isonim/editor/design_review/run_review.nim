## REV-M6 — small CLI-facing wrapper around ``agent_dispatch``.
##
## Mirrors the structural pattern of ``capture.nim``: the heavy
## lifting lives in a domain module (``agent_dispatch.nim``); this
## module just resolves the brief from the project's brief index and
## hands the pieces to ``dispatchReview``.

import std/[json, os, strutils, tables]

import db_connector/db_postgres

import ./brief_index
import ./agent_dispatch
import ./db

type
  RunReviewError* = object of CatchableError

proc resolveBriefsDir*(projectPath: string): string =
  if projectPath.len == 0: return ""
  let direct = projectPath / "briefs"
  if dirExists(direct): return direct
  projectPath

proc lookupRunBriefId(db: ReviewDb; runId: string): string =
  ## Goes through ``design_review.fetch_run`` (SECURITY DEFINER) so the
  ## app role does not need a direct SELECT grant on the ``runs`` table.
  let escRun = runId.replace("'", "''")
  let raw =
    try:
      db.conn.getValue(sql(
        "SELECT design_review.fetch_run('" & escRun & "'::uuid)::text"))
    except DbError:
      return ""
  if raw.len == 0: return ""
  let node = parseJson(raw)
  if "brief_id" in node: node["brief_id"].getStr else: ""

proc runReview*(runId, projectPath, workspaceRoot, reviewStorePath,
                promptTemplatePath, agentName, agentVersion: string;
                backend: AgentBackend; db: ReviewDb;
                dryRun: bool = false): string =
  ## Convenience entry point used by the CLI.  Reads the brief index
  ## fresh from disk (so the dispatcher works without a long-running
  ## editor process), then calls ``dispatchReview``.
  ##
  ## *Why we accept ``projectPath``.*  The dispatcher needs the brief
  ## TYPE information (``scoringDimensions``, ``coversPreviews``) to
  ## validate the reviewer output.  The historical brief *body* comes
  ## from git at the manifest pin, but the typed structure is read
  ## from the current project — REV-M5 already established that the
  ## brief schema is migration-compatible (extras preserved), so a
  ## type-level read off the working tree is safe.
  let briefsDir = resolveBriefsDir(projectPath)
  if briefsDir.len == 0 or not dirExists(briefsDir):
    raise newException(RunReviewError,
      "runReview: briefs directory not found: '" & projectPath & "'")

  let briefId = lookupRunBriefId(db, runId)
  if briefId.len == 0:
    raise newException(RunReviewError,
      "runReview: run not found: " & runId)

  let idx = buildBriefIndex(briefsDir)
  if briefId notin idx.byBriefId:
    raise newException(RunReviewError,
      "runReview: brief '" & briefId & "' not in " & briefsDir)
  let brief = idx.byBriefId[briefId]

  let cfg = ReviewConfigLite(
    workspaceRoot: workspaceRoot,
    reviewStorePath: reviewStorePath,
    promptTemplatePath: promptTemplatePath)

  return dispatchReview(runId, cfg, brief, db, backend,
                        agentName, agentVersion, dryRun)
