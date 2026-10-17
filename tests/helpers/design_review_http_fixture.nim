## REV-M7 — HTTP client helper for design-review API tests.
##
## Each REV-M7 API test boots the real ``isonim-review serve`` daemon
## against a fresh ``PgFixture`` and hits the four new endpoints with
## ``std/httpclient`` (the spec mandates the real transport — no in-
## process shims).  This module centralises the boot, free-port pick,
## env-var prep, and ``curl``-based readiness wait so the test files
## just call ``startServeAndSeed`` once and shoot HTTP at the URL it
## returns.

import std/[json, os, osproc, posix, strtabs, strutils, times, monotimes, tempfiles]
import std/httpclient

import ./design_review_pg_fixture
import ./daemon_ready_handshake
import ./owned_cli_pg_fixture
import ./owned_cli_test_capture
import tools/isonim_review/cmd_init
import tools/isonim_review/config

export design_review_pg_fixture

const RepoRoot* = currentSourcePath().parentDir().parentDir().parentDir()
const CliPath* = RepoRoot / "build" / "bin" / "isonim-review"
const MigDir* = RepoRoot / "db" / "migrations"

type
  ServeFixture* = ref object
    pg*: PgFixture
    proc1*: OwnedChild
    stdoutLog*: string
    drainer*: DaemonStderrDrainer
    port*: int
    storePath*: string
    baseUrl*: string

proc pickFreeTcpPort*(): int {.deprecated:
    "prefer ISONIM_REVIEW_PORT=0 + waitForReady — see " &
    "tests/helpers/daemon_ready_handshake.nim".} =
  ## Kept for API compatibility; the fixture itself no longer uses
  ## this — it lets the daemon pick the port via ``Port(0)`` and
  ## reads the actual port back from the daemon's READY handshake.
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

proc finishHttpDaemon(child: OwnedChild; drainer: DaemonStderrDrainer) =
  # Preserve the initiating failure while independently draining, joining, and
  # closing. A duplicated stderr reader must join before Process pipe close.
  let original = getCurrentException()
  var failure: ref Exception
  var reaped = false
  try:
    discard drainDirectChild(child)
    reaped = true
  except Exception: failure = getCurrentException()
  if reaped:
    try: drainer.shutdown()
    except Exception:
      if failure == nil: failure = getCurrentException()
    try: child.close()
    except Exception:
      if failure == nil: failure = getCurrentException()
  if failure != nil:
    if original == nil: raise failure
    try: stderr.writeLine("Secondary HTTP daemon cleanup: " & failure.msg)
    except Exception: discard

proc startServeAndSeed*(): ServeFixture =
  ## Boot a fresh Postgres + apply migrations + start the daemon.
  ## Returns the fixture; caller is responsible for ``shutdown``.
  if not fileExists(CliPath):
    raise newException(IOError,
      "design_review_http_fixture: build/bin/isonim-review not built — " &
      "run ``just isonim-review-build`` first")
  var pg: PgFixture
  var p: OwnedChild
  var drainer: DaemonStderrDrainer
  try:
    pg = newPgFixture(applyMigrations = false)
    var cfg = defaults()
    cfg.db.host = "127.0.0.1"
    cfg.db.port = pg.port
    cfg.db.database = "isonim_design_review"
    cfg.db.url = "postgresql://127.0.0.1:" & $pg.port & "/isonim_design_review?hostaddr=127.0.0.1"
    runInit(cfg)

    let storeDir = getTempDir() / "isonim_review_store_" &
                    $((int(epochTime() * 1000)) mod 1_000_000)
    createDir(storeDir)

    # ISONIM_REVIEW_PORT=0 → daemon picks any free port via Port(0)
    # and reports the OS-assigned port back via the ``READY <port>``
    # stderr line (see daemon_ready_handshake.nim).  Replaces the
    # previous TOCTOU port-probe + curl-poll pattern.
    let environ = fixtureCliEnvironment(pg.port)
    environ["ISONIM_REVIEW_PORT"] = "0"

    # Write a config file the daemon reads so cfg.store.path is set to
    # our ephemeral store dir (env doesn't override it; only the TOML
    # file does).
    let cfgPath = getTempDir() / "isonim_review_cfg_" &
                  $((int(epochTime() * 1000)) mod 1_000_000) & ".toml"
    writeFile(cfgPath, "[store]\npath = \"" & storeDir & "\"\n")

    # ``poUsePath`` only — stderr stays its own pipe for the READY
    # drainer.
    let log = createTempFile("isonim-http-stdout-", ".log")
    log.cfile.close()
    let logIdentity = getFileInfo(log.path).id
    let bash = findExe("bash", followSymlinks = false)
    if bash.len == 0: raise newException(IOError, "Declared Bash role missing")
    p = startOwnedChild(bash,
      args = @["-p", "-c", "stdout=$1; shift; exec \"$@\" > \"$stdout\"",
        "isonim-owned-http-stdout", log.path, CliPath,
        "serve", "--migrations", MigDir, "--config", cfgPath],
      env = environ, options = {poUsePath})

    var httpPort: int
    drainer = startStderrDrainer(p.borrowedProcessForDrainer())
    if symlinkExists(log.path) or getFileInfo(log.path).kind != pcFile or
        getFileInfo(log.path).id != logIdentity:
      raise newException(IOError, "Owned daemon stdout log identity changed")
    httpPort = waitForReady(drainer, timeoutSecs = 15.0)

    result = ServeFixture(
      pg: pg, proc1: p, drainer: drainer, stdoutLog: log.path, port: httpPort,
      storePath: storeDir,
      baseUrl: "http://127.0.0.1:" & $httpPort,
    )
  except Exception:
    let original = getCurrentException()
    if p != nil:
      try: finishHttpDaemon(p, drainer)
      except Exception: discard # Initiating object retains precedence.
    elif drainer != nil:
      try: drainer.shutdown()
      except Exception: discard
    if pg != nil:
      try: pg.shutdown()
      except Exception as secondary:
        try: stderr.writeLine("Secondary Postgres cleanup: " & secondary.msg)
        except Exception: discard
    raise original

proc shutdown*(f: ServeFixture) =
  if f == nil: return
  let original = getCurrentException()
  var failure: ref Exception
  if f.proc1 != nil:
    try:
      f.proc1.signalOwnedChild(SIGTERM)
      let deadline = getMonoTime() + initDuration(seconds = 2)
      while getMonoTime() < deadline:
        if not f.proc1.running(): break
        sleep(50)
      if f.proc1.running(): f.proc1.signalOwnedChild(SIGKILL)
    except Exception: failure = getCurrentException()
    try: finishHttpDaemon(f.proc1, f.drainer)
    except Exception:
      if failure == nil: failure = getCurrentException()
    f.proc1 = nil
    f.drainer = nil
  elif f.drainer != nil:
    try: f.drainer.shutdown()
    except Exception: failure = getCurrentException()
    f.drainer = nil
  if f.pg != nil:
    try: f.pg.shutdown()
    except Exception:
      if failure == nil: failure = getCurrentException()
    f.pg = nil
  if f.storePath.len > 0:
    try: removeDir(f.storePath)
    except OSError: discard
  if failure != nil:
    if original == nil: raise failure
    try: stderr.writeLine("Secondary HTTP fixture cleanup: " & failure.msg)
    except Exception: discard

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
