## REV-M7 — HTTP client helper for design-review API tests.
##
## Each REV-M7 API test boots the real ``isonim-review serve`` daemon
## against a fresh ``PgFixture`` and hits the four new endpoints with
## ``std/httpclient`` (the spec mandates the real transport — no in-
## process shims).  This module centralises the boot, free-port pick,
## env-var prep, and ``curl``-based readiness wait so the test files
## just call ``startServeAndSeed`` once and shoot HTTP at the URL it
## returns.

import std/[json, os, osproc, posix, strtabs, strutils, times]
import std/httpclient

import ./design_review_pg_fixture
import tools/isonim_review/cmd_init
import tools/isonim_review/config

export design_review_pg_fixture

const RepoRoot* = currentSourcePath().parentDir().parentDir().parentDir()
const CliPath* = RepoRoot / "build" / "bin" / "isonim-review"
const MigDir* = RepoRoot / "db" / "migrations"

type
  ServeFixture* = ref object
    pg*: PgFixture
    proc1*: Process
    port*: int
    storePath*: string
    baseUrl*: string

proc pickFreeTcpPort*(): int =
  let curl = findExe("curl")
  if curl.len == 0:
    raise newException(IOError, "design_review_http_fixture: curl not on PATH")
  let now = epochTime()
  let seed = int(now * 1000) mod 100
  for offset in 0..99:
    let candidate = 18200 + ((seed + offset) mod 100)
    let probe = execCmdEx(curl & " -s -o /dev/null --max-time 0.5 " &
        "http://127.0.0.1:" & $candidate & "/")
    if probe.exitCode != 0:
      return candidate
  raise newException(IOError,
    "design_review_http_fixture: no free port in 18200..18299")

proc runInit(cfg: ReviewConfig) =
  let nullOut = open("/dev/null", fmWrite)
  defer: nullOut.close()
  if cmdInit(cfg, MigDir, nullOut) != 0:
    raise newException(IOError,
      "design_review_http_fixture: cmdInit failed")

proc startServeAndSeed*(): ServeFixture =
  ## Boot a fresh Postgres + apply migrations + start the daemon.
  ## Returns the fixture; caller is responsible for ``shutdown``.
  if not fileExists(CliPath):
    raise newException(IOError,
      "design_review_http_fixture: build/bin/isonim-review not built — " &
      "run ``just isonim-review-build`` first")
  let pg = newPgFixture(applyMigrations = false)
  var cfg = defaults()
  cfg.db.host = "127.0.0.1"
  cfg.db.port = pg.port
  cfg.db.database = "isonim_design_review"
  runInit(cfg)

  let storeDir = getTempDir() / "isonim_review_store_" &
                  $((int(epochTime() * 1000)) mod 1_000_000)
  createDir(storeDir)

  let httpPort = pickFreeTcpPort()
  var environ = newStringTable(modeCaseSensitive)
  for kv in envPairs():
    environ[kv.key] = kv.value
  environ["ISONIM_REVIEW_PGHOST"] = "127.0.0.1"
  environ["ISONIM_REVIEW_PGPORT"] = $pg.port
  environ["ISONIM_REVIEW_PORT"] = $httpPort

  # Write a config file the daemon reads so cfg.store.path is set to
  # our ephemeral store dir (env doesn't override it; only the TOML
  # file does).
  let cfgPath = getTempDir() / "isonim_review_cfg_" &
                $((int(epochTime() * 1000)) mod 1_000_000) & ".toml"
  writeFile(cfgPath, "[store]\npath = \"" & storeDir & "\"\n")

  let p = startProcess(CliPath,
    args = @["serve", "--migrations", MigDir, "--config", cfgPath],
    env = environ,
    options = {poUsePath, poStdErrToStdOut})

  # Wait for the daemon to bind.
  let curl = findExe("curl")
  var ok = false
  let deadline = epochTime() + 10.0
  while epochTime() < deadline:
    let r = execCmdEx(curl & " -s --max-time 1 -w '|%{http_code}' " &
        "http://127.0.0.1:" & $httpPort & "/health")
    if r.exitCode == 0 and r.output.contains("|200"):
      ok = true
      break
    sleep(150)
  if not ok:
    discard kill(p.processID.Pid, SIGKILL)
    p.close()
    raise newException(IOError,
      "design_review_http_fixture: daemon failed to boot on port " &
        $httpPort)

  ServeFixture(
    pg: pg, proc1: p, port: httpPort,
    storePath: storeDir,
    baseUrl: "http://127.0.0.1:" & $httpPort,
  )

