## TBAR-M5 — daemon-side integration test for
## ``POST /api/design-review/save-brief``.
##
## Boots a real ``isonim-review serve`` daemon (the same fixture used
## by TBAR-M1's list-history test) against:
##
##   * an ephemeral process-compose PG cluster (the daemon spawns DB
##     migrations whether or not we use the design-review routes —
##     it's the simplest path to a working build/bin/isonim-review);
##   * a temp directory that doubles as ``workspace.root`` and as the
##     home of a seeded brief at ``<workspace>/briefs/render/
##     fixture-task.md``.
##
## We then POST modified markdown bodies to ``/api/design-review/
## save-brief`` and verify:
##
##   1. Happy path — 200 + bytesWritten correct + the file on disk
##      contains the new body byte-for-byte.
##   2. Missing ``briefId`` field — 400 ``missing_field``.
##   3. Missing ``markdown`` field — 400 ``missing_field``.
##   4. Malformed JSON — 400 ``invalid_json``.
##   5. Unknown ``briefId`` — 404 ``unknown_briefId``.
##   6. Out-of-workspace guard — we set ``workspace.root`` to a
##      *subdirectory* of the temp dir, so a brief that lives one
##      level up is "outside" the configured workspace root and the
##      handler returns 403 ``outside_workspace``.
##
## No mocks — real daemon, real PG, real ``std/httpclient`` POST.

import std/[json, os, osproc, posix, strtabs, strutils, times, unittest]
import std/httpclient

import helpers/design_review_pg_fixture
import tools/isonim_review/cmd_init
import tools/isonim_review/config as review_config

# ---------------------------------------------------------------------------
# Minimal serve harness — mirrors ``design_review_http_fixture.nim`` but
# lets us write a custom config TOML (so we can pin ``workspace.root``
# at a temp dir of our choosing).
# ---------------------------------------------------------------------------

const RepoRoot = currentSourcePath().parentDir().parentDir()
const CliPath = RepoRoot / "build" / "bin" / "isonim-review"
const MigDir = RepoRoot / "db" / "migrations"

type
  SaveBriefFixture = ref object
    pg: PgFixture
    proc1: Process
    port: int
    storePath: string
    workspaceRoot: string
    configPath: string
    briefPath: string
    baseUrl: string

proc pickFreeTcpPort(): int =
  let curl = findExe("curl")
  if curl.len == 0:
    raise newException(IOError, "save_brief_route: curl not on PATH")
  let now = epochTime()
  let seed = int(now * 1000) mod 100
  for offset in 0..99:
    let candidate = 18400 + ((seed + offset) mod 100)
    let probe = execCmdEx(curl & " -s -o /dev/null --max-time 0.5 " &
        "http://127.0.0.1:" & $candidate & "/")
    if probe.exitCode != 0:
      return candidate
  raise newException(IOError, "save_brief_route: no free port in 18400..18499")

const FixtureBriefBody = """---
briefId: render.fixture-task
schemaVersion: 1
kind: render
title: Fixture Task Brief
coversPreviews:
  - storyRef: { group: "Fixture / Pages", name: "Inbox", kind: page, index: 0 }
    backends: [web]
captureViewports:
  - { width: 1920, height: 1080, label: "wide" }
reviewerSchemaVersion: 1
scoringDimensions:
  - { id: "fidelity", label: "Fidelity", weight: 1.0, scale: { min: 1, max: 10 } }
---

# Fixture Task Brief

Original body that the test will overwrite via the save-brief route.

## Section one

- bullet one
- bullet two

```nim
echo "code block"
```
"""

proc seedFixtureBrief(workspaceRoot: string;
                      body: string = FixtureBriefBody): string =
  ## Drop one brief at ``<workspaceRoot>/briefs/render/fixture-task.md``
  ## so the daemon's in-process BriefIndex picks it up on first load.
  let briefsDir = workspaceRoot / "briefs" / "render"
  createDir(briefsDir)
  let path = briefsDir / "fixture-task.md"
  writeFile(path, body)
  path

