## CMP-M2 — ``isonim-review campaign`` CLI tests.
##
## Each test runs ``build/bin/isonim-review campaign ...`` as a real
## subprocess against the real daemon + real Postgres + the fake ACP
## agent.  No in-process mocks at the DB, HTTP, or CLI boundary.

import std/[json, os, osproc, strutils, times, unittest]

import helpers/campaign_routes_fixture

# ---------------------------------------------------------------------------
# Fixture campaign doc + brief on disk — the CLI's ``start`` subcommand
# reads them off the filesystem and feeds them into the daemon.
# ---------------------------------------------------------------------------

type FixturePaths = object
  projectDir: string
  campaignDir: string
  briefsDir: string
  campaignPath: string
  briefPath: string

proc writeFixtures(): FixturePaths =
  result.projectDir = getTempDir() / ("cmp_m2_proj_" &
                       $((int(epochTime() * 1000)) mod 1_000_000))
  removeDir(result.projectDir)
  result.campaignDir = result.projectDir / "campaigns"
  result.briefsDir = result.projectDir / "briefs" / "render"
  createDir(result.campaignDir)
  createDir(result.briefsDir)
  result.campaignPath = result.campaignDir / "cli-fixture.md"
  result.briefPath = result.briefsDir / "demo-app.md"
  writeFile(result.campaignPath, """---
campaignId: cli-fixture
schemaVersion: 1
briefRefs:
  - render.demo-app
targetScore: 9.0
maxIterations: 3
status: pending
---

# CLI fixture campaign

## Objectives
- Smoke test the campaign CLI surface.

## Scope
- demo-app only.
""")
  writeFile(result.briefPath, """---
briefId: render.demo-app
schemaVersion: 1
kind: render
title: Demo App brief (CLI fixture)
coversPreviews:
  - storyRef: { group: "Demo App", name: "Page", kind: page, index: 0 }
    backends: [web]
captureViewports:
  - { width: 1280, height: 800, label: "wide" }
scoringDimensions:
  - { id: "render", label: "Render quality", weight: 1.0,
      scale: { min: 1, max: 10 } }
---

This is a CLI fixture brief.
""")

proc invokeCli(baseUrl: string;
               args: openArray[string]):
    tuple[exitCode: int; outText, errText: string] =
  let outPath = getTempDir() / ("cli_campaign_stdout_" &
                $((int(epochTime() * 1000)) mod 1_000_000))
  let errPath = getTempDir() / ("cli_campaign_stderr_" &
                $((int(epochTime() * 1000)) mod 1_000_000))
  defer:
    try: removeFile(outPath) except OSError: discard
    try: removeFile(errPath) except OSError: discard
  let parts = @[CliPath, "campaign"] & @args & @["--daemon=" & baseUrl]
  let cmd = parts.join(" ") &
    " > " & quoteShell(outPath) & " 2> " & quoteShell(errPath)
  let exitCode = execShellCmd(cmd)
  let outText =
    if fileExists(outPath): readFile(outPath) else: ""
  let errText =
    if fileExists(errPath): readFile(errPath) else: ""
  (exitCode, outText, errText)

# ---------------------------------------------------------------------------

test "test_cli_campaign_start_streams_orchestrator_output":
  let f = startCampaignDaemon(@[
    ("FAKE_ACP_STREAM_CHUNKS", "3"),
    ("FAKE_ACP_REPLY",         "ROUND ONE PLAN CHUNK"),
  ])
  defer: f.shutdown()
  let fx = writeFixtures()
  defer: removeDir(fx.projectDir)

  let (exitCode, outText, errText) = invokeCli(f.baseUrl,
    ["start", "--doc", fx.campaignPath])
  check exitCode == 0
  # The fake-ACP reply is split across three chunks; check that they
  # land on stdout joined into one string.
  check outText.contains("ROUND ONE PLAN CHUNK")
  # Lifecycle message on stderr — the CLI prints
  # ``campaign started: <uuid>`` after the SSE stream completes.
  check errText.contains("campaign started: ")
  check errText.contains("round complete (stopReason=end_turn)")

  check countCampaigns(f) == 1

test "test_cli_campaign_list_shows_running_campaign":
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let fx = writeFixtures()
  defer: removeDir(fx.projectDir)
  let (sExit, _, _) = invokeCli(f.baseUrl,
    ["start", "--doc", fx.campaignPath, "--no-tail"])
  check sExit == 0

  # The campaign's post-turn transition (active → failed when the
  # doc never sets a terminal status) runs asynchronously after the
  # SSE socket closes.  The list output may show either ``active``
  # or ``failed`` depending on timing.  We accept either, but assert
  # the campaign appears in the listing AND that one of the two
  # statuses landed.
  let (lExit, lOut, _) = invokeCli(f.baseUrl, ["list"])
  check lExit == 0
  check lOut.contains("active") or lOut.contains("failed")
  check lOut.contains(fx.campaignPath.extractFilename) or
        lOut.contains("cli-fixture.md")

