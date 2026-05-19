## REV-M3 — pg_dump / pg_restore round-trip smoke.
##
## Seed a small fixture, dump it with the real ``pg_dump`` binary,
## restore it into a *second* cluster, assert per-table counts match.
## This is the milestone's ``smoke_pg_dump_restore_roundtrip`` check.

import std/[os, osproc, strutils, unittest]
import db_connector/db_postgres
import helpers/design_review_pg_fixture

proc connectMigrator(f: PgFixture): DbConn =
  open("", "design_review_migrator", "",
    "host=127.0.0.1 port=" & $f.port &
      " dbname=isonim_design_review user=design_review_migrator")

proc connectApp(f: PgFixture): DbConn =
  open("", "design_review_app", "",
    "host=127.0.0.1 port=" & $f.port &
      " dbname=isonim_design_review user=design_review_app")

proc countTable(db: DbConn; t: string): int =
  parseInt(db.getValue(sql("SELECT count(*) FROM " & t)))

proc seedFixture(f: PgFixture) =
  ## Seed 3 runs, each with 4 captures + 1 report; plus 2 layouts.  The
  ## numbers are small so the dump stays cheap.
  let app = connectApp(f)
  defer: app.close()
  for i in 0..2:
    let rid = app.getValue(sql(
      "SELECT design_review.start_run('render.brief', 'h" & $i &
      "', 'tester')"))
    for v in 0..3:
      discard app.getValue(sql(
        "SELECT design_review.record_capture('" & rid & "'::uuid," &
        "'p" & $v & "/x:page#0@web','web','tablet','sha" & $v &
        "','/p/" & $i & "_" & $v & "',640,480)"))
    discard app.getValue(sql(
      "SELECT design_review.finish_captures('" & rid & "'::uuid)"))
    discard app.getValue(sql(
      "SELECT design_review.record_agent_report('" & rid & "'::uuid," &
      "'claude','v1','/p/r" & $i & "','{}'::jsonb)"))
  discard app.getValue(sql(
    "SELECT design_review.save_gallery_layout(" &
    "NULL, 'render.brief', 'user', 'alice', 'g1', '{}'::jsonb, 1)"))
  discard app.getValue(sql(
    "SELECT design_review.save_gallery_layout(" &
    "NULL, 'render.brief', 'workspace', NULL, 'g2', '{}'::jsonb, 1)"))

suite "REV-M3 pg_dump / pg_restore":
  test "smoke_pg_dump_restore_roundtrip":
    let src = newPgFixture()
    defer: src.shutdown()
    seedFixture(src)

    # Source counts.
    let srcDb = connectMigrator(src)
    let cRuns     = countTable(srcDb, "design_review.runs")
    let cCaptures = countTable(srcDb, "design_review.captures")
    let cReports  = countTable(srcDb, "design_review.agent_reports")
    let cLayouts  = countTable(srcDb, "design_review.gallery_layouts")
    let cAudit    = countTable(srcDb, "design_review.audit_events")
    srcDb.close()
    check cRuns == 3
    check cCaptures == 12
    check cReports == 3
    check cLayouts == 2
    check cAudit > 0

    # pg_dump → file.
    let dumpFile = getTempDir() / "isonim_review_dump.sql"
    if fileExists(dumpFile): removeFile(dumpFile)
    let pgDump = findExe("pg_dump")
    check pgDump.len > 0
    let dumpCmd = pgDump & " -h 127.0.0.1 -p " & $src.port &
        " -U design_review_migrator" &
        " -d isonim_design_review --no-owner --no-acl" &
        " -f " & dumpFile.quoteShell
    let dumpRes = execCmdEx(dumpCmd)
    check dumpRes.exitCode == 0
    check fileExists(dumpFile)
    check getFileSize(dumpFile) > 0

    # Restore into a second cluster (without re-applying migrations:
    # the dump carries the DDL).
    let dst = newPgFixture(applyMigrations = false)
    defer: dst.shutdown()
    let psql = findExe("psql")
    let restoreCmd = psql & " -h 127.0.0.1 -p " & $dst.port &
        " -U design_review_migrator -d isonim_design_review" &
        " -v ON_ERROR_STOP=1 -f " & dumpFile.quoteShell
    let restoreRes = execCmdEx(restoreCmd)
    check restoreRes.exitCode == 0

    let dstDb = connectMigrator(dst)
    defer: dstDb.close()
    check countTable(dstDb, "design_review.runs")            == cRuns
    check countTable(dstDb, "design_review.captures")        == cCaptures
    check countTable(dstDb, "design_review.agent_reports")   == cReports
    check countTable(dstDb, "design_review.gallery_layouts") == cLayouts
    check countTable(dstDb, "design_review.audit_events")    == cAudit