proc startSaveBriefFixture(workspaceUnderRoot = false;
                           enableDiagRoutes = false;
                           initialBriefBody = FixtureBriefBody;
                           symlinkEscape = false): SaveBriefFixture =
  ## ``workspaceUnderRoot`` — when true, set ``workspace.root`` to a
  ## *subdirectory* of the temp dir AND expose the parent's briefs/
  ## tree via ``ISONIM_REVIEW_EXTRA_BRIEFS_DIRS`` so the daemon
  ## locates the brief in its index but its sourceFile is outside the
  ## configured ``workspace.root`` — the 403 ``outside_workspace``
  ## path under test.
  ##
  ## ``enableDiagRoutes`` — when true, set
  ## ``ISONIM_REVIEW_ENABLE_DIAG_ROUTES=1`` so the daemon's
  ## ``/api/design-review/_test/brief-index`` route returns the
  ## in-memory index instead of a 404.  Used by the byPreview
  ## refresh test.
  ##
  ## ``initialBriefBody`` — override the seeded brief body (default
  ## ``FixtureBriefBody``).  Lets the byPreview test seed a brief
  ## with a known initial ``coversPreviews`` shape.
  ##
  ## ``symlinkEscape`` — when true, place the brief at
  ## ``<tempRoot>/outside/escape.md`` (outside the workspace), then
  ## create ``<workspaceRoot>/briefs/escape`` as a symlink to
  ## ``<tempRoot>/outside`` and add the symlinked path to
  ## ``ISONIM_REVIEW_EXTRA_BRIEFS_DIRS``.  The daemon discovers the
  ## brief via the symlinked path (its ``sourceFile`` lexically lies
  ## inside ``workspace.root``) but the realpath of the brief is
  ## outside the workspace — exercises the symlink-resolving
  ## containment check.
  if not fileExists(CliPath):
    raise newException(IOError,
      "save_brief_route: build/bin/isonim-review missing — " &
      "run ``just isonim-review-build`` first")
  let pg = newPgFixture(applyMigrations = false)

  let tempRoot = getTempDir() / "isonim_save_brief_" &
                  $((int(epochTime() * 1000)) mod 1_000_000)
  createDir(tempRoot)

  var briefPath: string
  var workspaceRoot: string
  var extraBriefsDirs: string

  if symlinkEscape:
    # ``<tempRoot>/workspace`` is the configured workspace root.
    # ``<tempRoot>/outside`` lives outside it on disk.  The brief
    # file is at ``<tempRoot>/outside/escape.md``.  We create the
    # symlink ``<tempRoot>/workspace/briefs/escape`` → outside, so
    # the lexical brief path under the symlink lies inside the
    # workspace.  Only realpath-aware canonicalisation can reject
    # it.
    workspaceRoot = tempRoot / "workspace"
    createDir(workspaceRoot / "briefs")
    let outsideDir = tempRoot / "outside"
    createDir(outsideDir)
    let realBrief = outsideDir / "escape.md"
    writeFile(realBrief, initialBriefBody)
    let symlinkPath = workspaceRoot / "briefs" / "escape"
    createSymlink(outsideDir, symlinkPath)
    # The handler will see this as the brief's ``sourceFile`` —
    # lexically inside the workspace, but realpath points out.
    briefPath = symlinkPath / "escape.md"
    extraBriefsDirs = symlinkPath
  else:
    # The brief always lands in the temp root's ``briefs/render/`` dir.
    briefPath = seedFixtureBrief(tempRoot, initialBriefBody)
    workspaceRoot =
      if workspaceUnderRoot:
        let nested = tempRoot / "nested-workspace"
        createDir(nested)
        nested
      else:
        tempRoot
    extraBriefsDirs =
      if workspaceUnderRoot:
        tempRoot / "briefs"
      else: ""

  let storeDir = tempRoot / "store"
  createDir(storeDir)

  let httpPort = pickFreeTcpPort()
  var environ = newStringTable(modeCaseSensitive)
  for kv in envPairs():
    environ[kv.key] = kv.value
  environ["ISONIM_REVIEW_PGHOST"] = "127.0.0.1"
  environ["ISONIM_REVIEW_PGPORT"] = $pg.port
  environ["ISONIM_REVIEW_PORT"] = $httpPort
  if extraBriefsDirs.len > 0:
    environ["ISONIM_REVIEW_EXTRA_BRIEFS_DIRS"] = extraBriefsDirs
  if enableDiagRoutes:
    environ["ISONIM_REVIEW_ENABLE_DIAG_ROUTES"] = "1"

  let cfgPath = tempRoot / "isonim-review.toml"
  writeFile(cfgPath,
    "[store]\npath = \"" & storeDir & "\"\n" &
    "[workspace]\nroot = \"" & workspaceRoot & "\"\n")

  # Run migrations against the ephemeral cluster.  We import
  # ``cmdInit`` directly (same pattern as
  # ``design_review_http_fixture.runInit``) so the test doesn't have to
  # parse the CLI's exit code / log format.
  var initCfg = review_config.defaults()
  initCfg.db.host = "127.0.0.1"
  initCfg.db.port = pg.port
  initCfg.db.database = "isonim_design_review"
  let nullOut = open("/dev/null", fmWrite)
  defer: nullOut.close()
  if cmdInit(initCfg, MigDir, nullOut) != 0:
    raise newException(IOError, "save_brief_route: cmdInit failed")

  let p = startProcess(CliPath,
    args = @["serve", "--migrations", MigDir, "--config", cfgPath],
    env = environ,
    options = {poUsePath, poStdErrToStdOut})

  let curl = findExe("curl")
  var ok = false
  let deadline = epochTime() + 10.0
  while epochTime() < deadline:
    let r = execCmdEx(curl & " -s --max-time 1 -w '|%{http_code}' " &
        "http://127.0.0.1:" & $httpPort & "/health")
    if r.exitCode == 0 and r.output.contains("|200"):
      ok = true
      break
    sleep(150)
  if not ok:
    discard kill(p.processID.Pid, SIGKILL)
    p.close()
    raise newException(IOError,
      "save_brief_route: daemon failed to boot on port " & $httpPort)

  SaveBriefFixture(
    pg: pg, proc1: p, port: httpPort,
    storePath: storeDir,
    workspaceRoot: workspaceRoot,
    configPath: cfgPath,
    briefPath: briefPath,
    baseUrl: "http://127.0.0.1:" & $httpPort,
  )

