## REV-M3 — reusable Postgres fixture for design-review integration tests.
##
## Boots a real PostgreSQL cluster against an ephemeral PGDATA + port,
## applies migrations, hands back a connection string, and tears down on
## ``shutdown``.  Every PG test in REV-M3..REV-M10 consumes this — no
## mocks at the DB boundary.
##
## How it works
## ------------
## We deliberately do NOT shell out to ``process-compose up -d`` here:
##   1. ``process-compose`` runs detached but rebinds to its own working
##      directory + state files, which makes cleanup brittle in tests that
##      run in parallel under the same user.
##   2. The five processes are simple enough that ``pg_ctl`` + a few
##      ``psql`` calls is shorter and more debuggable than parsing
##      ``process-compose`` status JSON.
##
## What we DO drive end-to-end via ``process-compose`` is the milestone's
## explicit ``e2e_process_compose_boots_postgres_without_sudo`` test in
## ``e2e_design_review_pg_process_compose.nim``.  That test is the one
## that proves the orchestrator file boots a healthy cluster.

import std/[algorithm, os, osproc, streams, strutils, times]

const RepoRoot* = currentSourcePath().parentDir().parentDir().parentDir()
const MigrationsDir* = RepoRoot / "db" / "migrations"

type
  PgFixture* = ref object
    dataDir*:          string
    port*:             int
    connectionString*: string
    appConnectionString*:      string
    migratorConnectionString*: string
    started*:          bool

# ----- internal helpers ----------------------------------------------------

proc detectPgBinDir(): string =
  ## Probe ``$PATH`` for ``initdb``; if absent, fall back to a
  ## ``nix-shell -p postgresql_16`` wrapper.  This keeps the harness
  ## working when the user is inside the Nix dev shell *and* when they're
  ## not (current darwin reality — see Outstanding Tasks in the spec).
  let probe = findExe("initdb")
  if probe.len > 0:
    return probe.parentDir
  raise newException(IOError,
    "design_review_pg_fixture: ``initdb`` not on $PATH.  " &
    "Enter the Nix dev shell (``nix develop``) or wrap your test " &
    "invocation in ``nix-shell -p postgresql_16 process-compose --run '...'``.")

proc pgBin(binDir, name: string): string =
  result = binDir / name
  if not fileExists(result):
    raise newException(IOError,
      "design_review_pg_fixture: " & name & " not found at " & result)

proc pickFreePort(): int =
  ## Best-effort: pick a port in 5500..5599 that doesn't already have a
  ## ``postmaster.pid`` colliding under ``$TMPDIR``.  In CI two parallel
  ## test files might still race; for now we sequence them via Justfile
  ## ordering rather than locking.
  ## We try a high-numbered range so collisions with system Postgres
  ## (5432, 5433) and developer clusters are unlikely.
  let now = epochTime()
  let seed = int(now * 1000) mod 100
  for offset in 0..99:
    let candidate = 5500 + ((seed + offset) mod 100)
    # ``pg_isready`` reports "no response" if no server bound; that's our
    # "free" signal.  ``execCmdEx`` returns 2 in that case.
    let probe = execCmdEx("pg_isready -h 127.0.0.1 -p " & $candidate &
                          " -t 1 -q")
    if probe.exitCode != 0:
      return candidate
  raise newException(IOError,
    "design_review_pg_fixture: no free port in 5500..5599 (all responding)")

proc runPsql(binDir: string; port: int; dbName, sql: string;
    role: string = "") =
  let psql = pgBin(binDir, "psql")
  var cmd = psql & " -h 127.0.0.1 -p " & $port & " -d " & dbName &
            " -v ON_ERROR_STOP=1"
  if role.len > 0:
    cmd.add " -U " & role
  cmd.add " -c \"" & sql.replace("\"", "\\\"") & "\""
  let res = execCmdEx(cmd)
  if res.exitCode != 0:
    raise newException(IOError,
      "design_review_pg_fixture: psql failed: " & cmd & "\n" & res.output)

