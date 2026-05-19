## REV-M4 — end-to-end: ``isonim-review init`` against a real
## ``process-compose``-managed cluster.
##
## We do *not* run ``just dev-pg-start`` directly because that target
## binds the developer-default ``$PGDATA`` path (``$PWD/.dev/postgres``)
## and would clobber the user's local cluster.  Instead we drive
## ``process-compose`` against the milestone's ``process-compose.yaml``
## with an ephemeral ``ISONIM_REVIEW_PGDATA`` + ``ISONIM_REVIEW_PGPORT``
## — the same trick ``e2e_design_review_pg_process_compose.nim``
## uses for REV-M3.
##
## The acceptance gate is the post-condition the milestone spells out
## — ``SELECT count(*) FROM public.schema_migrations`` returns the
## number of migration files we ship (REV-M3's 001+002 plus REV-M7's
## 003) between init and stop.

import std/[os, osproc, streams, strtabs, strutils, times, unittest]
import db_connector/db_postgres

const RepoRoot = currentSourcePath().parentDir().parentDir()
const ComposeFile = RepoRoot / "process-compose.yaml"
const MigDir = RepoRoot / "db" / "migrations"
const CliPath = RepoRoot / "build" / "bin" / "isonim-review"

proc pickFreePort(): int =
  ## Same heuristic the REV-M3 e2e uses — try 5500..5599 and skip
  ## anything already responding to ``pg_isready``.
  let now = epochTime()
  let seed = int(now * 1000) mod 100
  for offset in 0..99:
    let candidate = 5500 + ((seed + offset) mod 100)
    let probe = execCmdEx("pg_isready -h 127.0.0.1 -p " & $candidate &
        " -t 1 -q")
    if probe.exitCode != 0:
      return candidate
  return 5599

proc waitForReady(port: int; timeoutSeconds = 60): bool =
  let deadline = epochTime() + timeoutSeconds.float
  while epochTime() < deadline:
    let r = execCmdEx("pg_isready -h 127.0.0.1 -p " & $port & " -q")
    if r.exitCode == 0: return true
    sleep(400)
  false

proc runEndToEnd() =
  let port = pickFreePort()
  let tmpRoot = getTempDir() / "isonim_review_e2e_init"
  createDir(tmpRoot)
  let dataDir = tmpRoot / ("pg-" & $port & "-" &
      $((int(epochTime() * 1000)) mod 1000000))
  createDir(dataDir)
  let pcPort = $(port + 200)
  let sock = (tmpRoot / "pc.sock").quoteShell

  putEnv("ISONIM_REVIEW_PGDATA", dataDir)
  putEnv("ISONIM_REVIEW_PGPORT", $port)
  putEnv("ISONIM_REVIEW_MIGRATIONS_DIR", MigDir)

  let upCmd = "process-compose up --detached --config " &
      ComposeFile.quoteShell &
      " --port " & pcPort &
      " --unix-socket " & sock &
      " >/dev/null 2>&1"
  discard execShellCmd(upCmd)

  let ready = waitForReady(port, 60)
  check ready

  # process-compose runs ``postgres-create-roles`` →
  # ``postgres-create-db`` → ``postgres-migrate`` *after* the database
  # is ready; ``pg_isready`` returning ok doesn't imply the migrate
  # step has finished.  Wait until ``schema_migrations`` reports every
  # shipped migration before invoking the CLI — that's the natural
  # barrier.
  proc migratorReady(): bool =
    var conn: DbConn
    try:
      conn = open("", "", "",
        "host=127.0.0.1 port=" & $port &
          " dbname=isonim_design_review user=design_review_migrator " &
          "connect_timeout=2")
    except DbError:
      return false
    defer: conn.close()
    try:
      let v = conn.getValue(sql"""
        SELECT count(*) FROM public.schema_migrations""")
      # REV-M8 added migration 004 (``fetch_layout``).
      return parseInt(v) >= 4
    except DbError:
      return false
  let migrateDeadline = epochTime() + 60.0
  var migrateOk = false
  while epochTime() < migrateDeadline:
    if migratorReady():
      migrateOk = true
      break
    sleep(400)
  check migrateOk

  # Now run the CLI's ``init`` against the running cluster.  The
  # process-compose ``postgres-migrate`` step has already applied every
  # migration via the bash script, so this run is the idempotent
  # re-apply.  The CLI should converge to the same row count without
  # re-running any migration.
  var environ = newStringTable(modeCaseSensitive)
  for kv in envPairs():
    environ[kv.key] = kv.value
  environ["ISONIM_REVIEW_PGHOST"] = "127.0.0.1"
  environ["ISONIM_REVIEW_PGPORT"] = $port

  let p = startProcess(CliPath,
    args = @["init", "--migrations", MigDir],
    env = environ,
    options = {poStdErrToStdOut, poUsePath})
  let outText = p.outputStream.readAll()
  let initRc = p.waitForExit()
  p.close()
  check initRc == 0
  check ("apply 001" in outText) or ("skip 001" in outText)
  check ("apply 002" in outText) or ("skip 002" in outText)
  check ("apply 003" in outText) or ("skip 003" in outText)
  check ("apply 004" in outText) or ("skip 004" in outText)

  # Post-condition: schema_migrations contains every version we ship.
  let conn = open("", "", "",
    "host=127.0.0.1 port=" & $port & " dbname=isonim_design_review " &
    "user=design_review_migrator")
  let countStr = conn.getValue(sql"""
    SELECT count(*) FROM public.schema_migrations""")
  conn.close()
  # REV-M8 added migration 004 (``fetch_layout``).
  check parseInt(countStr) == 4

  let downCmd = "process-compose down --config " & ComposeFile.quoteShell &
      " --unix-socket " & sock &
      " >/dev/null 2>&1"
  discard execShellCmd(downCmd)

  discard execShellCmd("pkill -9 -f 'postgres -D " & dataDir &
      "' >/dev/null 2>&1")
  sleep(500)
  try: removeDir(tmpRoot)
  except OSError: discard

suite "REV-M4 e2e isonim-review init":
  test "e2e_cli_init_against_process_compose":
    if findExe("process-compose").len == 0:
      skip()
    else:
      check fileExists(CliPath)
      runEndToEnd()
