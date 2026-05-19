## REV-M6 — agent dispatcher tests.
##
## Drive ``dispatchReview`` end-to-end against a real PostgreSQL via
## ``PgFixture`` and a deterministic canned backend.  No mocks at the
## DB boundary; the agent backend is the only fixture surface, and
## that's the documented contract (REV-M6's *Out of scope*).

import std/[os, osproc, strutils, times, unittest]

import db_connector/db_postgres

import isonim/editor/design_review/agent_dispatch
import isonim/editor/design_review/brief_format
import isonim/editor/design_review/db as dr_db
import isonim/editor/design_review/manifest_hash
import isonim/editor/types

import helpers/design_review_pg_fixture

# --------------------------------------------------------------------------- #
#  Workspace + brief fixtures.
# --------------------------------------------------------------------------- #

proc runOrFail(cmd: string; cwd: string): string =
  let res = execCmdEx(cmd, workingDir = cwd)
  if res.exitCode != 0:
    raise newException(IOError, cmd & " failed (" & $res.exitCode & "):\n" &
                       res.output)
  res.output

proc gitInit(repoPath: string) =
  createDir(repoPath)
  discard runOrFail("git init -q -b main && " &
                    "git config user.email 'test@test' && " &
                    "git config user.name 'tester' && " &
                    "git config commit.gpgsign false", repoPath)

proc gitCommit(repoPath, message: string): string =
  discard runOrFail("git add -A && git commit -q -m '" & message & "'",
                    repoPath)
  return runOrFail("git rev-parse HEAD", repoPath).strip()

proc writeManifest(workspaceRoot, repoName, sha: string) =
  let repoDir = workspaceRoot / ".repo"
  createDir(repoDir)
  writeFile(repoDir / "manifest.xml",
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<manifest>\n" &
    "  <project name=\"" & repoName & "\" path=\"" & repoName &
    "\" revision=\"" & sha & "\"/>\n</manifest>\n")

const FixtureBriefYaml = """---
briefId: render.fixture
schemaVersion: 1
kind: render
title: fixture
coversPreviews:
  - storyRef: { group: G, name: N, kind: page, index: 0 }
    backends: [web]
captureViewports:
  - { width: 32, height: 32, label: tablet }
reviewerSchemaVersion: 1
scoringDimensions:
  - { id: a, label: A, weight: 1.0, scale: { min: 0, max: 10 } }
---
brief body fixture
"""

proc tmpWorkspaceWithBrief(suffix: string): tuple[ws, manifestHash: string;
                                                  brief: Brief] =
  let ws = getTempDir() / ("isonim_ad_" & suffix & "_" & $epochTime().int)
  removeDir(ws)
  createDir(ws)
  let repoA = ws / "repo-a"
  gitInit(repoA)
  createDir(repoA / "briefs" / "render")
  writeFile(repoA / "briefs" / "render" / "fixture.md", FixtureBriefYaml)
  let sha = gitCommit(repoA, "initial brief")
  writeManifest(ws, "repo-a", sha)
  let hash = captureManifestHash(ws)
  # Also write the brief under the workspace root's working-tree
  # briefs/ dir so the dispatcher's type-level brief read finds it.
  createDir(ws / "briefs" / "render")
  writeFile(ws / "briefs" / "render" / "fixture.md", FixtureBriefYaml)
  let brief = parseBrief(ws / "briefs" / "render" / "fixture.md")
  result = (ws, hash, brief)

# --------------------------------------------------------------------------- #
#  DB helpers (raw SQL, mirroring the capture module's pattern).
# --------------------------------------------------------------------------- #

proc startRunSql(db: ReviewDb; briefId, manifestHash, who: string): string =
  let escB = briefId.replace("'", "''")
  let escH = manifestHash.replace("'", "''")
  let escW = who.replace("'", "''")
  db.conn.getValue(sql(
    "SELECT design_review.start_run('" & escB & "', '" & escH &
    "', '" & escW & "')"))

proc recordCaptureSql(db: ReviewDb; runId, previewId, backend, vp,
                      sha, path: string; w, h: int): string =
  let escRun = runId.replace("'", "''")
  let escPv  = previewId.replace("'", "''")
  let escBe  = backend.replace("'", "''")
  let escVp  = vp.replace("'", "''")
  let escSha = sha.replace("'", "''")
  let escPath = path.replace("'", "''")
  db.conn.getValue(sql(
    "SELECT design_review.record_capture('" & escRun &
    "'::uuid,'" & escPv & "','" & escBe & "','" & escVp & "','" &
    escSha & "','" & escPath & "'," & $w & "," & $h & ")"))

