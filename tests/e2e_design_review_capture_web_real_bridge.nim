## REV-M5 (follow-up) — end-to-end capture against the *real*
## ``isonim-examples-web`` launcher binary.
##
## This test is the deferred piece from REV-M5/M10's "live
## isonim-render-serve subprocess + real backend launchers" task.  It
## complements ``e2e_design_review_capture_fullsweep.nim`` (which uses
## an in-process fake bridge) by exercising the full launcher-spawn
## path:
##
##   1. Spin up a real Postgres cluster via the REV-M3 ``PgFixture``.
##   2. Build a clean tmpdir workspace with a synthetic .repo manifest
##      and the single-backend brief from
##      ``tests/fixtures/design_review/briefs_for_real_capture/render/
##      task-app-web.md``.
##   3. Invoke ``isonim-review capture`` *without* ``--bridge`` so the
##      pipeline routes through ``backend_launcher.launchBackend`` and
##      spawns the real ``isonim-examples-web`` binary at a port in
##      the 8200..8299 range.
##   4. Assert: exit code 0, ≥1 row in ``design_review.captures``, ≥1
##      PNG in the content-addressed store with ``width > 0``,
##      ``height > 0``, and at least three distinct RGB values across
##      the pixel buffer (rules out the flat fallback gradient).
##
## The web launcher is the easiest backend to drive — no GPU, no
## device, no emulator — so this test is reliable on CI without any
## additional system setup.

import std/[os, osproc, parseutils, streams, strtabs, strutils,
            times, unittest]

import db_connector/db_postgres

import isonim/editor/design_review/png_codec

import helpers/design_review_pg_fixture

const RepoRootHere = currentSourcePath().parentDir().parentDir()
const IsonimReviewBin = RepoRootHere / "build" / "bin" / "isonim-review"
const ExamplesRoot = RepoRootHere.parentDir() / "isonim-examples"
const WebLauncherBin =
  ExamplesRoot / "build" / "backends" / "isonim-examples-web"
const FixtureBrief = RepoRootHere / "tests" / "fixtures" /
  "design_review" / "briefs_for_real_capture" / "render" /
  "task-app-web.md"

proc shouldExist(path, hint: string) =
  if not fileExists(path):
    raise newException(IOError,
      "e2e_design_review_capture_web_real_bridge: " & path &
      " not found.  " & hint)

# ---------------------------------------------------------------------------
# Workspace fixture builder (mirrors e2e_design_review_capture_fullsweep)
# ---------------------------------------------------------------------------

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

proc copyBriefIntoWorkspace(workspaceRoot, briefSrc: string) =
  let briefsDir = workspaceRoot / "briefs" / "render"
  createDir(briefsDir)
  copyFile(briefSrc, briefsDir / "task-app-web.md")

proc buildWorkspace(suffix: string): string =
  let ws = getTempDir() / ("isonim_e2e_real_" & suffix &
                            "_" & $epochTime().int)
  removeDir(ws)
  createDir(ws)
  let sha = initRepo(ws / "repo-a")
  writeManifest(ws, "repo-a", sha)
  copyBriefIntoWorkspace(ws, FixtureBrief)
  ws

proc writeConfig(workspaceRoot, storePath, backendDir: string;
                 pgPort: int): string =
  let cfgPath = workspaceRoot / "config.toml"
  writeFile(cfgPath,
    "[db]\nhost = \"127.0.0.1\"\nport = " & $pgPort &
    "\ndatabase = \"isonim_design_review\"\n" &
    "url = \"postgres://design_review_app@127.0.0.1:" & $pgPort &
    "/isonim_design_review\"\n" &
    "[store]\npath = \"" & storePath & "\"\n" &
    "[workspace]\nroot = \"" & workspaceRoot & "\"\n" &
    "[backend]\nbinary_dir = \"" & backendDir & "\"\n")
  cfgPath

proc runIsonimReview(args: seq[string]; cwd: string):
                     tuple[exitCode: int; stdout, stderr: string] =
  var environ = newStringTable(modeCaseSensitive)
  for kv in envPairs():
    environ[kv.key] = kv.value
  let p = startProcess(IsonimReviewBin, args = args,
                       workingDir = cwd, env = environ,
                       options = {poUsePath})
  let so = p.outputStream.readAll()
  let se = p.errorStream.readAll()
  let code = p.waitForExit()
  p.close()
  (exitCode: code, stdout: so, stderr: se)

