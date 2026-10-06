## REV-M10 — the acceptance gate enforces the clean-tree rule
## end-to-end.  Asserts:
##
##   * With one uncommitted edit anywhere in the workspace,
##     ``isonim-review capture`` exits non-zero.
##   * design_review.runs gains zero rows.
##   * The content-addressed PNG store gains zero files.
##
## This is REV-M5's clean-tree gate verified through the full CLI
## subprocess against the real PgFixture.

import std/[asyncdispatch, asyncnet, nativesockets, net, os, osproc,
            streams, strtabs, strutils, unittest]

import db_connector/db_postgres

import isonim_render_serve/packet
import isonim_render_serve/ws_frame
import isonim_render_serve/bridge   # computeAcceptKey

import helpers/design_review_pg_fixture
import helpers/repro_workspace_fixture

# ---------------------------------------------------------------------------
# Fake-bridge — never expected to be hit (the clean-tree gate aborts
# before the bridge is contacted), but the CLI still requires a URL.
# ---------------------------------------------------------------------------

type FakeBridge = ref object
  port: int
  listener: AsyncSocket
  closing: bool

proc pickPort(): int =
  let s = newSocket()
  s.bindAddr(Port(0))
  let p = s.getLocalAddr()[1]
  s.close()
  int(p)

proc handleClient(client: AsyncSocket) {.async.} =
  # Trivial accept-then-close — exercised only if the gate fails open.
  try: client.close() except CatchableError: discard

proc startFakeBridge(): FakeBridge =
  let port = pickPort()
  let listener = newAsyncSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(port))
  listener.listen()
  result = FakeBridge(port: port, listener: listener, closing: false)
  let fbRef = result
  proc loop() {.async.} =
    while not fbRef.closing:
      try:
        let client = await fbRef.listener.accept()
        asyncCheck handleClient(client)
      except CatchableError:
        break
  asyncCheck loop()
  for _ in 0 .. 3: poll(20)

proc stop(fb: FakeBridge) =
  fb.closing = true
  try: fb.listener.close() except CatchableError: discard

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

const RepoRootHere = currentSourcePath().parentDir().parentDir()
const IsonimReviewBin = RepoRootHere / "build" / "bin" / "isonim-review"

const TaskAppBriefYaml = """---
briefId: render.task-app
schemaVersion: 1
kind: render
title: Task App — cross-backend visual review
coversPreviews:
  - storyRef: { group: "Task App / Pages", name: "Inbox", kind: page, index: 0 }
    backends: [web, tui, gpui, freya, cocoa, android, ios]
captureViewports:
  - { width: 32, height: 32, label: tablet }
reviewerSchemaVersion: 1
scoringDimensions:
  - { id: chrome,    label: "Editor Chrome", weight: 0.4, scale: { min: 1, max: 10 } }
  - { id: rendering, label: "App Rendering", weight: 0.6, scale: { min: 1, max: 10 } }
---
body
"""

proc shouldHave(path: string) =
  if not fileExists(path):
    raise newException(IOError,
      "REV-M10 e2e: required file not found at " & path)

proc mirrorBriefToWorkspace(workspaceRoot: string) =
  let briefsDir = workspaceRoot / "briefs" / "render"
  createDir(briefsDir)
  writeFile(briefsDir / "task-app.md", TaskAppBriefYaml)

proc buildDirtyWorkspace(suffix: string): string =
  ## A hermetic reprobuild workspace whose ``repo-a`` carries the
  ## committed, published brief, plus one uncommitted edit.  Returns the
  ## workspace root; remove its parent to clean up.
  let ws = newReproWorkspace("rev_m10_" & suffix, ["repo-a"],
    files = [("repo-a", "briefs/render/task-app.md", TaskAppBriefYaml)]).root
  mirrorBriefToWorkspace(ws)
  # Introduce one uncommitted edit in repo-a.
  writeFile(ws / "repo-a" / "README.md", "edited\n")
  ws

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

proc runCli(args: seq[string]; cwd: string):
                     tuple[exitCode: int; stdout, stderr: string] =
  var environ = newStringTable(modeCaseSensitive)
  for kv in envPairs():
    environ[kv.key] = kv.value
  let p = startProcess(IsonimReviewBin, args = args,
                       workingDir = cwd, env = environ,
                       options = {poUsePath})
  while p.running:
    poll(20)
  let so = p.outputStream.readAll()
  let se = p.errorStream.readAll()
  let code = p.waitForExit()
  p.close()
  (exitCode: code, stdout: so, stderr: se)

proc openMigConn(pgPort: int): DbConn =
  open("", "design_review_migrator", "",
       "host=127.0.0.1 port=" & $pgPort &
       " dbname=isonim_design_review user=design_review_migrator")

proc countPngFiles(storePath: string): int =
  result = 0
  if not dirExists(storePath): return
  for kind, path in walkDir(storePath, relative = false):
    if kind == pcDir:
      for k2, p2 in walkDir(path):
        if k2 == pcFile and p2.endsWith(".png"):
          inc result

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

suite "REV-M10 dirty-workspace acceptance":

  setup:
    shouldHave(IsonimReviewBin)

  test "e2e_pipeline_refuses_dirty_workspace":
    let pgf = newPgFixture()
    defer: pgf.shutdown()
    let fb = startFakeBridge()
    defer: fb.stop()

    let ws = buildDirtyWorkspace("dirty")
    defer: removeDir(ws.parentDir)
    let storePath = ws / "store"
    let cfg = writeConfig(ws, storePath, pgf.port)

    let res = runCli(@[
      "capture", "--brief", "render.task-app",
      "--bridge", "ws://127.0.0.1:" & $fb.port,
      "--workspace", ws, "--project", ws, "--config", cfg], cwd = ws)

    # Non-zero exit; the stderr names the dirty file.
    check res.exitCode != 0
    check ("README.md" in res.stderr) or ("dirty" in res.stderr.toLowerAscii)

    # Zero DB rows.
    let mig = openMigConn(pgf.port)
    defer: mig.close()
    let nRuns = parseInt(mig.getValue(
      sql"SELECT count(*) FROM design_review.runs"))
    check nRuns == 0
    let nCaptures = parseInt(mig.getValue(
      sql"SELECT count(*) FROM design_review.captures"))
    check nCaptures == 0

    # Zero PNG files in the store.
    check countPngFiles(storePath) == 0
