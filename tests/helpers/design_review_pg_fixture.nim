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

import std/[algorithm, net, os, osproc, streams, strutils, times, tempfiles, monotimes, options, strtabs, uri, json]
when defined(linux):
  import std/posix
  import owned_cli_pg_fixture
  import owned_pg_query
  import db_connector/db_common

const RepoRoot* = currentSourcePath().parentDir().parentDir().parentDir()
const MigrationsDir* = RepoRoot / "db" / "migrations"

const
  NullStdio = when defined(windows): "" else: " </dev/null >/dev/null 2>&1"
    ## ``execCmd`` runs its command through ``/bin/sh`` on POSIX, where the
    ## daemonised server must not inherit our pipes (see ``newPgFixture``).
    ## On Windows ``execCmd`` is a plain ``CreateProcessW``: no shell to
    ## parse redirects, and no pipes for the server to hold open.
  InitdbLocale = when defined(windows): "C" else: "C.UTF-8"
    ## Windows has no ``C.UTF-8`` locale; ``C`` with ``--encoding=UTF8``
    ## gives the same byte-order collation.
  UnixSockets = not defined(windows)
    ## Windows clusters listen on TCP only (every connection string the
    ## fixture hands out is ``127.0.0.1:<port>`` anyway).

type
  PgFixture* = ref object
    dataDir*:          string
    port*:             int
    connectionString*: string
    appConnectionString*:      string
    migratorConnectionString*: string
    started*:          bool
    when defined(linux):
      ownedServer: OwnedChild

# ----- internal helpers ----------------------------------------------------

const OwnedPgDirectLogExec* = "log=$1; shift; exec \"$@\" > \"$log\" 2>&1"

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
  result = binDir / name.addFileExt(ExeExt)
  if not fileExists(result):
    raise newException(IOError,
      "design_review_pg_fixture: " & name & " not found at " & result)

proc allocateEphemeralPort(): int =
  ## Atomically obtain a genuinely-free loopback port.  We bind a
  ## throwaway TCP socket to ``127.0.0.1:0`` and read the port the kernel
  ## assigned from its free pool, then close the socket so postgres can
  ## take it.  Because the port came from an actual successful ``bind``
  ## (not a ``pg_isready`` guess against a fixed 5500..5599 range) there
  ## is no check-then-use TOCTOU: the port was provably unbound the
  ## instant we held it.  The socket only ``bind``s (never ``listen`` /
  ## ``connect``), so there is no ``TIME_WAIT`` and the port is reusable
  ## immediately.  The residual microsecond window between our ``close``
  ## and postgres' ``bind`` is closed by the retry-on-EADDRINUSE loop in
  ## ``newPgFixture``.
  let s = newSocket()
  try:
    s.bindAddr(Port(0), "127.0.0.1")
    let (_, p) = s.getLocalAddr()
    result = int(p)
  finally:
    s.close()

proc privatePgEnv(port: int): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): result[key] = value
  for key in ["PGSERVICE", "PGSERVICEFILE"]:
    if result.hasKey(key): result.del(key)
  result["PGHOST"] = "127.0.0.1"
  result["PGHOSTADDR"] = "127.0.0.1"
  result["PGPORT"] = $port
  when defined(linux):
    let account = getpwuid(geteuid())
    if account == nil or account.pw_name == nil:
      raise newException(IOError, "Cannot authenticate initdb OS owner")
    result["PGUSER"] = $account.pw_name

proc capturePrivate(executable: string; args: seq[string]; port: int;
    workingDir = "") : tuple[output: string, code: int] =
  when defined(linux):
    result = runOwnedCapture(executable, workingDir = workingDir, args = args,
      env = privatePgEnv(port))
  else:
    let child = startProcess(executable, workingDir = workingDir, args = args,
      env = privatePgEnv(port), options = {poUsePath, poStdErrToStdOut})
    try:
      result.output = child.outputStream.readAll()
      result.code = child.waitForExit()
    finally:
      # Non-Linux retained-descendant ownership still needs native controls.
      child.close()

proc runPsql(binDir: string; port: int; dbName, sql: string;
    role: string = "") =
  var args = @["-h", "127.0.0.1", "-p", $port, "-d", dbName,
    "-v", "ON_ERROR_STOP=1", "-c", sql]
  if role.len > 0: args = @["-U", role] & args
  let response = capturePrivate(pgBin(binDir, "psql"), args, port)
  if response.code != 0:
    raise newException(IOError, "Private psql failed:\n" & response.output)

