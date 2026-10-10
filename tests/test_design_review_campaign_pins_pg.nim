## REV-M5 follow-up (2026-10-10) — campaign pins in the database
## (migration 012), against a real PostgreSQL cluster (``PgFixture``).
##
## ``campaign_db.openCampaignRound`` is exactly what
## ``POST /api/campaign/start`` does with the pin the CLI took: store the
## record, create or reopen the campaign, begin the round.  The pins here
## are synthetic but canonical workspace locks — the database verifies
## that a record hashes to its pin, not that its revisions exist
## (``test_design_review_campaign_pins`` covers taking real pins).

import std/[json, os, strutils, unittest]

import db_connector/db_postgres

import isonim/editor/design_review/campaign_db
import isonim/editor/design_review/campaign_pin
import isonim/editor/design_review/db
import isonim/editor/design_review/pin_db
import isonim/editor/design_review/workspace_pin

import helpers/design_review_pg_fixture

proc pinFor(rev: char): WorkspacePin =
  let toml = renderCanonicalLock(WorkspaceLock(project: "isonim",
    scope: ProjectScope, repos: @[LockedRepo(name: "isonim",
      path: "isonim", remote: "origin", revision: repeat(rev, 40))]))
  WorkspacePin(pin: pinOf(toml), lockToml: toml)

proc startFor(docPath, docSha: string): CampaignStart =
  CampaignStart(docPath: docPath, docSha: docSha,
                briefRefs: @["render.demo-app"], targetScore: 9.0,
                hasTargetScore: true, maxIterations: 3,
                agentBackend: "claude", startedBy: "tester")

proc openApp(f: PgFixture): ReviewDb =
  ReviewDb(conn: open("", "design_review_app", "",
    "host=127.0.0.1 port=" & $f.port &
    " dbname=isonim_design_review user=design_review_app"))

proc openMigrator(f: PgFixture): DbConn =
  open("", "design_review_migrator", "",
    "host=127.0.0.1 port=" & $f.port &
    " dbname=isonim_design_review user=design_review_migrator")

proc fetchCampaign(db: ReviewDb; id: string): JsonNode =
  parseJson(db.conn.getValue(
    sql"SELECT design_review.fetch_campaign(?::uuid, 100)::text", id))

proc eventsOf(c: JsonNode; kind: string): seq[JsonNode] =
  for e in c["events"]:
    if e["event_kind"].getStr == kind: result.add e

proc countCampaigns(f: PgFixture): int =
  let m = openMigrator(f)
  defer: m.close()
  parseInt(m.getValue(sql"SELECT count(*) FROM design_review.campaigns"))

