## REV-M4 — ``isonim-review serve`` smoke test.
##
## Boots the daemon binary via ``osproc.startProcess`` (no in-process
## shim — the milestone forbids it), hits ``/health`` with ``curl``,
## SIGTERMs the daemon, and asserts both the response shape and a
## sub-2-second shutdown.
##
## Covers ``test_cli_serve_health_endpoint`` from the milestone's
## Verification block.

import std/[json, os, osproc, posix, strtabs, strutils, times, unittest]

import helpers/design_review_pg_fixture
import tools/isonim_review/cmd_init
import tools/isonim_review/config

const RepoRoot = currentSourcePath().parentDir().parentDir()
const MigDir = RepoRoot / "db" / "migrations"
const CliPath = RepoRoot / "build" / "bin" / "isonim-review"

proc pickFreeTcpPort(): int =
  ## Best-effort: pick a port in 18100..18199 nothing's listening on
  ## right now.  We rely on ``curl http://127.0.0.1:N/`` returning
  ## ``Connection refused`` (exit 7) as the "free" signal.
  let curl = findExe("curl")
  if curl.len == 0:
    raise newException(IOError,
      "test_cli_serve_health_endpoint: ``curl`` not on PATH")
  let now = epochTime()
  let seed = int(now * 1000) mod 100
  for offset in 0..99:
    let candidate = 18100 + ((seed + offset) mod 100)
    let probe = execCmdEx(curl & " -s -o /dev/null --max-time 0.5 " &
        "http://127.0.0.1:" & $candidate & "/")
    if probe.exitCode != 0:
      return candidate
  raise newException(IOError,
    "test_cli_serve_health_endpoint: no free port in 18100..18199")

proc runInit(cfg: ReviewConfig) =
  let nullOut = open("/dev/null", fmWrite)
  defer: nullOut.close()
  check cmdInit(cfg, MigDir, nullOut) == 0

suite "REV-M4 isonim-review serve smoke":

  test "test_cli_serve_health_endpoint":
    check fileExists(CliPath)
    let f = newPgFixture(applyMigrations = false)
    defer: f.shutdown()
    var cfg = defaults()
    cfg.db.host = "127.0.0.1"
    cfg.db.port = f.port
    cfg.db.database = "isonim_design_review"
    runInit(cfg)

    let httpPort = pickFreeTcpPort()

    var environ = newStringTable(modeCaseSensitive)
    for kv in envPairs():
      environ[kv.key] = kv.value
    environ["ISONIM_REVIEW_PGHOST"] = "127.0.0.1"
    environ["ISONIM_REVIEW_PGPORT"] = $f.port
    environ["ISONIM_REVIEW_PORT"] = $httpPort

    let p = startProcess(CliPath,
      args = @["serve", "--migrations", MigDir],
      env = environ,
      options = {poUsePath, poStdErrToStdOut})

    # Wait for the daemon to actually bind.  ``curl --max-time`` keeps
    # the test snappy; the daemon's startup is dominated by libpq's
    # connect time, well under one second.
    let curl = findExe("curl")
    var ok = false
    var body = ""
    let bootDeadline = epochTime() + 8.0
    while epochTime() < bootDeadline:
      let r = execCmdEx(curl & " -s --max-time 1 -w '|%{http_code}' " &
          "http://127.0.0.1:" & $httpPort & "/health")
      if r.exitCode == 0 and r.output.contains("|200"):
        let pipeIdx = r.output.rfind('|')
        body = r.output[0 ..< pipeIdx]
        ok = true
        break
      sleep(150)

    check ok
    if ok:
      # Response is the same JSON shape db-health --json produces.
      let j = parseJson(body)
      check j.hasKey("postgres_reachable")
      check j.hasKey("app_role_reachable")
      check j.hasKey("migrator_role_reachable")
      check j.hasKey("schema_version_current")
      check j["postgres_reachable"].getBool
      check j["app_role_reachable"].getBool
      check j["migrator_role_reachable"].getBool

      # Graceful shutdown: SIGTERM, then assert exit within 2 s.
      let shutdownStart = epochTime()
      discard kill(p.processID.Pid, SIGTERM)
      var exited = false
      let shutdownDeadline = epochTime() + 2.0
      while epochTime() < shutdownDeadline:
        if not p.running():
          exited = true
          break
        sleep(50)
      let exitCode =
        if exited: p.waitForExit()
        else:
          discard kill(p.processID.Pid, SIGKILL)
          p.waitForExit()
      let elapsed = epochTime() - shutdownStart
      p.close()
      check exited
      check elapsed < 2.0
      # Clean exit code (Nim's quit(0) on the receive-SIGTERM path
      # returns 0; if the OS-level signal was delivered before our
      # handler installed, the binary may exit via SIGTERM (143).
      # Both are acceptable "clean enough" for the smoke test.)
      check exitCode == 0 or exitCode == 143
    else:
      discard kill(p.processID.Pid, SIGKILL)
      p.close()
