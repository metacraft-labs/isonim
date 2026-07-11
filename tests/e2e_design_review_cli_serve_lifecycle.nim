## REV-M4 — end-to-end: ``isonim-review serve`` lifecycle against a
## real ``process-compose``-managed cluster.
##
## Boots the cluster via process-compose with an ephemeral PGDATA +
## port (same approach as ``e2e_design_review_cli_init.nim``), starts
## the daemon, curl's ``/health`` for a 200, SIGTERMs the daemon, and
## asserts it exits within 5 s with no orphan postgres children.

import std/[json, net, os, osproc, posix, strtabs, strutils, times, unittest]
import db_connector/db_postgres

const RepoRoot = currentSourcePath().parentDir().parentDir()
const ComposeFile = RepoRoot / "process-compose.yaml"
const MigDir = RepoRoot / "db" / "migrations"
const CliPath = RepoRoot / "build" / "bin" / "isonim-review"

proc allocateEphemeralPorts(n: int): seq[int] =
  ## Atomically obtain ``n`` DISTINCT genuinely-free loopback ports.  We
  ## hold a ``127.0.0.1:0`` bind open for every port simultaneously
  ## while reading each kernel-assigned number, so no two of them can
  ## alias, then close them all so the daemon / postgres / process-compose
  ## can take them.  This replaces the old ``pg_isready`` / ``curl``
  ## fixed-range scans, which had a check-then-use TOCTOU window (a
  ## sibling or unrelated host process could grab the "free" port between
  ## the probe and the actual bind) and were the source of the
  ## ``Address already in use`` port-collision flakes.
  var socks: seq[Socket] = @[]
  try:
    for _ in 0 ..< n:
      let s = newSocket()
      s.bindAddr(Port(0), "127.0.0.1")
      socks.add s
      let (_, p) = s.getLocalAddr()
      result.add int(p)
  finally:
    for s in socks: s.close()

proc leftoverCliProcesses(cliPath: string): int =
  ## Count live processes whose full command line references ``cliPath``,
  ## EXCLUDING the ``pgrep`` invocation itself.  ``pgrep -f`` otherwise
  ## matches the ``sh -c "pgrep -f <cliPath>"`` wrapper (the pattern
  ## string is in that wrapper's own argv), which would make a raw
  ## ``exitCode != 0`` check race/false-positive.  ``pgrep -af`` prints
  ## "pid cmdline"; we drop any line whose cmdline contains ``pgrep``.
  let r = execCmdEx("pgrep -af " & quoteShell(cliPath))
  if r.exitCode != 0: return 0          # nothing matched at all
  for line in r.output.splitLines():
    let s = line.strip()
    if s.len == 0: continue
    if "pgrep" in s: continue           # the wrapper shell / pgrep itself
    inc result

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
      if parseInt(v) >= 3:
        ok = true
      conn.close()
    except DbError:
      ok = false
    if ok: return true
    sleep(400)
  false

proc runLifecycle() =
  # Allocate all three loopback ports atomically + distinct: postgres,
  # the daemon's HTTP port, and process-compose's own admin port.
  let ports = allocateEphemeralPorts(3)
  let pgPort = ports[0]
  let httpPort = ports[1]
  let pcAdminPort = ports[2]
  let tmpRoot = getTempDir() / "isonim_review_e2e_serve"
  createDir(tmpRoot)
  let dataDir = tmpRoot / ("pg-" & $pgPort & "-" &
      $((int(epochTime() * 1000)) mod 1000000))
  createDir(dataDir)
  let pcPort = $pcAdminPort
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
  # milestone.  ``waitForExit`` above reaps the daemon itself, but the
  # kernel may still be tearing down transient descendants for a beat,
  # so poll until no ``isonim-review`` process remains (bounded), rather
  # than a single-shot check that races the reaping.
  var leftoverGone = false
  let leftoverDeadline = epochTime() + 5.0
  while epochTime() < leftoverDeadline:
    if leftoverCliProcesses(CliPath) == 0:
      leftoverGone = true
      break
    sleep(80)
  check leftoverGone

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