test "test_cli_campaign_show_prints_state":
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let fx = writeFixtures()
  defer: removeDir(fx.projectDir)
  let (sExit, sOut, _) = invokeCli(f.baseUrl,
    ["start", "--doc", fx.campaignPath, "--no-tail"])
  check sExit == 0
  let campaignId = sOut.strip()
  check campaignId.len >= 32

  let (showExit, showOut, _) = invokeCli(f.baseUrl,
    ["show", campaignId])
  check showExit == 0
  check showOut.contains("brief_refs:")
  check showOut.contains("render.demo-app")
  # The campaign may be ``active`` (post-turn cleanup hasn't fired
  # yet) or ``failed`` (the fallback transition has fired since the
  # fixture doc never sets a terminal status).  Accept either.
  check showOut.contains("status:         active") or
        showOut.contains("status:         failed")
  check showOut.contains("max_iterations: 3")
  check showOut.contains("recent_events:")

proc invokeCliWithStdin(baseUrl: string;
                        args: openArray[string];
                        stdinPayload: string):
    tuple[exitCode: int; outText, errText: string] =
  ## Same shape as :proc:`invokeCli` but feeds ``stdinPayload`` to the
  ## subprocess's stdin via shell redirection from a temp file.  Used by
  ## the ``--stdin`` CLI tests.
  let outPath = getTempDir() / ("cli_campaign_stdout_" &
                $((int(epochTime() * 1000)) mod 1_000_000))
  let errPath = getTempDir() / ("cli_campaign_stderr_" &
                $((int(epochTime() * 1000)) mod 1_000_000))
  let stdinPath = getTempDir() / ("cli_campaign_stdin_" &
                $((int(epochTime() * 1000)) mod 1_000_000))
  writeFile(stdinPath, stdinPayload)
  defer:
    try: removeFile(outPath) except OSError: discard
    try: removeFile(errPath) except OSError: discard
    try: removeFile(stdinPath) except OSError: discard
  let parts = @[CliPath, "campaign"] & @args & @["--daemon=" & baseUrl]
  let cmd = parts.join(" ") &
    " < " & quoteShell(stdinPath) &
    " > " & quoteShell(outPath) & " 2> " & quoteShell(errPath)
  let exitCode = execShellCmd(cmd)
  let outText =
    if fileExists(outPath): readFile(outPath) else: ""
  let errText =
    if fileExists(errPath): readFile(errPath) else: ""
  (exitCode, outText, errText)

# ---------------------------------------------------------------------------
# CMP-M4 — ``isonim-review campaign inject`` + ``campaign edit-doc``.
#
# CMP-M7 update: these three ``inject_*`` subtests were written against the
# CMP-M4 assumption that a campaign keeps a live ACP session after ``start``.
# CMP-M6/CMP-M7 made the campaign a single ACP turn whose session is torn
# down (``dropSession`` + ``shutdownAndRelease``) the moment the turn ends,
# and ``start --no-tail`` drains the SSE stream to that ``end`` event before
# it returns.  So by the time ``inject`` runs, the session is gone and the
# route is honest about it: it returns 404 ``no_active_session`` and records
# NO note — the contract deliberately enshrined by
# ``test_design_review_campaign_routes.nim`` (``test_inject_after_turn_end_
# returns_404`` / ``test_inject_after_turn_end_does_not_record_event``).
# These subtests assert that same CMP-M7 contract end-to-end through the CLI
# + daemon + Postgres stack for each of the three text-input methods; each
# still verifies its input method resolved a non-empty string (an empty
# resolution exits 2 "text is empty" BEFORE the POST, not 5).  Exercising the
# in-flight-inject success path is intentionally left to a future milestone
# — the fake-ACP fixture exits too fast to hold a session open reliably (see
# the campaign_routes note).
# ---------------------------------------------------------------------------

test "test_cli_campaign_inject_after_turn_end_positional_text_returns_404":
  ## ``isonim-review campaign inject <id> "hello operator"`` after
  ## ``start --no-tail`` → exit 5 (route 404 ``no_active_session``), no
  ## ``operator_injection`` note recorded (CMP-M7 contract).
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let fx = writeFixtures()
  defer: removeDir(fx.projectDir)
  let (sExit, sOut, _) = invokeCli(f.baseUrl,
    ["start", "--doc", fx.campaignPath, "--no-tail"])
  check sExit == 0
  let campaignId = sOut.strip()

  let (iExit, _, iErr) = invokeCli(f.baseUrl,
    ["inject", campaignId, "hello operator"])
  check iExit == 5
  check iErr.contains("no_active_session")

  var sawInjection = false
  for e in eventsForCampaign(f, campaignId):
    if e.kind == "note":
      let p = parseJson(e.payload)
      if p{"kind"}.getStr("") == "operator_injection":
        sawInjection = true
  check not sawInjection

