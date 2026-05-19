## REV-M4 — ``isonim-review init`` tests against a real Postgres
## fixture (no DB mocks).  Covers the four ``test_cli_init_*`` checks
## from the milestone's Verification block.
##
## The fixture in ``helpers/design_review_pg_fixture.nim`` applies
## ``db/migrations/*.sql`` by default; we pass ``applyMigrations=false``
## here because the whole point is to exercise the CLI's migration
## driver.  ``schema_migrations`` is created by the CLI's own
## ``ensureMigrationsTable`` path, matching the bash script's contract.

import std/[os, osproc, streams, strtabs, strutils, unittest]
import db_connector/db_postgres

import helpers/design_review_pg_fixture
import tools/isonim_review/cmd_init
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

proc countMigrations(f: PgFixture): int =
  let c = connectMigrator(f)
  defer: c.close()
  let v = c.getValue(sql"SELECT count(*) FROM public.schema_migrations")
  parseInt(v)

suite "REV-M4 isonim-review init":

  test "test_cli_init_applies_migrations_from_empty_db":
    ## Fresh cluster with no migrations applied → cmdInit reports
    ## ``applied N`` and ``schema_migrations`` contains exactly the
    ## two migration files we ship in REV-M3.
    let f = newPgFixture(applyMigrations = false)
    defer: f.shutdown()

    let cfg = cfgFor(f)
    let tmpLog = getTempDir() / "isonim_init_test_out_a.log"
    let outFile = open(tmpLog, fmWrite)
    let rc = cmdInit(cfg, MigDir, outFile)
    outFile.close()
    let outText = readFile(tmpLog)
    removeFile(tmpLog)
    check rc == 0
    check countMigrations(f) == 2
    check "apply 001" in outText
    check "apply 002" in outText
    check "applied 2 migration(s)" in outText

  test "test_cli_init_is_noop_on_already_migrated":
    ## Second run against the same cluster: every migration is
    ## skipped, no rows inserted, stdout names the skipped versions.
    let f = newPgFixture(applyMigrations = false)
    defer: f.shutdown()

    let cfg = cfgFor(f)
    let tmp1 = getTempDir() / "isonim_init_test_out_b1.log"
    let outFile1 = open(tmp1, fmWrite)
    check cmdInit(cfg, MigDir, outFile1) == 0
    outFile1.close()
    removeFile(tmp1)
    let before = countMigrations(f)

    let tmp2 = getTempDir() / "isonim_init_test_out_b2.log"
    let outFile2 = open(tmp2, fmWrite)
    let rc = cmdInit(cfg, MigDir, outFile2)
    outFile2.close()
    let outText = readFile(tmp2)
    removeFile(tmp2)
    check rc == 0
    check countMigrations(f) == before
    check "skip 001" in outText
    check "skip 002" in outText
    check "no migrations to apply" in outText

  test "test_cli_init_refuses_dirty_migration_state":
    ## Apply, then DELETE row 1 (leaving design_review.runs in place).
    ## Re-running init must refuse: row missing but table exists.
    let f = newPgFixture(applyMigrations = false)
    defer: f.shutdown()

    let cfg = cfgFor(f)
    let tmp1 = getTempDir() / "isonim_init_test_out_c1.log"
    let outFile1 = open(tmp1, fmWrite)
    check cmdInit(cfg, MigDir, outFile1) == 0
    outFile1.close()
    removeFile(tmp1)

    block tamper:
      let c = connectMigrator(f)
      defer: c.close()
      c.exec(sql"DELETE FROM public.schema_migrations WHERE version = 1")

    # Capture stderr by spawning the CLI subprocess — the dirty-state
    # error goes to stderr.  This is exactly what the milestone
    # describes: ``init exits non-zero with 'schema state
    # inconsistent: migration 1 missing but design_review.runs exists'``.
    let cli = RepoRoot / "build" / "bin" / "isonim-review"
    check fileExists(cli)

    # Use osproc with an environment carrying the libpq port + host
    # so the CLI connects to the fixture cluster.
    var environ = newStringTable(modeCaseSensitive)
    for kv in envPairs():
      environ[kv.key] = kv.value
    environ["ISONIM_REVIEW_PGHOST"] = "127.0.0.1"
    environ["ISONIM_REVIEW_PGPORT"] = $f.port
    let p2 = startProcess(cli,
      args = @["init", "--migrations", MigDir],
      env = environ,
      options = {poStdErrToStdOut, poUsePath})
    defer: p2.close()
    let out2 = p2.outputStream.readAll()
    let rc = p2.waitForExit()
    check rc != 0
    check "schema state inconsistent" in out2
    check "migration 1" in out2
    check "design_review.runs" in out2

    # No new row inserted by the failed run.
    let after = block:
      let c = connectMigrator(f)
      defer: c.close()
      parseInt(c.getValue(sql"SELECT count(*) FROM public.schema_migrations"))
    check after == 1  # only migration 2's row remains

  test "test_cli_init_refuses_modified_migration_file":
    ## Apply, copy a migration to a scratch dir, mutate one byte,
    ## re-run init pointing at the scratch dir.  Content-hash drift
    ## must fail loudly.
    let f = newPgFixture(applyMigrations = false)
    defer: f.shutdown()

    let cfg = cfgFor(f)
    let tmp1 = getTempDir() / "isonim_init_test_out_d1.log"
    let outFile1 = open(tmp1, fmWrite)
    check cmdInit(cfg, MigDir, outFile1) == 0
    outFile1.close()
    removeFile(tmp1)

    let scratch = getTempDir() / "isonim_review_migrations_drift"
    if dirExists(scratch): removeDir(scratch)
    createDir(scratch)
    # Copy lib.sql + both migrations, then mutate migration 001.
    copyFile(MigDir / "lib.sql", scratch / "lib.sql")
    copyFile(
      MigDir / "001_design_review_schema.sql",
      scratch / "001_design_review_schema.sql")
    copyFile(
      MigDir / "002_design_review_routines.sql",
      scratch / "002_design_review_routines.sql")
    let altered = scratch / "001_design_review_schema.sql"
    var body = readFile(altered)
    body.add "\n-- drift marker\n"
    writeFile(altered, body)

    let tmp2 = getTempDir() / "isonim_init_test_out_d2.log"
    let outFile2 = open(tmp2, fmWrite)
    # cmdInit writes errors to stderr; we capture via redirect by
    # spawning the binary.
    outFile2.close()
    removeFile(tmp2)

    let cli = RepoRoot / "build" / "bin" / "isonim-review"
    check fileExists(cli)
    var environ = newStringTable(modeCaseSensitive)
    for kv in envPairs():
      environ[kv.key] = kv.value
    environ["ISONIM_REVIEW_PGHOST"] = "127.0.0.1"
    environ["ISONIM_REVIEW_PGPORT"] = $f.port
    let p = startProcess(cli,
      args = @["init", "--migrations", scratch],
      env = environ,
      options = {poStdErrToStdOut, poUsePath})
    defer: p.close()
    let outText = p.outputStream.readAll()
    let rc = p.waitForExit()
    check rc != 0
    check "content hash mismatch" in outText
    check "migration 1" in outText

    # Both rows still present — no partial reapplication.
    let after = block:
      let c = connectMigrator(f)
      defer: c.close()
      parseInt(c.getValue(sql"SELECT count(*) FROM public.schema_migrations"))
    check after == 2

    removeDir(scratch)
