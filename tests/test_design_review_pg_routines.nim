## REV-M3 — per-routine integration tests.
##
## Real Postgres, real routines, no mocks at the DB boundary.  Each test
## exercises one routine's happy path plus its documented validation
## behaviour (idempotency, version conflicts, scope CHECKs, etc.).

import std/[json, strutils, unittest]
import db_connector/db_postgres
import helpers/design_review_pg_fixture

proc dsn(f: PgFixture; user: string): string =
  "host=127.0.0.1 port=" & $f.port & " dbname=isonim_design_review user=" & user

proc connectMigrator(f: PgFixture): DbConn =
  open("", "design_review_migrator", "", dsn(f, "design_review_migrator"))

proc connectApp(f: PgFixture): DbConn =
  open("", "design_review_app", "", dsn(f, "design_review_app"))

proc scalar(db: DbConn; q: string): string =
  ## ``getValue`` reads exactly one column from one row and drains the
  ## result set — safer than half-iterating ``fastRows`` which leaves the
  ## connection in single-row-mode and breaks the next query.
  db.getValue(sql(q))

proc countTable(db: DbConn; table: string): int =
  parseInt(scalar(db, "SELECT count(*) FROM " & table))

suite "REV-M3 routines":
  var f: PgFixture
  setup:
    f = newPgFixture()
  teardown:
    f.shutdown()

  test "test_app_role_cannot_directly_insert_into_runs":
    let app = connectApp(f)
    defer: app.close()
    var raised = false
    var sqlstate = ""
    try:
      app.exec(sql"""INSERT INTO design_review.runs
        (brief_id, manifest_hash, status, started_by)
        VALUES ('render.test', 'abc123', 'capturing', 'tester')""")
    except DbError as e:
      raised = true
      sqlstate = e.msg
    check raised
    # ``insufficient_privilege`` is SQLSTATE 42501.  Postgres wraps it in
    # a libpq message; the substring check is robust against driver
    # formatting differences.
    check ("permission denied" in sqlstate) or ("42501" in sqlstate)

  test "test_app_role_can_execute_start_run_routine":
    let app = connectApp(f)
    defer: app.close()
    let runId = scalar(app,
      "SELECT design_review.start_run('render.test', 'abc123', 'tester')")
    check runId.len == 36   # UUID
    let mig = connectMigrator(f)
    defer: mig.close()
    check countTable(mig, "design_review.runs") == 1

  test "test_app_role_cannot_drop_tables":
    let app = connectApp(f)
    defer: app.close()
    var raised = false
    var msg = ""
    try:
      app.exec(sql"DROP TABLE design_review.runs")
    except DbError as e:
      raised = true
      msg = e.msg
    check raised
    check ("must be owner" in msg) or ("permission denied" in msg) or
          ("42501" in msg) or ("insufficient_privilege" in msg)

  test "test_audit_event_fk_referential_integrity":
    let mig = connectMigrator(f)
    defer: mig.close()
    var raised = false
    var msg = ""
    try:
      mig.exec(sql"""INSERT INTO design_review.audit_events
        (actor, event_kind, run_id, payload)
        VALUES ('t', 'x', gen_random_uuid(), '{}'::jsonb)""")
    except DbError as e:
      raised = true
      msg = e.msg
    check raised
    check ("foreign key" in msg.toLowerAscii) or
          ("foreign_key_violation" in msg) or ("23503" in msg)

  test "test_audit_event_appended_in_same_transaction_as_state_change":
    let app = connectApp(f)
    defer: app.close()
    # Baseline counts (read via migrator since app can't SELECT base tables).
    let mig = connectMigrator(f)
    defer: mig.close()
    check countTable(mig, "design_review.runs") == 0
    check countTable(mig, "design_review.audit_events") == 0
    # Open an explicit txn through the app role, call start_run, ROLLBACK.
    app.exec(sql"BEGIN")
    let rid = scalar(app,
      "SELECT design_review.start_run('render.txn', 'h', 'tester')")
    check rid.len == 36
    app.exec(sql"ROLLBACK")
    # Audit row must roll back with the state change.  If they were in
    # different transactions the audit row would persist.
    check countTable(mig, "design_review.runs") == 0
    check countTable(mig, "design_review.audit_events") == 0

  test "test_gallery_layout_scope_check_rejects_invalid_combinations":
    let app = connectApp(f)
    defer: app.close()
    # scope='user' with NULL owner_user_id → rejected by routine validation.
    var raised = false
    try:
      discard scalar(app,
        "SELECT design_review.save_gallery_layout(" &
        "NULL, 'render.brief', 'user', NULL, 'l', '{}'::jsonb, 1)")
    except DbError: raised = true
    check raised
    # scope='workspace' with non-NULL owner_user_id → rejected.
    raised = false
    try:
      discard scalar(app,
        "SELECT design_review.save_gallery_layout(" &
        "NULL, 'render.brief', 'workspace', 'alice', 'l', '{}'::jsonb, 1)")
    except DbError: raised = true
    check raised

  test "test_capture_unique_run_preview_viewport":
    let app = connectApp(f)
    defer: app.close()
    let mig = connectMigrator(f)
    defer: mig.close()
    let rid = scalar(app,
      "SELECT design_review.start_run('render.test', 'h', 't')")
    let cid1 = scalar(app,
      "SELECT design_review.record_capture('" & rid & "'::uuid," &
      "'p/i:page#0@web','web','tablet','sha','/p',1,1)")
    let cid2 = scalar(app,
      "SELECT design_review.record_capture('" & rid & "'::uuid," &
      "'p/i:page#0@web','web','tablet','sha','/p',1,1)")
    check cid1 == cid2
    # Exactly one capture row and exactly one capture.recorded audit row.
    let captureCount = countTable(mig, "design_review.captures")
    check captureCount == 1
    let auditRecorded = parseInt(scalar(mig,
      "SELECT count(*) FROM design_review.audit_events " &
      "WHERE event_kind = 'capture.recorded'"))
    check auditRecorded == 1

  test "test_record_agent_report_idempotent_on_natural_key":
    let app = connectApp(f)
    defer: app.close()
    let mig = connectMigrator(f)
    defer: mig.close()
    let rid = scalar(app,
      "SELECT design_review.start_run('render.test', 'h', 't')")
    discard scalar(app,
      "SELECT design_review.finish_captures('" & rid & "'::uuid)")
    let r1 = scalar(app,
      "SELECT design_review.record_agent_report('" & rid & "'::uuid," &
      "'claude','v1','/p','{}'::jsonb)")
    let r2 = scalar(app,
      "SELECT design_review.record_agent_report('" & rid & "'::uuid," &
      "'claude','v1','/p','{}'::jsonb)")
    check r1 == r2
    check countTable(mig, "design_review.agent_reports") == 1

  test "test_save_gallery_layout_optimistic_concurrency_rejects_stale":
    let app = connectApp(f)
    defer: app.close()
    # Initial INSERT (p_layout_id NULL → version=1).
    let first = scalar(app,
      "SELECT design_review.save_gallery_layout(" &
      "NULL, 'render.brief', 'user', 'alice', 'l', '{\"v\":1}'::jsonb, 1)")
    check first.len > 0
    let firstObj = parseJson(first)
    let layoutId = firstObj["layout_id"].getStr
    check firstObj["version"].getInt == 1
    # Second save with expected_version=1 → bumps to v=2.
    let second = scalar(app,
      "SELECT design_review.save_gallery_layout(" &
      "'" & layoutId & "'::uuid, 'render.brief', 'user', 'alice', " &
      "'l', '{\"v\":2}'::jsonb, 1)")
    let secondObj = parseJson(second)
    check secondObj["version"].getInt == 2
    # Third save with stale expected_version=1 → raises layout_version_conflict.
    var raised = false
    var msg = ""
    try:
      discard scalar(app,
        "SELECT design_review.save_gallery_layout(" &
        "'" & layoutId & "'::uuid, 'render.brief', 'user', 'alice', " &
        "'l', '{\"v\":3}'::jsonb, 1)")
    except DbError as e:
      raised = true
      msg = e.msg
    check raised
    check "layout_version_conflict" in msg
