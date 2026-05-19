## REV-M4 — end-to-end: ``isonim-review serve`` lifecycle against a
## real ``process-compose``-managed cluster.
##
## Boots the cluster via process-compose with an ephemeral PGDATA +
## port (same approach as ``e2e_design_review_cli_init.nim``), starts
## the daemon, curl's ``/health`` for a 200, SIGTERMs the daemon, and
## asserts it exits within 5 s with no orphan postgres children.

import std/[json, os, osproc, posix, strtabs, strutils, times, unittest]
import db_connector/db_postgres

const RepoRoot = currentSourcePath().parentDir().parentDir()
const ComposeFile = RepoRoot / "process-compose.yaml"
const MigDir = RepoRoot / "db" / "migrations"
const CliPath = RepoRoot / "build" / "bin" / "isonim-review"

proc pickFreePort(): int =
  let now = epochTime()
  let seed = int(now * 1000) mod 100
  for offset in 0..99:
    let candidate = 5500 + ((seed + offset) mod 100)
    let probe = execCmdEx("pg_isready -h 127.0.0.1 -p " & $candidate &
        " -t 1 -q")
    if probe.exitCode != 0:
      return candidate
  return 5599

proc pickFreeTcpPort(low, high: int): int =
  let curl = findExe("curl")
  let span = high - low + 1
  let now = epochTime()
  let seed = int(now * 1000) mod span
  for offset in 0..<span:
    let candidate = low + ((seed + offset) mod span)
    let r = execCmdEx(curl & " -s -o /dev/null --max-time 0.3 " &
        "http://127.0.0.1:" & $candidate & "/")
    if r.exitCode != 0:
      return candidate
  return high

proc waitForReady(port: int; timeoutSeconds = 60): bool =
  let deadline = epochTime() + timeoutSeconds.float
  while epochTime() < deadline:
    let r = execCmdEx("pg_isready -h 127.0.0.1 -p " & $port & " -q")
    if r.exitCode == 0: return true
    sleep(400)
  false

proc waitForMigrated(port: int; timeoutSeconds = 60): bool =
  let deadline = epochTime() + timeoutSeconds.float
  while epochTime() < deadline:
    var conn: DbConn
    var ok = false
    try:
      conn = open("", "", "",
        "host=127.0.0.1 port=" & $port &
          " dbname=isonim_design_review user=design_review_migrator " &
          "connect_timeout=2")
      let v = conn.getValue(sql"""
        SELECT count(*) FROM public.schema_migrations""")
      if parseInt(v) >= 2:
        ok = true
      conn.close()
    except DbError:
      ok = false
    if ok: return true
    sleep(400)
  false

proc runLifecycle() =
  let pgPort = pickFreePort()
  let httpPort = pickFreeTcpPort(18200, 18299)
  let tmpRoot = getTempDir() / "isonim_review_e2e_serve"
  createDir(tmpRoot)
  let dataDir = tmpRoot / ("pg-" & $pgPort & "-" &
      $((int(epochTime() * 1000)) mod 1000000))
  createDir(dataDir)
  let pcPort = $(pgPort + 300)
  let sock = (tmpRoot / "pc.sock").quoteShell

  putEnv("ISONIM_REVIEW_PGDATA", dataDir)
  putEnv("ISONIM_REVIEW_PGPORT", $pgPort)
  putEnv("ISONIM_REVIEW_MIGRATIONS_DIR", MigDir)

  let upCmd = "process-compose up --detached --config " &
      ComposeFile.quoteShell &
      " --port " & pcPort &
      " --unix-socket " & sock &
      " >/dev/null 2>&1"
  discard execShellCmd(upCmd)
  check waitForReady(pgPort, 60)
  check waitForMigrated(pgPort, 60)

  # Spawn the daemon.
  var environ = newStringTable(modeCaseSensitive)
  for kv in envPairs():
    environ[kv.key] = kv.value
  environ["ISONIM_REVIEW_PGHOST"] = "127.0.0.1"
  environ["ISONIM_REVIEW_PGPORT"] = $pgPort
  environ["ISONIM_REVIEW_PORT"] = $httpPort
  let daemon = startProcess(CliPath,
    args = @["serve", "--migrations", MigDir],
    env = environ,
    options = {poStdErrToStdOut, poUsePath})

  # Wait for /health to answer 200.
  let curl = findExe("curl")
  var healthOk = false
  var healthBody = ""
  let bootDeadline = epochTime() + 10.0
  while epochTime() < bootDeadline:
    let r = execCmdEx(curl & " -s --max-time 1 -w '|%{http_code}' " &
        "http://127.0.0.1:" & $httpPort & "/health")
    if r.exitCode == 0 and r.output.contains("|200"):
      let idx = r.output.rfind('|')
      healthBody = r.output[0 ..< idx]
      healthOk = true
      break
    sleep(150)
  check healthOk

  if healthOk:
    let j = parseJson(healthBody)
    check j["postgres_reachable"].getBool

  # SIGTERM the daemon, assert exit within 5 s.
  let shutdownStart = epochTime()
  discard kill(daemon.processID.Pid, SIGTERM)
  var exited = false
  let shutdownDeadline = epochTime() + 5.0
  while epochTime() < shutdownDeadline:
    if not daemon.running():
      exited = true
      break
    sleep(80)
  let exitCode =
    if exited: daemon.waitForExit()
    else:
      discard kill(daemon.processID.Pid, SIGKILL)
      daemon.waitForExit()
  let elapsed = epochTime() - shutdownStart
  daemon.close()
  check exited
  check elapsed < 5.0
  check exitCode == 0 or exitCode == 143

  # No orphan children: process-compose still owns postgres; the
  # daemon shouldn't have spawned any other subprocess in this
  # milestone.  Check no process matches the binary's path.
  let leftovers = execCmdEx("pgrep -f " & quoteShell(CliPath))
  check leftovers.exitCode != 0  # pgrep returns 1 when nothing matches.

  # Tear the cluster down.
  let downCmd = "process-compose down --config " & ComposeFile.quoteShell &
      " --unix-socket " & sock &
      " >/dev/null 2>&1"
  discard execShellCmd(downCmd)
  discard execShellCmd("pkill -9 -f 'postgres -D " & dataDir &
      "' >/dev/null 2>&1")
  sleep(500)
  try: removeDir(tmpRoot)
  except OSError: discard

suite "REV-M4 e2e isonim-review serve":
  test "e2e_cli_serve_lifecycle":
    if findExe("process-compose").len == 0:
      skip()
    elif findExe("curl").len == 0:
      skip()
    else:
      check fileExists(CliPath)
      runLifecycle()
