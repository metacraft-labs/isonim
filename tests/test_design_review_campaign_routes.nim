## CMP-M2 — daemon ``/api/campaign/*`` route tests.
##
## Real PostgreSQL via the REV-M3 ``PgFixture`` + real daemon spawned
## via ``campaign_routes_fixture.startCampaignDaemon`` + real fake ACP
## agent in the background.  No in-process mocks at the DB or HTTP
## boundary.

import std/[json, strutils, unittest]

import helpers/campaign_routes_fixture

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