proc countDistinctRgb(img: PngImage; cap = 16): int =
  ## Walk the decoded RGBA buffer and count unique (R, G, B) triples
  ## up to ``cap``.  Stops early once we hit the cap to keep the test
  ## fast on large surfaces.  The launcher paints a navy background +
  ## header band + per-character accent stripes, so any non-trivial
  ## capture comfortably exceeds the 3-distinct threshold.
  var seen: seq[uint32] = @[]
  var i = 0
  while i < img.pixels.len:
    let key = (uint32(img.pixels[i]) shl 16) or
              (uint32(img.pixels[i+1]) shl 8) or
              uint32(img.pixels[i+2])
    var found = false
    for s in seen:
      if s == key:
        found = true; break
    if not found:
      seen.add key
      if seen.len >= cap:
        return seen.len
    i += 4
  seen.len

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "REV-M5 follow-up: capture against real isonim-examples-web":

  setup:
    shouldExist(IsonimReviewBin,
      "Build it with `just isonim-review-build`.")
    shouldExist(WebLauncherBin,
      "Build it via `direnv exec ~/metacraft/isonim-examples just build-backends`.")
    shouldExist(FixtureBrief,
      "Fixture is required for this test.")

  test "e2e_capture_web_against_real_launcher":
    let pgf = newPgFixture()
    defer: pgf.shutdown()
    let ws = buildWorkspace("web")
    defer: removeDir(ws)
    let storePath = ws / "store"
    let backendDir = ExamplesRoot / "build" / "backends"
    let cfg = writeConfig(ws, storePath, backendDir, pgf.port)

    # Note: no ``--bridge`` flag — the capture pipeline routes through
    # ``backend_launcher.launchBackend`` and spawns the real web binary.
    let res = runIsonimReview(@[
      "capture", "--brief", "render.task-app-web",
      "--workspace", ws,
      "--project", ws,
      "--config", cfg,
      "--backend-binary-dir", backendDir,
      "--backends", "web"], cwd = ws)
    if res.exitCode != 0:
      echo "stdout:\n", res.stdout
      echo "stderr:\n", res.stderr
    check res.exitCode == 0

    let mig = open("", "design_review_migrator", "",
                   "host=127.0.0.1 port=" & $pgf.port &
                   " dbname=isonim_design_review " &
                   "user=design_review_migrator")
    defer: mig.close()
    let captures = parseInt(mig.getValue(sql"""
      SELECT count(*) FROM design_review.captures"""))
    check captures >= 1

    let backendCount = parseInt(mig.getValue(sql"""
      SELECT count(*) FROM design_review.captures
       WHERE backend = 'web'"""))
    check backendCount >= 1

    # Find the first PNG in the store and decode it.
    var pngPath = ""
    var widthSeen = 0
    var heightSeen = 0
    for kind, dirPath in walkDir(storePath, relative = false):
      if kind == pcDir:
        for k2, p2 in walkDir(dirPath):
          if k2 == pcFile and p2.endsWith(".png"):
            pngPath = p2
            break
      if pngPath.len > 0: break
    check pngPath.len > 0

    let pngBytes = readFile(pngPath)
    var bytesBuf = newSeq[byte](pngBytes.len)
    for i, c in pngBytes:
      bytesBuf[i] = byte(c)
    let img = decodePng32(bytesBuf)
    widthSeen = img.width
    heightSeen = img.height
    check widthSeen > 0
    check heightSeen > 0
    # The launcher paints a navy background + header band + per-row
    # accent stripes, so a healthy capture has many distinct RGB
    # triples.  Any flat-colour buffer collapses to ≤2.
    let distinctCount = countDistinctRgb(img, cap = 16)
    check distinctCount >= 3

    # DB-recorded dimensions should agree with the decoded ones.
    let dimRow = mig.getValue(sql"""
      SELECT width || 'x' || height FROM design_review.captures
       LIMIT 1""")
    var dbW, dbH: int
    let xIdx = dimRow.find('x')
    if xIdx > 0:
      discard parseInt(dimRow[0 ..< xIdx], dbW)
      discard parseInt(dimRow[xIdx + 1 .. ^1], dbH)
    check dbW == widthSeen
    check dbH == heightSeen
