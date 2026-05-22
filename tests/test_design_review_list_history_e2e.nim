## TBAR-M1 — end-to-end ``list-history`` exercise through the editor's
## own HTTP client surface, against the real daemon.
##
## This test exists to seal a regression in the editor's gallery
## history-button flow.  The chain is:
##
##   * The history-button mount in ``views/design_review_mount.nim``
##     derives a ``briefId: Signal[string]`` from the active story +
##     selected backend.  When that derivation goes wrong, the briefId
##     written into the URL doesn't match the briefId stored in the
##     ``design_review.runs`` table, so the daemon's
##     ``list_history(briefId, ...)`` call returns an empty array and
##     the gallery overlay renders empty even when the DB has runs.
##
##   * The fix lives in ``resolveBriefId`` (or wherever the bug ends
##     up being).  This test pins the regression in two complementary
##     ways:
##
##     1. ``test_fetch_list_history_returns_run_for_real_brief`` —
##        boots the real ``isonim-review serve`` daemon against a
##        process-compose Postgres cluster, seeds 1 run + 7 captures +
##        1 agent report against ``brief_id = 'render.task-app'``, and
##        drives the editor's own ``fetchListHistory`` proc end-to-end.
##        Asserts a non-empty array with the seeded ``run_id``.
##
##     2. ``test_resolve_brief_id_matches_render_task_app_for_inbox`` —
##        VM-level guard.  Creates an ``EditorVM`` with the Inbox story
##        + ``pbWeb`` backend and asserts that the briefId signal lands
##        on ``render.task-app`` (the canonical briefId baked into
##        ``builtInBriefIndex``).  This is the actual editor JS
##        path — the one the user's browser hit when the history
##        button rendered an empty gallery against ``m1.local:8091``.
##
## No mocks at any layer — real daemon, real PG cluster, real
## ``EditorHttpClient`` (its native backend, which is path-equivalent
## to the JS ``fetch`` path for everything except transport).

import std/[json, os, osproc, streams, strutils, unittest]