proc finishCapturesSql(db: ReviewDb; runId: string) =
  let escRun = runId.replace("'", "''")
  discard db.conn.getValue(sql(
    "SELECT design_review.finish_captures('" & escRun & "'::uuid)"))

proc runStatusSql(conn: DbConn; runId: string): string =
  ## The app role lacks direct SELECT on ``runs`` — pass a migrator
  ## connection.
  let escRun = runId.replace("'", "''")
  conn.getValue(sql(
    "SELECT status FROM design_review.runs WHERE run_id = '" &
    escRun & "'::uuid"))

# --------------------------------------------------------------------------- #
#  Reviewer-output fixture builder.
# --------------------------------------------------------------------------- #

proc reviewerOutputFor(brief: Brief; runId, manifestHash: string;
                       agentName, agentVersion: string;
                       score: int = 8;
                       status: string = "pass"): string =
  let previewId = canonicalPreviewId(brief.coversPreviews[0].storyRef, pbWeb)
  let overallStatus = status
  result = "---\n"
  result.add "reviewerSchemaVersion: 1\n"
  result.add "briefId: " & brief.briefId & "\n"
  result.add "runId: " & runId & "\n"
  result.add "agentName: " & agentName & "\n"
  result.add "agentVersion: " & agentVersion & "\n"
  result.add "manifestHash: " & manifestHash & "\n"
  result.add "capturedAt: 2026-05-19T11:32:04Z\n"
  result.add "overall:\n  score: " & $score & ".0\n  status: " & overallStatus & "\n"
  result.add "previews:\n"
  result.add "  \"" & previewId & "\":\n"
  result.add "    scores: { a: " & $score & " }\n"
  result.add "    status: " & overallStatus & "\n"
  result.add "    defects: []\n"
  result.add "---\nbody\n"

proc writeCanned(path, contents: string) =
  createDir(path.parentDir)
  writeFile(path, contents)

# --------------------------------------------------------------------------- #
#  Tests.
# --------------------------------------------------------------------------- #

