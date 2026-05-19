## REV-M9 — bench-threshold smoke tests.
##
## Each test runs the design-review benchmark binary against an
## ephemeral ``PgFixture`` cluster (the same hermetic harness REV-M3..M8
## use), restricted to one routine, with abbreviated iteration counts so
## the suite runs in CI under a minute.  The threshold values used are
## the *production* thresholds from ``bench/thresholds.toml`` — never
## relaxed for the test suite.
##
## What "abbreviated" means here:
##   - 200 iterations per routine (vs 1000 in production).  200 still
##     gives a credible p50/p95 (the percentile is computed by rank,
##     not by parametric fit), and at 200 the whole test takes <2 s.
##   - For ``list_history``, we use the same 10 000-run fixture the
##     production bench seeds — the index scan only matters when the
##     table is large, so shrinking the fixture would *mask* a
##     regression rather than expose it.  The fixture is idempotent;
##     subsequent test runs cost ~one ``SELECT count(*)``.
##
## Each named test corresponds 1:1 to a REV-M9 Verification entry.

import std/[json, os, osproc, streams, strtabs, unittest]

import helpers/design_review_pg_fixture

const RepoRootHere = currentSourcePath().parentDir().parentDir()
const BenchBin = RepoRootHere / "build" / "bin" / "design_review_bench"

proc ensureBenchBin() =
  if not fileExists(BenchBin):
    raise newException(IOError,
      "design_review_bench binary not found at " & BenchBin &
      ".  Build it with `just bench-design-review-build`.")

proc seedDb(f: PgFixture) =
  ## Apply the three fixture seeders idempotently against the fixture
  ## cluster.  We use the migrator role (which the PgFixture sets up).
  let binDir = (block:
    let probe = findExe("psql")
    if probe.len == 0:
      raise newException(IOError, "psql not on PATH")
    probe.parentDir)
  let psql = binDir / "psql"
  for sqlFile in ["seed_10k_runs.sql", "seed_28_capture_run.sql",
                  "seed_layout_10k.sql"]:
    let path = RepoRootHere / "bench" / "fixtures" / sqlFile
    let cmd = psql & " -h 127.0.0.1 -p " & $f.port & " -d isonim_design_review" &
              " -U design_review_migrator -v ON_ERROR_STOP=1 -f " & path.quoteShell
    let res = execCmdEx(cmd)
    if res.exitCode != 0:
      raise newException(IOError,
        "seeder failed: " & sqlFile & " (" & $res.exitCode & ")\n" & res.output)

proc runBench(f: PgFixture; routine: string; iterations = 200): tuple[
    exitCode: int; output: string; resultJson: JsonNode] =
  ## Invokes the bench binary against the fixture cluster, restricted to
  ## one routine.  Returns the (exitCode, captured-output, parsed-JSON)
  ## triple so individual tests can assert on the verdict + percentiles.
  ensureBenchBin()
  let outDir = RepoRootHere / "bench-results"
  createDir(outDir)
  var env = newStringTable()
  env["ISONIM_REVIEW_PGPORT"] = $f.port
  env["ISONIM_REVIEW_PGHOST"] = "127.0.0.1"
  env["ISONIM_REVIEW_PGDB"]   = "isonim_design_review"
  env["ISONIM_REVIEW_PGUSER"] = "design_review_app"
  env["ISONIM_REVIEW_PGSEEDUSER"] = "design_review_migrator"
  env["PATH"] = getEnv("PATH")
  env["HOME"] = getEnv("HOME")
  let cmd = BenchBin & " --iterations:" & $iterations &
            " --routine:" & routine & " --no-fixtures --verbose"
  let p = startProcess("/bin/sh", args = @["-c", cmd], env = env,
      options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  result.output = p.outputStream.readAll()
  result.exitCode = p.waitForExit()
  # The bench always writes ``benchmark_results.json`` *unless*
  # ``--no-write`` is passed.  We re-read it to assert the routine's
  # verdict from the structured output rather than parsing stderr text.
  let gabPath = RepoRootHere / "bench-results" / "benchmark_results.json"
  if fileExists(gabPath):
    try: result.resultJson = parseJson(readFile(gabPath))
    except JsonParsingError: result.resultJson = newJNull()
  else:
    result.resultJson = newJNull()

proc findP50(node: JsonNode; routine: string): float =
  ## Pluck the ``p50_ms`` entry for the routine out of the
  ## github-action-benchmark JSON array.
  if node.kind != JArray: return -1
  for entry in node:
    let n = entry["name"].getStr
    if n == "isonim-design-review/" & routine & "/p50_ms":
      return entry["value"].getFloat
  -1

proc findP95(node: JsonNode; routine: string): float =
  if node.kind != JArray: return -1
  for entry in node:
    let n = entry["name"].getStr
    if n == "isonim-design-review/" & routine & "/p95_ms":
      return entry["value"].getFloat
  -1

# Shared fixture across all four tests — booting Postgres five times in
# a single test file is wasteful.  The fixture is reset between tests
# only where strictly required (``record_capture`` doesn't pollute
# either routine that runs after it).
suite "REV-M9 bench thresholds":
  var f: PgFixture
  setup:
    if f.isNil or not f.started:
      f = newPgFixture()
      seedDb(f)
  teardown:
    discard  # share the fixture across tests in this suite

  test "bench_list_history_p50_under_20ms":
    let r = runBench(f, "list_history")
    check r.exitCode == 0
    let p50 = findP50(r.resultJson, "list_history")
    let p95 = findP95(r.resultJson, "list_history")
    check p50 >= 0
    check p50 < 20.0
    check p95 < 50.0
    if r.exitCode != 0:
      echo r.output

  test "bench_fetch_run_p50_under_15ms":
    let r = runBench(f, "fetch_run")
    check r.exitCode == 0
    let p50 = findP50(r.resultJson, "fetch_run")
    let p95 = findP95(r.resultJson, "fetch_run")
    check p50 >= 0
    check p50 < 15.0
    check p95 < 40.0
    if r.exitCode != 0:
      echo r.output

  test "bench_save_gallery_layout_p50_under_10ms":
    let r = runBench(f, "save_gallery_layout")
    check r.exitCode == 0
    let p50 = findP50(r.resultJson, "save_gallery_layout")
    let p95 = findP95(r.resultJson, "save_gallery_layout")
    check p50 >= 0
    check p50 < 10.0
    check p95 < 25.0
    if r.exitCode != 0:
      echo r.output

  test "bench_record_capture_p50_under_5ms":
    let r = runBench(f, "record_capture")
    check r.exitCode == 0
    let p50 = findP50(r.resultJson, "record_capture")
    let p95 = findP95(r.resultJson, "record_capture")
    check p50 >= 0
    check p50 < 5.0
    check p95 < 15.0
    if r.exitCode != 0:
      echo r.output

  test "REV-M9 teardown: shutdown shared PgFixture":
    # ``std/unittest`` doesn't expose a suite teardown; we tack it onto
    # the last test so the fixture is reclaimed in CI cleanly.
    f.shutdown()
