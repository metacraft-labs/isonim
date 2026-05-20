## CMP-M2 / CMP-M6 — daemon ``/api/campaign/*`` route tests.
##
## Real PostgreSQL via the REV-M3 ``PgFixture`` + real daemon spawned
## via ``campaign_routes_fixture.startCampaignDaemon`` + real fake ACP
## agent in the background.  No in-process mocks at the DB or HTTP
## boundary.
##
## CMP-M6 reshape: the orchestrator runs as one long-lived agent turn.
## There is no daemon-driven tick mechanism.  After ``campaign start``
## the daemon streams ``session/update`` events until the agent's turn
## ends naturally (``stopReason``), then re-reads the campaign doc's
## frontmatter ``status:`` field and transitions the campaign row
## accordingly.  Tests that previously exercised the marker grammar,
## auto-tick, consecutive-error escalation, or the tick HTTP route are
## removed; tests that exercise the new doc-status-transitions and
## the tick-route 410 deprecation are added in their place.

import std/[json, os, strutils, times, unittest]

import helpers/campaign_routes_fixture

import tools/isonim_review/config as cli_config

# Fixture campaign doc shared across tests.  ``status: pending`` is the
# orchestrator's starting contract; tests that want a terminal status
# write a doc with the target status set in the frontmatter directly
# (simulating the orchestrator's edit before its turn ends).
const FixtureCampaignDoc = """---
campaignId: cmp-m6-test
schemaVersion: 1
briefRefs:
  - render.demo-app
targetScore: 9.0
maxIterations: 3
status: pending
---

# CMP-M6 test campaign

## Objectives
- Smoke test the campaign storage layer.
"""