import isonim/core/[signals, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/design_review/editor_http_client
import isonim/editor/views/design_review_mount

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
  let r = execCmdEx("shasum -a 256 " & path)
  if r.exitCode != 0:
    raise newException(IOError, "shasum failed: " & r.output)
  let parts = r.output.splitWhitespace()
  if parts.len == 0:
    raise newException(IOError, "shasum empty output")
  parts[0].toLowerAscii

proc seedRenderTaskAppFixture(f: ServeFixture): tuple[runId: string;
                                                       captureIds: seq[string]] =
  ## Seed exactly the rows the milestone brief calls for:
  ## 1 ``runs`` + 7 ``captures`` + 1 ``agent_reports`` against
  ## ``render.task-app``.  Uses the same SECURITY-DEFINER routines the
  ## production capture CLI uses, via psql to keep this test independent
  ## of any in-process DB connection wiring.
  let png = hexDecode(FixturePngHex)
  let scratch = getTempDir() / "isonim-tbar-m1-fixture-png"
  writeFile(scratch, png)
  let sha = sha256Lower(scratch)
  let dirInStore = f.storePath / sha[0 ..< 2]
  createDir(dirInStore)
  let pathInStore = dirInStore / (sha & ".png")
  if not fileExists(pathInStore):
    writeFile(pathInStore, png)
  removeFile(scratch)

  let connStr = "-h 127.0.0.1 -p " & $f.pg.port & " -d isonim_design_review"
  let runId = seedRunInDb(connStr, "render.task-app", "manifesthash-tbar-m1")
  var capIds: seq[string] = @[]
  const Backends = ["web", "tui", "gpui", "freya", "cocoa", "android", "ios"]
  for be in Backends:
    let previewId = "Task App %2F Pages/Inbox:page#0@" & be
    let capId = seedCaptureInDb(connStr, runId, previewId, be, "wide",
                                sha, pathInStore, 1920, 1080)
    capIds.add(capId)
  finishCapturesInDb(connStr, runId)
  # JSON literal must be space-free because the fixture's psql shell
  # quoting splits the command on shell whitespace.
  # The shared ``seedAgentReportInDb`` helper builds a single -c argument
  # with naive double-quote wrapping; JSON payloads need real shell-safe
  # escaping.  Use psql's stdin-driven mode here, with PostgreSQL's
  # ``$tag$..$tag$`` dollar-quoting around the JSON literal so we never
  # have to escape ``'`` or ``"``.
  block:
    let sql =
      "SELECT design_review.record_agent_report('" & runId &
      "'::uuid, 'tbar-m1-fixture', '0.0.0', '/dev/null', " &
      "$jb${\"summary\":\"tbar-m1-fixture-report\",\"backendScores\":[]}$jb$::jsonb);\n"
    let p = startProcess("psql",
      args = @["-h", "127.0.0.1", "-p", $f.pg.port,
               "-d", "isonim_design_review",
               "-v", "ON_ERROR_STOP=1", "-A", "-t", "-q"],
      options = {poUsePath, poStdErrToStdOut})
    p.inputStream.write(sql)
    p.inputStream.close()
    let output = p.outputStream.readAll()
    discard p.waitForExit()
    let code = p.peekExitCode()
    p.close()
    if code != 0:
      raise newException(IOError,
        "seedAgentReportInDb via stdin failed: " & output)
  (runId: runId, captureIds: capIds)

suite "TBAR-M1 list-history end-to-end":

  test "test_fetch_list_history_returns_run_for_real_brief":
    ## Exercises the editor's own ``fetchListHistory`` proc against a
    ## real daemon.  This is the bug under test: if the editor's HTTP
    ## layer is correct and the daemon's handler is correct, the
    ## response array has the seeded run.  If it's empty, the
    ## handler/transport regressed.
    let f = startServeAndSeed()
    defer: f.shutdown()
    let seeded = seedRenderTaskAppFixture(f)
    check seeded.runId.len == 36

    createRoot do (dispose: proc()):
      let client = newEditorHttpClient(f.baseUrl)
      var result: HttpCallbackResult
      var called = false
      proc cb(res: HttpCallbackResult) {.closure.} =
        result = res
        called = true
      fetchListHistory(client, "render.task-app", 50, 0, cb)
      check called
      check result.kind == hcOk
      check result.statusCode == 200
      # Non-empty array — the bug we're sealing is "empty array even
      # though the DB has rows".
      let body = parseJson(result.body)
      check body.kind == JArray
      check body.len == 1
      check body[0]["run_id"].getStr == seeded.runId
      check body[0]["brief_id"].getStr == "render.task-app"
      # ``capture_count`` and ``report_count`` are part of the list-
      # history row shape produced by ``design_review.list_history``;
      # the milestone brief calls them out as test oracles.
      check body[0]["capture_count"].getInt == 7
      check body[0]["report_count"].getInt == 1
      dispose()

  test "test_resolve_brief_id_matches_render_task_app_for_inbox":
    ## VM-level guard: the briefId an EditorVM with the canonical
    ## Inbox story + Web backend produces must match the briefId the
    ## DB stores (``render.task-app``).  This is the path the running
    ## browser editor takes; if this assertion fails the gallery
    ## history button hits an unrelated URL and the response is
    ## always empty.
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.selectedStory.val = StoryRef(
        group: "Task App / Pages",
        name: "Inbox",
        kind: skPage,
        index: 0)
      vm.platform.val = pbWeb
      let st = ensureDesignReviewState(vm)
      # The reactive effect set up in ``ensureDesignReviewState``
      # is scheduled — flush by re-reading the signal (signals propagate
      # synchronously on the native backend).
      let bid = st.briefId.val
      check bid == "render.task-app"
      dispose()
