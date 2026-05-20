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

  let (lExit, lOut, _) = invokeCli(f.baseUrl, ["list"])
  check lExit == 0
  check lOut.contains("active")
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
  check showOut.contains("status:         active")
  check showOut.contains("max_iterations: 3")
  check showOut.contains("recent_events:")

test "test_cli_campaign_tick_advances_round":
  let f = startCampaignDaemon(@[("FAKE_ACP_STREAM_CHUNKS", "2")])
  defer: f.shutdown()
  let fx = writeFixtures()
  defer: removeDir(fx.projectDir)
  let (sExit, sOut, _) = invokeCli(f.baseUrl,
    ["start", "--doc", fx.campaignPath, "--no-tail"])
  check sExit == 0
  let campaignId = sOut.strip()

  let (tExit, _, _) = invokeCli(f.baseUrl,
    ["tick", campaignId, "--no-tail"])
  check tExit == 0
  # Verify a round_started landed by reading the DB directly.
  let events = eventsForCampaign(f, campaignId)
  var sawRoundStarted = false
  for e in events:
    if e.kind == "round_started":
      sawRoundStarted = true
      let payload = parseJson(e.payload)
      check payload{"round"}.getInt(0) >= 1
  check sawRoundStarted

test "test_cli_campaign_stop_marks_status":
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let fx = writeFixtures()
  defer: removeDir(fx.projectDir)
  let (sExit, sOut, _) = invokeCli(f.baseUrl,
    ["start", "--doc", fx.campaignPath, "--no-tail"])
  check sExit == 0
  let campaignId = sOut.strip()

  let (stopExit, _, _) = invokeCli(f.baseUrl,
    ["stop", campaignId, "--reason", "cli-test-shutdown"])
  check stopExit == 0

  let (showExit, showOut, _) = invokeCli(f.baseUrl,
    ["show", campaignId])
  check showExit == 0
  check showOut.contains("status:         stopped")
  check showOut.contains("status_reason:  cli-test-shutdown")
