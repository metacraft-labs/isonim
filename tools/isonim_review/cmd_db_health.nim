## REV-M4 — ``isonim-review db-health`` subcommand.
##
## Five independent probes, each reportable in isolation:
##
##   1. ``postgres_reachable`` — open a connection against the configured
##      host/port using the OS user (matches the dev cluster's ``trust``
##      auth).  Includes a wall-clock timeout so a stopped Postgres does
##      not hang the command.
##
##   2. ``app_role_reachable`` — open a connection as
##      ``design_review_app`` and call a representative routine
##      (``design_review.list_history``) so the probe exercises both
##      LOGIN and EXECUTE grants.  We pass ``limit=0`` and a placeholder
##      brief id; the call returns zero rows but proves the boundary is
##      reachable.
##
##   3. ``migrator_role_reachable`` — same shape against
##      ``design_review_migrator``.  The migrator role has full DDL so
##      a plain ``SELECT 1`` is enough; the actual probe is the
##      connection itself.
##
##   4. ``schema_version_current`` — compare the on-disk migrations to
##      the rows in ``public.schema_migrations``.  Returns the set of
##      pending versions when out of sync.
##
##   5. ``process_compose_running`` — best-effort: probes ``ps -ax``
##      for a ``process-compose`` command line.  No reliance on a pid
##      file (process-compose's default location is socket-based, not
##      pid-file based).  Documented detection method, easy to
##      cross-check by hand.
##
## Default output: one ``key: value`` line per probe (human readable).
## ``--json`` emits the same data as a single JSON object plus
## ``schema_version`` and ``pending_migrations`` for the gallery UI to
## consume.

import std/[json, os, osproc, parseutils, strutils, times]
import db_connector/db_postgres

import ./config
import ./cmd_init

type
  HealthReport* = object
    postgresReachable*: bool
    postgresError*: string
    appRoleReachable*: bool
    appRoleError*: string
    migratorRoleReachable*: bool
    migratorRoleError*: string
    schemaVersionCurrent*: bool
    schemaVersion*: int
    pendingMigrations*: seq[int]
    schemaError*: string
    processComposeRunning*: bool
    processComposeError*: string
    elapsedMs*: int

const ProbeTimeoutSeconds = 4
  ## Hard wall-clock cap on probes that connect through libpq.  The
  ## spec requires ``db-health`` to bail out in under 5 s when
  ## Postgres is down; libpq's default connect timeout can exceed
  ## that, so we splice ``connect_timeout=N`` into the conn string.

proc withConnectTimeout(connStr: string; seconds: int): string =
  ## Append ``connect_timeout=N`` to a libpq URI.  Idempotent: if the
  ## key already appears we leave it alone.
  if "connect_timeout" in connStr:
    return connStr
  if '?' in connStr:
    return connStr & "&connect_timeout=" & $seconds
  connStr & "?connect_timeout=" & $seconds

proc tryOpen(connStr: string): tuple[ok: bool; conn: DbConn; err: string] =
  ## ``open`` that captures DbError as a string instead of propagating.
  try:
    let c = open("", "", "", connStr)
    return (true, c, "")
  except DbError as e:
    return (false, DbConn(nil), e.msg)
  except Exception as e:
    return (false, DbConn(nil), e.msg)

proc probePostgres(cfg: ReviewConfig): tuple[ok: bool; err: string] =
  ## Probe 1: anyone can reach the server.  We use the migrator's
  ## connection string because the dev cluster's OS user might not
  ## match the URI's default user; the migrator role exists on every
  ## migrated cluster.
  let connStr = withConnectTimeout(
    connectionString(cfg, role = "migrator"), ProbeTimeoutSeconds)
  let r = tryOpen(connStr)
  if not r.ok:
    return (false, r.err)
  defer: r.conn.close()
  try:
    discard r.conn.getValue(sql"SELECT 1")
    return (true, "")
  except DbError as e:
    return (false, e.msg)