suite "campaign pins (PostgreSQL, migration 012)":
  var f: PgFixture
  setup:
    f = newPgFixture()
  teardown:
    f.shutdown()

  test "test_campaign_start_records_its_pin_as_start_pin_and_round_1":
    let db = openApp(f)
    defer: db.close()
    let pin = pinFor('a')
    let opened = openCampaignRound(db, startFor("/c/start.md", "sha-1"), pin)
    check opened.round == 1
    let c = fetchCampaign(db, opened.campaignId)
    check c["manifest_hash"].getStr == pin.pin
    check fetchWorkspacePinLock(db, pin.pin) == pin.lockToml
    let p = parseCampaignProvenance(c)
    check p.startState == cpsPinned
    check p.rounds.len == 1
    check p.rounds[0].round == 1
    check p.rounds[0].pin == pin.pin
    check p.rounds[0].startedBy == "tester"
    let started = eventsOf(c, "round_started")
    check started.len == 1
    check started[0]["payload"]["round"].getInt == 1
    check started[0]["payload"]["workspace_pin"].getStr == pin.pin

  test "test_every_round_records_its_own_pin_and_keeps_the_start_pin":
    let db = openApp(f)
    defer: db.close()
    let (a, b) = (pinFor('a'), pinFor('b'))
    let first = openCampaignRound(db, startFor("/c/rounds.md", "sha-r"), a)
    # The turn ends: a round_complete event, then a terminal status.
    discard db.conn.getValue(sql(
      "SELECT design_review.record_campaign_event('" & first.campaignId &
      "'::uuid, 'round_complete', '{\"round\": 1}'::jsonb)"))
    discard db.conn.getValue(sql(
      "SELECT design_review.transition_campaign('" & first.campaignId &
      "'::uuid, 'failed', 'turn over')"))
    # ``campaign start`` again on the same doc: a new round, own pin.
    let second = openCampaignRound(db, startFor("/c/rounds.md", "sha-r"), b)
    check second.campaignId == first.campaignId
    check second.round == 2
    let c = fetchCampaign(db, first.campaignId)
    check c["status"].getStr == "active"
    check c["manifest_hash"].getStr == a.pin      # the start pin stays
    let p = parseCampaignProvenance(c)
    check p.rounds.len == 2
    check p.rounds[0].pin == a.pin
    check p.rounds[1].round == 2
    check p.rounds[1].pin == b.pin
    check p.unpinnedRounds == 0
    check countCampaigns(f) == 1

  test "test_start_campaign_refuses_a_placeholder_or_unrecorded_pin":
    let db = openApp(f)
    defer: db.close()
    db.asApp()
    for value in ["local", "test:fixture", pinFor('c').pin]:
      expect DbError:
        discard db.conn.getValue(sql(
          "SELECT design_review.start_campaign('/c/x.md', 'sha-x', " &
          "ARRAY['render.demo-app']::text[], NULL, 3, '" & value &
          "', 'claude', NULL, 'tester')"))
    check countCampaigns(f) == 0

  test "test_begin_campaign_round_refuses_an_unrecorded_pin":
    let db = openApp(f)
    defer: db.close()
    let opened = openCampaignRound(db, startFor("/c/unrec.md", "sha-u"),
                                   pinFor('a'))
    expect DbError:
      discard db.conn.getValue(sql(
        "SELECT design_review.begin_campaign_round('" & opened.campaignId &
        "'::uuid, '" & pinFor('d').pin & "', 'tester')"))
    let p = parseCampaignProvenance(fetchCampaign(db, opened.campaignId))
    check p.rounds.len == 1

  test "test_legacy_local_campaign_still_loads_and_continues_pinned":
    # A row written before migration 012: manifest_hash 'local', two
    # completed rounds, no round pins.
    let m = openMigrator(f)
    defer: m.close()
    let legacyId = m.getValue(sql"""
      INSERT INTO design_review.campaigns (doc_path, doc_sha, brief_refs,
        target_score, max_iterations, manifest_hash, status, agent_backend,
        started_by, finished_at)
      VALUES ('/c/legacy.md', 'sha-legacy', ARRAY['render.demo-app'],
        9.0, 3, 'local', 'failed', 'claude', 'cli', NOW())
      RETURNING campaign_id::text""")
    for i in 1 .. 2:
      m.exec(sql"""
        INSERT INTO design_review.campaign_events (campaign_id, event_kind, payload)
        VALUES (?::uuid, 'round_complete', '{}'::jsonb)""", legacyId)

    let db = openApp(f)
    defer: db.close()
    db.asApp()
    let c = fetchCampaign(db, legacyId)
    check c["manifest_hash"].getStr == "local"
    check c["rounds"].len == 0
    check c["rounds_completed"].getInt == 2
    let p = parseCampaignProvenance(c)
    check p.startState == cpsLegacyUnpinned
    check p.unpinnedRounds == 2
    check LegacyUnpinnedNote in renderCampaignProvenance(p).join("\n")
    var listed = false
    for row in db.conn.fastRows(sql(
        "SELECT design_review.list_campaigns(NULL, 50, 0)::text")):
      if parseJson(row[0])["campaign_id"].getStr == legacyId: listed = true
    check listed

    # Restarting the legacy campaign pins the new round, numbered after
    # the rounds it already ran; its start stays legacy.
    let pin = pinFor('e')
    let opened = openCampaignRound(db, startFor("/c/legacy.md", "sha-legacy"),
                                   pin)
    check opened.campaignId == legacyId
    check opened.round == 3
    let after = parseCampaignProvenance(fetchCampaign(db, legacyId))
    check after.startPin == "local"
    check after.startState == cpsLegacyUnpinned
    check after.rounds.len == 1
    check after.rounds[0].round == 3
    check after.rounds[0].pin == pin.pin
    check after.unpinnedRounds == 2

