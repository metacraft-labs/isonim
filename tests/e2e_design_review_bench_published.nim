## REV-M9 — verifies the benchmark JSON output structure matches what
## the continuous-benchmarking pipeline expects.
##
## The pipeline downstream (``benchmark-action/github-action-benchmark``)
## expects a JSON array where every entry has:
##   - ``name``  — string, used as the chart series.
##   - ``unit``  — string, displayed on the y-axis.
##   - ``value`` — number, the measurement.
##   - ``extra`` — optional string with free-form metadata.
##
## See ``metacraft-specs/policies/continuous-benchmarking.md`` §
## "Machine-Readable Output" for the canonical shape.
##
## This test runs the bench once, then re-reads
## ``bench-results/benchmark_results.json`` and asserts:
##   - it's a non-empty JSON array;
##   - every entry has ``name``, ``unit``, ``value``;
##   - ``unit`` is one of the documented units (``ms`` here);
##   - ``value`` is a finite, non-negative number;
##   - the name namespace ``isonim-design-review/<routine>/<percentile>``
##     covers all four routines (one row per routine per the spec's
##     compliance-matrix requirement).
##
## Also verifies that the per-run snapshot is well-formed JSON: the
## continuous-benchmarking pipeline doesn't read these, but human
## reviewers do (during incident investigation), so structural
## correctness is part of the contract.

import std/[json, math, os, osproc, streams, strtabs, strutils, unittest]

import helpers/design_review_pg_fixture

const RepoRootHere = currentSourcePath().parentDir().parentDir()
const BenchBin = RepoRootHere / "build" / "bin" / "design_review_bench"

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
      raise newException(IOError, "seeder failed: " & sqlFile & "\n" & res.output)

suite "REV-M9 bench published shape":
  test "e2e_benchmark_results_published_to_continuous_benchmarking":
    if not fileExists(BenchBin):
      raise newException(IOError, "bench binary missing: " & BenchBin)
    let f = newPgFixture()
    defer: f.shutdown()
    seedFixtures(f)

    var env = newStringTable()
    env["ISONIM_REVIEW_PGPORT"] = $f.port
    env["ISONIM_REVIEW_PGHOST"] = "127.0.0.1"
    env["ISONIM_REVIEW_PGDB"]   = "isonim_design_review"
    env["ISONIM_REVIEW_PGUSER"] = "design_review_app"
    env["ISONIM_REVIEW_PGSEEDUSER"] = "design_review_migrator"
    env["PATH"] = getEnv("PATH")
    env["HOME"] = getEnv("HOME")
    let cmd = BenchBin & " --iterations:200 --no-fixtures"
    let p = startProcess("/bin/sh", args = @["-c", cmd], env = env,
        options = {poUsePath, poStdErrToStdOut})
    defer: p.close()
    let output = p.outputStream.readAll()
    let code = p.waitForExit()
    check code == 0
    if code != 0:
      echo output

    # ----- github-action-benchmark JSON -----
    let gabPath = RepoRootHere / "bench-results" / "benchmark_results.json"
    check fileExists(gabPath)
    let gab = parseJson(readFile(gabPath))
    check gab.kind == JArray
    check gab.len >= 8 # 4 routines × (p50 + p95)

    let routines = ["list_history", "fetch_run",
                    "save_gallery_layout", "record_capture"]
    var coverage: seq[string] = @[]
    for entry in gab:
      check entry.kind == JObject
      check entry.hasKey("name")
      check entry.hasKey("unit")
      check entry.hasKey("value")
      check entry["name"].kind == JString
      check entry["unit"].kind == JString
      let unit = entry["unit"].getStr
      check unit == "ms"  # documented unit for latency
      let value = entry["value"].getFloat
      check value >= 0.0
      check classify(value) notin {fcInf, fcNegInf, fcNan}
      coverage.add entry["name"].getStr

    for routine in routines:
      check ("isonim-design-review/" & routine & "/p50_ms") in coverage
      check ("isonim-design-review/" & routine & "/p95_ms") in coverage

    # ----- per-run snapshot -----
    let outDir = RepoRootHere / "bench-results"
    var perRunSnaps: seq[string] = @[]
    for kind, path in walkDir(outDir):
      if kind == pcFile and path.endsWith(".json") and
         not path.endsWith("benchmark_results.json"):
        perRunSnaps.add path
    check perRunSnaps.len >= 1
    let snap = parseJson(readFile(perRunSnaps[^1]))
    check snap.kind == JObject
    check snap.hasKey("routines")
    check snap.hasKey("iterations")
    check snap.hasKey("timestamp")
    check snap["routines"].kind == JArray
    check snap["routines"].len == 4
    for r in snap["routines"]:
      check r.kind == JObject
      check r.hasKey("name")
      check r.hasKey("p50_ms")
      check r.hasKey("p95_ms")
      check r.hasKey("p50_pass")
      check r.hasKey("p95_pass")
      check r.hasKey("verdict")
      check r["verdict"].getStr in ["pass", "threshold_violation"]