suite "REV-M6 agent dispatch":

  test "test_record_agent_report_idempotent_on_natural_key":
    let pgf = newPgFixture()
    defer: pgf.shutdown()
    let (ws, hash, brief) = tmpWorkspaceWithBrief("idem")
    defer: removeDir(ws)

    let appConn = open("", "design_review_app", "",
                       "host=127.0.0.1 port=" & $pgf.port &
                       " dbname=isonim_design_review user=design_review_app")
    let db = ReviewDb(conn: appConn)
    defer: db.close()
    # Migrator connection used by the tests to SELECT from base tables
    # (the app role is restricted to EXECUTE on the routines).
    let migConn = open("", "design_review_migrator", "",
                       "host=127.0.0.1 port=" & $pgf.port &
                       " dbname=isonim_design_review user=design_review_migrator")
    defer: migConn.close()

    let runId = startRunSql(db, "render.fixture", hash, "tester")
    let previewId = canonicalPreviewId(brief.coversPreviews[0].storyRef, pbWeb)
    discard recordCaptureSql(db, runId, previewId, "web", "tablet",
                             "sha1", "/tmp/x.png", 32, 32)
    finishCapturesSql(db, runId)

    let storePath = ws / "review-store"
    createDir(storePath)
    let cannedPath = ws / "canned.md"
    writeCanned(cannedPath, reviewerOutputFor(brief, runId, hash,
                                              "canned", "v1"))

    let backend = cannedBackend(cannedPath)
    let cfg = ReviewConfigLite(workspaceRoot: ws,
                               reviewStorePath: storePath,
                               promptTemplatePath: "")

    let r1 = dispatchReview(runId, cfg, brief, db, backend, "canned", "v1")
    let r2 = dispatchReview(runId, cfg, brief, db, backend, "canned", "v1")
    check r1 == r2

    let nReports = parseInt(migConn.getValue(sql(
      "SELECT count(*) FROM design_review.agent_reports WHERE run_id = '" &
      runId & "'::uuid")))
    check nReports == 1

  test "test_record_agent_report_transitions_run_status":
    let pgf = newPgFixture()
    defer: pgf.shutdown()
    let (ws, hash, brief) = tmpWorkspaceWithBrief("trans")
    defer: removeDir(ws)

    let appConn = open("", "design_review_app", "",
                       "host=127.0.0.1 port=" & $pgf.port &
                       " dbname=isonim_design_review user=design_review_app")
    let db = ReviewDb(conn: appConn)
    defer: db.close()
    # Migrator connection used by the tests to SELECT from base tables
    # (the app role is restricted to EXECUTE on the routines).
    let migConn = open("", "design_review_migrator", "",
                       "host=127.0.0.1 port=" & $pgf.port &
                       " dbname=isonim_design_review user=design_review_migrator")
    defer: migConn.close()

    let runId = startRunSql(db, "render.fixture", hash, "tester")
    let previewId = canonicalPreviewId(brief.coversPreviews[0].storyRef, pbWeb)
    discard recordCaptureSql(db, runId, previewId, "web", "tablet",
                             "sha1", "/tmp/x.png", 32, 32)
    finishCapturesSql(db, runId)
    check runStatusSql(migConn, runId) == "capture_complete"

    let storePath = ws / "review-store"
    createDir(storePath)
    let cannedPath = ws / "canned.md"
    writeCanned(cannedPath, reviewerOutputFor(brief, runId, hash,
                                              "canned", "v1"))
    let backend = cannedBackend(cannedPath)
    let cfg = ReviewConfigLite(workspaceRoot: ws,
                               reviewStorePath: storePath,
                               promptTemplatePath: "")

    let reportId = dispatchReview(runId, cfg, brief, db, backend,
                                  "canned", "v1")
    check reportId.len == 36   # UUID with dashes

    # finish_run was called by the dispatcher, so the run is now complete.
    check runStatusSql(migConn, runId) == "complete"

  test "test_record_agent_report_rejects_pre_capture_complete":
    let pgf = newPgFixture()
    defer: pgf.shutdown()
    let (ws, hash, brief) = tmpWorkspaceWithBrief("early")
    defer: removeDir(ws)

    let appConn = open("", "design_review_app", "",
                       "host=127.0.0.1 port=" & $pgf.port &
                       " dbname=isonim_design_review user=design_review_app")
    let db = ReviewDb(conn: appConn)
    defer: db.close()
    # Migrator connection used by the tests to SELECT from base tables
    # (the app role is restricted to EXECUTE on the routines).
    let migConn = open("", "design_review_migrator", "",
                       "host=127.0.0.1 port=" & $pgf.port &
                       " dbname=isonim_design_review user=design_review_migrator")
    defer: migConn.close()

    let runId = startRunSql(db, "render.fixture", hash, "tester")
    # NOTE: do not record any captures or finish — run stays in 'capturing'.
    check runStatusSql(migConn, runId) == "capturing"

    let storePath = ws / "review-store"
    createDir(storePath)
    let cannedPath = ws / "canned.md"
    writeCanned(cannedPath, reviewerOutputFor(brief, runId, hash,
                                              "canned", "v1"))
    let backend = cannedBackend(cannedPath)
    let cfg = ReviewConfigLite(workspaceRoot: ws,
                               reviewStorePath: storePath,
                               promptTemplatePath: "")

    expect RunNotReadyForReviewError:
      discard dispatchReview(runId, cfg, brief, db, backend,
                             "canned", "v1")
    let nReports = parseInt(migConn.getValue(sql(
      "SELECT count(*) FROM design_review.agent_reports WHERE run_id = '" &
      runId & "'::uuid")))
    check nReports == 0
    let nAudits = parseInt(migConn.getValue(sql(
      "SELECT count(*) FROM design_review.audit_events " &
      "WHERE run_id = '" & runId & "'::uuid AND event_kind = 'report.recorded'")))
    check nAudits == 0

  test "test_canned_backend_returns_file_contents":
    let tmp = getTempDir() / ("isonim_canned_" & $epochTime().int)
    createDir(tmp)
    defer: removeDir(tmp)
    let p = tmp / "canned.md"
    let body = "verbatim canned reviewer output\n"
    writeFile(p, body)
    let backend = cannedBackend(p)
    # The backend ignores the prompt + png args.
    check backend("ignored prompt", @["/dev/null/a.png", "/dev/null/b.png"]) == body
    check backend("", @[]) == body