proc runPsqlFile(binDir: string; port: int; dbName, file: string;
    role: string = "") =
  var args = @["-h", "127.0.0.1", "-p", $port, "-d", dbName,
    "-v", "ON_ERROR_STOP=1", "-f", file]
  if role.len > 0: args = @["-U", role] & args
  let response = capturePrivate(pgBin(binDir, "psql"), args, port,
    workingDir = file.parentDir)
  if response.code != 0:
    raise newException(IOError, "Private psql file failed:\n" & response.output)

proc waitForReady(binDir: string; fixture: PgFixture; timeoutSeconds = 30) =
  let port = fixture.port
  let pgIsReady = pgBin(binDir, "pg_isready")
  let deadline = getMonoTime() + initDuration(seconds = timeoutSeconds)
  while getMonoTime() < deadline:
    when defined(linux):
      if fixture.ownedServer == nil or not fixture.ownedServer.running():
        raise newException(IOError, "Retained PostgreSQL exited before readiness")
      let res = runOwnedCapture(pgIsReady, args = @[
        "-h", "127.0.0.1", "-p", $port, "-q"], workingDir = RepoRoot,
        env = privatePgEnv(port), deadline = some(deadline))
      if res.code == 0:
        if not fixture.ownedServer.running():
          raise newException(IOError, "Retained PostgreSQL exited during readiness")
        # PostgreSQL16.13 utils/pidfile.h defines status on line8 and
        # PM_STATUS_READY as "ready   ". A foreign pg_isready response must
        # not advance an initializing owned postmaster to connected SQL.
        let pidFile = fixture.dataDir / "postmaster.pid"
        if not fileExists(pidFile):
          let remaining = (deadline - getMonoTime()).inMilliseconds
          if remaining > 0: sleep(int(min(200'i64, remaining)))
          continue
        let rows = readFile(pidFile).splitLines()
        if rows.len < 4:
          let remaining = (deadline - getMonoTime()).inMilliseconds
          if remaining > 0: sleep(int(min(200'i64, remaining)))
          continue
        if rows[0] != $fixture.ownedServer.processID or
            rows[1] != fixture.dataDir or rows[3] != $fixture.port:
          raise newException(IOError, "Private PostgreSQL identity contradicts retained child")
        if rows.len < 8 or rows[7].strip() != "ready":
          let remaining = (deadline - getMonoTime()).inMilliseconds
          if remaining > 0: sleep(int(min(200'i64, remaining)))
          continue
        # pg_isready alone could have reached a foreign listener while the
        # retained postmaster was still starting. Read the connected server's
        # identity before issuing any role/database-changing SQL.
        let account = privatePgEnv(port)
        let owner = account["PGUSER"].replace("\\", "\\\\").replace("'", "\\'")
        let conninfo = "host=127.0.0.1 hostaddr=127.0.0.1 port=" & $port &
          " dbname=postgres user='" & owner & "' connect_timeout=2"
        let identity = parseJson(ownedPgValue(conninfo,
          "SELECT json_build_object('dataDir', current_setting('data_directory'), 'serverAddr', host(inet_server_addr()), 'serverPort', inet_server_port())::text",
          deadline))
        if not sameFile(identity["dataDir"].getStr(), fixture.dataDir) or
            identity["serverAddr"].getStr() != "127.0.0.1" or
            identity["serverPort"].getInt() != port:
          raise newException(IOError, "Connected PostgreSQL contradicts owned server identity")
        if not fixture.ownedServer.running() or
            readFile(fixture.dataDir / "postmaster.pid").splitLines()[0 .. 3] != rows[0 .. 3]:
          raise newException(IOError, "Owned PostgreSQL identity changed during connected proof")
        echo $(%*{"actualConnectedPrivatePGIdentity": identity,
          "retainedPostmasterPID": fixture.ownedServer.processID})
        return
    else:
      let res = execCmdEx(pgIsReady & " -h 127.0.0.1 -p " & $port & " -q")
      if res.exitCode == 0: return
    let remaining = (deadline - getMonoTime()).inMilliseconds
    if remaining > 0: sleep(int(min(200'i64, remaining)))
  raise newException(IOError,
    "design_review_pg_fixture: pg_isready timed out after " &
    $timeoutSeconds & "s on port " & $port)

# ----- public API ----------------------------------------------------------

proc migrationFiles*(): seq[string] =
  ## ``db/migrations/NNN_*.sql``, in the order they are applied.
  for kind, path in walkDir(MigrationsDir):
    if kind == pcFile and path.endsWith(".sql"):
      let base = path.extractFilename
      if base.len >= 4 and base[0..2].allCharsInSet({'0'..'9'}) and base[3] == '_':
        result.add path
  result.sort()

proc shutdown*(f: PgFixture)
proc stopFixture(f: PgFixture; allowFailedBoot: bool)

proc initializePgFixture(result: PgFixture; applyMigrations: bool;
    portAllocator: proc(): int) =
  ## 1) Allocate a genuinely-free ephemeral port atomically (bind :0).
  ## 2) Create a tmpdir as $PGDATA.
  ## 3) Boot postgres against this PGDATA + port.
  ## 4) Create the two design_review roles.
  ## 5) Create the ``isonim_design_review`` database.
  ## 6) Apply ``db/migrations/*.sql`` in order.
  ## 7) Return.
  let binDir = detectPgBinDir()
  let initdb = pgBin(binDir, "initdb")
  # pg_ctl daemonises postgres but the daemon inherits stdout/stderr from
  # the launching shell.  Under nim's ``execCmdEx`` (popen-based) those
  # inherited descriptors keep the pipe open, so the parent read blocks
  # *forever* despite pg_ctl itself exiting.  Force-redirect both
  # descriptors to /dev/null so the daemon doesn't hold them open.
  let pgCtl = pgBin(binDir, "pg_ctl")
  # Exclusive fixture parent; a failed constructor retains its own data.
  let tmpParent = createTempDir("isonim-review-pg-owned-", "")

  # Boot loop: allocate a genuinely-free port (bind :0), initdb, start.
  # If postgres cannot ``bind`` because an unrelated host process grabbed
  # the port in the microsecond after ``allocateEphemeralPort`` closed
  # its probe socket, we retry with a freshly-allocated port instead of
  # failing the whole fixture.  Bounded so a persistently-broken
  # environment still terminates.
  const MaxBootAttempts = 8
  var port = 0
  var dataDir = ""
  var booted = false
  var lastErr = ""
  for attempt in 0 ..< MaxBootAttempts:
    port = if portAllocator == nil: allocateEphemeralPort() else: portAllocator()
    if port < 1 or port > 65535: raise newException(IOError, "Invalid allocated private PG port")
    dataDir = tmpParent / ("pg-" & $port & "-" &
        $((int(epochTime() * 1000)) mod 1000000) & "-" & $attempt)
    createDir(dataDir)
    result.dataDir = dataDir
    result.port = port

    let res = capturePrivate(initdb, @["--locale=" & InitdbLocale,
      "--encoding=UTF8", "--auth=trust", "-D", dataDir], port)
    if res.code != 0:
      lastErr = "initdb failed:\n" & res.output
      try: removeDir(dataDir) except OSError: discard
      continue

    # Patch postgresql.conf in-place.
    let confPath = dataDir / "postgresql.conf"
    let socketDirs = if UnixSockets: dataDir else: ""
    let configLines = "\nlisten_addresses = '127.0.0.1'\nport = " & $port &
                      "\nunix_socket_directories = '" & socketDirs &
                      "'\nlog_statement = 'all'\nlog_connections = on\n" &
                      "log_disconnections = on\n"
    let f = open(confPath, fmAppend)
    f.write(configLines)
    f.close()

    let startCmd = pgCtl & " -D " & dataDir.quoteShell &
        " -l " & (dataDir / "postgres.log").quoteShell &
        " -w start" & NullStdio
    var startCode: int
    when defined(linux):
      # Exclusive regular log, all bytes retained. The fixed cached Bash
      # wrapper execs PostgreSQL in the same PID/birth held by OwnedChild.
      # No logging-collector actor is introduced by this fixture.
      let logPath = dataDir / "postgres.log"
      let logFd = posix.open(logPath.cstring, O_WRONLY or O_CREAT or O_EXCL,
        Mode(0o600))
      if logFd < 0:
        raise newException(IOError, "Exclusive PostgreSQL log creation refused: " & logPath)
      if posix.close(logFd) != 0:
        raise newException(IOError, "Exclusive PostgreSQL log close failed: " & logPath)
      let logIdentity = getFileInfo(logPath).id
      let bash = findExe("bash", followSymlinks = false)
      if bash.len == 0: raise newException(IOError, "Declared cached Bash role is missing")
      result.ownedServer = startOwnedChild(bash,
        args = @["-p", "-c", OwnedPgDirectLogExec, "isonim-owned-pg-log", logPath,
          pgBin(binDir, "postgres"), "-D", dataDir,
          "-c", "logging_collector=off"],
        options = {poParentStreams})
      result.started = true # Publish cleanup authority before any report/check.
      if symlinkExists(logPath) or getFileInfo(logPath).kind != pcFile or
          getFileInfo(logPath).id != logIdentity:
        raise newException(IOError, "Exclusive PostgreSQL log identity changed")
      echo $(%*{"actualPrivatePGLog": logPath, "logIdentity": $logIdentity,
        "bashInvocation": bash, "fixedExecScript": OwnedPgDirectLogExec,
        "retainedProcessID": result.ownedServer.processID})
      result.started = true
      startCode = 0
    else:
      startCode = execCmd(startCmd)
      if startCode == 0: result.started = true
    if startCode != 0:
      let logSlice =
        try: readFile(dataDir / "postgres.log")
        except IOError: "(no log)"
      # A lost race for the port manifests as a bind failure in the log.
      # Anything else is a genuine boot failure and must surface.
      if logSlice.contains("Address already in use") or
         logSlice.contains("could not bind"):
        let stopStatus = execCmd(pgCtl & " -D " & dataDir.quoteShell &
          " -m immediate stop" & NullStdio)
        if stopStatus != 0:
          raise newException(IOError, "Failed boot cleanup refused; retained PGDATA: " & dataDir)
        removeDir(dataDir)
        lastErr = "pg_ctl start lost port " & $port & " (EADDRINUSE)"
        continue
      raise newException(IOError,
        "design_review_pg_fixture: pg_ctl start failed (" & $startCode &
        "). Log:\n" & logSlice)
    try:
      waitForReady(binDir, result)
    except IOError:
      let original = getCurrentException()
      let logSlice =
        try: readFile(dataDir / "postgres.log")
        except IOError: "(no log)"
      if logSlice.contains("Address already in use") or logSlice.contains("could not bind"):
        stopFixture(result, allowFailedBoot = true)
        lastErr = "postgres start lost port " & $port & " (EADDRINUSE)"
        continue # Preserve all eight original boot attempts for bind failure.
      raise original
    booted = true
    break

  if not booted:
    raise newException(IOError,
      "design_review_pg_fixture: could not boot postgres after " &
      $MaxBootAttempts & " attempts; last error: " & lastErr &
      "; retained exclusive parent: " & tmpParent)

  let account = privatePgEnv(port)
  let owner = if account.hasKey("PGUSER"): account["PGUSER"] else: ""
  let ownerPart = if owner.len > 0: encodeUrl(owner, usePlus = false) & "@" else: ""
  result.connectionString = "postgres://" & ownerPart & "127.0.0.1:" & $port &
    "/isonim_design_review?hostaddr=127.0.0.1"
  result.appConnectionString = "postgres://design_review_app@127.0.0.1:" & $port &
    "/isonim_design_review?hostaddr=127.0.0.1"
  result.migratorConnectionString = "postgres://design_review_migrator@127.0.0.1:" &
    $port & "/isonim_design_review?hostaddr=127.0.0.1"

  # Roles (idempotent — fixture is one-shot so plain ``CREATE ROLE`` is fine).
  runPsql(binDir, port, "postgres",
          "CREATE ROLE design_review_migrator LOGIN")
  runPsql(binDir, port, "postgres",
          "CREATE ROLE design_review_app LOGIN")

  # Database, owned by migrator so DDL works without a switchover.
  let createdb = pgBin(binDir, "createdb")
  let cdb = capturePrivate(createdb, @["-h", "127.0.0.1", "-p", $port,
    "-O", "design_review_migrator", "isonim_design_review"], port)
  if cdb.code != 0:
    raise newException(IOError,
      "design_review_pg_fixture: createdb failed:\n" & cdb.output)

  if applyMigrations:
    # Run schema migrations + record them in public.schema_migrations.
    runPsql(binDir, port, "isonim_design_review",
            "CREATE TABLE IF NOT EXISTS public.schema_migrations (" &
            "version INT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL " &
            "DEFAULT NOW(), content_sha TEXT)",
            role = "design_review_migrator")
    for f in migrationFiles():
      runPsqlFile(binDir, port, "isonim_design_review", f,
                  role = "design_review_migrator")

proc applyMigrationFile*(f: PgFixture; path: string) =
  ## Apply one migration file as the migrator role, the way
  ## ``newPgFixture`` applies each of them.  For upgrade tests: build a
  ## ``newPgFixture(applyMigrations = false)`` cluster, apply the
  ## migrations up to some version, write rows the way that schema
  ## wrote them, then apply the rest.
  runPsqlFile(detectPgBinDir(), f.port, "isonim_design_review", path,
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

proc stopFixture(f: PgFixture; allowFailedBoot: bool) =
  ## pg_ctl16 --wait defaults to PGCTLTIMEOUT, otherwise60 seconds:
  ## https://www.postgresql.org/docs/16/app-pg-ctl.html
  ## Functional timeout is failure; retained recovery may outlive that bound.
  if f == nil or not f.started: return
  when defined(linux):
    let server = f.ownedServer
    if server == nil:
      raise newException(IOError, "Missing retained private PostgreSQL authority")
    let seconds = if existsEnv("PGCTLTIMEOUT"): parseInt(getEnv("PGCTLTIMEOUT")) else: 60
    if seconds < 0:
      raise newException(IOError, "Invalid negative PGCTLTIMEOUT; retained PGDATA: " & f.dataDir)
    let deadline = getMonoTime() + initDuration(seconds = seconds)
    var failure: ref Exception
    var status = -1
    try:
      if server.running(): server.signalOwnedChild(SIGINT)
      while server.running() and getMonoTime() < deadline:
        sleep(int(min(50'i64, max(1'i64, (deadline - getMonoTime()).inMilliseconds))))
      if server.running():
        failure = newException(IOError, "Original pg_ctl shutdown bound expired; retained PGDATA: " & f.dataDir)
        # Recovery only: original functional result stays failed, data retained.
        # This reuses the original held pidfd; actual wait never fabricates reap.
        status = drainDirectChild(server)
      else:
        status = server.waitForExit()
    except Exception:
      if failure == nil: failure = getCurrentException()
      # Retain actual authority and attempt owned recovery after signal/report
      # failures too; no numeric-PID reopen or unverified process signaling.
      try: status = drainDirectChild(server)
      except Exception:
        try: stderr.writeLine("Secondary retained PG recovery failure: " & getCurrentExceptionMsg())
        except Exception: discard
    var terminal = false
    try: terminal = not server.running()
    except Exception:
      if failure == nil: failure = getCurrentException()
    if terminal:
      f.ownedServer = nil
      f.started = false # Publish actual terminal state before throwing close.
      try: server.close()
      except Exception:
        if failure == nil: failure = getCurrentException()
    if failure != nil: raise failure
    if status != 0 and not allowFailedBoot:
      raise newException(IOError, "Private PostgreSQL exit " & $status &
        "; retained PGDATA: " & f.dataDir)
  else:
    let binDir = detectPgBinDir()
    let pgCtl = pgBin(binDir, "pg_ctl")
    let status = execCmd(pgCtl & " -D " & f.dataDir.quoteShell &
      " -m fast stop" & NullStdio)
    if status != 0:
      raise newException(IOError, "Private pg_ctl stop failed; retained PGDATA: " & f.dataDir)
  f.started = false
  removeDir(f.dataDir)
  # Only remove the exact exclusive parent after its own data vanished.
  # Unknown/retained entries remain for inspection; never delete them broadly.
  let parent = f.dataDir.parentDir
  if dirExists(parent):
    var empty = true
    for _ in walkDir(parent): empty = false
    if empty and not allowFailedBoot: removeDir(parent)

proc shutdown*(f: PgFixture) =
  let original = getCurrentException()
  try: stopFixture(f, allowFailedBoot = false)
  except Exception:
    if original == nil: raise
    try: stderr.writeLine("Secondary private PG cleanup failure: " & getCurrentExceptionMsg())
    except Exception: discard

proc newPgFixture*(applyMigrations = true; portAllocator: proc(): int = nil): PgFixture =
  ## Default allocation remains the real kernel ephemeral-port allocator.
  ## Explicit allocator supports deterministic real occupied-port controls;
  ## it never replaces PostgreSQL, sockets, migrations or ownership checks.
  result = PgFixture()
  try:
    initializePgFixture(result, applyMigrations, portAllocator)
  except Exception:
    let original = getCurrentException()
    try: result.shutdown()
    except Exception:
      # Preserve the initiating failure; secondary cleanup is still visible.
      try: stderr.writeLine("Private PG constructor cleanup failed: " &
        getCurrentExceptionMsg() & "; retained PGDATA: " & result.dataDir)
      except Exception: discard
    raise original
