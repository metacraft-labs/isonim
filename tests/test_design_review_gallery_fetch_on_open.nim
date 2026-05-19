## REV-M8 — production gallery auto-fetch on first open.
##
## The first review of REV-M8 caught a real gap: the production 🕘
## button toggled the gallery host but the data-fetch loop
## (``list-history`` → ``fetch-run`` per run → assemble tiles) was
## unfinished, so clicking the button showed an empty "No captures
## yet" placeholder even when the daemon had history for the active
## brief.  This test seals the gap: it boots a real daemon + a real
## Postgres fixture, seeds one run with two captures, then calls
## ``fetchGalleryTiles`` (the proc the production mount calls when
## the host first opens) and asserts the VM's ``tiles.val`` is
## populated with the seeded captures.
##
## No mocks — the http client, the JSON parsers, and the DB are all
## the production code paths.  This is the same shape as REV-M7's
## ``test_design_review_api_*`` suite (real daemon + real Postgres).

import std/[json, options, os, osproc, strutils, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/design_review/daemon_discovery
import isonim/editor/design_review/editor_http_client
import isonim/editor/views/design_review_mount
import isonim/editor/views/gallery_overlay

import helpers/design_review_http_fixture

const FixturePngHex =
  "89504e470d0a1a0a0000000d49484452000000010000000108020000009077" &
  "53de0000000c4944415478" &
  "9c63000100000500010d2db40000000049454e44ae426082"

proc hexDecode(s: string): string =
  result = newStringOfCap(s.len div 2)
  var i = 0
  while i + 1 < s.len:
    let hi = parseHexInt(s[i ..< i + 2])
    result.add(char(hi))
    inc i, 2

proc sha256Lower(path: string): string =
  ## Shell out to ``shasum`` — every nix-shell that has ``curl`` has
  ## ``shasum`` too.  We need the canonical lowercase hex digest.
  let r = execCmdEx("shasum -a 256 " & path)
  if r.exitCode != 0:
    raise newException(IOError, "shasum failed: " & r.output)
  let parts = r.output.splitWhitespace()
  if parts.len == 0:
    raise newException(IOError, "shasum empty output")
  parts[0].toLowerAscii

proc seedRunWithCaptures(f: ServeFixture; briefId: string;
                        captureCount: int): seq[string] =
  ## Put ``captureCount`` PNG bytes into the store and create one run +
  ## ``captureCount`` capture rows for ``briefId``.  Returns the list
  ## of capture ids (UUID strings) for assertion-side bookkeeping.
  result = @[]
  # 1) Write the same tiny PNG into the store at <sha[:2]>/<sha>.png
  #    (matching CaptureStore's directory layout).
  let png = hexDecode(FixturePngHex)
  let scratch = getTempDir() / "isonim-revm8-gfo-png"
  writeFile(scratch, png)
  let sha = sha256Lower(scratch)
  let dirInStore = f.storePath / sha[0 ..< 2]
  createDir(dirInStore)
  let pathInStore = dirInStore / (sha & ".png")
  if not fileExists(pathInStore):
    writeFile(pathInStore, png)
  removeFile(scratch)
  # 2) Create one run + N captures via psql (the fixture's seed
  # helpers use the same SECURITY DEFINER routines).
  let connStr = "-h 127.0.0.1 -p " & $f.pg.port & " -d isonim_design_review"
  let runId = seedRunInDb(connStr, briefId)
  for i in 0 ..< captureCount:
    let previewId = "p/" & briefId & "#" & $i & "@web"
    let capId = seedCaptureInDb(connStr, runId, previewId, "web", "mobile",
                                sha, pathInStore, 320, 568)
    result.add(capId)
  finishCapturesInDb(connStr, runId)

suite "REV-M8 gallery fetch-on-open":

  test "test_gallery_fetch_populates_tiles_from_seeded_run":
    let f = startServeAndSeed()
    defer: f.shutdown()
    discard seedRunWithCaptures(f, "render.task-app", 2)

    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      let st = ensureDesignReviewState(vm)
      # Override the discovery-bound client with one pointed at the
      # fixture's daemon (the env-var path would also work but this
      # is more explicit).
      st.httpClient = newEditorHttpClient(f.baseUrl)
      st.briefId.val = "render.task-app"
      check st.galleryVm.tiles.val.len == 0
      # Drive the same proc the production mount calls when the host
      # first opens.  The native client invokes the callback inline so
      # ``tiles.val`` is populated synchronously on return.
      fetchGalleryTiles(st)
      check st.galleryVm.tiles.val.len == 2
      let t0 = st.galleryVm.tiles.val[0]
      check t0.captureId.len == 36  # UUID
      check t0.runId.len == 36
      check t0.previewId.startsWith("p/render.task-app#")
      check t0.width == 320
      check t0.height == 568
      check t0.pngUrl.startsWith("/api/design-review/get-capture-png?id=")
      dispose()

  test "test_gallery_fetch_noop_when_brief_empty":
    let f = startServeAndSeed()
    defer: f.shutdown()
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      let st = ensureDesignReviewState(vm)
      st.httpClient = newEditorHttpClient(f.baseUrl)
      # No briefId set.
      fetchGalleryTiles(st)
      check st.galleryVm.tiles.val.len == 0
      dispose()

  test "test_gallery_fetch_clears_tiles_when_history_empty":
    let f = startServeAndSeed()
    defer: f.shutdown()
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      let st = ensureDesignReviewState(vm)
      st.httpClient = newEditorHttpClient(f.baseUrl)
      st.briefId.val = "render.never-recorded"
      # Pre-populate so we can observe the "clear on empty" branch.
      st.galleryVm.tiles.val = @[GalleryTile(captureId: "stale")]
      fetchGalleryTiles(st)
      check st.galleryVm.tiles.val.len == 0
      dispose()
