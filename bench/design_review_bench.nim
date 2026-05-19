## REV-M9 — design-review benchmark binary.
##
## Drives the four hot-path routines against a live process-compose
## Postgres cluster (or any cluster reachable via the standard
## ``ISONIM_REVIEW_*`` env vars).  For each routine it:
##
##   1. Seeds fixture data via ``bench/fixtures/*.sql`` (idempotent).
##   2. Warms one prepared statement on one persistent connection.
##   3. Runs the routine ``--iterations`` times (default 1000), collecting
##      per-iteration wall-clock timings via ``std/monotimes``.
##   4. Computes p50 / p95 / mean / max from sorted samples.
##   5. Compares against the thresholds in ``bench/thresholds.toml``.
##      Any percentile that exceeds its budget produces a
##      ``threshold_violation`` line on stderr and turns the process
##      exit code non-zero.
##
## Output (always, regardless of pass/fail):
##   - ``bench-results/<iso-timestamp>.json``  — full per-routine result
##     bundle with timings, verdicts, fixture sizes, host info.
##   - ``bench-results/benchmark_results.json`` — github-action-benchmark
##     compliance shape (one metric per (routine, percentile) pair).
##
## CLI flags
## ---------
##   ``--iterations:N``      — sample count per routine (default 1000).
##   ``--routine:NAME``      — restrict to one routine (repeatable).  When
##                             absent, all four routines run.
##   ``--fixture-runs:N``    — override ``list_history`` fixture size
##                             (default 10 000).  Lower values speed up
##                             the threshold tests; the *measured loop*
##                             does not care about fixture size beyond
##                             "large enough that the index matters".
##   ``--thresholds:PATH``   — alternate thresholds.toml.
##   ``--no-fixtures``       — skip ``psql -f`` seeding; assume rows
##                             already present.
##   ``--no-write``          — don't write JSON files (used by smoke tests).
##   ``--verbose``           — extra logging to stderr.
##
## Environment
## -----------
## Reads the standard isonim-review env contract:
##   ``ISONIM_REVIEW_PGPORT``  — default 5533.
##   ``ISONIM_REVIEW_PGHOST``  — default 127.0.0.1.
##   ``ISONIM_REVIEW_PGUSER``  — default ``design_review_app``.
##   ``ISONIM_REVIEW_PGDB``    — default ``isonim_design_review``.

import std/[algorithm, json, math, monotimes, os, osproc, parseopt,
            strformat, strutils, tables, times]
import db_connector/db_postgres

const RepoRoot = currentSourcePath().parentDir().parentDir()
const FixturesDir = currentSourcePath().parentDir() / "fixtures"
const DefaultThresholds = currentSourcePath().parentDir() / "thresholds.toml"

type
  Threshold = object
    p50MsMax: float
    p95MsMax: float

  RoutineName = enum
    rnListHistory      = "list_history"
    rnFetchRun         = "fetch_run"
    rnSaveGalleryLayout = "save_gallery_layout"
    rnRecordCapture    = "record_capture"

  RoutineResult = object
    name: string
    iterations: int
    p50Ms: float
    p95Ms: float
    meanMs: float
    minMs: float
    maxMs: float
    p50MsMax: float
    p95MsMax: float
    p50Pass: bool
    p95Pass: bool
    extra: string

  BenchConfig = object
    iterations: int
    routines: seq[RoutineName]
    fixtureRuns: int
    thresholdsPath: string
    noFixtures: bool
    noWrite: bool
    verbose: bool

# -----------------------------------------------------------------------------
# Minimal TOML reader: only what we need for ``thresholds.toml``.
# Supports ``[section]`` headers and ``key = number`` pairs.  Comments
# (``#``) and blank lines are ignored.  This avoids pulling in a TOML
# package for four floats.
# -----------------------------------------------------------------------------

proc readThresholds(path: string): Table[string, Threshold] =
  result = initTable[string, Threshold]()
  var current = ""
  for rawLine in lines(path):
    var line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    if line.startsWith("[") and line.endsWith("]"):
      current = line[1..^2].strip()
      if not result.hasKey(current):
        result[current] = Threshold(p50MsMax: 0, p95MsMax: 0)
      continue
    if current.len == 0:
      continue
    let eq = line.find('=')
    if eq < 0:
      continue
    let key = line[0..<eq].strip()
    var valueStr = line[(eq+1)..^1].strip()
    # Strip inline comment.
    let hashIdx = valueStr.find('#')
    if hashIdx >= 0:
      valueStr = valueStr[0..<hashIdx].strip()
    let value =
      try: parseFloat(valueStr)
      except ValueError: 0.0
    var t = result[current]
    case key
    of "p50_ms_max": t.p50MsMax = value
    of "p95_ms_max": t.p95MsMax = value
    else: discard
    result[current] = t

