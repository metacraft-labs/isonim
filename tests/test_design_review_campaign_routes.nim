## CMP-M2 — daemon ``/api/campaign/*`` route tests.
##
## Real PostgreSQL via the REV-M3 ``PgFixture`` + real daemon spawned
## via ``campaign_routes_fixture.startCampaignDaemon`` + real fake ACP
## agent in the background.  No in-process mocks at the DB or HTTP
## boundary.

import std/[json, os, strutils, times, unittest]

import helpers/campaign_routes_fixture

# Pure-Nim unit tests for the ORCHESTRATOR_STATUS marker parser.  We
# import the parser directly so we can exercise edge cases (missing
# marker, malformed marker, whitespace tolerance) without a daemon.
import isonim/editor/design_review/campaign_routes as cr
import tools/isonim_review/config as cli_config

# Fixture campaign doc shared across tests.
const FixtureCampaignDoc = """---
campaignId: cmp-m2-test
schemaVersion: 1
briefRefs:
  - render.demo-app
targetScore: 9.0
maxIterations: 3
status: pending
---

# CMP-M2 test campaign

## Objectives
- Smoke test the campaign storage layer.
"""

const FixtureBriefBody = """---
briefId: render.demo-app
schemaVersion: 1
kind: render
title: Demo App brief (CMP-M2 fixture)
coversPreviews:
  - storyRef: { group: "Demo App", name: "Page", kind: page, index: 0 }
    backends: [web]
captureViewports:
  - { width: 1280, height: 800, label: "wide" }
scoringDimensions:
  - { id: "render", label: "Render quality", weight: 1.0,
      scale: { min: 1, max: 10 } }
---

This is a CMP-M2 fixture brief.
"""

proc waitForEvent(f: CampaignFixture; campaignId, kind: string;
                  timeoutSec: float = 10.0): bool =
  ## Poll campaign_events until ``kind`` lands or ``timeoutSec`` elapses.
  let deadline = epochTime() + timeoutSec
  while epochTime() < deadline:
    let events = eventsForCampaign(f, campaignId)
    for e in events:
      if e.kind == kind:
        return true
    sleep(80)
  return false

proc countEvents(f: CampaignFixture; campaignId, kind: string): int =
  let events = eventsForCampaign(f, campaignId)
  result = 0
  for e in events:
    if e.kind == kind: inc result

proc startBody(docPath, docSha, briefBody: string;
               briefRefs: seq[string] = @["render.demo-app"]):
    string =
  ## Compose the JSON body the daemon's POST /api/campaign/start
  ## handler expects.
  var refsJson = newJArray()
  for r in briefRefs: refsJson.add(%r)
  var briefsJson = newJArray()
  briefsJson.add(%*{"briefId": "render.demo-app", "body": briefBody})
  let body = %* {
    "docPath":      docPath,
    "docSha":       docSha,
    "briefRefs":    refsJson,
    "targetScore":  9.0,
    "maxIterations": 3,
    "body":         FixtureCampaignDoc,
    "briefs":       briefsJson,
    "manifestHash": "test:fixture",
    "startedBy":    "tester",
    "latestReport": "",
  }
  return $body

# ---------------------------------------------------------------------------

test "test_start_campaign_persists_row_and_started_event":
  let f = startCampaignDaemon(@[("FAKE_ACP_STREAM_CHUNKS", "2")])
  defer: f.shutdown()
  let body = startBody("/tmp/cmp-m2-fixture/campaigns/test.md",
                       "sha-fixture-1", FixtureBriefBody)
  let (status, raw) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check status == 200
  check raw.contains("event: end")
  check raw.contains("\"campaignId\":\"")

  check countCampaigns(f) == 1
  let rows = fetchCampaignByDoc(f, "/tmp/cmp-m2-fixture/campaigns/test.md")
  check rows.len == 1
  check rows[0][1] == "active"          # status
  check rows[0][2] == "3"               # max_iterations
  check rows[0][3] == "test:fixture"    # manifest_hash
  check rows[0][5] == "tester"          # started_by
  check rows[0][6] == "sha-fixture-1"   # doc_sha

  let campaignId = rows[0][0]
  let events = eventsForCampaign(f, campaignId)
  var sawStarted = false
  var sawRoundComplete = false
  for e in events:
    if e.kind == "started": sawStarted = true
    if e.kind == "round_complete": sawRoundComplete = true
  check sawStarted
  check sawRoundComplete