test "test_cli_campaign_inject_after_turn_end_message_file_returns_404":
  ## ``--message-file`` reads the text off disk verbatim (newlines and
  ## all) and POSTs it; after ``start --no-tail`` the session is gone, so
  ## the route returns 404 ``no_active_session`` (CLI exit 5) and records
  ## no note.  Reaching the 404 (rather than exit 2 "text is empty")
  ## confirms the file was read into a non-empty string (CMP-M7).
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let fx = writeFixtures()
  defer: removeDir(fx.projectDir)
  let (sExit, sOut, _) = invokeCli(f.baseUrl,
    ["start", "--doc", fx.campaignPath, "--no-tail"])
  check sExit == 0
  let campaignId = sOut.strip()

  let msgPath = getTempDir() / ("cli_inject_msg_" &
                $((int(epochTime() * 1000)) mod 1_000_000) & ".txt")
  let payload = "multi-line message\nwith two lines\n"
  writeFile(msgPath, payload)
  defer:
    try: removeFile(msgPath) except OSError: discard

  let (iExit, _, iErr) = invokeCli(f.baseUrl,
    ["inject", campaignId, "--message-file", msgPath])
  check iExit == 5
  check iErr.contains("no_active_session")

  var sawInjection = false
  for e in eventsForCampaign(f, campaignId):
    if e.kind == "note":
      let p = parseJson(e.payload)
      if p{"kind"}.getStr("") == "operator_injection":
        sawInjection = true
  check not sawInjection

test "test_cli_campaign_inject_after_turn_end_stdin_returns_404":
  ## ``--stdin`` reads text from stdin and POSTs it; after
  ## ``start --no-tail`` the session is gone, so the route returns 404
  ## ``no_active_session`` (CLI exit 5) and records no note.  Reaching the
  ## 404 (rather than exit 2 "text is empty") confirms stdin was read into
  ## a non-empty string (CMP-M7).
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let fx = writeFixtures()
  defer: removeDir(fx.projectDir)
  let (sExit, sOut, _) = invokeCli(f.baseUrl,
    ["start", "--doc", fx.campaignPath, "--no-tail"])
  check sExit == 0
  let campaignId = sOut.strip()

  let payload = "stdin-piped operator inject"
  let (iExit, _, iErr) = invokeCliWithStdin(f.baseUrl,
    ["inject", campaignId, "--stdin"], payload)
  check iExit == 5
  check iErr.contains("no_active_session")

  var sawInjection = false
  for e in eventsForCampaign(f, campaignId):
    if e.kind == "note":
      let p = parseJson(e.payload)
      if p{"kind"}.getStr("") == "operator_injection":
        sawInjection = true
  check not sawInjection

test "test_cli_campaign_edit_doc_refreshes_sha":
  ## ``campaign edit-doc <id> --no-edit`` after mutating the on-disk
  ## doc: doc_sha updates, a doc_refreshed note event lands.
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let fx = writeFixtures()
  defer: removeDir(fx.projectDir)
  let (sExit, sOut, _) = invokeCli(f.baseUrl,
    ["start", "--doc", fx.campaignPath, "--no-tail"])
  check sExit == 0
  let campaignId = sOut.strip()

  let beforeRows = fetchCampaignByDoc(f, fx.campaignPath.absolutePath())
  let beforeSha = beforeRows[0][6]

  # Mutate the doc on disk.
  let original = readFile(fx.campaignPath)
  writeFile(fx.campaignPath,
    original & "\n## CLI edit-doc test\n\n- Added marker " &
    $epochTime() & "\n")

  let (eExit, _, eErr) = invokeCli(f.baseUrl,
    ["edit-doc", campaignId, "--no-edit"])
  check eExit == 0
  check eErr.contains("doc refreshed")
  check eErr.contains("contentChanged=true")

  let afterRows = fetchCampaignByDoc(f, fx.campaignPath.absolutePath())
  check afterRows.len == 1
  check afterRows[0][6] != beforeSha
  check afterRows[0][6].len == 64

  var sawRefresh = false
  for e in eventsForCampaign(f, campaignId):
    if e.kind == "note":
      let p = parseJson(e.payload)
      if p{"kind"}.getStr("") == "doc_refreshed":
        sawRefresh = true
        check p{"contentChanged"}.getBool(false)
        check p{"oldSha"}.getStr("") == beforeSha
        check p{"newSha"}.getStr("") == afterRows[0][6]
  check sawRefresh

test "test_cli_campaign_stop_marks_status":
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let fx = writeFixtures()
  defer: removeDir(fx.projectDir)
  let (sExit, sOut, _) = invokeCli(f.baseUrl,
    ["start", "--doc", fx.campaignPath, "--no-tail"])
  check sExit == 0
  let campaignId = sOut.strip()

  # In the CMP-M6 single-turn model the campaign may have already
  # transitioned to ``failed`` (post-turn fallback) by the time the
  # CLI's ``stop`` subprocess runs.  Either:
  #   * stop wins the race → exit 0, status becomes ``stopped``;
  #   * the failed-fallback wins → stop's transition_campaign rejects
  #     the terminal-to-terminal flip, the CLI exits 5, and the show
  #     output reflects ``failed``.
  let (stopExit, _, _) = invokeCli(f.baseUrl,
    ["stop", campaignId, "--reason", "cli-test-shutdown"])
  check stopExit in [0, 5]

  let (showExit, showOut, _) = invokeCli(f.baseUrl,
    ["show", campaignId])
  check showExit == 0
  check showOut.contains("status:         stopped") or
        showOut.contains("status:         failed")
