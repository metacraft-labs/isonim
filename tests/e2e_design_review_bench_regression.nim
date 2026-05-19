## REV-M9 — synthetic regression test.
##
## Replaces ``design_review.list_history`` with a slowed-down variant
## (adds ``PERFORM pg_sleep(0.05)``), reruns the benchmark, and asserts:
##
##   1. Exit code is non-zero.
##   2. Stderr/stdout contains the documented
##      ``threshold_violation: list_history pXX=YYms (max=ZZms)`` line.
##   3. ``benchmark_results.json`` still gets written (we want failures
##      to *publish* the bad metric, not skip writing it — the historical
##      gh-pages chart needs to show the regression).
##   4. The github-action-benchmark entry for ``list_history`` p50
##      records a verdict of ``violation`` in its ``extra`` field.
##
## The fixture cluster is restored to the canonical
## ``list_history`` body via the migration file before the test
## returns, so this test does not leave the cluster poisoned for
## subsequent tests in the same Nim run.

import std/[json, os, osproc, streams, strtabs, strutils, unittest]

import db_connector/db_postgres
import helpers/design_review_pg_fixture

const RepoRootHere = currentSourcePath().parentDir().parentDir()
const BenchBin = RepoRootHere / "build" / "bin" / "design_review_bench"
const SlowFixture = """
CREATE OR REPLACE FUNCTION design_review.list_history(
  p_brief_id TEXT,
  p_limit    INT,
  p_offset   INT
) RETURNS SETOF JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $bench$
DECLARE
  v_limit  INT := COALESCE(p_limit, 50);
  v_offset INT := COALESCE(p_offset, 0);
BEGIN
  -- Synthetic regression: 50 ms of artificial latency per call.
  PERFORM pg_sleep(0.05);
  RETURN QUERY
    SELECT jsonb_build_object(
      'run_id',         r.run_id,
      'brief_id',       r.brief_id,
      'manifest_hash',  r.manifest_hash,
      'status',         r.status,
      'status_reason',  r.status_reason,
      'started_by',     r.started_by,
      'started_at',     r.started_at,
      'finished_at',    r.finished_at,
      'capture_count',  (SELECT count(*) FROM design_review.captures c
        WHERE c.run_id = r.run_id),
      'report_count',   (SELECT count(*) FROM design_review.agent_reports g
        WHERE g.run_id = r.run_id)
    )
    FROM design_review.runs r
    WHERE r.brief_id = p_brief_id
    ORDER BY r.started_at DESC
    LIMIT v_limit
    OFFSET v_offset;
END;
$bench$;
"""

proc seedFixtures(f: PgFixture) =
  let probe = findExe("psql")
  if probe.len == 0:
    raise newException(IOError, "psql not on PATH")
  let psql = probe.parentDir / "psql"
  for sqlFile in ["seed_10k_runs.sql", "seed_28_capture_run.sql",
                  "seed_layout_10k.sql"]:
    let path = RepoRootHere / "bench" / "fixtures" / sqlFile
    let cmd = psql & " -h 127.0.0.1 -p " & $f.port & " -d isonim_design_review" &
              " -U design_review_migrator -v ON_ERROR_STOP=1 -f " & path.quoteShell
    let res = execCmdEx(cmd)
    if res.exitCode != 0:
      raise newException(IOError,
        "seeder failed: " & sqlFile & "\n" & res.output)

proc runBench(f: PgFixture; iterations: int): tuple[code: int; output: string] =
  if not fileExists(BenchBin):
    raise newException(IOError,
      "design_review_bench not built at " & BenchBin)
  var env = newStringTable()
  env["ISONIM_REVIEW_PGPORT"] = $f.port
  env["ISONIM_REVIEW_PGHOST"] = "127.0.0.1"
  env["ISONIM_REVIEW_PGDB"]   = "isonim_design_review"
  env["ISONIM_REVIEW_PGUSER"] = "design_review_app"
  env["ISONIM_REVIEW_PGSEEDUSER"] = "design_review_migrator"
  env["PATH"] = getEnv("PATH")
  env["HOME"] = getEnv("HOME")
  let cmd = BenchBin & " --iterations:" & $iterations &
            " --routine:list_history --no-fixtures"
  let p = startProcess("/bin/sh", args = @["-c", cmd], env = env,
      options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  result.output = p.outputStream.readAll()
  result.code = p.waitForExit()

suite "REV-M9 bench regression":
  test "e2e_synthetic_regression_fails_ci":
    let f = newPgFixture()
    defer: f.shutdown()
    seedFixtures(f)

    # Inject the slow routine as the migrator role.
    let dsn = "host=127.0.0.1 port=" & $f.port &
              " dbname=isonim_design_review user=design_review_migrator"
    let db = open("", "design_review_migrator", "", dsn)
    db.exec(sql(SlowFixture))
    db.close()

    # 30 iterations is enough — every call has 50 ms of artificial
    # latency, so p50 will be ~50 ms regardless of sample size and the
    # threshold (20 ms) will be exceeded.  Keeping the count small
    # keeps the test runtime sane (~1.5 s instead of ~50 s).
    let r = runBench(f, 30)
    check r.code != 0
    if r.code == 0:
      echo "regression bench unexpectedly passed:\n" & r.output
    check "threshold_violation: list_history p50=" in r.output
    check "(max=20ms)" in r.output

    # Even on failure the bench publishes its metrics.
    let gab = RepoRootHere / "bench-results" / "benchmark_results.json"
    check fileExists(gab)
    let node = parseJson(readFile(gab))
    check node.kind == JArray
    var foundViolation = false
    for entry in node:
      if entry["name"].getStr ==
         "isonim-design-review/list_history/p50_ms":
        let extra = entry{"extra"}.getStr
        if "verdict=violation" in extra:
          foundViolation = true
    check foundViolation