test "test_start_campaign_idempotent_on_doc_sha":
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let docPath = "/tmp/cmp-m2-fixture/campaigns/idempotent.md"
  let body = startBody(docPath, "sha-fixture-idem", FixtureBriefBody)
  let (s1, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s1 == 200
  let (s2, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s2 == 200
  check countCampaigns(f) == 1
  let rows = fetchCampaignByDoc(f, docPath)
  check rows.len == 1
  let campaignId = rows[0][0]
  # Two starts → two ACP turns → two round_complete events, but only one
  # 'started' event (the second call returns the same id without re-
  # writing the started row).
  let events = eventsForCampaign(f, campaignId)
  var startedCount = 0
  for e in events:
    if e.kind == "started": inc startedCount
  check startedCount == 1

test "test_start_campaign_rejects_missing_briefRefs":
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let body = $(%* {
    "docPath": "/tmp/cmp-m2-fixture/campaigns/no-brief.md",
    "docSha":  "sha-no-brief",
    "briefRefs": newJArray(),
    "maxIterations": 3,
    "body": FixtureCampaignDoc,
    "briefs": newJArray(),
    "manifestHash": "test:fixture",
    "startedBy": "tester",
  })
  let (code, respBody) = campaignPost(f, "/api/campaign/start", body)
  check code == 400
  let node = parseJson(respBody)
  check node{"error"}.getStr("") == "missing_briefRefs"
  check countCampaigns(f) == 0

test "test_list_campaigns_filters_by_status":
  let f = startCampaignDaemon()
  defer: f.shutdown()
  # Seed three campaigns with distinct doc shas.
  for i in 1 .. 3:
    let body = startBody("/tmp/cmp-m2-fixture/campaigns/list-" & $i & ".md",
                         "sha-list-" & $i, FixtureBriefBody)
    let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
    check s == 200
  # Transition #2 and #3 to 'stopped' via the stop endpoint.
  let allRows = fetchCampaignByDoc(f, "/tmp/cmp-m2-fixture/campaigns/list-2.md")
  let id2 = allRows[0][0]
  let stopBody = $(%* {"campaignId": id2, "reason": "test stop"})
  let (sc, _) = campaignPost(f, "/api/campaign/stop", stopBody)
  check sc == 200
  let r3 = fetchCampaignByDoc(f, "/tmp/cmp-m2-fixture/campaigns/list-3.md")
  let id3 = r3[0][0]
  let (sc3, _) = campaignPost(f, "/api/campaign/stop",
                              $(%* {"campaignId": id3, "reason": "test stop"}))
  check sc3 == 200

  let (codeActive, bodyActive) = campaignGet(f,
    "/api/campaign/list?status=active&limit=10&offset=0")
  check codeActive == 200
  let arrActive = parseJson(bodyActive)
  check arrActive.kind == JArray
  check arrActive.len == 1

  let (codeStopped, bodyStopped) = campaignGet(f,
    "/api/campaign/list?status=stopped&limit=10&offset=0")
  check codeStopped == 200
  let arrStopped = parseJson(bodyStopped)
  check arrStopped.kind == JArray
  check arrStopped.len == 2

test "test_fetch_campaign_returns_row_with_events":
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let body = startBody("/tmp/cmp-m2-fixture/campaigns/fetch.md",
                       "sha-fetch", FixtureBriefBody)
  let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s == 200
  let rows = fetchCampaignByDoc(f, "/tmp/cmp-m2-fixture/campaigns/fetch.md")
  let campaignId = rows[0][0]

  let (code, respBody) = campaignGet(f,
    "/api/campaign/fetch?campaignId=" & campaignId & "&eventLimit=20")
  check code == 200
  let node = parseJson(respBody)
  check node{"campaign_id"}.getStr == campaignId
  check node{"status"}.getStr == "active"
  let refs = node{"brief_refs"}
  check refs != nil
  check refs.kind == JArray
  check refs[0].getStr("") == "render.demo-app"
  let events = node{"events"}
  check events != nil
  check events.kind == JArray
  check events.len >= 2  # 'started' + 'round_complete'

test "test_tick_records_round_started_event":
  let f = startCampaignDaemon(@[("FAKE_ACP_STREAM_CHUNKS", "2")])
  defer: f.shutdown()
  let body = startBody("/tmp/cmp-m2-fixture/campaigns/tick.md",
                       "sha-tick", FixtureBriefBody)
  let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s == 200
  let rows = fetchCampaignByDoc(f, "/tmp/cmp-m2-fixture/campaigns/tick.md")
  let campaignId = rows[0][0]

  let (tickStatus, _) = rawPostStream(f.baseUrl, "/api/campaign/tick",
    $(%* {"campaignId": campaignId}))
  check tickStatus == 200

  let events = eventsForCampaign(f, campaignId)
  var roundStartedRound = 0
  var roundCompleteCount = 0
  for e in events:
    if e.kind == "round_started":
      let node = parseJson(e.payload)
      roundStartedRound = node{"round"}.getInt(0)
    if e.kind == "round_complete":
      inc roundCompleteCount
  check roundStartedRound >= 1
  check roundCompleteCount >= 2

# ---------------------------------------------------------------------------
# CMP-M2.1 — marker parser unit tests (no daemon).
# ---------------------------------------------------------------------------

test "test_orchestrator_status_marker_extracted_when_present":
  let text = """
Round Completion Signal: This round is complete and ready for a tick.

<<<ORCHESTRATOR_STATUS reason=tick_ready round=2 defects_addressed=1 blocker_summary="">>>
"""
  let s = cr.parseOrchestratorStatus(text)
  check s.present
  check s.reason == "tick_ready"
  check s.hasRound
  check s.round == 2
  check s.hasDefectsAddressed
  check s.defectsAddressed == 1
  check s.blockerSummary == ""

test "test_orchestrator_status_marker_absent_records_missing":
  let text = """
Plan body without the structured marker.

Round Completion Signal: This round is complete.
"""
  let s = cr.parseOrchestratorStatus(text)
  check not s.present
  check s.reason == "unknown"
  check not s.hasRound

test "test_orchestrator_status_marker_quoted_blocker_summary":
  let text = """
<<<ORCHESTRATOR_STATUS reason=needs_human round=3 defects_addressed= blocker_summary="brief language ambiguous: \"industrial\" vs \"futurist\"">>>
"""
  let s = cr.parseOrchestratorStatus(text)
  check s.present
  check s.reason == "needs_human"
  check s.round == 3
  check not s.hasDefectsAddressed
  check s.blockerSummary == "brief language ambiguous: \"industrial\" vs \"futurist\""

test "test_orchestrator_status_marker_takes_last_when_repeated":
  let text = """
<<<ORCHESTRATOR_STATUS reason=tick_ready round=1 defects_addressed= blocker_summary="">>>

(later in the body the orchestrator emits a corrected marker:)

<<<ORCHESTRATOR_STATUS reason=converged round=2 defects_addressed=3 blocker_summary="">>>
"""
  let s = cr.parseOrchestratorStatus(text)
  check s.reason == "converged"
  check s.round == 2

test "test_orchestrator_status_marker_invalid_reason_treated_as_missing":
  let text = """
<<<ORCHESTRATOR_STATUS reason=happy_face round=4 defects_addressed= blocker_summary="">>>
"""
  let s = cr.parseOrchestratorStatus(text)
  check not s.present
  check s.reason == "unknown"

# ---------------------------------------------------------------------------
# CMP-M2.1 — config knob env-var plumbing.
# ---------------------------------------------------------------------------

test "test_campaign_idle_timeout_default_15_min":
  ## With no env overrides, the daemon's [agent].campaign_idle_timeout_ms
  ## defaults to 900_000 ms (15 minutes).  That value flows into
  ## newCampaignRegistry via cmd_serve.newReviewServer.
  putEnv("ISONIM_CAMPAIGN_IDLE_TIMEOUT_MS", "")
  let cfg = cli_config.loadConfig()
  check cfg.agent.campaignIdleTimeoutMs == 900_000

test "test_campaign_auto_tick_delay_configurable":
  ## ISONIM_CAMPAIGN_AUTOTICK_DELAY_MS=5000 → cfg knob picks it up
  ## AND when the orchestrator emits tick_ready the auto-tick fires
  ## after at least the configured delay (within a generous upper
  ## bound to allow for scheduler jitter).
  putEnv("ISONIM_CAMPAIGN_AUTOTICK_DELAY_MS", "5000")
  let cfg = cli_config.loadConfig()
  check cfg.agent.campaignAutoTickDelayMs == 5000
  delEnv("ISONIM_CAMPAIGN_AUTOTICK_DELAY_MS")
  let cfg2 = cli_config.loadConfig()
  check cfg2.agent.campaignAutoTickDelayMs == 2_000

  # End-to-end: configure the daemon with a 5_000 ms delay; the
  # auto_tick_scheduled event fires immediately but the FOLLOWING
  # round_started (from the auto-tick firing) must not appear before
  # 4.5 s have passed.
  let reply = "Body.\n\n" &
    "<<<ORCHESTRATOR_STATUS reason=tick_ready round=1 defects_addressed= blocker_summary=\"\">>>"
  let f = startCampaignDaemon(@[
    ("FAKE_ACP_REPLY", reply),
    ("FAKE_ACP_STREAM_CHUNKS", "1"),
    ("ISONIM_CAMPAIGN_AUTOTICK_DELAY_MS", "5000"),
  ])
  defer: f.shutdown()
  let docPath = "/tmp/cmp-m2-fixture/campaigns/autotick-delay.md"
  let body = startBody(docPath, "sha-autotick-delay", FixtureBriefBody)
  let started = epochTime()
  let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s == 200
  let rows = fetchCampaignByDoc(f, docPath)
  let campaignId = rows[0][0]
  check waitForEvent(f, campaignId, "auto_tick_scheduled", 8.0)
  check waitForEvent(f, campaignId, "round_started", 20.0)
  let elapsed = epochTime() - started
  check elapsed >= 4.5


test "test_auto_tick_scheduled_on_tick_ready":
  ## Fake-ACP emits a round body ending with the tick_ready marker.
  ## After the first round_complete lands, the daemon must (a) record
  ## an ``auto_tick_scheduled`` event and (b) drive a follow-up round
  ## tagged ``round=2``.
  let reply = "Plan body.\n\n" &
    "<<<ORCHESTRATOR_STATUS reason=tick_ready round=1 defects_addressed= blocker_summary=\"\">>>"
  let f = startCampaignDaemon(@[
    ("FAKE_ACP_REPLY", reply),
    ("FAKE_ACP_STREAM_CHUNKS", "1"),
    ("ISONIM_CAMPAIGN_AUTOTICK_DELAY_MS", "200"),
  ])
  defer: f.shutdown()
  let docPath = "/tmp/cmp-m2-fixture/campaigns/autotick.md"
  let body = startBody(docPath, "sha-autotick", FixtureBriefBody)
  let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s == 200
  let rows = fetchCampaignByDoc(f, docPath)
  let campaignId = rows[0][0]
  # Wait for the daemon's auto-tick + the resulting follow-up round.
  check waitForEvent(f, campaignId, "auto_tick_scheduled", 8.0)
  check waitForEvent(f, campaignId, "round_started", 8.0)
  # Second round_complete (from the auto-tick) must eventually land.
  var sawRound2RoundStarted = false
  let deadline = epochTime() + 12.0
  while epochTime() < deadline:
    let events = eventsForCampaign(f, campaignId)
    for e in events:
      if e.kind == "round_started":
        let p = parseJson(e.payload)
        if p{"round"}.getInt(0) == 2:
          sawRound2RoundStarted = true
          break
    if sawRound2RoundStarted: break
    sleep(120)
  check sawRound2RoundStarted

test "test_auto_tick_bounded_by_max_iterations":
  ## A campaign with max_iterations=1 + a tick_ready marker MUST NOT
  ## schedule another tick; instead the daemon transitions the
  ## campaign to ``escalated`` with reason ``iteration cap reached``.
  let reply = "Plan body.\n\n" &
    "<<<ORCHESTRATOR_STATUS reason=tick_ready round=1 defects_addressed= blocker_summary=\"\">>>"
  let f = startCampaignDaemon(@[
    ("FAKE_ACP_REPLY", reply),
    ("FAKE_ACP_STREAM_CHUNKS", "1"),
    ("ISONIM_CAMPAIGN_AUTOTICK_DELAY_MS", "200"),
  ])
  defer: f.shutdown()
  let docPath = "/tmp/cmp-m2-fixture/campaigns/cap.md"
  # Manually override maxIterations=1 in the body.
  var refsJson = newJArray()
  refsJson.add(%"render.demo-app")
  var briefsJson = newJArray()
  briefsJson.add(%*{"briefId": "render.demo-app", "body": FixtureBriefBody})
  let bodyJson = %* {
    "docPath":      docPath,
    "docSha":       "sha-cap",
    "briefRefs":    refsJson,
    "targetScore":  9.0,
    "maxIterations": 1,
    "body":         FixtureCampaignDoc,
    "briefs":       briefsJson,
    "manifestHash": "test:fixture",
    "startedBy":    "tester",
    "latestReport": "",
  }
  let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", $bodyJson)
  check s == 200
  let rows = fetchCampaignByDoc(f, docPath)
  let campaignId = rows[0][0]
  # The escalation event must arrive within a few seconds; auto-tick
  # must NOT fire (no auto_tick_scheduled event).
  check waitForEvent(f, campaignId, "escalation", 8.0)
  let after = fetchCampaignByDoc(f, docPath)
  check after[0][1] == "escalated"
  check countEvents(f, campaignId, "auto_tick_scheduled") == 0

test "test_auto_tick_cancelled_by_stop":
  ## CMP-M2.1 — a pending auto-tick scheduled by ``tick_ready`` must be
  ## cancelled when ``campaign stop`` lands before it fires.  The
  ## generation-counter pattern in ``scheduleAutoTick`` is the
  ## load-bearing piece: ``handleStop`` calls ``bumpAutoTickGen`` and
  ## the sleeping coroutine compares on wake-up + bails on mismatch.
  ##
  ## Setup: delay=4000 ms (long enough to stop before it fires).
  ## Send start, wait for the auto_tick_scheduled event, immediately
  ## stop the campaign, then poll for ~6 s to assert NO follow-up
  ## ``round_started`` event with ``source=auto_tick`` ever lands.
  let reply = "Plan body.\n\n" &
    "<<<ORCHESTRATOR_STATUS reason=tick_ready round=1 defects_addressed= blocker_summary=\"\">>>"
  let f = startCampaignDaemon(@[
    ("FAKE_ACP_REPLY", reply),
    ("FAKE_ACP_STREAM_CHUNKS", "1"),
    ("ISONIM_CAMPAIGN_AUTOTICK_DELAY_MS", "4000"),
  ])
  defer: f.shutdown()
  let docPath = "/tmp/cmp-m2-fixture/campaigns/cancel-by-stop.md"
  let body = startBody(docPath, "sha-cancel-by-stop", FixtureBriefBody)
  let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s == 200
  let rows = fetchCampaignByDoc(f, docPath)
  let campaignId = rows[0][0]
  # The scheduled marker must appear; the actual auto-tick must not.
  check waitForEvent(f, campaignId, "auto_tick_scheduled", 4.0)
  # Stop the campaign before the auto-tick's 4-second sleep elapses.
  let (sc, _) = campaignPost(f, "/api/campaign/stop",
    $(%* {"campaignId": campaignId, "reason": "cancel-by-stop test"}))
  check sc == 200
  # Wait past the auto-tick's would-be fire time and assert no
  # auto_tick-sourced round_started + no second round_complete ever
  # landed.  Six-second window covers the 4-s sleep + scheduling
  # jitter.
  let deadline = epochTime() + 6.0
  while epochTime() < deadline:
    sleep(120)
  let events = eventsForCampaign(f, campaignId)
  var sawAutoTickRoundStarted = false
  var roundCompleteCount = 0
  for e in events:
    if e.kind == "round_started":
      let p = parseJson(e.payload)
      if p{"source"}.getStr("") == "auto_tick":
        sawAutoTickRoundStarted = true
    if e.kind == "round_complete":
      inc roundCompleteCount
  check not sawAutoTickRoundStarted
  # Only the start's baseline round_complete should exist; the cancelled
  # auto-tick must NOT have written a second one.
  check roundCompleteCount == 1
  # Campaign status is now ``stopped``.
  let after = fetchCampaignByDoc(f, docPath)
  check after[0][1] == "stopped"

test "test_converged_transitions_campaign":
  ## reason=converged → campaign transitions to ``converged`` and no
  ## auto-tick is scheduled.
  let reply = "All cells at target.\n\n" &
    "<<<ORCHESTRATOR_STATUS reason=converged round=1 defects_addressed=0 blocker_summary=\"\">>>"
  let f = startCampaignDaemon(@[
    ("FAKE_ACP_REPLY", reply),
    ("FAKE_ACP_STREAM_CHUNKS", "1"),
    ("ISONIM_CAMPAIGN_AUTOTICK_DELAY_MS", "200"),
  ])
  defer: f.shutdown()
  let docPath = "/tmp/cmp-m2-fixture/campaigns/converged.md"
  let body = startBody(docPath, "sha-converged", FixtureBriefBody)
  let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s == 200
  let rows = fetchCampaignByDoc(f, docPath)
  let campaignId = rows[0][0]
  # transition_campaign(converged) writes a 'finished' event per the
  # routine's mapping; check that AND the campaign row's status.
  check waitForEvent(f, campaignId, "finished", 8.0)
  let after = fetchCampaignByDoc(f, docPath)
  check after[0][1] == "converged"
  check countEvents(f, campaignId, "auto_tick_scheduled") == 0

test "test_round_counter_increments":
  ## Disable auto-tick via env, then drive three explicit ticks.
  ## round_started rows must carry round=1, 2, 3 in order.
  let f = startCampaignDaemon(@[
    ("FAKE_ACP_STREAM_CHUNKS", "1"),
    ("ISONIM_CAMPAIGN_AUTOTICK_DISABLED", "1"),
  ])
  defer: f.shutdown()
  let docPath = "/tmp/cmp-m2-fixture/campaigns/counter.md"
  let body = startBody(docPath, "sha-counter", FixtureBriefBody)
  let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s == 200
  let rows = fetchCampaignByDoc(f, docPath)
  let campaignId = rows[0][0]
  # Drive two explicit ticks after the start (start already produced
  # round 1's round_complete).  The tick handler claims round numbers
  # 2 and 3 in succession via dbNextRound.
  for _ in 1 .. 2:
    let (tickStatus, _) = rawPostStream(f.baseUrl, "/api/campaign/tick",
      $(%* {"campaignId": campaignId}))
    check tickStatus == 200
  # Collect round_started events in chronological order and read their
  # round numbers.
  let events = eventsForCampaign(f, campaignId)
  var seenRounds: seq[int]
  for e in events:
    if e.kind == "round_started":
      let p = parseJson(e.payload)
      seenRounds.add p{"round"}.getInt(0)
  check seenRounds == @[2, 3]
  # round 1 isn't recorded as round_started because handleStart's
  # baseline round only writes a round_complete; the orchestrator's
  # "round 1" is implicit in the campaign row's start.

test "test_consecutive_error_escalation":
  ## After three consecutive ``stopReason=error`` round_complete events,
  ## the daemon must auto-escalate the campaign.  We drive the in-memory
  ## counter via the same proc the dispatcher uses (``recordErrorRound``);
  ## the end-to-end ACP path can't synthesize ``stopReason=error`` without
  ## bringing in a fail-mode on fake-ACP, which is out of scope here.
  ## This test verifies the threshold logic in isolation; the daemon's
  ## ``applyOrchestratorStatusAfterRound`` calls the same proc and acts
  ## on its return value.
  let reg = cr.newCampaignRegistry(nil, nil, "/tmp/nope.md",
                                   idleTimeoutMs = 900_000,
                                   autoTickDelayMs = 2_000)
  let cid = "00000000-0000-0000-0000-000000000abc"
  check reg.recordErrorRound(cid, true) == 1
  check reg.recordErrorRound(cid, true) == 2
  check reg.recordErrorRound(cid, true) == 3
  # The dispatcher escalates when the returned count >= 3.

test "test_consecutive_error_count_resets_on_non_error":
  ## Verify the in-memory counter resets on a non-error round so a
  ## campaign that has one transient error followed by a recovery
  ## doesn't escalate when it later sees another isolated error.
  let reg = cr.newCampaignRegistry(nil, nil, "/tmp/nope.md",
                                   idleTimeoutMs = 900_000,
                                   autoTickDelayMs = 2_000)
  let cid = "00000000-0000-0000-0000-000000000001"
  check reg.recordErrorRound(cid, true) == 1
  check reg.recordErrorRound(cid, true) == 2
  check reg.recordErrorRound(cid, false) == 0
  check reg.recordErrorRound(cid, true) == 1

test "test_stop_transitions_status_and_closes_session":
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let body = startBody("/tmp/cmp-m2-fixture/campaigns/stop.md",
                       "sha-stop", FixtureBriefBody)
  let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s == 200
  let rows = fetchCampaignByDoc(f, "/tmp/cmp-m2-fixture/campaigns/stop.md")
  let campaignId = rows[0][0]

  let (sc, _) = campaignPost(f, "/api/campaign/stop",
    $(%* {"campaignId": campaignId, "reason": "test stop"}))
  check sc == 200

  let afterStop = fetchCampaignByDoc(f, "/tmp/cmp-m2-fixture/campaigns/stop.md")
  check afterStop[0][1] == "stopped"   # status

  # Subsequent tick must fail with 404 — the in-memory session for this
  # campaign was dropped.
  let (tickCode, tickBody) = campaignPost(f, "/api/campaign/tick",
    $(%* {"campaignId": campaignId}))
  check tickCode == 404
  let node = parseJson(tickBody)
  check node{"error"}.getStr("") == "no_active_session"