suite "campaign pins (PostgreSQL, upgrading to migration 012)":

  test "test_migration_012_keeps_campaigns_written_before_it_working":
    # A database that ran 001..011 and holds campaigns written the
    # pre-012 way (the CLI's placeholder "local" as manifest_hash), then
    # upgraded: 012 must apply over those rows, and they must keep
    # loading, listing, changing status and restarting.
    let f = newPgFixture(applyMigrations = false)
    defer: f.shutdown()
    var pending: seq[string]
    for path in migrationFiles():
      if path.extractFilename < "012": f.applyMigrationFile(path)
      else: pending.add path
    check pending.len >= 1
    check pending[0].extractFilename == "012_design_review_campaign_pins.sql"

    let db = openApp(f)
    defer: db.close()
    db.asApp()
    proc legacyStart(docPath: string): string =
      db.conn.getValue(sql(
        "SELECT design_review.start_campaign('" & docPath & "', 'sha-old', " &
        "ARRAY['render.demo-app']::text[], NULL, 3, 'local', 'claude', " &
        "NULL, 'cli')::text"))
    let finished = legacyStart("/c/old-finished.md")
    let running = legacyStart("/c/old-running.md")
    check finished.len > 0 and running.len > 0
    for i in 1 .. 2:
      discard db.conn.getValue(sql(
        "SELECT design_review.record_campaign_event('" & finished &
        "'::uuid, 'round_complete', '{}'::jsonb)"))
    discard db.conn.getValue(sql(
      "SELECT design_review.transition_campaign('" & finished &
      "'::uuid, 'failed', 'turn over')"))

    for path in pending: f.applyMigrationFile(path)

    # Loads: the legacy start pin is reported as is, as legacy-unpinned.
    let c = fetchCampaign(db, finished)
    check c["manifest_hash"].getStr == "local"
    check c["rounds"].len == 0
    check c["rounds_completed"].getInt == 2
    let p = parseCampaignProvenance(c)
    check p.startState == cpsLegacyUnpinned
    check p.unpinnedRounds == 2
    # Lists.
    var listed: seq[string]
    for row in db.conn.fastRows(sql(
        "SELECT design_review.list_campaigns(NULL, 50, 0)::text")):
      listed.add parseJson(row[0])["campaign_id"].getStr
    check finished in listed and running in listed
    # Changes status (no CHECK on manifest_hash trips over 'local').
    discard db.conn.getValue(sql(
      "SELECT design_review.transition_campaign('" & running &
      "'::uuid, 'stopped', 'upgrade test')"))
    check fetchCampaign(db, running)["status"].getStr == "stopped"
    # Restarts: the new round is pinned and numbered after the two the
    # campaign already ran; the legacy start pin is not rewritten.
    let pin = pinFor('f')
    let opened = openCampaignRound(db,
      startFor("/c/old-finished.md", "sha-old"), pin)
    check opened.campaignId == finished
    check opened.round == 3
    let after = parseCampaignProvenance(fetchCampaign(db, finished))
    check after.startPin == "local"
    check after.rounds.len == 1
    check after.rounds[0].round == 3
    check after.rounds[0].pin == pin.pin
    # And a new campaign can no longer be started with the placeholder.
    expect DbError:
      discard legacyStart("/c/new-after-upgrade.md")
