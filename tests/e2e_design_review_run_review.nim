## REV-M6 — end-to-end run-review pipeline tests.
##
## Each test spawns the real ``isonim-review`` binary against a
## synthetic workspace with a committed brief + a seeded run + a
## canned reviewer output.  The DB layer is the real ``PgFixture``;
## the agent backend is the deterministic ``canned`` backend.

import std/[json, os, osproc, streams, strtabs, strutils, times, unittest]

import db_connector/db_postgres

import isonim/editor/design_review/brief_format
import isonim/editor/design_review/manifest_hash
import isonim/editor/types

import helpers/design_review_pg_fixture

# --------------------------------------------------------------------------- #
#  Workspace + binary helpers.
# --------------------------------------------------------------------------- #

const RepoRootHere = currentSourcePath().parentDir().parentDir()
const IsonimReviewBin = RepoRootHere / "build" / "bin" / "isonim-review"

proc shouldHave(path: string) =
  if not fileExists(path):
    raise newException(IOError,
      "e2e_design_review_run_review: binary not found at " & path &
      ".  Build it with `just isonim-review-build`.")

proc runOrFail(cmd, cwd: string): string =
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
                    "git config commit.gpgsign false",
                    repoPath)

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
ORIGINAL_BRIEF_BODY_MARKER
"""

const FixtureBriefYamlEdited = """---
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
EDITED_BRIEF_BODY_MARKER
"""

proc tmpWs(suffix: string): string =
  result = getTempDir() / ("isonim_e2e_rr_" & suffix & "_" & $epochTime().int)
  removeDir(result)
  createDir(result)

proc seedWorkspace(ws: string;
                   briefContent: string = FixtureBriefYaml):
                  tuple[manifestHash, initialSha: string] =
  ## Initialise a single-repo workspace with the committed brief.
  ## Returns the manifest hash captured against the pinned revision
  ## *and* the initial commit SHA so callers can later rewrite the
  ## manifest XML to point back at it.
  let repoA = ws / "repo-a"
  gitInit(repoA)
  createDir(repoA / "briefs" / "render")
  writeFile(repoA / "briefs" / "render" / "fixture.md", briefContent)
  let sha = gitCommit(repoA, "initial brief")
  writeManifest(ws, "repo-a", sha)
  # Mirror the brief to the workspace root so the dispatcher can read
  # the typed brief structure without git-history lookups.
  createDir(ws / "briefs" / "render")
  writeFile(ws / "briefs" / "render" / "fixture.md", briefContent)
  (manifestHash: captureManifestHash(ws), initialSha: sha)

proc writeConfig(workspaceRoot, storePath: string; pgPort: int): string =
  let cfgPath = workspaceRoot / "config.toml"
  writeFile(cfgPath,
    "[db]\nhost = \"127.0.0.1\"\nport = " & $pgPort &
    "\ndatabase = \"isonim_design_review\"\n" &
    "url = \"postgres://design_review_app@127.0.0.1:" & $pgPort &
    "/isonim_design_review\"\n" &
    "[store]\npath = \"" & storePath & "\"\n" &
    "[workspace]\nroot = \"" & workspaceRoot & "\"\n")
  cfgPath

proc runIsonimReview(args: seq[string]; cwd: string):
                     tuple[exitCode: int; stdout, stderr: string] =
  var environ = newStringTable(modeCaseSensitive)
  for kv in envPairs():
    environ[kv.key] = kv.value
  let p = startProcess(IsonimReviewBin, args = args,
                       workingDir = cwd, env = environ,
                       options = {poUsePath})
  let code = p.waitForExit()
  let so = p.outputStream.readAll()
  let se = p.errorStream.readAll()
  p.close()
  (exitCode: code, stdout: so, stderr: se)

# --------------------------------------------------------------------------- #
#  Seed run helpers (the SQL is short; no need for a separate module).
# --------------------------------------------------------------------------- #

proc openAppConn(pgPort: int): DbConn =
  open("", "design_review_app", "",
       "host=127.0.0.1 port=" & $pgPort &
       " dbname=isonim_design_review user=design_review_app")

proc openMigConn(pgPort: int): DbConn =
  open("", "design_review_migrator", "",
       "host=127.0.0.1 port=" & $pgPort &
       " dbname=isonim_design_review user=design_review_migrator")

proc seedRun(conn: DbConn; briefId, manifestHash, previewId: string): string =
  let escB = briefId.replace("'", "''")
  let escH = manifestHash.replace("'", "''")
  let runId = conn.getValue(sql(
    "SELECT design_review.start_run('" & escB & "', '" & escH &
    "', 'tester')"))
  let escRun = runId.replace("'", "''")
  let escPv = previewId.replace("'", "''")
  discard conn.getValue(sql(
    "SELECT design_review.record_capture('" & escRun &
    "'::uuid,'" & escPv & "','web','tablet','sha1','/tmp/x.png',32,32)"))
  discard conn.getValue(sql(
    "SELECT design_review.finish_captures('" & escRun & "'::uuid)"))
  runId

proc writeCanned(path, runId, manifestHash, agentName, agentVersion: string;
                 previewId: string) =
  let body = "---\n" &
    "reviewerSchemaVersion: 1\n" &
    "briefId: render.fixture\n" &
    "runId: " & runId & "\n" &
    "agentName: " & agentName & "\n" &
    "agentVersion: " & agentVersion & "\n" &
    "manifestHash: " & manifestHash & "\n" &
    "capturedAt: 2026-05-19T11:32:04Z\n" &
    "overall:\n  score: 8.0\n  status: pass\n" &
    "previews:\n" &
    "  \"" & previewId & "\":\n" &
    "    scores: { a: 8 }\n" &
    "    status: pass\n" &
    "    defects: []\n" &
    "---\nbody\n"
  createDir(path.parentDir)
  writeFile(path, body)

# --------------------------------------------------------------------------- #
#  Tests.
# --------------------------------------------------------------------------- #

suite "REV-M6 run-review (e2e)":

  setup:
    shouldHave(IsonimReviewBin)

  test "e2e_run_review_against_fixture_captures":
    let pgf = newPgFixture()
    defer: pgf.shutdown()
    let ws = tmpWs("fixture")
    defer: removeDir(ws)
    let (manifestHash, _) = seedWorkspace(ws)
    let storePath = ws / "review-store"
    let cfg = writeConfig(ws, storePath, pgf.port)

    let appConn = openAppConn(pgf.port)
    defer: appConn.close()
    let migConn = openMigConn(pgf.port)
    defer: migConn.close()
    let brief = parseBrief(ws / "briefs" / "render" / "fixture.md")
    let previewId = canonicalPreviewId(brief.coversPreviews[0].storyRef, pbWeb)
    let runId = seedRun(appConn, "render.fixture", manifestHash, previewId)

    let cannedPath = ws / "canned.md"
    writeCanned(cannedPath, runId, manifestHash, "canned", "v1", previewId)
    let cannedBytes = readFile(cannedPath)

    let res = runIsonimReview(@[
      "run-review", "--run", runId,
      "--agent-backend", "canned",
      "--canned-path", cannedPath,
      "--agent-name", "canned",
      "--agent-version", "v1",
      "--workspace", ws,
      "--project", ws,
      "--config", cfg], cwd = ws)
    if res.exitCode != 0:
      echo "stdout:\n" & res.stdout
      echo "stderr:\n" & res.stderr
    check res.exitCode == 0

    # One row in agent_reports with the expected JSONB.
    let nReports = parseInt(migConn.getValue(sql(
      "SELECT count(*) FROM design_review.agent_reports " &
      "WHERE run_id = '" & runId & "'::uuid")))
    check nReports == 1
    let parsed = parseJson(migConn.getValue(sql(
      "SELECT parsed_scores::text FROM design_review.agent_reports " &
      "WHERE run_id = '" & runId & "'::uuid")))
    check parsed["schemaVersion"].getInt == 1
    check parsed["overall"]["status"].getStr == "pass"
    check parsed["previews"][previewId]["scores"]["a"].getInt == 8

    # Raw output is in review-store/reports/<runId>/canned.md byte-identical.
    let rawPath = storePath / "reports" / runId / "canned.md"
    check fileExists(rawPath)
    check readFile(rawPath) == cannedBytes

    # Run reached the terminal 'complete' status.
    let status = migConn.getValue(sql(
      "SELECT status FROM design_review.runs WHERE run_id = '" &
      runId & "'::uuid"))
    check status == "complete"

  test "e2e_run_review_uses_brief_at_manifest_hash":
    let pgf = newPgFixture()
    defer: pgf.shutdown()
    let ws = tmpWs("histbrief")
    defer: removeDir(ws)
    let (manifestHashA, shaInitial) = seedWorkspace(ws)
    let storePath = ws / "review-store"
    let cfg = writeConfig(ws, storePath, pgf.port)

    let appConn = openAppConn(pgf.port)
    defer: appConn.close()
    let migConn = openMigConn(pgf.port)
    defer: migConn.close()
    let brief = parseBrief(ws / "briefs" / "render" / "fixture.md")
    let previewId = canonicalPreviewId(brief.coversPreviews[0].storyRef, pbWeb)
    let runId = seedRun(appConn, "render.fixture", manifestHashA, previewId)

    # Edit + recommit the brief body in repo-a — manifest hash B will
    # capture this new commit.  After this, the workspace's manifest
    # points at B; the run is pinned at A.  We restore manifest A
    # before calling run-review so the brief-at-revision lookup
    # succeeds.
    writeFile(ws / "repo-a" / "briefs" / "render" / "fixture.md",
              FixtureBriefYamlEdited)
    let shaB = gitCommit(ws / "repo-a", "edit brief")
    writeManifest(ws, "repo-a", shaB)
    let manifestHashB = captureManifestHash(ws)
    check manifestHashA != manifestHashB
    # Restore manifest pin to A so briefAtRevision can validate the hash.
    writeManifest(ws, "repo-a", shaInitial)
    check captureManifestHash(ws) == manifestHashA

    # Run review in dry-run mode so we can inspect the prompt the
    # dispatcher assembles without needing a real reviewer output.
    let dryOut = ws / "dry-out.txt"
    let cannedPath = ws / "canned.md"
    writeCanned(cannedPath, runId, manifestHashA, "canned", "v1", previewId)
    let res = runIsonimReview(@[
      "run-review", "--run", runId,
      "--agent-backend", "canned",
      "--canned-path", cannedPath,
      "--agent-name", "canned",
      "--agent-version", "v1",
      "--workspace", ws,
      "--project", ws,
      "--config", cfg,
      "--dry-run-out", dryOut], cwd = ws)
    if res.exitCode != 0:
      echo "stdout:\n" & res.stdout
      echo "stderr:\n" & res.stderr
    check res.exitCode == 0
    check fileExists(dryOut)
    let prompt = readFile(dryOut)
    # The prompt must contain manifest A's brief body, NOT manifest B's.
    check prompt.contains("ORIGINAL_BRIEF_BODY_MARKER")
    check (not prompt.contains("EDITED_BRIEF_BODY_MARKER"))

  test "e2e_concurrent_two_agent_reports_one_run":
    let pgf = newPgFixture()
    defer: pgf.shutdown()
    let ws = tmpWs("concurrent")
    defer: removeDir(ws)
    let (manifestHash, _) = seedWorkspace(ws)
    let storePath = ws / "review-store"
    let cfg = writeConfig(ws, storePath, pgf.port)

    let appConn = openAppConn(pgf.port)
    defer: appConn.close()
    let migConn = openMigConn(pgf.port)
    defer: migConn.close()
    let brief = parseBrief(ws / "briefs" / "render" / "fixture.md")
    let previewId = canonicalPreviewId(brief.coversPreviews[0].storyRef, pbWeb)
    let runId = seedRun(appConn, "render.fixture", manifestHash, previewId)

    let cannedAlpha = ws / "alpha.md"
    let cannedBeta = ws / "beta.md"
    writeCanned(cannedAlpha, runId, manifestHash, "canned", "alpha", previewId)
    writeCanned(cannedBeta, runId, manifestHash, "canned", "beta", previewId)

    # Spawn both CLI invocations concurrently — different agent versions
    # against the same run, so neither should hit a unique_violation.
    var environ = newStringTable(modeCaseSensitive)
    for kv in envPairs(): environ[kv.key] = kv.value
    let pA = startProcess(IsonimReviewBin,
      args = @["run-review", "--run", runId,
               "--agent-backend", "canned",
               "--canned-path", cannedAlpha,
               "--agent-name", "canned",
               "--agent-version", "alpha",
               "--workspace", ws, "--project", ws, "--config", cfg],
      workingDir = ws, env = environ, options = {poUsePath})
    let pB = startProcess(IsonimReviewBin,
      args = @["run-review", "--run", runId,
               "--agent-backend", "canned",
               "--canned-path", cannedBeta,
               "--agent-name", "canned",
               "--agent-version", "beta",
               "--workspace", ws, "--project", ws, "--config", cfg],
      workingDir = ws, env = environ, options = {poUsePath})
    let codeA = pA.waitForExit()
    let codeB = pB.waitForExit()
    let outA = pA.outputStream.readAll()
    let outB = pB.outputStream.readAll()
    let errA = pA.errorStream.readAll()
    let errB = pB.errorStream.readAll()
    pA.close(); pB.close()
    if codeA != 0 or codeB != 0:
      echo "alpha exit=", codeA, " stdout:\n", outA, "\nstderr:\n", errA
      echo "beta  exit=", codeB, " stdout:\n", outB, "\nstderr:\n", errB
    check codeA == 0
    check codeB == 0

    let nReports = parseInt(migConn.getValue(sql(
      "SELECT count(*) FROM design_review.agent_reports " &
      "WHERE run_id = '" & runId & "'::uuid")))
    check nReports == 2

    let status = migConn.getValue(sql(
      "SELECT status FROM design_review.runs WHERE run_id = '" &
      runId & "'::uuid"))
    check status == "complete"

    let nAudits = parseInt(migConn.getValue(sql(
      "SELECT count(*) FROM design_review.audit_events " &
      "WHERE run_id = '" & runId &
      "'::uuid AND event_kind = 'report.recorded'")))
    check nAudits == 2