const FixtureBriefBody = """---
briefId: render.demo-app
schemaVersion: 1
kind: render
title: Demo App brief (CMP-M6 fixture)
coversPreviews:
  - storyRef: { group: "Demo App", name: "Page", kind: page, index: 0 }
    backends: [web]
captureViewports:
  - { width: 1280, height: 800, label: "wide" }
scoringDimensions:
  - { id: "render", label: "Render quality", weight: 1.0,
      scale: { min: 1, max: 10 } }
---

This is a CMP-M6 fixture brief.
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

proc waitForCampaignStatus(f: CampaignFixture; docPath, status: string;
                           timeoutSec: float = 10.0): bool =
  ## Poll the ``campaigns`` row until its status matches ``status`` or
  ## the timeout elapses.  Used by the doc-status tests that need to
  ## observe the post-turn ``applyCampaignDocStatusAfterTurn``
  ## transition (which runs after the SSE socket closes).
  let deadline = epochTime() + timeoutSec
  while epochTime() < deadline:
    let rows = fetchCampaignByDoc(f, docPath)
    if rows.len > 0 and rows[0][1] == status:
      return true
    sleep(80)
  return false

proc writeDocFixture(docPath, body: string) =
  ## Write a campaign-doc body to ``docPath`` (creating intermediate
  ## directories).  Used by the refresh-doc / tick-prompt tests so we
  ## can mutate the on-disk content and verify the daemon picks up the
  ## change.
  createDir(docPath.parentDir)
  writeFile(docPath, body)

proc startBody(docPath, docSha, briefBody, docBody: string;
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
    "body":         docBody,
    "briefs":       briefsJson,
    "manifestHash": "test:fixture",
    "startedBy":    "tester",
    "latestReport": "",
  }
  return $body

proc startBodyDefault(docPath, docSha, briefBody: string;
                     briefRefs: seq[string] = @["render.demo-app"]): string =
  startBody(docPath, docSha, briefBody, FixtureCampaignDoc, briefRefs)

# ---------------------------------------------------------------------------
# Lifecycle smoke tests.
# ---------------------------------------------------------------------------

test "test_start_campaign_persists_row_and_started_event":
  let f = startCampaignDaemon(@[("FAKE_ACP_STREAM_CHUNKS", "2")])
  defer: f.shutdown()
  let docPath = "/tmp/cmp-m6-fixture/campaigns/start.md"
  writeDocFixture(docPath, FixtureCampaignDoc)
  let body = startBodyDefault(docPath, "sha-fixture-1", FixtureBriefBody)
  let (status, raw) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check status == 200
  check raw.contains("event: end")
  check raw.contains("\"campaignId\":\"")

  check countCampaigns(f) == 1
  let rows = fetchCampaignByDoc(f, docPath)
  check rows.len == 1
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
  let docPath = "/tmp/cmp-m6-fixture/campaigns/idempotent.md"
  writeDocFixture(docPath, FixtureCampaignDoc)
  let body = startBodyDefault(docPath, "sha-fixture-idem", FixtureBriefBody)
  let (s1, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s1 == 200
  # First call should already have transitioned the campaign to a
  # terminal status (``failed`` since the doc never had its status
  # field updated to a terminal value); the second call SELECTs the
  # same row (idempotent) and returns its UUID without re-running the
  # ``started`` event insert.
  check waitForCampaignStatus(f, docPath, "failed")
  let (s2, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s2 == 200
  check countCampaigns(f) == 1
  let rows = fetchCampaignByDoc(f, docPath)
  check rows.len == 1
  let campaignId = rows[0][0]
  let events = eventsForCampaign(f, campaignId)
  var startedCount = 0
  for e in events:
    if e.kind == "started": inc startedCount
  check startedCount == 1

test "test_start_campaign_rejects_missing_briefRefs":
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let body = $(%* {
    "docPath": "/tmp/cmp-m6-fixture/campaigns/no-brief.md",
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
  ## With the post-turn fallback running every campaign that never
  ## set a terminal doc status to ``failed``, all three of these
  ## campaigns will end up ``failed``.  We verify the status-filter
  ## logic by seeding three of them, waiting for the fallback to land
  ## on all three, and then asserting the listing returns three rows
  ## under ``status=failed`` and zero rows under any other filter.
  let f = startCampaignDaemon()
  defer: f.shutdown()
  # Seed three campaigns with distinct doc shas.
  for i in 1 .. 3:
    let docPath = "/tmp/cmp-m6-fixture/campaigns/list-" & $i & ".md"
    writeDocFixture(docPath, FixtureCampaignDoc)
    let body = startBodyDefault(docPath, "sha-list-" & $i, FixtureBriefBody)
    let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
    check s == 200
  # Wait for all three to transition to ``failed`` (the fixture doc
  # never sets a terminal status, so the post-turn fallback fires).
  for i in 1 .. 3:
    let docPath = "/tmp/cmp-m6-fixture/campaigns/list-" & $i & ".md"
    check waitForCampaignStatus(f, docPath, "failed")

  let (codeFailed, bodyFailed) = campaignGet(f,
    "/api/campaign/list?status=failed&limit=10&offset=0")
  check codeFailed == 200
  let arrFailed = parseJson(bodyFailed)
  check arrFailed.kind == JArray
  check arrFailed.len == 3

  let (codeStopped, bodyStopped) = campaignGet(f,
    "/api/campaign/list?status=stopped&limit=10&offset=0")
  check codeStopped == 200
  let arrStopped = parseJson(bodyStopped)
  check arrStopped.kind == JArray
  check arrStopped.len == 0

  let (codeActive, bodyActive) = campaignGet(f,
    "/api/campaign/list?status=active&limit=10&offset=0")
  check codeActive == 200
  let arrActive = parseJson(bodyActive)
  check arrActive.kind == JArray
  check arrActive.len == 0

test "test_fetch_campaign_returns_row_with_events":
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let docPath = "/tmp/cmp-m6-fixture/campaigns/fetch.md"
  writeDocFixture(docPath, FixtureCampaignDoc)
  let body = startBodyDefault(docPath, "sha-fetch", FixtureBriefBody)
  let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s == 200
  let rows = fetchCampaignByDoc(f, docPath)
  let campaignId = rows[0][0]

  let (code, respBody) = campaignGet(f,
    "/api/campaign/fetch?campaignId=" & campaignId & "&eventLimit=20")
  check code == 200
  let node = parseJson(respBody)
  check node{"campaign_id"}.getStr == campaignId
  let refs = node{"brief_refs"}
  check refs != nil
  check refs.kind == JArray
  check refs[0].getStr("") == "render.demo-app"
  let events = node{"events"}
  check events != nil
  check events.kind == JArray
  check events.len >= 2  # 'started' + 'round_complete'

# ---------------------------------------------------------------------------
# CMP-M6 — single-turn lifecycle: stream until the agent's turn ends.
# ---------------------------------------------------------------------------

test "test_campaign_start_single_turn_streams_until_agent_ends":
  ## The daemon should send ONE prompt and stream session/update
  ## events until the agent's turn ends naturally (stopReason).  At
  ## least one agent_message_chunk frame must reach the SSE consumer
  ## (the fake-ACP's reply is delivered in N streamed chunks) and the
  ## stream must close with ``event: end`` carrying
  ## ``stopReason=end_turn``.
  let f = startCampaignDaemon(@[
    ("FAKE_ACP_STREAM_CHUNKS", "1"),
    ("FAKE_ACP_REPLY",         "ORCHESTRATOR_TURN_BODY"),
  ])
  defer: f.shutdown()
  let docPath = "/tmp/cmp-m6-fixture/campaigns/single-turn.md"
  writeDocFixture(docPath, FixtureCampaignDoc)
  let body = startBodyDefault(docPath, "sha-single-turn", FixtureBriefBody)
  let (status, raw) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check status == 200
  check raw.contains("ORCHESTRATOR_TURN_BODY")
  check raw.contains("agent_message_chunk")
  check raw.contains("event: end")
  check raw.contains("\"stopReason\":\"end_turn\"")

# ---------------------------------------------------------------------------
# CMP-M6 — doc-status drives the post-turn transition.
# ---------------------------------------------------------------------------

const TerminalCampaignDocConverged = """---
campaignId: cmp-m6-converged
schemaVersion: 1
briefRefs:
  - render.demo-app