proc shutdown(f: SaveBriefFixture) =
  if f == nil: return
  if f.proc1 != nil:
    try: discard kill(f.proc1.processID.Pid, SIGTERM)
    except: discard
    let deadline = epochTime() + 2.0
    while epochTime() < deadline:
      if not f.proc1.running(): break
      sleep(50)
    if f.proc1.running():
      try: discard kill(f.proc1.processID.Pid, SIGKILL)
      except: discard
    discard f.proc1.waitForExit()
    f.proc1.close()
    f.proc1 = nil
  if f.pg != nil:
    f.pg.shutdown()
    f.pg = nil

proc httpPostFixture(baseUrl, path, body: string):
    tuple[code: int; body: string] =
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  let headers = newHttpHeaders([("Content-Type", "application/json")])
  let resp = client.request(baseUrl & path, httpMethod = HttpPost,
                            body = body, headers = headers)
  (code: parseInt(resp.status.split(' ')[0]), body: resp.body)

proc httpGetFixture(baseUrl, path: string):
    tuple[code: int; body: string] =
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  let resp = client.request(baseUrl & path, httpMethod = HttpGet)
  (code: parseInt(resp.status.split(' ')[0]), body: resp.body)

# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------

const NewBody = """---
briefId: render.fixture-task
schemaVersion: 1
kind: render
title: Fixture Task Brief (updated)
coversPreviews:
  - storyRef: { group: "Fixture / Pages", name: "Inbox", kind: page, index: 0 }
    backends: [web]
captureViewports:
  - { width: 1920, height: 1080, label: "wide" }
reviewerSchemaVersion: 1
scoringDimensions:
  - { id: "fidelity", label: "Fidelity", weight: 1.0, scale: { min: 1, max: 10 } }
---

# Updated body

This is the new body written by the save-brief route.
"""