proc probeAppRole(cfg: ReviewConfig): tuple[ok: bool; err: string] =
  ## Probe 2: ``design_review_app`` can both LOGIN and EXECUTE a
  ## representative routine.  Picking ``list_history`` (read-only,
  ## small footprint) avoids accidentally inserting a row into
  ## ``design_review.audit_events`` every health check.
  let connStr = withConnectTimeout(
    connectionString(cfg, role = "app"), ProbeTimeoutSeconds)
  let r = tryOpen(connStr)
  if not r.ok:
    return (false, r.err)
  defer: r.conn.close()
  try:
    for _ in r.conn.fastRows(sql"""
        SELECT design_review.list_history('design-review-health', 0, 0)
      """):
      discard
    return (true, "")
  except DbError as e:
    return (false, e.msg)

proc probeMigratorRole(cfg: ReviewConfig): tuple[ok: bool; err: string] =
  ## Probe 3: ``design_review_migrator`` can LOGIN.  The role has full
  ## DDL so a ``SELECT 1`` after connect is enough; we don't try a
  ## representative DDL command (creating + dropping a sandbox table
  ## would write rows the user doesn't want on every health probe).
  let connStr = withConnectTimeout(
    connectionString(cfg, role = "migrator"), ProbeTimeoutSeconds)
  let r = tryOpen(connStr)
  if not r.ok:
    return (false, r.err)
  defer: r.conn.close()
  try:
    discard r.conn.getValue(sql"SELECT 1")
    return (true, "")
  except DbError as e:
    return (false, e.msg)

proc probeSchema(cfg: ReviewConfig; migDir: string):
    tuple[ok: bool; schemaVersion: int; pending: seq[int]; err: string] =
  ## Probe 4: compare on-disk migrations to rows in
  ## ``schema_migrations``.  Returns the highest applied version (0 if
  ## the table is empty / missing) and the list of versions present on
  ## disk but absent from the table.
  var files: seq[MigrationFile]
  try:
    files = listMigrationFiles(migDir)
  except InitError as e:
    return (false, 0, @[], e.msg)
  let connStr = withConnectTimeout(
    connectionString(cfg, role = "migrator"), ProbeTimeoutSeconds)
  let r = tryOpen(connStr)
  if not r.ok:
    return (false, 0, @[], r.err)
  defer: r.conn.close()

  var applied: seq[int]
  try:
    for row in r.conn.fastRows(sql"""
        SELECT version FROM public.schema_migrations ORDER BY version"""):
      var v: int
      discard parseInt(row[0], v, 0)
      applied.add v
  except DbError as e:
    # If the table doesn't exist yet, treat as "no migrations applied
    # yet"; pending = every file.
    if "schema_migrations" in e.msg or "does not exist" in e.msg:
      applied = @[]
    else:
      return (false, 0, @[], e.msg)

  var pending: seq[int]
  for f in files:
    if f.version notin applied:
      pending.add f.version
  let high = if applied.len == 0: 0 else: applied[^1]
  (pending.len == 0, high, pending, "")

proc probeProcessCompose*(): tuple[ok: bool; err: string] =
  ## Probe 5: is a ``process-compose`` orchestrator running for this
  ## workspace?  We use ``pgrep -f 'process-compose'`` when available
  ## (POSIX-friendly), falling back to ``ps -ax | grep`` so the probe
  ## works in stripped-down environments.  Either way, the detection
  ## is a string match on the process command line — documented as
  ## such so the user can cross-check by hand.
  let pgrep = findExe("pgrep")
  if pgrep.len > 0:
    let r = execCmdEx(pgrep & " -f process-compose")
    return (r.exitCode == 0 and r.output.strip.len > 0, "")
  let ps = findExe("ps")
  if ps.len > 0:
    let r = execCmdEx(ps & " -ax")
    if r.exitCode != 0:
      return (false, "ps failed: " & r.output)
    for line in r.output.splitLines():
      if "process-compose" in line and "grep" notin line:
        return (true, "")
    return (false, "")
  return (false, "no pgrep or ps on PATH")

