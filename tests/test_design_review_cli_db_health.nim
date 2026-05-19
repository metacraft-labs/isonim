## REV-M4 — ``isonim-review db-health`` tests against the REV-M3 PG
## fixture (no DB mocks).  Covers the four ``test_cli_db_health_*``
## checks from the milestone's Verification block.

import std/[json, os, times, unittest]
import db_connector/db_postgres

import helpers/design_review_pg_fixture
import tools/isonim_review/cmd_init
import tools/isonim_review/cmd_db_health
import tools/isonim_review/config

const RepoRoot = currentSourcePath().parentDir().parentDir()
const MigDir = RepoRoot / "db" / "migrations"

proc connectMigrator(f: PgFixture): DbConn =
  open("", "design_review_migrator", "",
    "host=127.0.0.1 port=" & $f.port &
      " dbname=isonim_design_review user=design_review_migrator")

proc cfgFor(f: PgFixture): ReviewConfig =
  result = defaults()
  result.db.host = "127.0.0.1"
  result.db.port = f.port
  result.db.database = "isonim_design_review"

proc runInit(cfg: ReviewConfig) =
  let nullOut = open("/dev/null", fmWrite)
  defer: nullOut.close()
  check cmdInit(cfg, MigDir, nullOut) == 0

suite "REV-M4 isonim-review db-health":

  test "test_cli_db_health_all_green_after_init":
    ## Fresh fixture → init → db-health.  Every DB probe must be
    ## green; the JSON projection has the documented shape.
    let f = newPgFixture(applyMigrations = false)
    defer: f.shutdown()
    let cfg = cfgFor(f)
    runInit(cfg)
    let rep = collectHealth(cfg, MigDir)
    check rep.postgresReachable
    check rep.appRoleReachable
    check rep.migratorRoleReachable
    check rep.schemaVersionCurrent
    check rep.schemaVersion == 3
    check rep.pendingMigrations.len == 0

    # JSON projection contains the documented keys.
    let j = parseJson(renderJson(rep))
    check j["postgres_reachable"].getBool
    check j["app_role_reachable"].getBool
    check j["migrator_role_reachable"].getBool
    check j["schema_version_current"].getBool
    check j["schema_version"].getInt == 3

  test "test_cli_db_health_distinguishes_app_vs_migrator":
    ## Revoke the routine the app-role probe calls; db-health must
    ## drop ``app_role_reachable`` while keeping ``migrator_role_reachable``
    ## green.
    let f = newPgFixture(applyMigrations = false)
    defer: f.shutdown()
    let cfg = cfgFor(f)
    runInit(cfg)

    block tamper:
      let c = connectMigrator(f)
      defer: c.close()
      # Postgres' default is to grant EXECUTE on functions to PUBLIC
      # (any role with USAGE on the schema can run them).  To actually
      # take the routine away from ``design_review_app`` we revoke from
      # both PUBLIC and the role explicitly — same pattern an admin
      # would use in production.
      c.exec(sql"""
        REVOKE EXECUTE ON FUNCTION
          design_review.list_history(text, int, int)
        FROM PUBLIC, design_review_app""")

    let rep = collectHealth(cfg, MigDir)
    check rep.postgresReachable
    check not rep.appRoleReachable
    check rep.migratorRoleReachable

  test "test_cli_db_health_detects_stale_schema":
    ## Add an extra migration file (one beyond the highest shipped)
    ## to a scratch dir without applying it; db-health must mark
    ## ``schema_version_current=false`` and list the new version in
    ## ``pending_migrations``.
    let f = newPgFixture(applyMigrations = false)
    defer: f.shutdown()
    let cfg = cfgFor(f)
    runInit(cfg)

    let scratch = getTempDir() / "isonim_review_migrations_pending"
    if dirExists(scratch): removeDir(scratch)
    createDir(scratch)
    copyFile(MigDir / "lib.sql", scratch / "lib.sql")
    copyFile(
      MigDir / "001_design_review_schema.sql",
      scratch / "001_design_review_schema.sql")
    copyFile(
      MigDir / "002_design_review_routines.sql",
      scratch / "002_design_review_routines.sql")
    copyFile(
      MigDir / "003_design_review_fetch_capture.sql",
      scratch / "003_design_review_fetch_capture.sql")
    writeFile(
      scratch / "004_dummy.sql",
      "-- placeholder migration not yet applied\n" &
        "SELECT 1;\n")
    defer: removeDir(scratch)

    let rep = collectHealth(cfg, scratch)
    check rep.postgresReachable
    check not rep.schemaVersionCurrent
    check 4 in rep.pendingMigrations
    # Schema version is still the highest applied (3), not 4.
    check rep.schemaVersion == 3

  test "test_cli_db_health_detects_postgres_down":
    ## Aim at a port that nothing's listening on.  db-health must
    ## return non-zero, mark postgres_reachable=false, and finish
    ## in under 5 s — the spec's hard deadline.
    var cfg = defaults()
    cfg.db.host = "127.0.0.1"
    cfg.db.port = 65499  # well above the fixture range; nothing listens here.
    cfg.db.database = "isonim_design_review"

    let started = epochTime()
    let rep = collectHealth(cfg, MigDir)
    let elapsed = epochTime() - started
    check not rep.postgresReachable
    check elapsed < 5.0  # spec demands < 5 s
    # The aggregate is not green.
    check not allGreen(rep)
