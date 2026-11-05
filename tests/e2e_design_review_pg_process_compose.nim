## REV-M3 — end-to-end: boot the cluster via the real
## ``process-compose.yaml`` file, prove ``pg_isready`` reports the cluster
## healthy without any sudo, then prove ``process-compose down`` leaves
## the data dir intact.
##
## This is the milestone's
## ``e2e_process_compose_boots_postgres_without_sudo`` check.  It must
## drive a *real* ``process-compose`` subprocess — no in-process
## simulation.

import std/[os, osproc, times, unittest, tempfiles, strutils, monotimes, json]

const RepoRoot = currentSourcePath().parentDir().parentDir()
const ComposeFile = RepoRoot / "process-compose.yaml"

proc waitForReady(port: int; timeoutSeconds = 45): bool =
  let pgIsReady = findExe("pg_isready")
  if pgIsReady.len == 0: return false
  let deadline = epochTime() + timeoutSeconds.float
  while epochTime() < deadline:
    let res = execCmdEx(pgIsReady & " -h 127.0.0.1 -p " & $port & " -q")
    if res.exitCode == 0:
      return true
    sleep(500)
  return false

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

proc waitOwnedExit(child: Process; timeoutMs: int): int =
  # In selected Nim 2.2.4, timed waitForExit sends SIGKILL after its deadline.
  # Polling running() instead reaps only this retained child; on timeout we
  # preserve its identity for the owning controller, without sending signals.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while child.running() and getMonoTime() < deadline:
    sleep(50)
  if child.running():
    echo "owned child wait pid=", child.processID, " live-retained=true"
    flushFile(stdout)
    return -1
  result = child.waitForExit() # running() already reaped terminal status.
  echo "owned child wait pid=", child.processID, " reaped=true exit=", result
  flushFile(stdout)

proc runE2e() =
  let port = pickFreePort()
  let tmpRoot = createTempDir("isonim-review-e2e-pc-", "")
  let dataDir = tmpRoot / "postgres"
  createDir(dataDir)

  # Pass the cluster-shape env via the parent environment so the YAML
  # ``environment:`` section (which lists names only) inherits them.
  putEnv("ISONIM_REVIEW_PGDATA", dataDir)
  putEnv("ISONIM_REVIEW_PGPORT", $port)
  putEnv("ISONIM_REVIEW_MIGRATIONS_DIR", RepoRoot / "db" / "migrations")
  let pcPort = $(port + 100)

  # Keep the actual orchestrator as an owned child instead of detaching
  # and later finding processes by a command-line substring. Parent streams
  # avoid an unread child pipe while readiness is polled independently.
  let compose = startProcess(findExe("process-compose"), workingDir = RepoRoot,
    args = @["up", "--config", ComposeFile, "--port", pcPort,
      "--unix-socket", tmpRoot / "pc.sock", "--tui=false"],
    options = {poUsePath, poParentStreams})
  let composePid = compose.processID
  var composeBirth, composeSid: string
  var downPid = 0
  var stopped = false
  defer:
    if stopped:
      compose.close()
      removeDir(tmpRoot)
    else:
      let retained = %*{"directory": tmpRoot, "PGDATA": dataDir,
        "socket": tmpRoot / "pc.sock", "composePid": composePid,
        "composeBirth": composeBirth, "composeSid": composeSid,
        "downPid": downPid}
      writeFile(tmpRoot / "retained-owner.json", $retained)
      echo "Preserved unfinished owned fixture: ", retained

  try:
    when defined(linux):
      let rawStat = readFile("/proc/" & $composePid & "/stat")
      let fields = rawStat[rawStat.rfind(')') + 2 .. ^1].splitWhitespace()
      composeBirth = fields[19]
      composeSid = fields[3]
      echo "owned process-compose pid=", composePid,
        " birth=", composeBirth, " sid=", composeSid
      flushFile(stdout)
    else:
      echo "owned process-compose child=", composePid
    # Wait for Postgres readiness.
    let ready = waitForReady(port, 60)
    check ready
    # ``data dir is intact'' guard: PG_VERSION must exist.
    check fileExists(dataDir / "PG_VERSION")
    # Readiness must belong to the cluster started in this private PGDATA,
    # rather than another service that happened to bind the selected TCP port.
    let pidRecord = readFile(dataDir / "postmaster.pid").splitLines()
    check pidRecord.len >= 4
    check pidRecord[1] == dataDir
    check parseInt(pidRecord[3]) == port
    let pgStatus = execCmdEx("pg_ctl -D " & dataDir.quoteShell & " status")
    check pgStatus.exitCode == 0
    when defined(linux):
      let postgresPid = parseInt(pidRecord[0])
      let pgRawStat = readFile("/proc/" & $postgresPid & "/stat")
      let pgFields = pgRawStat[pgRawStat.rfind(')') + 2 .. ^1].splitWhitespace()
      let pgArgs = readFile("/proc/" & $postgresPid & "/cmdline").split('\0')
      check pgArgs.len >= 3
      check pgArgs[1] == "-D" and pgArgs[2] == dataDir
      var ancestor = parseInt(pgFields[1])
      var foundOwner = false
      for depth in 0 ..< 64:
        if ancestor == composePid:
          foundOwner = true
          break
        if ancestor <= 1: break
        let raw = readFile("/proc/" & $ancestor & "/stat")
        let parentFields = raw[raw.rfind(')') + 2 .. ^1].splitWhitespace()
        ancestor = parseInt(parentFields[1])
      check foundOwner
      echo "owned postgres pid=", postgresPid,
        " birth=", pgFields[19], " sid=", pgFields[3]
      flushFile(stdout)

  finally:
    # Address only this private orchestrator; retain the actual control child
    # until its bounded poll reaps it; incomplete shutdown is preserved.
    let down = startProcess(findExe("process-compose"), workingDir = RepoRoot,
      args = @["down", "--unix-socket", tmpRoot / "pc.sock"],
      options = {poUsePath, poParentStreams})
    downPid = down.processID
    let downStatus = waitOwnedExit(down, 35_000)
    if downStatus != -1: down.close()
    check downStatus == 0

    # The data dir must NOT have been wiped by the down step.
    check fileExists(dataDir / "PG_VERSION")
    check fileExists(dataDir / "postgresql.conf")

    # The private socket addresses only this owned orchestrator. After its
    # graceful down, require its actual retained child to exit and require
    # PostgreSQL's own data-directory controller to report no running server.
    # No broad process signal or shared temporary directory removal is used.
    block:
      let composeExit = waitOwnedExit(compose, 35_000)
      check composeExit == 0
      let postgresStatus = execCmdEx("pg_ctl -D " & dataDir.quoteShell & " status")
      check postgresStatus.exitCode == 3
      stopped = downStatus == 0 and composeExit == 0 and postgresStatus.exitCode == 3

suite "REV-M3 process-compose e2e":
  test "e2e_process_compose_boots_postgres_without_sudo":
    if findExe("process-compose").len == 0:
      skip()
    else:
      runE2e()