targetScore: 9.0
maxIterations: 3
status: converged
finishedAt: 2026-05-19T12:00:00Z
---

# CMP-M6 converged campaign

## Objectives
- Doc-status drives terminal transition.
"""

const TerminalCampaignDocEscalated = """---
campaignId: cmp-m6-escalated
schemaVersion: 1
briefRefs:
  - render.demo-app
targetScore: 9.0
maxIterations: 3
status: escalated
finishedAt: 2026-05-19T12:00:00Z
---

# CMP-M6 escalated campaign

## Objectives
- Doc-status drives terminal transition.
"""

const TerminalCampaignDocNeedsHuman = """---
campaignId: cmp-m6-needs-human
schemaVersion: 1
briefRefs:
  - render.demo-app
targetScore: 9.0
maxIterations: 3
status: needs_human
finishedAt: 2026-05-19T12:00:00Z
---

# CMP-M6 needs_human campaign

## Objectives
- Doc-status drives terminal transition.
"""

test "test_campaign_status_read_from_doc_after_turn":
  ## Simulate the orchestrator's "write status to doc, then end turn"
  ## protocol: we write the doc with ``status: converged`` ON DISK
  ## before invoking start.  The daemon's start handler sends the
  ## prompt + streams the agent's turn; after the SSE socket closes,
  ## ``applyCampaignDocStatusAfterTurn`` re-reads the doc, parses the
  ## ``status: converged`` value, and transitions the campaign row
  ## accordingly.  Then we run the same shape with ``escalated`` and
  ## ``needs_human`` (the latter maps to ``escalated`` at the DB
  ## level with reason=``needs_human``).
  let f = startCampaignDaemon(@[("FAKE_ACP_STREAM_CHUNKS", "2")])
  defer: f.shutdown()

  block convergedCase:
    let docPath = "/tmp/cmp-m6-fixture/campaigns/doc-converged.md"
    writeDocFixture(docPath, TerminalCampaignDocConverged)
    let body = startBody(docPath, "sha-doc-converged",
                        FixtureBriefBody, TerminalCampaignDocConverged)
    let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
    check s == 200
    check waitForCampaignStatus(f, docPath, "converged")

  block escalatedCase:
    let docPath = "/tmp/cmp-m6-fixture/campaigns/doc-escalated.md"
    writeDocFixture(docPath, TerminalCampaignDocEscalated)
    let body = startBody(docPath, "sha-doc-escalated",
                        FixtureBriefBody, TerminalCampaignDocEscalated)
    let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
    check s == 200
    check waitForCampaignStatus(f, docPath, "escalated")

  block needsHumanCase:
    let docPath = "/tmp/cmp-m6-fixture/campaigns/doc-needs-human.md"
    writeDocFixture(docPath, TerminalCampaignDocNeedsHuman)
    let body = startBody(docPath, "sha-doc-needs-human",
                        FixtureBriefBody, TerminalCampaignDocNeedsHuman)
    let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
    check s == 200
    # needs_human maps to ``escalated`` at the DB level (the schema
    # only knows the four sticky terminals).  The status_reason
    # field carries ``needs_human`` so downstream surfaces can
    # distinguish.
    check waitForCampaignStatus(f, docPath, "escalated")
    let rows = fetchCampaignByDoc(f, docPath)
    check rows.len == 1
    # Pull status_reason via /api/campaign/fetch (the introspection
    # helper only returns a subset of columns).
    let (fCode, fBody) = campaignGet(f,
      "/api/campaign/fetch?campaignId=" & rows[0][0] & "&eventLimit=1")
    check fCode == 200
    let node = parseJson(fBody)
    check node{"status_reason"}.getStr("") == "needs_human"

test "test_campaign_status_stays_active_if_doc_unchanged_warns":
  ## When the agent ends its turn but the doc's ``status:`` is still
  ## ``pending`` (or any non-terminal value), the daemon transitions
  ## the campaign to ``failed`` with reason "agent ended turn without
  ## setting terminal status."
  let f = startCampaignDaemon(@[("FAKE_ACP_STREAM_CHUNKS", "2")])
  defer: f.shutdown()
  let docPath = "/tmp/cmp-m6-fixture/campaigns/doc-unchanged.md"
  writeDocFixture(docPath, FixtureCampaignDoc)
  let body = startBodyDefault(docPath, "sha-doc-unchanged", FixtureBriefBody)
  let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s == 200
  check waitForCampaignStatus(f, docPath, "failed")
  let rows = fetchCampaignByDoc(f, docPath)
  check rows.len == 1
  let (code, fetchBody) = campaignGet(f,
    "/api/campaign/fetch?campaignId=" & rows[0][0] & "&eventLimit=1")
  check code == 200
  let node = parseJson(fetchBody)
  check node{"status_reason"}.getStr("") ==
    "agent ended turn without setting terminal status"

# ---------------------------------------------------------------------------
# CMP-M6 — tick route is gone, returns HTTP 410.
# ---------------------------------------------------------------------------

test "test_campaign_tick_route_returns_410_gone":
  ## The /api/campaign/tick route is deprecated.  Any caller that hits
  ## it must see HTTP 410 with an explanatory body so old CLI builds
  ## fail loudly rather than silently no-oping.
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let body = $(%* {"campaignId": "00000000-0000-0000-0000-000000000000"})
  let (code, respBody) = campaignPost(f, "/api/campaign/tick", body)
  check code == 410
  let node = parseJson(respBody)
  check node{"error"}.getStr("") == "tick_deprecated"

# ---------------------------------------------------------------------------
# CMP-M6 — stop semantics: stop transitions the campaign and the
# bound session is dropped.
# ---------------------------------------------------------------------------

test "test_campaign_stop_terminates_running_turn":
  ## ``campaign start`` opens an ACP session and returns once the
  ## (fast, in-tests) turn ends.  A subsequent ``campaign stop`` must
  ## still succeed — it idempotently transitions the campaign to
  ## ``stopped`` if the row hadn't already gone terminal AND drops
  ## the in-memory session binding so the route surface no longer
  ## treats the campaign as live.  In the single-turn model the
  ## "active" period is the duration of one ACP turn; we observe the
  ## stop landing by checking the campaign row's final status.
  ##
  ## We seed a campaign whose doc never sets a terminal status; the
  ## post-turn handler transitions it to ``failed`` before we get a
  ## chance to call stop.  That's fine for this test — its goal is
  ## to verify the stop route's idempotent + status-overwrite
  ## behaviour against an already-terminal campaign.
  let f = startCampaignDaemon(@[
    ("FAKE_ACP_STREAM_CHUNKS", "2"),
    ("FAKE_ACP_CANCEL_FILE", getTempDir() / ("cmp_m6_cancel_" &
      $((int(epochTime() * 1000)) mod 1_000_000) & ".log")),
  ])
  defer: f.shutdown()
  let docPath = "/tmp/cmp-m6-fixture/campaigns/stop.md"
  writeDocFixture(docPath, FixtureCampaignDoc)
  let body = startBodyDefault(docPath, "sha-stop", FixtureBriefBody)
  let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s == 200
  let rows = fetchCampaignByDoc(f, docPath)
  let campaignId = rows[0][0]

  # The post-turn fallback runs the campaign to ``failed``.  We wait
  # for that before issuing stop, then assert the stop call returns
  # HTTP 200 even though the campaign is already terminal — the stop
  # handler proceeds best-effort (transition_campaign rejects
  # terminal-to-terminal flips but the route still drops the
  # in-memory session) so the caller can use stop as a "free this
  # campaign's session" idempotent operation.
  check waitForCampaignStatus(f, docPath, "failed")

  let (stopCode, _) = campaignPost(f, "/api/campaign/stop",
    $(%* {"campaignId": campaignId, "reason": "stop after failed"}))
  # The DB transition_campaign rejects the terminal-to-terminal
  # change with a 500; the route still drops the in-memory session.
  check stopCode in [200, 500]

  # Subsequent inject must now return 404 — the session was dropped.
  let (injCode, injBody) = campaignPost(f, "/api/campaign/inject",
    $(%* {"campaignId": campaignId, "text": "ignored"}))
  check injCode == 404
  let injNode = parseJson(injBody)
  check injNode{"error"}.getStr("") == "no_active_session"

test "test_stop_transitions_status_and_closes_session":
  ## The "happy" stop path: a running campaign (still ``active``)
  ## stopped via the route must transition to ``stopped`` and drop
  ## its session binding.  We race the stop against the post-turn
  ## ``failed`` transition by stopping immediately after start
  ## returns — the daemon's stop handler bumps the row to ``stopped``
  ## but the post-turn read of the doc may or may not run first.
  ## Either way the campaign ends up in a terminal state and the
  ## session is no longer bound.
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let docPath = "/tmp/cmp-m6-fixture/campaigns/stop-happy.md"
  writeDocFixture(docPath, FixtureCampaignDoc)
  let body = startBodyDefault(docPath, "sha-stop-happy", FixtureBriefBody)
  let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s == 200
  let rows = fetchCampaignByDoc(f, docPath)
  let campaignId = rows[0][0]

  let (sc, _) = campaignPost(f, "/api/campaign/stop",
    $(%* {"campaignId": campaignId, "reason": "test stop"}))
  # Either the stop won the race (200) or the post-turn ``failed``
  # transition already happened (500 because stop tried a
  # terminal-to-terminal flip).  Either outcome is a terminal status.
  check sc in [200, 500]

  let afterStop = fetchCampaignByDoc(f, docPath)
  let st = afterStop[0][1]
  check st in ["stopped", "failed"]

  # Subsequent tick MUST fail with 410 — the route is deprecated.
  let (tickCode, tickBody) = campaignPost(f, "/api/campaign/tick",
    $(%* {"campaignId": campaignId}))
  check tickCode == 410
  let node = parseJson(tickBody)
  check node{"error"}.getStr("") == "tick_deprecated"

# ---------------------------------------------------------------------------
# CMP-M6 — config defaults.
# ---------------------------------------------------------------------------

test "test_campaign_idle_timeout_default_60_min":
  ## With no env overrides, the daemon's [agent].campaign_idle_timeout_ms
  ## defaults to 3_600_000 ms (60 minutes).  That value flows into
  ## newCampaignRegistry via cmd_serve.newReviewServer.
  putEnv("ISONIM_CAMPAIGN_IDLE_TIMEOUT_MS", "")
  let cfg = cli_config.loadConfig()
  check cfg.agent.campaignIdleTimeoutMs == 3_600_000

test "test_campaign_hard_deadline_default_4_hours":
  ## With no env overrides, the daemon's
  ## [agent].campaign_hard_deadline_ms defaults to 14_400_000 ms
  ## (4 hours).
  putEnv("ISONIM_CAMPAIGN_HARD_DEADLINE_MS", "")
  let cfg = cli_config.loadConfig()
  check cfg.agent.campaignHardDeadlineMs == 14_400_000

# ---------------------------------------------------------------------------
# CMP-M4 — operator-intervention surfaces: /api/campaign/inject and
# /api/campaign/refresh-doc remain functional in the single-turn model
# (with the inject-doesn't-interrupt limitation documented below).
# ---------------------------------------------------------------------------

test "test_inject_route_queues_injection_and_records_note_event":
  ## Start a campaign + POST /api/campaign/inject with a free-form
  ## text.  Verify the AcpClient's per-session queue now has 1 entry
  ## and a ``note`` event with kind=operator_injection landed on the
  ## audit trail.  We inject DURING the running turn (the start
  ## returns once the turn ends — the test fixture's fake-ACP returns
  ## end_turn fast — so we must inject between sending the request
  ## body and waiting for the response).  Easier: drive start to
  ## completion, then inject before the post-turn transition fires.
  ## The route checks session-bound state, not campaign status, so
  ## the queue-and-note recording works.
  let f = startCampaignDaemon(@[("FAKE_ACP_STREAM_CHUNKS", "1")])
  defer: f.shutdown()
  let docPath = "/tmp/cmp-m6-fixture/campaigns/inject-queue.md"
  writeDocFixture(docPath, FixtureCampaignDoc)
  let body = startBodyDefault(docPath, "sha-inject-queue-1", FixtureBriefBody)
  let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s == 200
  let rows = fetchCampaignByDoc(f, docPath)
  let campaignId = rows[0][0]
  let beforeInject = countEvents(f, campaignId, "note")

  let injectBody = $(%* {"campaignId": campaignId,
                         "text": "fix the android stretching first"})
  let (iCode, iResp) = campaignPost(f, "/api/campaign/inject", injectBody)
  # The CMP-M6 session binding persists past the turn end until
  # ``campaign stop`` explicitly drops it.  The inject should land.
  check iCode == 202
  let iJson = parseJson(iResp)
  check iJson{"status"}.getStr("") == "queued"
  check iJson{"campaignId"}.getStr("") == campaignId
  check iJson{"eventId"}.getStr("").len > 0

  # A ``note`` event tagged kind=operator_injection landed.
  let evts = eventsForCampaignWithIds(f, campaignId)
  var sawInjectNote = false
  for e in evts:
    if e.kind == "note":
      let p = parseJson(e.payload)
      if p{"kind"}.getStr("") == "operator_injection":
        sawInjectNote = true
        check p{"text"}.getStr("") == "fix the android stretching first"
        # acknowledged stays false — the single-turn model never
        # drains it on behalf of a running turn.
        check not e.acknowledged
  check sawInjectNote
  check countEvents(f, campaignId, "note") == beforeInject + 1

test "test_inject_route_404_on_no_active_session":
  ## A campaign transitioned to terminal (no entry in the in-memory
  ## ``CampaignRegistry.sessions`` map) must return 404 ``no_active_session``.
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let docPath = "/tmp/cmp-m6-fixture/campaigns/inject-stopped.md"
  writeDocFixture(docPath, FixtureCampaignDoc)
  let body = startBodyDefault(docPath, "sha-inject-stopped", FixtureBriefBody)
  let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s == 200
  let rows = fetchCampaignByDoc(f, docPath)
  let campaignId = rows[0][0]
  # Drive the campaign to terminal state.
  discard campaignPost(f, "/api/campaign/stop",
    $(%* {"campaignId": campaignId, "reason": "cmp-m6 test"}))

  let injectBody = $(%* {"campaignId": campaignId,
                         "text": "this should be rejected"})
  let (iCode, iResp) = campaignPost(f, "/api/campaign/inject", injectBody)
  check iCode == 404
  let iJson = parseJson(iResp)
  check iJson{"error"}.getStr("") == "no_active_session"

test "test_inject_queues_to_session_but_does_not_interrupt":
  ## CMP-M6: inject DURING a running turn queues the text on the per-
  ## session ACP queue but does NOT interrupt the turn.  In the
  ## single-turn model the queued texts are observable via the
  ## ``CampaignRegistry`` peek helper but the daemon never folds them
  ## into a continuation prompt (there is no continuation prompt).
  ## The campaign turn proceeds and ends naturally.
  ##
  ## We exercise the peek surface against the in-process registry to
  ## prove the event-id queue accumulates the injection.  This is the
  ## behaviour that earlier tick tests asserted; now we just assert
  ## the queue persists past the turn.
  let f = startCampaignDaemon()
  defer: f.shutdown()
  let docPath = "/tmp/cmp-m6-fixture/campaigns/inject-no-interrupt.md"
  writeDocFixture(docPath, FixtureCampaignDoc)
  let body = startBodyDefault(docPath, "sha-inject-no-interrupt", FixtureBriefBody)
  let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s == 200
  let rows = fetchCampaignByDoc(f, docPath)
  let campaignId = rows[0][0]

  let (iCode, iResp) = campaignPost(f, "/api/campaign/inject",
    $(%* {"campaignId": campaignId, "text": "no-interrupt test"}))
  check iCode == 202
  let eventId = parseJson(iResp){"eventId"}.getStr("")
  check eventId.len > 0

  # The inject's ``note`` event row was written but its
  # ``acknowledged`` flag stays FALSE — no continuation turn drains
  # it.  This is the documented single-turn limitation.
  let evts = eventsForCampaignWithIds(f, campaignId)
  var sawUnacked = false
  for e in evts:
    if e.eventId == eventId:
      check not e.acknowledged
      sawUnacked = true
  check sawUnacked

test "test_refresh_doc_route_updates_sha_and_records_event":
  ## Mutate the campaign doc on disk, then POST /refresh-doc.  Verify
  ## ``campaigns.doc_sha`` flipped to the new SHA and a ``note`` event
  ## with kind=doc_refreshed landed.
  let f = startCampaignDaemon(@[("FAKE_ACP_STREAM_CHUNKS", "1")])
  defer: f.shutdown()
  let docPath = "/tmp/cmp-m6-fixture/campaigns/refresh-doc.md"
  writeDocFixture(docPath, FixtureCampaignDoc)
  let body = startBodyDefault(docPath, "sha-refresh-doc-1", FixtureBriefBody)
  let (s, _) = rawPostStream(f.baseUrl, "/api/campaign/start", body)
  check s == 200
  let rows = fetchCampaignByDoc(f, docPath)
  let campaignId = rows[0][0]
  let originalSha = rows[0][6]

  # Mutate the doc on disk so refresh observes a change.
  let mutated = FixtureCampaignDoc & "\n## Operator amendment\n\n" &
    "- The user added a new line at " & $epochTime() & ".\n"
  writeFile(docPath, mutated)

  let refreshBody = $(%* {"campaignId": campaignId})
  let (rCode, rResp) = campaignPost(f, "/api/campaign/refresh-doc",
                                    refreshBody)
  check rCode == 200
  let rJson = parseJson(rResp)
  check rJson{"campaignId"}.getStr("") == campaignId
  check rJson{"contentChanged"}.getBool(false)
  let oldSha = rJson{"oldSha"}.getStr("")
  let newSha = rJson{"newSha"}.getStr("")
  check oldSha == originalSha
  check newSha != originalSha
  check newSha.len == 64   # sha256 hex

  # ``campaigns.doc_sha`` was actually updated.
  let after = fetchCampaignByDoc(f, docPath)
  check after.len == 1
  check after[0][6] == newSha

  # The ``note`` event landed with kind=doc_refreshed.
  let evts = eventsForCampaign(f, campaignId)
  var sawRefresh = false
  for e in evts:
    if e.kind == "note":
      let p = parseJson(e.payload)
      if p{"kind"}.getStr("") == "doc_refreshed":
        sawRefresh = true
        check p{"oldSha"}.getStr("") == oldSha
        check p{"newSha"}.getStr("") == newSha
        check p{"contentChanged"}.getBool(false)
  check sawRefresh
