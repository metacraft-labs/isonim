## CMP-M2 / CMP-M6 — campaign full-lifecycle end-to-end test.
##
## Drives a real ``isonim-review`` CLI subprocess against a real daemon
## + real PostgreSQL via the fixture, with the fake ACP agent as the
## backend.  Exercises: start → list → show → tail → stop in the
## single-turn campaign model.  ``tick`` is no longer part of the
## lifecycle — the orchestrator runs as one long-lived ACP turn — so
## the e2e doesn't drive a tick.

import std/[os, osproc, strutils, times, unittest]

import helpers/campaign_routes_fixture

proc writeCampaignFixture(): tuple[campaignPath, briefPath, projectDir: string] =
  let projectDir = getTempDir() / ("cmp_m2_e2e_" &
                    $((int(epochTime() * 1000)) mod 1_000_000))
  removeDir(projectDir)
  let campaignDir = projectDir / "campaigns"
  let briefsDir = projectDir / "briefs" / "render"
  createDir(campaignDir)
  createDir(briefsDir)
  let campaignPath = campaignDir / "e2e.md"
  let briefPath = briefsDir / "demo-app.md"
  writeFile(campaignPath, """---
campaignId: cmp-m2-e2e
schemaVersion: 1
briefRefs:
  - render.demo-app
targetScore: 9.0
maxIterations: 2
status: pending
---

# CMP-M2 end-to-end campaign

## Objectives
- Verify the full lifecycle: start, tick, show, stop.
""")
  writeFile(briefPath, """---
briefId: render.demo-app
schemaVersion: 1
kind: render
title: Demo App brief (e2e fixture)
coversPreviews:
  - storyRef: { group: "Demo App", name: "Page", kind: page, index: 0 }
    backends: [web]
captureViewports:
  - { width: 1280, height: 800, label: "wide" }
scoringDimensions:
  - { id: "render", label: "Render quality", weight: 1.0,
      scale: { min: 1, max: 10 } }
---

Demo brief.
""")
  return (campaignPath, briefPath, projectDir)

proc invokeCli(baseUrl: string;
               args: openArray[string]):
    tuple[exitCode: int; outText, errText: string] =
  let outPath = getTempDir() / ("e2e_cmp_stdout_" &
                $((int(epochTime() * 1000)) mod 1_000_000))
  let errPath = getTempDir() / ("e2e_cmp_stderr_" &
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

test "e2e_campaign_full_lifecycle":
  let f = startCampaignDaemon(@[
    ("FAKE_ACP_STREAM_CHUNKS", "4"),
    ("FAKE_ACP_REPLY",         "ORCHESTRATOR PLAN")])
  defer: f.shutdown()
  let (campaignPath, _, projectDir) = writeCampaignFixture()
  defer: removeDir(projectDir)

  # 1) Start (with streaming).
  let (startExit, startOut, startErr) = invokeCli(f.baseUrl,
    ["start", "--doc", campaignPath])
  check startExit == 0
  check startOut.contains("ORCHESTRATOR PLAN")
  check startErr.contains("campaign started: ")
  check startErr.contains("round complete (stopReason=end_turn)")

  # 2) Pull the campaign id off the DB so we don't depend on parsing
  # the stderr UUID format.
  check countCampaigns(f) == 1
  let rows = fetchCampaignByDoc(f, campaignPath.absolutePath)
  check rows.len == 1
  let campaignId = rows[0][0]
  # Either ``active`` (post-turn transition hasn't fired yet) or
  # ``failed`` (the fixture doc never set a terminal status).
  check rows[0][1] in ["active", "failed"]
  check rows[0][2] == "2"      # max_iterations from doc

  # 3) list returns it.
  let (lExit, lOut, _) = invokeCli(f.baseUrl, ["list"])
  check lExit == 0
  check lOut.contains("active") or lOut.contains("failed")

  # 4) show prints fields.
  let (shExit, shOut, _) = invokeCli(f.baseUrl, ["show", campaignId])
  check shExit == 0
  check shOut.contains("render.demo-app")
  check shOut.contains("status:         active") or
        shOut.contains("status:         failed")

  # 5) tail (no follow) prints the events without blocking.
  let (tailExit, tailOut, _) = invokeCli(f.baseUrl,
    ["tail", campaignId])
  check tailExit == 0
  check tailOut.contains("started")
  check tailOut.contains("round_complete")

  # 6) stop.  In the single-turn model the campaign may already be
  # ``failed`` by the time we get here; the stop call still succeeds
  # at dropping the in-memory session (the transition_campaign call
  # may reject the terminal-to-terminal flip — accept either outcome).
  let (stopExit, _, _) = invokeCli(f.baseUrl,
    ["stop", campaignId, "--reason", "e2e-shutdown"])
  check stopExit in [0, 5]
  let afterStop = fetchCampaignByDoc(f, campaignPath.absolutePath)
  check afterStop[0][1] in ["stopped", "failed"]
