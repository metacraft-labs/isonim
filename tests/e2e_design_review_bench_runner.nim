## REV-M9 — end-to-end ``just bench-design-review`` runner test.
##
## Spawns the benchmark binary against an ephemeral ``PgFixture``
## cluster (so the test is hermetic; we do NOT depend on a
## developer-started ``just dev-pg-start``) and asserts:
##
##   1. Exit code is zero.
##   2. ``bench-results/benchmark_results.json`` exists, parses, and
##      contains entries for all four routines (p50 + p95 each).
##   3. A per-run JSON snapshot is also written under
##      ``bench-results/`` with a timestamp in its name.
##   4. Every routine's verdict in the per-run JSON is ``"pass"``.
##
## The test invokes the bench binary directly with the production
## ``--iterations:1000`` count.  ``just bench-design-review`` is a thin
## bash wrapper around the binary plus a ``pg_isready`` guard; the
## binary is what does the actual work, and the wrapper's behaviour is
## covered by ``e2e_design_review_bench_regression.nim`` (which calls
## the wrapper end-to-end).

import std/[json, os, osproc, streams, strtabs, strutils, unittest]

import helpers/design_review_pg_fixture

const RepoRootHere = currentSourcePath().parentDir().parentDir()
const BenchBin = RepoRootHere / "build" / "bin" / "design_review_bench"

proc ensureBenchBin() =
  if not fileExists(BenchBin):
    raise newException(IOError,
      "design_review_bench binary not found at " & BenchBin)

suite "REV-M9 bench runner":
  test "e2e_benchmark_runner_against_process_compose":
    ensureBenchBin()
    let f = newPgFixture()
    defer: f.shutdown()

    # Snapshot the bench-results directory so we can identify the
    # per-run file produced by this invocation (the timestamp in the
    # name lets us tell our file apart from any historical files).
    let outDir = RepoRootHere / "bench-results"
    createDir(outDir)
    let preexisting = block:
      var s: seq[string]
      for kind, p in walkDir(outDir):
        if kind == pcFile and p.endsWith(".json") and
           not p.endsWith("benchmark_results.json"):
          s.add p
      s

    var env = newStringTable()
    env["ISONIM_REVIEW_PGPORT"] = $f.port
    env["ISONIM_REVIEW_PGHOST"] = "127.0.0.1"
    env["ISONIM_REVIEW_PGDB"]   = "isonim_design_review"
    env["ISONIM_REVIEW_PGUSER"] = "design_review_app"
    env["ISONIM_REVIEW_PGSEEDUSER"] = "design_review_migrator"
    env["PATH"] = getEnv("PATH")
    env["HOME"] = getEnv("HOME")
    let cmd = BenchBin & " --iterations:1000"
    let p = startProcess("/bin/sh", args = @["-c", cmd], env = env,
        options = {poUsePath, poStdErrToStdOut})
    defer: p.close()
    let output = p.outputStream.readAll()
    let code = p.waitForExit()
    check code == 0
    if code != 0:
      echo output

    # 1) github-action-benchmark JSON must exist and cover all four
    #    routines × two percentiles.
    let gabPath = outDir / "benchmark_results.json"
    check fileExists(gabPath)
    let gab = parseJson(readFile(gabPath))
    check gab.kind == JArray
    let routines = ["list_history", "fetch_run",
                    "save_gallery_layout", "record_capture"]
    for routine in routines:
      var sawP50 = false
      var sawP95 = false
      for entry in gab:
        let n = entry["name"].getStr
        if n == "isonim-design-review/" & routine & "/p50_ms":
          sawP50 = true
          check entry["unit"].getStr == "ms"
          # The entry's "extra" field must mark the verdict as ``pass``.
          let extra = entry{"extra"}.getStr
          check "verdict=pass" in extra
        elif n == "isonim-design-review/" & routine & "/p95_ms":
          sawP95 = true
          check entry["unit"].getStr == "ms"
      check sawP50
      check sawP95

    # 2) A per-run snapshot (different name) must also have been
    #    produced.  We don't pin the exact name because it includes a
    #    wall-clock timestamp; we just assert that *something new*
    #    appeared.
    var newOnes: seq[string] = @[]
    for kind, path in walkDir(outDir):
      if kind != pcFile: continue
      if path.endsWith("benchmark_results.json"): continue
      if path in preexisting: continue
      newOnes.add path
    check newOnes.len >= 1

    # 3) Verdict in the per-run JSON: all four routines pass both
    #    percentiles.
    if newOnes.len >= 1:
      let perRun = parseJson(readFile(newOnes[^1]))
      check perRun.kind == JObject
      check perRun.hasKey("routines")
      let arr = perRun["routines"]
      check arr.kind == JArray
      check arr.len == 4
      for entry in arr:
        let name = entry["name"].getStr
        let verdict = entry["verdict"].getStr
        check verdict == "pass"
        if verdict != "pass":
          echo "FAIL ", name, " p50=", entry["p50_ms"].getFloat,
               " p95=", entry["p95_ms"].getFloat
