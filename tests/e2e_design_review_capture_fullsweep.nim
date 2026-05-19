## REV-M5 — end-to-end capture pipeline tests.
##
## Each test spawns the real ``isonim-review`` binary against a
## synthetic workspace and a fake bridge.  The DB layer is the real
## ``PgFixture`` from REV-M3; no mocks at the DB boundary.

import std/[asyncdispatch, asyncnet, nativesockets, net, os, osproc,
            streams, strtabs, strutils, times, unittest]

import db_connector/db_postgres

import isonim_render_serve/packet
import isonim_render_serve/ws_frame
import isonim_render_serve/bridge   # computeAcceptKey

import isonim/editor/design_review/manifest_hash

import helpers/design_review_pg_fixture

# ---------------------------------------------------------------------------
# Fake bridge — same shape as the unit tests.  Supports optional
# transient-failure injection on the Nth accepted connection.
# ---------------------------------------------------------------------------

type FakeBridge = ref object
  port: int
  listener: AsyncSocket
  closing: bool
  refuseNthConn: int    ## 1-indexed; 0 disables
  connsSeen: int

proc pickPort(): int =
  let s = newSocket()
  s.bindAddr(Port(0))
  let p = s.getLocalAddr()[1]
  s.close()
  int(p)

proc handleClient(fb: FakeBridge; client: AsyncSocket;
                  refuse: bool) {.async.} =
  let fd = AsyncFD(getFd(client))
  if refuse:
    # Drop the connection without sending the upgrade response.
    try: client.close() except CatchableError: discard
    return
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
        # I packet body starts at byte 5 (after the u32 LE length).
        iBody = msg.payload[5 .. ^1]
        break
  # Seed the pixel pattern from the I body so different (storyRef)
  # tuples produce different PNG bytes.  This mirrors what a real
  # bridge would do (different stories paint different canvases).
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

proc startFakeBridge(refuseNthConn: int = 0): FakeBridge =
  let port = pickPort()
  let listener = newAsyncSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(port))
  listener.listen()
  result = FakeBridge(port: port, listener: listener,
                      closing: false, refuseNthConn: refuseNthConn)
  let fbRef = result
  proc loop() {.async.} =
    while not fbRef.closing:
      try:
        let client = await fbRef.listener.accept()
        inc fbRef.connsSeen
        let refuse = (fbRef.refuseNthConn > 0 and
                      fbRef.connsSeen == fbRef.refuseNthConn)
        asyncCheck handleClient(fbRef, client, refuse)
      except CatchableError:
        break
  asyncCheck loop()
  for _ in 0 .. 3: poll(20)

proc stop(fb: FakeBridge) =
  fb.closing = true
  try: fb.listener.close() except CatchableError: discard

# ---------------------------------------------------------------------------
# Workspace fixture builder
# ---------------------------------------------------------------------------

const RepoRootHere = currentSourcePath().parentDir().parentDir()
const IsonimReviewBin = RepoRootHere / "build" / "bin" / "isonim-review"

proc shouldHave*(path: string) =
  if not fileExists(path):
    raise newException(IOError,
      "e2e_design_review_capture_fullsweep: binary not found at " & path &
      ".  Build it with `just isonim-review-build`.")

proc runOrFail(cmd: string; cwd: string) =
  let res = execCmdEx(cmd, workingDir = cwd)
  if res.exitCode != 0:
    raise newException(IOError, cmd & " failed (" & $res.exitCode &
                       "):\n" & res.output)

proc initRepo(repoPath: string): string =
  createDir(repoPath)
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

proc writeBrief(workspaceRoot: string) =
  let briefsDir = workspaceRoot / "briefs" / "render"
  createDir(briefsDir)
  writeFile(briefsDir / "fixture.md",
    "---\n" &
    "briefId: render.fixture\n" &
    "schemaVersion: 1\n" &
    "kind: render\n" &
    "title: fixture\n" &
    "coversPreviews:\n" &
    "  - storyRef: { group: G, name: \"N one\", kind: page, index: 0 }\n" &
    "    backends: [web]\n" &
    "  - storyRef: { group: G, name: \"N two\", kind: page, index: 0 }\n" &
    "    backends: [web]\n" &
    "captureViewports:\n" &
    "  - { width: 32, height: 32, label: tablet }\n" &
    "reviewerSchemaVersion: 1\n" &
    "scoringDimensions:\n" &
    "  - { id: a, label: A, weight: 1.0, scaleMin: 0, scaleMax: 5 }\n" &
    "---\nbody\n")