# -----------------------------------------------------------------------------
# Connection helpers
# -----------------------------------------------------------------------------

proc envOr(name, default: string): string =
  let v = getEnv(name)
  if v.len > 0: v else: default

proc connect(): DbConn =
  let host = envOr("ISONIM_REVIEW_PGHOST", "127.0.0.1")
  let port = envOr("ISONIM_REVIEW_PGPORT", "5533")
  let user = envOr("ISONIM_REVIEW_PGUSER", "design_review_app")
  let db   = envOr("ISONIM_REVIEW_PGDB",   "isonim_design_review")
  let dsn  = "host=" & host & " port=" & port &
             " dbname=" & db & " user=" & user
  result = open("", user, "", dsn)

proc psqlSeed(file: string; verbose: bool) =
  ## Apply a fixture SQL file via ``psql``.  We shell out rather than
  ## issue the SQL through libpq because the seeders use ``DO $$ ... $$``
  ## blocks that span multiple statements; ``db_postgres.exec`` doesn't
  ## stream those cleanly.
  let host = envOr("ISONIM_REVIEW_PGHOST", "127.0.0.1")
  let port = envOr("ISONIM_REVIEW_PGPORT", "5533")
  let dbn  = envOr("ISONIM_REVIEW_PGDB",   "isonim_design_review")
  let user = envOr("ISONIM_REVIEW_PGSEEDUSER", "design_review_migrator")
  let cmd = "psql -h " & host & " -p " & port & " -d " & dbn &
            " -U " & user & " -v ON_ERROR_STOP=1 -f " & file.quoteShell
  if verbose:
    stderr.writeLine("[bench] seed: " & cmd)
  let res = execCmdEx(cmd)
  if res.exitCode != 0:
    raise newException(IOError,
      "psql seeder failed (" & $res.exitCode & "): " & cmd & "\n" & res.output)

# -----------------------------------------------------------------------------
# Stats
# -----------------------------------------------------------------------------

proc percentile(sortedMs: seq[float]; pct: float): float =
  ## Nearest-rank percentile.  ``pct`` in [0, 100].
  if sortedMs.len == 0: return 0.0
  let rank = int(ceil(pct / 100.0 * float(sortedMs.len))) - 1
  let idx = max(0, min(sortedMs.len - 1, rank))
  sortedMs[idx]

proc summarise(samples: seq[float]): tuple[p50, p95, mean, mn, mx: float] =
  var s = samples
  s.sort()
  result.p50 = percentile(s, 50)
  result.p95 = percentile(s, 95)
  result.mean = (if s.len == 0: 0.0 else: sum(s) / float(s.len))
  result.mn = (if s.len == 0: 0.0 else: s[0])
  result.mx = (if s.len == 0: 0.0 else: s[^1])

# -----------------------------------------------------------------------------
# Benchmarks
# -----------------------------------------------------------------------------

proc fetchListHistoryBriefId(db: DbConn): string =
  ## The seeded brief; consistent with ``seed_10k_runs.sql``.
  "render.bench-fixture"

proc fetchRunUuid(db: DbConn): string =
  ## Look up the run-id seeded by ``seed_28_capture_run.sql`` via the
  ## ``list_history`` routine (the only path the app role is permitted
  ## to use for the ``runs`` table — base-table SELECTs are denied).
  let raw = db.getValue(sql"""SELECT design_review.list_history(
    'render.fetch-bench', 1, 0)::text""")
  if raw.len == 0:
    raise newException(IOError,
      "seed_28_capture_run fixture missing — re-seed via " &
      "bench/fixtures/seed_28_capture_run.sql.")
  let node = parseJson(raw)
  result = node["run_id"].getStr
  if result.len == 0:
    raise newException(IOError,
      "list_history returned no run_id for seeded brief")