suite "TBAR-M5 save-brief route":

  test "test_save_brief_happy_path_writes_file_and_returns_200":
    let f = startSaveBriefFixture()
    defer: f.shutdown()
    let payload = $(%* {
      "briefId": "render.fixture-task",
      "markdown": NewBody,
    })
    let resp = httpPostFixture(f.baseUrl, "/api/design-review/save-brief",
                                payload)
    check resp.code == 200
    let body = parseJson(resp.body)
    check body["briefId"].getStr == "render.fixture-task"
    check body["bytesWritten"].getInt == NewBody.len
    # The handler canonicalises the resolved path; the test's
    # ``briefPath`` may differ only by symlink resolution.
    check body["path"].getStr.len > 0
    # File on disk matches verbatim.
    let onDisk = readFile(f.briefPath)
    check onDisk == NewBody

  test "test_save_brief_missing_briefId_returns_400_missing_field":
    let f = startSaveBriefFixture()
    defer: f.shutdown()
    let resp = httpPostFixture(f.baseUrl, "/api/design-review/save-brief",
                                """{"markdown":"hello"}""")
    check resp.code == 400
    let body = parseJson(resp.body)
    check body["error"].getStr == "missing_field"

  test "test_save_brief_missing_markdown_returns_400_missing_field":
    let f = startSaveBriefFixture()
    defer: f.shutdown()
    let resp = httpPostFixture(f.baseUrl, "/api/design-review/save-brief",
                                """{"briefId":"render.fixture-task"}""")
    check resp.code == 400
    let body = parseJson(resp.body)
    check body["error"].getStr == "missing_field"

  test "test_save_brief_malformed_json_returns_400_invalid_json":
    let f = startSaveBriefFixture()
    defer: f.shutdown()
    let resp = httpPostFixture(f.baseUrl, "/api/design-review/save-brief",
                                "not json at all")
    check resp.code == 400
    let body = parseJson(resp.body)
    check body["error"].getStr == "invalid_json"

  test "test_save_brief_unknown_briefId_returns_404":
    let f = startSaveBriefFixture()
    defer: f.shutdown()
    let payload = $(%* {
      "briefId": "render.does-not-exist",
      "markdown": "no-op",
    })
    let resp = httpPostFixture(f.baseUrl, "/api/design-review/save-brief",
                                payload)
    check resp.code == 404
    let body = parseJson(resp.body)
    check body["error"].getStr == "unknown_briefId"

  test "test_save_brief_outside_workspace_returns_403":
    ## ``workspace.root`` is set to ``<tempRoot>/nested-workspace`` but
    ## the brief lives at ``<tempRoot>/briefs/render/fixture-task.md``
    ## — one level above the configured workspace root.  The guard
    ## must refuse the write.
    let f = startSaveBriefFixture(workspaceUnderRoot = true)
    defer: f.shutdown()
    let payload = $(%* {
      "briefId": "render.fixture-task",
      "markdown": "should be rejected",
    })
    let resp = httpPostFixture(f.baseUrl, "/api/design-review/save-brief",
                                payload)
    check resp.code == 403
    let body = parseJson(resp.body)
    check body["error"].getStr == "outside_workspace"
    # File on disk is unchanged — the brief still carries the original
    # body, not the malicious payload.
    let onDisk = readFile(f.briefPath)
    check onDisk == FixtureBriefBody

  test "test_save_brief_refreshes_byPreview_index":
    ## Verifies bug fix: ``reparseBrief`` must refresh ``byPreview``
    ## (the inverted ``previewId → briefId`` map) in lockstep with
    ## ``byBriefId`` after a save that changes ``coversPreviews``.
    ## Without this, the editor's history button would resolve the
    ## wrong briefId for the active story until daemon restart.
    ##
    ## We exercise the lifecycle in three saves:
    ##   1. Initial body covers ``(storyA, web)`` only.
    ##   2. Save adds storyB ⇒ both ``(storyA, web)`` and
    ##      ``(storyB, web)`` resolve to the brief.
    ##   3. Save drops storyA ⇒ ``(storyA, web)`` no longer resolves;
    ##      ``(storyB, web)`` still does.
    const InitialBody = """---
briefId: render.fixture-task
schemaVersion: 1
kind: render
title: Fixture Task Brief
coversPreviews:
  - storyRef: { group: "Fixture", name: "StoryA", kind: page, index: 0 }
    backends: [web]
captureViewports:
  - { width: 1920, height: 1080, label: "wide" }
reviewerSchemaVersion: 1
scoringDimensions:
  - { id: "fidelity", label: "Fidelity", weight: 1.0, scale: { min: 1, max: 10 } }
---

# Initial body
"""
    const BodyAB = """---
briefId: render.fixture-task
schemaVersion: 1
kind: render
title: Fixture Task Brief
coversPreviews:
  - storyRef: { group: "Fixture", name: "StoryA", kind: page, index: 0 }
    backends: [web]
  - storyRef: { group: "Fixture", name: "StoryB", kind: page, index: 0 }
    backends: [web]
captureViewports:
  - { width: 1920, height: 1080, label: "wide" }
reviewerSchemaVersion: 1
scoringDimensions:
  - { id: "fidelity", label: "Fidelity", weight: 1.0, scale: { min: 1, max: 10 } }
---

# Two stories
"""
    const BodyBOnly = """---
briefId: render.fixture-task
schemaVersion: 1
kind: render
title: Fixture Task Brief
coversPreviews:
  - storyRef: { group: "Fixture", name: "StoryB", kind: page, index: 0 }
    backends: [web]
captureViewports:
  - { width: 1920, height: 1080, label: "wide" }
reviewerSchemaVersion: 1
scoringDimensions:
  - { id: "fidelity", label: "Fidelity", weight: 1.0, scale: { min: 1, max: 10 } }
---

# Only StoryB
"""
    # canonicalPreviewId for the seeded shapes — the encoder leaves
    # spaces / letters untouched and only escapes ``/``, ``@``, ``#``,
    # ``%`` (none of which appear in the StoryA / StoryB story refs
    # below), so the canonical form is literal.
    const PreviewA = "Fixture/StoryA:page#0@web"
    const PreviewB = "Fixture/StoryB:page#0@web"

    let f = startSaveBriefFixture(enableDiagRoutes = true,
                                  initialBriefBody = InitialBody)
    defer: f.shutdown()

    # ``byPreview`` lookups go through a test-only diagnostic route
    # the daemon exposes when ``ISONIM_REVIEW_ENABLE_DIAG_ROUTES=1``.
    # The route returns ``{byBriefId: [ids], byPreview: {pid: [ids]}}``
    # — strictly read-only.
    proc indexDump(): JsonNode =
      # The diag handler triggers ``ensureLoaded`` itself, so a single
      # GET is enough.  Returns ``{byBriefId: [...], byPreview: {...}}``.
      let r = httpGetFixture(f.baseUrl,
                             "/api/design-review/_test/brief-index")
      check r.code == 200
      parseJson(r.body)

    proc previewResolvesTo(dump: JsonNode; previewId, briefId: string): bool =
      if not dump.hasKey("byPreview"): return false
      let by = dump["byPreview"]
      if not by.hasKey(previewId): return false
      for entry in by[previewId]:
        if entry.getStr == briefId: return true
      false

    # 1. Initial state — only ``(StoryA, web)`` resolves.
    let d0 = indexDump()
    check previewResolvesTo(d0, PreviewA, "render.fixture-task")
    check not previewResolvesTo(d0, PreviewB, "render.fixture-task")

    # 2. Save with StoryA + StoryB ⇒ both resolve.
    let r1 = httpPostFixture(f.baseUrl, "/api/design-review/save-brief",
                              $(%* {
                                "briefId": "render.fixture-task",
                                "markdown": BodyAB,
                              }))
    check r1.code == 200
    let d1 = indexDump()
    check previewResolvesTo(d1, PreviewA, "render.fixture-task")
    check previewResolvesTo(d1, PreviewB, "render.fixture-task")

    # 3. Save dropping StoryA ⇒ only StoryB resolves.
    let r2 = httpPostFixture(f.baseUrl, "/api/design-review/save-brief",
                              $(%* {
                                "briefId": "render.fixture-task",
                                "markdown": BodyBOnly,
                              }))
    check r2.code == 200
    let d2 = indexDump()
    check not previewResolvesTo(d2, PreviewA, "render.fixture-task")
    check previewResolvesTo(d2, PreviewB, "render.fixture-task")

  test "test_save_brief_rejects_symlink_traversal":
    ## Verifies bug fix: ``isInsideDir`` / ``canonicalize`` must
    ## resolve symlinks before the containment check, so a brief
    ## whose lexical path lies inside ``workspace.root`` but whose
    ## realpath points outside cannot be written through.
    ##
    ## Setup: ``<workspace>/briefs/escape`` is a symlink to
    ## ``<tempRoot>/outside``.  A brief at
    ## ``<tempRoot>/outside/escape.md`` is discovered via the
    ## symlinked path — its ``sourceFile`` LEXICALLY looks
    ## ``inside`` the workspace, but realpath says ``outside``.
    ## The guard must respond 403 ``outside_workspace``.
    let f = startSaveBriefFixture(symlinkEscape = true)
    defer: f.shutdown()
    let payload = $(%* {
      "briefId": "render.fixture-task",
      "markdown": "should be rejected",
    })
    let resp = httpPostFixture(f.baseUrl, "/api/design-review/save-brief",
                                payload)
    check resp.code == 403
    let body = parseJson(resp.body)
    check body["error"].getStr == "outside_workspace"
    # File on disk is unchanged.
    let onDisk = readFile(f.briefPath)
    check onDisk == FixtureBriefBody

  test "test_save_brief_reparses_index_so_next_save_sees_new_body":
    ## Two POSTs in a row.  The second targets the same briefId; the
    ## handler must locate the brief via the in-memory index (which
    ## the first save re-parsed) and the third on-disk byte-string
    ## must match the third payload.
    let f = startSaveBriefFixture()
    defer: f.shutdown()
    let firstPayload = $(%* {
      "briefId": "render.fixture-task",
      "markdown": NewBody,
    })
    let r1 = httpPostFixture(f.baseUrl, "/api/design-review/save-brief",
                              firstPayload)
    check r1.code == 200

    let secondBody = NewBody.replace(
      "This is the new body written by the save-brief route.",
      "Second-save body — the index re-parse picked the new content.")
    let secondPayload = $(%* {
      "briefId": "render.fixture-task",
      "markdown": secondBody,
    })
    let r2 = httpPostFixture(f.baseUrl, "/api/design-review/save-brief",
                              secondPayload)
    check r2.code == 200
    let onDisk = readFile(f.briefPath)
    check onDisk == secondBody