proc collectHealth*(cfg: ReviewConfig; migDir: string): HealthReport =
  ## Run every probe and pack the results into a single report.  Each
  ## probe is independent so partial failures still surface useful
  ## information.
  let started = epochTime()
  var rep: HealthReport
  block postgres:
    let (ok, err) = probePostgres(cfg)
    rep.postgresReachable = ok
    rep.postgresError = err

  if rep.postgresReachable:
    let (a, aerr) = probeAppRole(cfg)
    rep.appRoleReachable = a
    rep.appRoleError = aerr

    let (m, merr) = probeMigratorRole(cfg)
    rep.migratorRoleReachable = m
    rep.migratorRoleError = merr

    let (sok, sv, pending, serr) = probeSchema(cfg, migDir)
    rep.schemaVersionCurrent = sok
    rep.schemaVersion = sv
    rep.pendingMigrations = pending
    rep.schemaError = serr
  else:
    # If Postgres is down every dependent probe is automatically false
    # — record that explicitly so callers don't conflate "no data"
    # with "data says false".
    rep.appRoleError = "skipped: postgres unreachable"
    rep.migratorRoleError = "skipped: postgres unreachable"
    rep.schemaError = "skipped: postgres unreachable"

  let (pcOk, pcErr) = probeProcessCompose()
  rep.processComposeRunning = pcOk
  rep.processComposeError = pcErr

  rep.elapsedMs = int((epochTime() - started) * 1000.0)
  rep

proc renderHuman*(rep: HealthReport): string =
  ## ``key: yes|no`` per probe, plus a final ``schema_version`` line.
  ## Returns the rendered text (no trailing newline).
  proc yn(b: bool): string = (if b: "yes" else: "no")
  var lines: seq[string]
  lines.add "postgres_reachable: " & yn(rep.postgresReachable)
  lines.add "app_role_reachable: " & yn(rep.appRoleReachable)
  lines.add "migrator_role_reachable: " & yn(rep.migratorRoleReachable)
  lines.add "schema_version_current: " & yn(rep.schemaVersionCurrent)
  lines.add "schema_version: " & $rep.schemaVersion
  if rep.pendingMigrations.len > 0:
    var parts: seq[string]
    for v in rep.pendingMigrations:
      parts.add $v
    lines.add "pending_migrations: " & parts.join(",")
  lines.add "process_compose_running: " & yn(rep.processComposeRunning)
  lines.join("\n")

proc renderJson*(rep: HealthReport): string =
  ## Canonical JSON shape.  Used by ``db-health --json`` and by
  ## ``serve``'s ``/health`` endpoint — these MUST agree byte-for-byte
  ## so the gallery UI has one schema to consume.
  var pending = newJArray()
  for v in rep.pendingMigrations:
    pending.add %v
  let j = %* {
    "postgres_reachable": rep.postgresReachable,
    "app_role_reachable": rep.appRoleReachable,
    "migrator_role_reachable": rep.migratorRoleReachable,
    "schema_version_current": rep.schemaVersionCurrent,
    "schema_version": rep.schemaVersion,
    "pending_migrations": pending,
    "process_compose_running": rep.processComposeRunning,
  }
  $j

proc allGreen*(rep: HealthReport): bool =
  ## Aggregate over the four DB probes.  ``process_compose_running``
  ## is informational only — a developer running ``isonim-review``
  ## against a manually-launched ``postgres`` should still see green.
  rep.postgresReachable and
    rep.appRoleReachable and
    rep.migratorRoleReachable and
    rep.schemaVersionCurrent

proc cmdDbHealth*(cfg: ReviewConfig; jsonOut: bool;
                  migDir: string = "";
                  stdoutOut: File = stdout): int =
  ## Implements ``isonim-review db-health`` and the daemon's
  ## ``/health`` endpoint share the same body.  Returns 0 if every DB
  ## probe is green, 1 otherwise.
  let dir =
    if migDir.len > 0: migDir
    else: getCurrentDir() / "db" / "migrations"
  let rep = collectHealth(cfg, dir)
  if jsonOut:
    stdoutOut.writeLine(renderJson(rep))
  else:
    stdoutOut.writeLine(renderHuman(rep))
  if allGreen(rep): 0 else: 1
