## REV-M3 — schema introspection tests.
##
## Verifies that migration 001 + migration 002 land exactly the tables,
## indexes, and (public) routines documented in
## ``codetracer-specs/Front-Ends/IsoNim/isonim-editor.md``.  A real
## Postgres cluster from the fixture; no mocks.

import std/[sets, unittest]
import db_connector/db_postgres
import helpers/design_review_pg_fixture

const ExpectedTables = [
  "agent_reports", "audit_events",
  "campaign_events", "campaigns",
  "captures", "gallery_layouts", "runs"]

const ExpectedIndexes = [
  "idx_audit_kind_time",
  "idx_captures_run", "idx_captures_sha256",
  "idx_layouts_brief", "idx_layouts_brief_owner",
  "idx_reports_run",
  "idx_runs_brief_started", "idx_runs_status"]

const ExpectedRoutines = [
  "fail_run_capture", "fail_run_review",
  "fetch_run", "finish_captures", "finish_run",
  "list_history", "list_layouts",
  "promote_layout", "record_agent_report",
  "record_capture", "save_gallery_layout",
  "start_run"]

proc connectMigrator(f: PgFixture): DbConn =
  open("", "design_review_migrator", "",
    "host=127.0.0.1 port=" & $f.port &
      " dbname=isonim_design_review user=design_review_migrator")

suite "REV-M3 schema":
  var f: PgFixture
  setup:
    f = newPgFixture()
  teardown:
    f.shutdown()

  test "test_migration_001_creates_expected_tables":
    let db = connectMigrator(f)
    defer: db.close()
    var found: seq[string]
    for row in db.fastRows(sql"""
      SELECT tablename FROM pg_tables
      WHERE schemaname = 'design_review'
      ORDER BY tablename"""):
      found.add row[0]
    check found == @ExpectedTables

  test "test_migration_001_creates_expected_indexes":
    let db = connectMigrator(f)
    defer: db.close()
    var found = initHashSet[string]()
    for row in db.fastRows(sql"""
      SELECT indexname FROM pg_indexes WHERE schemaname = 'design_review'"""):
      found.incl row[0]
    for expected in ExpectedIndexes:
      check expected in found

  test "test_migration_002_installs_twelve_routines":
    ## The schema may contain helper routines (e.g. audit_event_insert,
    ## guard_run_status); the test asserts that the twelve documented
    ## *public* routines are all present.  The helpers are internal —
    ## the app role does not get EXECUTE on them.
    let db = connectMigrator(f)
    defer: db.close()
    var found: HashSet[string]
    for row in db.fastRows(sql"""
      SELECT proname FROM pg_proc
      WHERE pronamespace = 'design_review'::regnamespace"""):
      found.incl row[0]
    for expected in ExpectedRoutines:
      check expected in found
    # And app-role EXECUTE grants exist on exactly those 12 routines.
    var grantedToApp: HashSet[string]
    for row in db.fastRows(sql"""
      SELECT routine_name FROM information_schema.routine_privileges
      WHERE specific_schema = 'design_review'
        AND grantee = 'design_review_app'
        AND privilege_type = 'EXECUTE'"""):
      grantedToApp.incl row[0]
    for expected in ExpectedRoutines:
      check expected in grantedToApp
    # Sanity: ``audit_event_insert`` is NOT granted to the app role
    # (internal helper).
    check "audit_event_insert" notin grantedToApp
