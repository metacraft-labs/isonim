## REV-M3 — end-to-end: boot the cluster via the real
## ``process-compose.yaml`` file, prove ``pg_isready`` reports the cluster
## healthy without any sudo, then prove ``process-compose down`` leaves
## the data dir intact.
##
## This is the milestone's
## ``e2e_process_compose_boots_postgres_without_sudo`` check.  It must
## drive a *real* ``process-compose`` subprocess — no in-process
## simulation.

import std/[os, osproc, times, unittest]

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

proc runE2e() =
  let port = pickFreePort()
  let tmpRoot = getTempDir() / "isonim_review_e2e_pc"
  createDir(tmpRoot)
  let dataDir = tmpRoot / ("pg-" & $port & "-" &
      $((int(epochTime() * 1000)) mod 1000000))
  createDir(dataDir)

  # Pass the cluster-shape env via the parent environment so the YAML
  # ``environment:`` section (which lists names only) inherits them.
  putEnv("ISONIM_REVIEW_PGDATA", dataDir)
  putEnv("ISONIM_REVIEW_PGPORT", $port)
  putEnv("ISONIM_REVIEW_MIGRATIONS_DIR", RepoRoot / "db" / "migrations")
  let pcPort = $(port + 100)
  let sock = (tmpRoot / "pc.sock").quoteShell

  # Up — detached so the parent test can keep running.
  let upCmd = "process-compose up --detached --config " &
      ComposeFile.quoteShell &
      " --port " & pcPort &
      " --unix-socket " & sock &
      " >/dev/null 2>&1"
  discard execShellCmd(upCmd)

  # Wait for Postgres readiness.
  let ready = waitForReady(port, 60)
  check ready
  # ``data dir is intact'' guard: PG_VERSION must exist.
  check fileExists(dataDir / "PG_VERSION")

  # Down.  Output redirected so the pipe doesn't keep the daemon
  # postgres alive (same fd issue as the fixture).
  let downCmd = "process-compose down --config " & ComposeFile.quoteShell &
      " --unix-socket " & sock &
      " >/dev/null 2>&1"
  discard execShellCmd(downCmd)

  # The data dir must NOT have been wiped by the down step.
  check fileExists(dataDir / "PG_VERSION")
  check fileExists(dataDir / "postgresql.conf")

  # Cleanup.
  discard execShellCmd("pkill -9 -f 'postgres -D " & dataDir &
      "' >/dev/null 2>&1")
  sleep(500)
  try: removeDir(tmpRoot)
  except OSError: discard

suite "REV-M3 process-compose e2e":
  test "e2e_process_compose_boots_postgres_without_sudo":
    if findExe("process-compose").len == 0:
      skip()
    else:
      runE2e()
