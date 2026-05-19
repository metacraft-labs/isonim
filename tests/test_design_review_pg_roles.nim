## REV-M3 — grant-enforcement tests.
##
## Cross-checks the stored-procedure boundary: ``design_review_app`` has
## EXECUTE on every routine and *no* INSERT/UPDATE/DELETE/SELECT on any
## base table.  ``design_review_migrator`` has DDL.  Helpers
## (audit_event_insert / guard_run_status) are not exposed to the app role.

import std/[sets, strutils, unittest]
import db_connector/db_postgres
import helpers/design_review_pg_fixture

const BaseTables = [
  "runs", "captures", "agent_reports", "gallery_layouts", "audit_events"]

proc connectApp(f: PgFixture): DbConn =
  open("", "design_review_app", "",
    "host=127.0.0.1 port=" & $f.port &
      " dbname=isonim_design_review user=design_review_app")

proc connectMigrator(f: PgFixture): DbConn =
  open("", "design_review_migrator", "",
    "host=127.0.0.1 port=" & $f.port &
      " dbname=isonim_design_review user=design_review_migrator")

suite "REV-M3 roles":
  var f: PgFixture
  setup:
    f = newPgFixture()
  teardown:
    f.shutdown()

  test "app_role_has_no_write_grants_on_base_tables":
    let mig = connectMigrator(f)
    defer: mig.close()
    var grantedToApp: HashSet[string]
    for row in mig.fastRows(sql"""
      SELECT table_name || '/' || privilege_type
      FROM information_schema.table_privileges
      WHERE table_schema = 'design_review'
        AND grantee = 'design_review_app'"""):
      grantedToApp.incl row[0]
    # No write/select grants of any kind.
    for t in BaseTables:
      for priv in [
          "SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE",
          "REFERENCES", "TRIGGER"]:
        check (t & "/" & priv) notin grantedToApp

  test "app_role_has_execute_on_every_public_routine":
    let mig = connectMigrator(f)
    defer: mig.close()
    let expected = [
      "fail_run_capture", "fail_run_review", "fetch_run",
      "finish_captures", "finish_run", "list_history",
      "list_layouts", "promote_layout",
      "record_agent_report", "record_capture",
      "save_gallery_layout", "start_run"]
    var grantedToApp: HashSet[string]
    for row in mig.fastRows(sql"""
      SELECT routine_name FROM information_schema.routine_privileges
      WHERE specific_schema = 'design_review'
        AND grantee = 'design_review_app'
        AND privilege_type = 'EXECUTE'"""):
      grantedToApp.incl row[0]
    for name in expected:
      check name in grantedToApp

  test "app_role_cannot_execute_internal_helpers":
    let app = connectApp(f)
    defer: app.close()
    # ``audit_event_insert`` has no GRANT EXECUTE to the app role; the
    # call should be rejected with insufficient_privilege.
    var raised = false
    var msg = ""
    try:
      discard app.getValue(sql"""SELECT design_review.audit_event_insert(
        'app', 'should.fail', NULL, NULL, NULL, '{}'::jsonb)""")
    except DbError as e:
      raised = true
      msg = e.msg
    check raised
    check ("permission denied" in msg) or ("42501" in msg)

  test "migrator_role_can_create_and_drop_tables":
    let mig = connectMigrator(f)
    defer: mig.close()
    # Use a sandbox table under the migrator-owned schema; this proves
    # DDL works in the actual review database, not just in a sandbox
    # outside the schema we care about.
    mig.exec(sql"""CREATE TABLE design_review._migrator_test (x INT)""")
    mig.exec(sql"""INSERT INTO design_review._migrator_test VALUES (42)""")
    let v = mig.getValue(sql"SELECT x FROM design_review._migrator_test")
    check v == "42"
    mig.exec(sql"DROP TABLE design_review._migrator_test")

  test "app_role_cannot_create_tables_in_design_review_schema":
    let app = connectApp(f)
    defer: app.close()
    var raised = false
    try:
      app.exec(sql"CREATE TABLE design_review._app_should_fail (x INT)")
    except DbError:
      raised = true
    check raised