proc shutdown*(f: ServeFixture) =
  if f == nil: return
  if f.proc1 != nil:
    try: discard kill(f.proc1.processID.Pid, SIGTERM)
    except: discard
    let deadline = epochTime() + 2.0
    while epochTime() < deadline:
      if not f.proc1.running(): break
      sleep(50)
    if f.proc1.running():
      try: discard kill(f.proc1.processID.Pid, SIGKILL)
      except: discard
    discard f.proc1.waitForExit()
    f.proc1.close()
    f.proc1 = nil
  if f.pg != nil:
    f.pg.shutdown()
    f.pg = nil
  if f.storePath.len > 0:
    try: removeDir(f.storePath)
    except OSError: discard

# --- HTTP helpers ----------------------------------------------------------

proc httpGet*(f: ServeFixture; path: string):
    tuple[code: int; body: string; contentType: string; cacheControl: string] =
  ## Minimal GET wrapper — returns the raw status, body, and the two
  ## response headers the REV-M7 tests care about.  Uses ``std/httpclient``
  ## with no follow-redirect (we don't issue any).
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  let resp = client.request(f.baseUrl & path, httpMethod = HttpGet)
  let body = resp.body
  let ct = if resp.headers.hasKey("Content-Type"):
             $resp.headers["Content-Type"]
           else: ""
  let cc = if resp.headers.hasKey("Cache-Control"):
             $resp.headers["Cache-Control"]
           else: ""
  (code: parseInt(resp.status.split(' ')[0]),
   body: body,
   contentType: ct,
   cacheControl: cc)

proc httpPost*(f: ServeFixture; path, body: string):
    tuple[code: int; body: string; contentType: string] =
  ## Minimal POST wrapper — REV-M8 layout endpoints take JSON bodies.
  let client = newHttpClient(timeout = 5000)
  defer: client.close()
  let headers = newHttpHeaders([("Content-Type", "application/json")])
  let resp = client.request(f.baseUrl & path, httpMethod = HttpPost,
                            body = body, headers = headers)
  let respBody = resp.body
  let ct = if resp.headers.hasKey("Content-Type"):
             $resp.headers["Content-Type"]
           else: ""
  (code: parseInt(resp.status.split(' ')[0]),
   body: respBody,
   contentType: ct)

# --- DB seed helpers -------------------------------------------------------

proc seedRunInDb*(connStr, briefId: string; manifestHash = "h"): string =
  ## Insert one ``runs`` row via ``start_run`` (SECURITY DEFINER) and
  ## return its UUID.  Uses ``psql`` so we don't have to deal with the
  ## test's own DbConn lifetime.
  let psqlCmd = "psql " & connStr & " -v ON_ERROR_STOP=1 -A -t -c " &
                "\"SELECT design_review.start_run('" & briefId &
                "', '" & manifestHash & "', 'tester')\""
  let res = execCmdEx(psqlCmd)
  if res.exitCode != 0:
    raise newException(IOError,
      "seedRunInDb failed: " & res.output)
  result = res.output.strip()

proc seedCaptureInDb*(connStr, runId, previewId, backend, viewport,
                     pngSha, pngPath: string;
                     width = 100; height = 100): string =
  let psqlCmd = "psql " & connStr & " -v ON_ERROR_STOP=1 -A -t -c " &
                "\"SELECT design_review.record_capture('" & runId &
                "'::uuid, '" & previewId & "', '" & backend & "', '" &
                viewport & "', '" & pngSha & "', '" & pngPath & "', " &
                $width & ", " & $height & ")\""
  let res = execCmdEx(psqlCmd)
  if res.exitCode != 0:
    raise newException(IOError,
      "seedCaptureInDb failed: " & res.output)
  result = res.output.strip()

proc seedAgentReportInDb*(connStr, runId, agentName, agentVersion,
                          rawPath, parsedScoresJson: string): string =
  let escaped = parsedScoresJson.replace("'", "''")
  let psqlCmd = "psql " & connStr & " -v ON_ERROR_STOP=1 -A -t -c " &
                "\"SELECT design_review.record_agent_report('" & runId &
                "'::uuid, '" & agentName & "', '" & agentVersion & "', '" &
                rawPath & "', '" & escaped & "'::jsonb)\""
  let res = execCmdEx(psqlCmd)
  if res.exitCode != 0:
    raise newException(IOError,
      "seedAgentReportInDb failed: " & res.output)
  result = res.output.strip()

proc finishCapturesInDb*(connStr, runId: string) =
  let psqlCmd = "psql " & connStr & " -v ON_ERROR_STOP=1 -A -t -c " &
                "\"SELECT design_review.finish_captures('" & runId &
                "'::uuid)\""
  let res = execCmdEx(psqlCmd)
  if res.exitCode != 0:
    raise newException(IOError,
      "finishCapturesInDb failed: " & res.output)