proc layoutFixture(db: DbConn):
    tuple[layoutId: string; payload: string; version: int] =
  ## Look up the layout seeded by ``seed_layout_10k.sql`` via the
  ## ``list_layouts`` routine (the app role is denied direct
  ## ``gallery_layouts`` SELECTs).  The returned JSONB carries the
  ## payload and the current version which the bench loop needs for
  ## optimistic-concurrency updates.
  let rows = db.getAllRows(sql"""SELECT design_review.list_layouts(
    'render.bench-fixture', 'bench-user')::text""")
  for row in rows:
    if row.len == 0 or row[0].len == 0:
      continue
    let node = parseJson(row[0])
    if node["name"].getStr == "bench-layout" and
       node["scope"].getStr == "user" and
       node["owner_user_id"].getStr == "bench-user":
      result = (
        layoutId: node["layout_id"].getStr,
        payload: $node["layout"],
        version: node["version"].getInt,
      )
      return
  raise newException(IOError,
    "seed_layout_10k fixture missing — re-seed via " &
    "bench/fixtures/seed_layout_10k.sql.")

proc startCapturingRun(db: DbConn): string =
  ## Open a fresh run in ``capturing`` status so ``record_capture`` can
  ## insert into it for the duration of the benchmark.  Created via the
  ## SECURITY DEFINER routine, so it's the same code path production
  ## uses.
  db.getValue(sql"""SELECT design_review.start_run(
    'render.bench-capture', 'bench-capture-manifest', 'bench-fixture')""")

proc benchListHistory(db: DbConn; iterations: int): seq[float] =
  let briefId = fetchListHistoryBriefId(db)
  let stmt = db.prepare("bench_list_history",
    sql"SELECT design_review.list_history($1, 10, 0)", 1)
  # Warm
  discard db.getAllRows(stmt, briefId)
  result = newSeqOfCap[float](iterations)
  for _ in 0..<iterations:
    let t0 = getMonoTime()
    discard db.getAllRows(stmt, briefId)
    let dt = (getMonoTime() - t0).inMicroseconds.float / 1000.0
    result.add dt

proc benchFetchRun(db: DbConn; iterations: int): seq[float] =
  let runId = fetchRunUuid(db)
  let stmt = db.prepare("bench_fetch_run",
    sql"SELECT design_review.fetch_run($1::uuid)::text", 1)
  discard db.getValue(stmt, runId)
  result = newSeqOfCap[float](iterations)
  for _ in 0..<iterations:
    let t0 = getMonoTime()
    discard db.getValue(stmt, runId)
    let dt = (getMonoTime() - t0).inMicroseconds.float / 1000.0
    result.add dt

proc benchSaveGalleryLayout(db: DbConn; iterations: int): seq[float] =
  ## Hot path is the UPDATE branch.  Each save bumps ``version`` so the
  ## next call must read the new version first; we keep a local copy and
  ## advance it.  The bench measures the routine call, not the version
  ## refresh — but version refresh is one ``SELECT`` to the same row,
  ## negligible compared to a JSONB UPDATE + audit insert.
  let fixture = layoutFixture(db)
  let layoutId = fixture.layoutId
  let payload = fixture.payload
  var version = fixture.version
  let saveSql = "SELECT design_review.save_gallery_layout(" &
    "$1::uuid, 'render.bench-fixture', 'user', 'bench-user', " &
    "'bench-layout', $2::jsonb, $3::int)::text"
  let stmt = db.prepare("bench_save_gallery_layout", sql(saveSql), 3)
  # Warm
  let warm = db.getValue(stmt, layoutId, payload, $version)
  version = parseJson(warm)["version"].getInt
  result = newSeqOfCap[float](iterations)
  for _ in 0..<iterations:
    let t0 = getMonoTime()
    let raw = db.getValue(stmt, layoutId, payload, $version)
    let dt = (getMonoTime() - t0).inMicroseconds.float / 1000.0
    result.add dt
    version = parseJson(raw)["version"].getInt

proc benchRecordCapture(db: DbConn; iterations: int): seq[float] =
  ## ``record_capture`` requires the parent run to be in status
  ## ``capturing``.  We open one such run, then insert ``iterations + 1``
  ## fresh captures (preview_id varies per iteration so we hit the
  ## INSERT path on every call instead of the ON CONFLICT short-circuit).
  let runId = startCapturingRun(db)
  let recSql = "SELECT design_review.record_capture(" &
    "$1::uuid, $2, 'web', 'wide', " &
    "'sha-bench', '/bench/png', 1280, 720)"
  let stmt = db.prepare("bench_record_capture", sql(recSql), 2)
  # Warm with a sentinel preview id.
  discard db.getValue(stmt, runId, "bench/warm")
  result = newSeqOfCap[float](iterations)
  for i in 0..<iterations:
    let pid = "bench/preview-" & $i
    let t0 = getMonoTime()
    discard db.getValue(stmt, runId, pid)
    let dt = (getMonoTime() - t0).inMicroseconds.float / 1000.0
    result.add dt