proc buildWorkspace(suffix: string; dirty = false): string =
  let ws = getTempDir() / ("isonim_e2e_" & suffix &
                            "_" & $epochTime().int)
  removeDir(ws)
  createDir(ws)
  let sha = initRepo(ws / "repo-a")
  writeManifest(ws, "repo-a", sha)
  writeBrief(ws)
  if dirty:
    writeFile(ws / "repo-a" / "README.md", "edited\n")
  ws

# ---------------------------------------------------------------------------
# Config writer + CLI invocation
# ---------------------------------------------------------------------------

proc writeConfig(workspaceRoot, storePath: string;
                 pgPort: int): string =
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
  ## Explicitly pass our env to the child so DYLD-related path
  ## variables (set by the surrounding ``nix-shell`` so libpq can
  ## be dynamically loaded) survive macOS's SIP env-stripping
  ## semantics, which sometimes drop ``DYLD_*`` on implicit inherit.
  ##
  ## While the CLI runs we drive *this* process's asyncdispatch so
  ## the fake-bridge listener accepts the CLI's WebSocket connection.
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

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "REV-M5 capture full sweep (e2e)":

  setup:
    shouldHave(IsonimReviewBin)

  test "e2e_capture_full_sweep_one_brief_clean":
    let pgf = newPgFixture()
    defer: pgf.shutdown()
    let fb = startFakeBridge()
    defer: fb.stop()
    let ws = buildWorkspace("clean")
    defer: removeDir(ws)
    let storePath = ws / "store"
    let cfg = writeConfig(ws, storePath, pgf.port)

    let res = runIsonimReview(@[
      "capture", "--brief", "render.fixture",
      "--bridge", "ws://127.0.0.1:" & $fb.port,
      "--workspace", ws,
      "--project", ws,
      "--config", cfg], cwd = ws)
    check res.exitCode == 0

    let mig = open("", "design_review_migrator", "",
                   "host=127.0.0.1 port=" & $pgf.port &
                   " dbname=isonim_design_review " &
                   "user=design_review_migrator")
    defer: mig.close()
    let runs = parseInt(mig.getValue(sql"""
      SELECT count(*) FROM design_review.runs
      WHERE brief_id = 'render.fixture' AND status = 'capture_complete'"""))
    check runs == 1
    let captures = parseInt(mig.getValue(sql"""
      SELECT count(*) FROM design_review.captures"""))
    check captures == 2

    # Two PNG files in the store, content-addressed.
    var pngFiles = 0
    for kind, path in walkDir(storePath, relative = false):
      if kind == pcDir:
        for k2, p2 in walkDir(path):
          if k2 == pcFile and p2.endsWith(".png"):
            inc pngFiles
    check pngFiles == 2

  test "e2e_capture_refuses_dirty_workspace":
    let pgf = newPgFixture()
    defer: pgf.shutdown()
    let fb = startFakeBridge()
    defer: fb.stop()
    let ws = buildWorkspace("dirty", dirty = true)
    defer: removeDir(ws)
    let storePath = ws / "store"
    let cfg = writeConfig(ws, storePath, pgf.port)
    let res = runIsonimReview(@[
      "capture", "--brief", "render.fixture",
      "--bridge", "ws://127.0.0.1:" & $fb.port,
      "--workspace", ws,
      "--project", ws,
      "--config", cfg], cwd = ws)
    check res.exitCode != 0
    check ("README.md" in res.stderr)
    let mig = open("", "design_review_migrator", "",
                   "host=127.0.0.1 port=" & $pgf.port &
                   " dbname=isonim_design_review " &
                   "user=design_review_migrator")
    defer: mig.close()
    let runs = parseInt(mig.getValue(
      sql"SELECT count(*) FROM design_review.runs"))
    check runs == 0
    # Store directory shouldn't exist or should be empty.
    var pngFiles = 0
    if dirExists(storePath):
      for kind, path in walkDir(storePath, relative = false):
        if kind == pcDir:
          for k2, p2 in walkDir(path):
            if k2 == pcFile and p2.endsWith(".png"):
              inc pngFiles
    check pngFiles == 0

  test "e2e_capture_retry_after_partial_failure_resumes":
    let pgf = newPgFixture()
    defer: pgf.shutdown()
    # First connection succeeds, *second* connection is refused — so
    # the first preview's capture goes through but the second one
    # fails mid-sweep.  The orchestration aborts after capturing 1 of
    # the 2 previews.  We then retry with a fresh bridge (no
    # refusal) and assert the (second) run completes and the captures
    # table has the full sweep.
    let fb1 = startFakeBridge(refuseNthConn = 2)
    defer: fb1.stop()
    let ws = buildWorkspace("retry")
    defer: removeDir(ws)
    let storePath = ws / "store"
    let cfg = writeConfig(ws, storePath, pgf.port)

    let r1 = runIsonimReview(@[
      "capture", "--brief", "render.fixture",
      "--bridge", "ws://127.0.0.1:" & $fb1.port,
      "--workspace", ws, "--project", ws, "--config", cfg], cwd = ws)
    # The orchestrator catches the timeout/handshake failure and
    # exits non-zero; the first capture has already been persisted.
    check r1.exitCode != 0
    fb1.stop()

    let mig = open("", "design_review_migrator", "",
                   "host=127.0.0.1 port=" & $pgf.port &
                   " dbname=isonim_design_review " &
                   "user=design_review_migrator")
    defer: mig.close()
    let firstCaptures = parseInt(mig.getValue(
      sql"SELECT count(*) FROM design_review.captures"))
    check firstCaptures == 1

    # Retry: fresh bridge, clean workspace.
    let fb2 = startFakeBridge()
    defer: fb2.stop()
    let r2 = runIsonimReview(@[
      "capture", "--brief", "render.fixture",
      "--bridge", "ws://127.0.0.1:" & $fb2.port,
      "--workspace", ws, "--project", ws, "--config", cfg], cwd = ws)
    check r2.exitCode == 0
    let totalCaptures = parseInt(mig.getValue(
      sql"SELECT count(*) FROM design_review.captures"))
    check totalCaptures == 3   # 1 from r1 + 2 from r2
    # Both runs exist.  The first is in capture_failed-or-capturing
    # state; the second is capture_complete.
    let complete = parseInt(mig.getValue(sql"""
      SELECT count(*) FROM design_review.runs
       WHERE status = 'capture_complete'"""))
    check complete == 1

  test "e2e_capture_records_workspace_manifest_hash":
    let pgf = newPgFixture()
    defer: pgf.shutdown()
    let fb = startFakeBridge()
    defer: fb.stop()
    let ws = buildWorkspace("hash")
    defer: removeDir(ws)
    let storePath = ws / "store"
    let cfg = writeConfig(ws, storePath, pgf.port)

    let res = runIsonimReview(@[
      "capture", "--brief", "render.fixture",
      "--bridge", "ws://127.0.0.1:" & $fb.port,
      "--workspace", ws, "--project", ws, "--config", cfg], cwd = ws)
    check res.exitCode == 0

    # The DB row's manifest_hash must equal the value we get from
    # captureManifestHash() against the same workspace.
    let mig = open("", "design_review_migrator", "",
                   "host=127.0.0.1 port=" & $pgf.port &
                   " dbname=isonim_design_review " &
                   "user=design_review_migrator")
    defer: mig.close()
    let stored = mig.getValue(sql"""
      SELECT manifest_hash FROM design_review.runs
      WHERE brief_id = 'render.fixture' LIMIT 1""")
    check stored.len == 64

    let xml = readFile(ws / ".repo" / "manifest.xml")
    let computed = captureManifestHashOfBytes(xml)
    check computed == stored
