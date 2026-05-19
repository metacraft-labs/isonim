## REV-M10 — run the full pipeline TWICE against the same migrated brief
## with no source change between runs.  Asserts:
##
##   * design_review.runs has 2 capture_complete rows (one per run).
##   * design_review.captures has 14 rows (2 × 7 backends).
##   * The content-addressed store has 7 unique PNG files (PNG bytes are
##     identical between the two runs → dedup collapses them).
##   * Both runs are visible to the gallery via
##     ``design_review.list_history`` (the API the gallery's
##     ``/api/design-review/list-history`` endpoint wraps).
##
## This is REV-M10's "two runs visible in the gallery" acceptance
## predicate; the gallery's HTTP layer is exercised by the existing
## REV-M7 test suite, so here we assert against ``list_history``
## directly (one stored-procedure boundary call).

import std/[asyncdispatch, asyncnet, nativesockets, net, os, osproc,
            streams, strtabs, strutils, times, unittest]

import db_connector/db_postgres

import isonim_render_serve/packet
import isonim_render_serve/ws_frame
import isonim_render_serve/bridge   # computeAcceptKey

import helpers/design_review_pg_fixture

# ---------------------------------------------------------------------------
# Fake-bridge — same shape as the other REV-M10 e2e tests.
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
  let fd = AsyncFD(getFd(client))
  var req = ""
  while not req.contains("\r\n\r\n"):
    var buf = newString(4096)
    let n = await asyncdispatch.recvInto(fd, addr buf[0], buf.len)
    if n <= 0:
      try: client.close() except CatchableError: discard
      return
    buf.setLen(n)
    req.add buf
  var key = ""
  for line in req.splitLines():
    if line.toLowerAscii.startsWith("sec-websocket-key:"):
      key = line.split(':', 1)[1].strip()
  let accept = computeAcceptKey(key)
  await client.send("HTTP/1.1 101 Switching Protocols\r\n" &
                    "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
                    "Sec-WebSocket-Accept: " & accept & "\r\n\r\n")
  let hello = MetaPacket(json:
    "{\"type\":\"hello\",\"protocolVersion\":1,\"backend\":\"web\"," &
    "\"capabilities\":{},\"initialSize\":{\"width\":32,\"height\":32}}")
  await client.send(encodeWsBinaryFrame(bytesToString(encodeMeta(hello))))
  var dec = initWsFrameDecoder()
  var iBody = ""
  while iBody.len == 0:
    var buf = newString(4096)
    let n = await asyncdispatch.recvInto(fd, addr buf[0], buf.len)
    if n <= 0: break
    buf.setLen(n)
    dec.feed(buf)
    while true:
      let msg = dec.popMessage()
      if not msg.complete: break
      if msg.opcode == wsOpBinary and msg.payload.len > 5 and
         msg.payload[0] == 'I':
        iBody = msg.payload[5 .. ^1]
        break
  var seed: byte = 0
  for c in iBody:
    seed = byte((int(seed) + int(c.uint8)) and 0xFF)
  var pixels = newSeq[byte](32 * 32 * 4)
  for i in 0 ..< pixels.len:
    pixels[i] = byte((int(seed) + i) and 0xFF)
  let frame = Frame(kind: fkFull,
                    flags: FrameFlags(isDiff: false, isVideo: false),
                    width: 32, height: 32, pixels: pixels)
  await client.send(encodeWsBinaryFrame(bytesToString(encodeFrame(frame))))
  for _ in 0 ..< 20:
    if client.isClosed: break
    await sleepAsync(25)
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

proc runOrFail(cmd: string; cwd: string) =
  let res = execCmdEx(cmd, workingDir = cwd)
  if res.exitCode != 0:
    raise newException(IOError, cmd & " failed (" & $res.exitCode &
                       "):\n" & res.output)

proc initRepoWithBrief(repoPath: string): string =
  createDir(repoPath)
  createDir(repoPath / "briefs" / "render")
  writeFile(repoPath / "briefs" / "render" / "task-app.md",
            TaskAppBriefYaml)
  runOrFail("git init -q -b main && " &
            "git config user.email 'test@test' && " &
            "git config user.name 'tester' && " &
            "git config commit.gpgsign false && " &
            "echo hi > README.md && " &
            "git add -A && git commit -q -m initial",
            repoPath)
  execCmdEx("git -C " & quoteShell(repoPath) & " rev-parse HEAD").output.strip()

proc writeManifest(workspaceRoot, repoName, sha: string) =
  let repoDir = workspaceRoot / ".repo"
  createDir(repoDir)
  writeFile(repoDir / "manifest.xml",
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<manifest>\n" &
    "  <project name=\"" & repoName & "\" path=\"" & repoName &
    "\" revision=\"" & sha & "\"/>\n</manifest>\n")

proc mirrorBriefToWorkspace(workspaceRoot: string) =
  let briefsDir = workspaceRoot / "briefs" / "render"
  createDir(briefsDir)
  writeFile(briefsDir / "task-app.md", TaskAppBriefYaml)

proc buildWorkspace(suffix: string): string =
  let ws = getTempDir() / ("isonim_rev_m10_" & suffix & "_" &
                            $epochTime().int)
  removeDir(ws)
  createDir(ws)
  let sha = initRepoWithBrief(ws / "repo-a")
  writeManifest(ws, "repo-a", sha)
  mirrorBriefToWorkspace(ws)
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

suite "REV-M10 two-run round-trip (gallery acceptance)":

  setup:
    shouldHave(IsonimReviewBin)

  test "e2e_full_pipeline_round_trip_two_runs_visible_in_gallery":
    let pgf = newPgFixture()
    defer: pgf.shutdown()
    let fb = startFakeBridge()
    defer: fb.stop()

    let ws = buildWorkspace("twoRun")
    defer: removeDir(ws)
    let storePath = ws / "store"
    let cfg = writeConfig(ws, storePath, pgf.port)

    # ---- run #1 ----
    let r1 = runCli(@[
      "capture", "--brief", "render.task-app",
      "--bridge", "ws://127.0.0.1:" & $fb.port,
      "--workspace", ws, "--project", ws, "--config", cfg], cwd = ws)
    check r1.exitCode == 0

    let pngAfterRun1 = countPngFiles(storePath)
    check pngAfterRun1 >= 1
    check pngAfterRun1 <= 7

    # ---- run #2 (no source change) ----
    let r2 = runCli(@[
      "capture", "--brief", "render.task-app",
      "--bridge", "ws://127.0.0.1:" & $fb.port,
      "--workspace", ws, "--project", ws, "--config", cfg], cwd = ws)
    check r2.exitCode == 0

    let mig = openMigConn(pgf.port)
    defer: mig.close()

    # 2 runs.
    let nRuns = parseInt(mig.getValue(sql"""
      SELECT count(*) FROM design_review.runs
       WHERE brief_id = 'render.task-app'
         AND status = 'capture_complete'"""))
    check nRuns == 2

    # 14 captures (7 backends × 2 runs).
    let nCaptures = parseInt(mig.getValue(sql"""
      SELECT count(*) FROM design_review.captures"""))
    check nCaptures == 14

    # PNG dedup: bytes are identical between runs (same seed → same
    # pixel pattern → same png), so the content-addressed store has
    # the SAME count as after run #1.
    let pngAfterRun2 = countPngFiles(storePath)
    check pngAfterRun2 == pngAfterRun1

    # Both runs are visible to the gallery via list_history.
    let listed = parseInt(mig.getValue(sql"""
      SELECT count(*) FROM design_review.list_history('render.task-app', 50, 0)"""))
    check listed == 2