proc runRoutine(db: DbConn; r: RoutineName; iterations: int;
                thresholds: Table[string, Threshold]): RoutineResult =
  let samples =
    case r
    of rnListHistory:      benchListHistory(db, iterations)
    of rnFetchRun:         benchFetchRun(db, iterations)
    of rnSaveGalleryLayout: benchSaveGalleryLayout(db, iterations)
    of rnRecordCapture:    benchRecordCapture(db, iterations)
  let stats = summarise(samples)
  let t = thresholds.getOrDefault($r, Threshold(p50MsMax: 0, p95MsMax: 0))
  let p50Pass = (t.p50MsMax <= 0) or (stats.p50 <= t.p50MsMax)
  let p95Pass = (t.p95MsMax <= 0) or (stats.p95 <= t.p95MsMax)
  result = RoutineResult(
    name: $r,
    iterations: iterations,
    p50Ms: stats.p50,
    p95Ms: stats.p95,
    meanMs: stats.mean,
    minMs: stats.mn,
    maxMs: stats.mx,
    p50MsMax: t.p50MsMax,
    p95MsMax: t.p95MsMax,
    p50Pass: p50Pass,
    p95Pass: p95Pass,
    extra: "iterations=" & $iterations,
  )

# -----------------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------------

proc resultsToJson(results: seq[RoutineResult]; iterations: int;
                   thresholdsPath: string): JsonNode =
  result = newJObject()
  result["iterations"] = newJInt(iterations)
  result["thresholds_path"] = newJString(thresholdsPath)
  result["timestamp"] = newJString($now())
  result["host"] = newJString(getEnv("HOSTNAME", hostOS))
  result["pg_port"] = newJString(envOr("ISONIM_REVIEW_PGPORT", "5533"))
  var arr = newJArray()
  for r in results:
    var obj = newJObject()
    obj["name"]        = newJString(r.name)
    obj["iterations"]  = newJInt(r.iterations)
    obj["p50_ms"]      = newJFloat(r.p50Ms)
    obj["p95_ms"]      = newJFloat(r.p95Ms)
    obj["mean_ms"]     = newJFloat(r.meanMs)
    obj["min_ms"]      = newJFloat(r.minMs)
    obj["max_ms"]      = newJFloat(r.maxMs)
    obj["p50_ms_max"]  = newJFloat(r.p50MsMax)
    obj["p95_ms_max"]  = newJFloat(r.p95MsMax)
    obj["p50_pass"]    = newJBool(r.p50Pass)
    obj["p95_pass"]    = newJBool(r.p95Pass)
    obj["verdict"]     = newJString(
      if r.p50Pass and r.p95Pass: "pass" else: "threshold_violation")
    arr.add obj
  result["routines"] = arr

proc resultsToGithubActionBenchmark(results: seq[RoutineResult]): JsonNode =
  ## github-action-benchmark "customSmallerIsBetter" payload — one entry
  ## per (routine, percentile) pair.  Names start with
  ## ``isonim-design-review/...`` so the gh-pages chart groups them.
  result = newJArray()
  for r in results:
    var p50 = newJObject()
    p50["name"]  = newJString("isonim-design-review/" & r.name & "/p50_ms")
    p50["unit"]  = newJString("ms")
    p50["value"] = newJFloat(r.p50Ms)
    p50["extra"] = newJString(
      "p50_max=" & $r.p50MsMax & " " & r.extra & " verdict=" &
      (if r.p50Pass: "pass" else: "violation"))
    result.add p50
    var p95 = newJObject()
    p95["name"]  = newJString("isonim-design-review/" & r.name & "/p95_ms")
    p95["unit"]  = newJString("ms")
    p95["value"] = newJFloat(r.p95Ms)
    p95["extra"] = newJString(
      "p95_max=" & $r.p95MsMax & " " & r.extra & " verdict=" &
      (if r.p95Pass: "pass" else: "violation"))
    result.add p95

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

proc usage(): string =
  result = """isonim design-review benchmark — REV-M9

Usage:
  design_review_bench [--iterations:N] [--routine:NAME ...]
                      [--fixture-runs:N] [--thresholds:PATH]
                      [--no-fixtures] [--no-write] [--verbose]

Routines:
  list_history, fetch_run, save_gallery_layout, record_capture

Defaults: iterations=1000, fixture-runs=10000, all four routines."""