proc runPsqlFile(binDir: string; port: int; dbName, file: string;
    role: string = "") =
  let psql = pgBin(binDir, "psql")
  var args = @[
    "-h", "127.0.0.1", "-p", $port, "-d", dbName,
    "-v", "ON_ERROR_STOP=1", "-f", file]
  if role.len > 0:
    args = @["-U", role] & args
  let p = startProcess(psql, args = args,
      workingDir = file.parentDir,
      options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  let output = p.outputStream.readAll()
  let exitCode = p.waitForExit()
  if exitCode != 0:
    raise newException(IOError,
      "design_review_pg_fixture: psql -f " & file &
      " failed (" & $exitCode & "):\n" & output)

proc waitForReady(binDir: string; port: int; timeoutSeconds = 30) =
  let pgIsReady = pgBin(binDir, "pg_isready")
  let deadline = epochTime() + timeoutSeconds.float
  while epochTime() < deadline:
    let res = execCmdEx(pgIsReady & " -h 127.0.0.1 -p " & $port & " -q")
    if res.exitCode == 0:
      return
    sleep(200)
  raise newException(IOError,
    "design_review_pg_fixture: pg_isready timed out after " &
    $timeoutSeconds & "s on port " & $port)

# ----- public API ----------------------------------------------------------

proc newPgFixture*(applyMigrations = true): PgFixture =
  ## 1) Pick an ephemeral free port in 5500..5599.
  ## 2) Create a tmpdir as $PGDATA.
  ## 3) Boot postgres against this PGDATA + port.
  ## 4) Create the two design_review roles.
  ## 5) Create the ``isonim_design_review`` database.
  ## 6) Apply ``db/migrations/*.sql`` in order.
  ## 7) Return.
  let binDir = detectPgBinDir()
  let port = pickFreePort()
  # Single fixed parent dir keeps cleanup explicit even if a previous
  # crash left a half-built PGDATA around.
  let tmpParent = getTempDir() / "isonim_review_pg"
  createDir(tmpParent)
  let dataDir = tmpParent / ("pg-" & $port & "-" &
      $((int(epochTime() * 1000)) mod 1000000))
  createDir(dataDir)

  let initdb = pgBin(binDir, "initdb")
  let res = execCmdEx(initdb & " --locale=C.UTF-8 --encoding=UTF8 " &
                      "--auth=trust -D " & dataDir.quoteShell)
  if res.exitCode != 0:
    raise newException(IOError,
      "design_review_pg_fixture: initdb failed:\n" & res.output)

  # Patch postgresql.conf in-place.
  let confPath = dataDir / "postgresql.conf"
  let configLines = "\nlisten_addresses = '127.0.0.1'\nport = " & $port &
                    "\nunix_socket_directories = '" & dataDir &
                    "'\nlog_statement = 'all'\nlog_connections = on\n" &
                    "log_disconnections = on\n"
  let f = open(confPath, fmAppend)
  f.write(configLines)
  f.close()

  # pg_ctl daemonises postgres but the daemon inherits stdout/stderr from
  # the launching shell.  Under nim's ``execCmdEx`` (popen-based) those
  # inherited descriptors keep the pipe open, so the parent read blocks
  # *forever* despite pg_ctl itself exiting.  Force-redirect both
  # descriptors to /dev/null so the daemon doesn't hold them open.
  let pgCtl = pgBin(binDir, "pg_ctl")
  let startCmd = pgCtl & " -D " & dataDir.quoteShell &
      " -l " & (dataDir / "postgres.log").quoteShell &
      " -w start </dev/null >/dev/null 2>&1"
  let startCode = execCmd(startCmd)
  if startCode != 0:
    let logSlice =
      try: readFile(dataDir / "postgres.log")
      except IOError: "(no log)"
    raise newException(IOError,
      "design_review_pg_fixture: pg_ctl start failed (" & $startCode &
      "). Log:\n" & logSlice)
  waitForReady(binDir, port)

  result = PgFixture(
    dataDir: dataDir,
    port:    port,
    connectionString: "postgres://127.0.0.1:" & $port & "/isonim_design_review",
    appConnectionString: "postgres://design_review_app@127.0.0.1:" & $port &
                          "/isonim_design_review",
    migratorConnectionString: "postgres://design_review_migrator@127.0.0.1:" &
                              $port & "/isonim_design_review",
    started: true,
  )

  # Roles (idempotent — fixture is one-shot so plain ``CREATE ROLE`` is fine).
  runPsql(binDir, port, "postgres",
          "CREATE ROLE design_review_migrator LOGIN")
  runPsql(binDir, port, "postgres",
          "CREATE ROLE design_review_app LOGIN")

  # Database, owned by migrator so DDL works without a switchover.
  let createdb = pgBin(binDir, "createdb")
  let cdb = execCmdEx(createdb & " -h 127.0.0.1 -p " & $port &
                      " -O design_review_migrator isonim_design_review")
  if cdb.exitCode != 0:
    raise newException(IOError,
      "design_review_pg_fixture: createdb failed:\n" & cdb.output)

  if applyMigrations:
    # Run schema migrations + record them in public.schema_migrations.
    runPsql(binDir, port, "isonim_design_review",
            "CREATE TABLE IF NOT EXISTS public.schema_migrations (" &
            "version INT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL " &
            "DEFAULT NOW(), content_sha TEXT)",
            role = "design_review_migrator")
    var files: seq[string]
    for kind, path in walkDir(MigrationsDir):
      if kind == pcFile and path.endsWith(".sql"):
        let base = path.extractFilename
        if base.len >= 4 and base[0..2].allCharsInSet({'0'..'9'}) and base[3] == '_':
          files.add path
    files.sort()
    for f in files:
      runPsqlFile(binDir, port, "isonim_design_review", f,
                  role = "design_review_migrator")

proc reset*(f: PgFixture) =
  ## TRUNCATE every base table.  Useful between tests in the same suite
  ## so they share a hot Postgres process without crosstalk.  Runs as the
  ## migrator role.
  if not f.started:
    return
  let binDir = detectPgBinDir()
  runPsql(binDir, f.port, "isonim_design_review",
          "TRUNCATE TABLE design_review.audit_events, " &
          "design_review.agent_reports, design_review.captures, " &
          "design_review.gallery_layouts, design_review.runs, " &
          "design_review.campaign_events, design_review.campaigns CASCADE",
          role = "design_review_migrator")

proc shutdown*(f: PgFixture) =
  ## Best-effort: stop the server, remove the data dir.  Never raises.
  if f == nil or not f.started:
    return
  let binDir =
    try: detectPgBinDir()
    except IOError: ""
  if binDir.len > 0:
    let pgCtl = binDir / "pg_ctl"
    discard execCmd(pgCtl & " -D " & f.dataDir.quoteShell &
                    " -m fast stop </dev/null >/dev/null 2>&1")
  try:
    removeDir(f.dataDir)
  except OSError:
    discard
  f.started = false