proc parseArgs(): BenchConfig =
  result = BenchConfig(
    iterations: 1000,
    routines: @[],
    fixtureRuns: 10000,
    thresholdsPath: DefaultThresholds,
    noFixtures: false,
    noWrite: false,
    verbose: false,
  )
  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "iterations":
        result.iterations = parseInt(p.val)
      of "routine":
        case p.val
        of $rnListHistory:      result.routines.add rnListHistory
        of $rnFetchRun:         result.routines.add rnFetchRun
        of $rnSaveGalleryLayout: result.routines.add rnSaveGalleryLayout
        of $rnRecordCapture:    result.routines.add rnRecordCapture
        else:
          quit("Unknown routine: " & p.val & "\n\n" & usage(), 2)
      of "fixture-runs":
        result.fixtureRuns = parseInt(p.val)
      of "thresholds":
        result.thresholdsPath = p.val
      of "no-fixtures":
        result.noFixtures = true
      of "no-write":
        result.noWrite = true
      of "verbose", "v":
        result.verbose = true
      of "help", "h":
        echo usage(); quit(0)
      else:
        quit("Unknown option: --" & p.key & "\n\n" & usage(), 2)
    of cmdArgument:
      quit("Unexpected positional arg: " & p.key & "\n\n" & usage(), 2)
  if result.routines.len == 0:
    result.routines = @[rnListHistory, rnFetchRun,
                        rnSaveGalleryLayout, rnRecordCapture]

proc main() =
  let cfg = parseArgs()
  let thresholds = readThresholds(cfg.thresholdsPath)

  if not cfg.noFixtures:
    # Seed the three idempotent fixtures.  When ``fixture-runs`` is
    # lower than the spec's 10 000, we still apply the canonical
    # seeder — the seeder reads the *target* count from itself, so we
    # need a lightweight override path.  The threshold tests use
    # ``--fixture-runs:1000`` and the seeder honours that via env var.
    putEnv("ISONIM_REVIEW_BENCH_RUN_TARGET", $cfg.fixtureRuns)
    if rnListHistory in cfg.routines:
      psqlSeed(FixturesDir / "seed_10k_runs.sql", cfg.verbose)
    if rnFetchRun in cfg.routines:
      psqlSeed(FixturesDir / "seed_28_capture_run.sql", cfg.verbose)
    if rnSaveGalleryLayout in cfg.routines:
      psqlSeed(FixturesDir / "seed_layout_10k.sql", cfg.verbose)

  let db = connect()
  defer: db.close()
  # The SECURITY DEFINER routines already set their own search_path; we
  # qualify every routine call as ``design_review.<name>`` so no session
  # search_path tweak is required here.

  var results: seq[RoutineResult] = @[]
  for r in cfg.routines:
    if cfg.verbose:
      stderr.writeLine("[bench] running " & $r &
                       " for " & $cfg.iterations & " iterations")
    let rr = runRoutine(db, r, cfg.iterations, thresholds)
    results.add rr
    let verdict =
      if rr.p50Pass and rr.p95Pass: "PASS"
      else: "FAIL"
    stderr.writeLine(fmt"[bench] {$r:>22} p50={rr.p50Ms:7.3f}ms " &
      fmt"p95={rr.p95Ms:7.3f}ms (max p50={rr.p50MsMax}ms p95={rr.p95MsMax}ms) {verdict}")
    if not rr.p50Pass:
      stderr.writeLine("threshold_violation: " & $r &
        " p50=" & $int(round(rr.p50Ms)) & "ms" &
        " (max=" & $int(round(rr.p50MsMax)) & "ms)")
    if not rr.p95Pass:
      stderr.writeLine("threshold_violation: " & $r &
        " p95=" & $int(round(rr.p95Ms)) & "ms" &
        " (max=" & $int(round(rr.p95MsMax)) & "ms)")

  if not cfg.noWrite:
    let outDir = RepoRoot / "bench-results"
    createDir(outDir)
    let stamp = now().format("yyyy-MM-dd'T'HH-mm-ss")
    let perRunPath = outDir / (stamp & ".json")
    let perRunJson = resultsToJson(results, cfg.iterations, cfg.thresholdsPath)
    writeFile(perRunPath, perRunJson.pretty & "\n")
    let gabPath = outDir / "benchmark_results.json"
    writeFile(gabPath, resultsToGithubActionBenchmark(results).pretty & "\n")
    stderr.writeLine("[bench] wrote " & perRunPath)
    stderr.writeLine("[bench] wrote " & gabPath)

  # Exit code: 0 iff every percentile across every routine passed.
  var ok = true
  for r in results:
    if not r.p50Pass or not r.p95Pass:
      ok = false
  if not ok:
    quit(1)

when isMainModule:
  main()
