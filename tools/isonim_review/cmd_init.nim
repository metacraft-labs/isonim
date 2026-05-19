## REV-M4 — ``isonim-review init`` subcommand.
##
## Drives the same migration flow as ``db/migrate.sh`` but from Nim, so
## the canonical migration owner is the CLI binary (the bash script
## stays around as a fallback / for ad-hoc psql use; see
## ``Implementation Details`` in the milestones file for the rationale).
##
## Idempotency contract:
##
##   * ``public.schema_migrations`` has one row per applied file, with
##     the file's sha256 content hash recorded.
##   * Files already represented in ``schema_migrations`` with a
##     matching sha are skipped silently.
##   * Files already represented but with a *different* sha cause the
##     command to fail loudly — that's drift, not a legitimate re-apply.
##   * Files not yet represented are applied in lexicographic order
##     inside a single transaction each, then their row is inserted.
##
## Dirty-state guard: if a migration's row is missing from
## ``schema_migrations`` but the artefacts that migration creates are
## already present, we refuse to advance.  Heuristic: migration 001
## creates ``design_review.runs``; migration 002 creates the
## ``design_review.start_run`` function.
##
## SHA-256 source.  Nim 2.x's stdlib only ships SHA-1 (``std/sha1``);
## a SHA-256 implementation lives in the external ``checksums`` package
## that nimble installs alongside Nim but it isn't on the importable
## path inside this repo's build environment.  Rather than add a new
## dependency we shell out to ``shasum -a 256`` (POSIX, present on
## macOS and Linux) — the same command ``db/migrate.sh`` uses, so the
## two drivers produce byte-identical digests.

import std/[algorithm, os, osproc, parseutils, strutils, streams]
import db_connector/db_postgres

import ./config

type
  InitError* = object of CatchableError

  MigrationFile* = object
    version*: int
    path*: string
    name*: string
    contentSha*: string

proc sha256File*(path: string): string =
  ## Lowercase hex sha256 of a file's bytes.  Shells out to
  ## ``shasum -a 256`` to match the digest format the bash migrator
  ## records.  Returns the digest, or raises ``InitError`` on failure.
  let exe = findExe("shasum")
  let r =
    if exe.len > 0:
      execCmdEx("shasum -a 256 " & quoteShell(path))
    else:
      execCmdEx("sha256sum " & quoteShell(path))
  if r.exitCode != 0:
    raise newException(InitError,
      "isonim-review init: sha256 of " & path & " failed: " & r.output)
  let parts = r.output.splitWhitespace()
  if parts.len == 0:
    raise newException(InitError,
      "isonim-review init: sha256 of " & path & " returned empty output")
  parts[0].toLowerAscii()

proc listMigrationFiles*(migDir: string): seq[MigrationFile] =
  ## Enumerate ``<migDir>/NNN_*.sql``.  Skips ``lib.sql`` (included via
  ## ``\i`` from inside the migrations themselves).  Returns the files
  ## sorted by their numeric version prefix.
  if not dirExists(migDir):
    raise newException(InitError,
      "isonim-review init: migrations dir not found: " & migDir)
  var files: seq[MigrationFile]
  for kind, path in walkDir(migDir):
    if kind != pcFile: continue
    let base = path.extractFilename
    if base == "lib.sql": continue
    if not base.endsWith(".sql"): continue
    if base.len < 5 or base[3] != '_': continue
    if not base[0..2].allCharsInSet({'0'..'9'}): continue
    var v: int
    discard parseInt(base[0..2], v, 0)
    files.add MigrationFile(
      version: v,
      path: path,
      name: base,
      contentSha: sha256File(path),
    )
  files.sort(proc(a, b: MigrationFile): int = cmp(a.version, b.version))
  result = files

proc ensureMigrationsTable(db: DbConn) =
  ## Bootstrap ``public.schema_migrations``.  Same shape ``db/migrate.sh``
  ## creates, so bash and Nim drivers can coexist in the wild.
  db.exec(sql"""
    CREATE TABLE IF NOT EXISTS public.schema_migrations (
      version    INT PRIMARY KEY,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      content_sha TEXT
    )
  """)

proc artefactExists(db: DbConn; version: int): bool =
  ## Did migration ``version``'s visible artefact land?  Used to detect
  ## "row deleted but schema intact" dirty state.
  case version
  of 1:
    let r = db.getValue(sql"""
      SELECT 1 FROM pg_tables
      WHERE schemaname = 'design_review' AND tablename = 'runs'""")
    return r == "1"
  of 2:
    let r = db.getValue(sql"""
      SELECT 1 FROM pg_proc p
      JOIN pg_namespace n ON p.pronamespace = n.oid
      WHERE n.nspname = 'design_review' AND p.proname = 'start_run'""")
    return r == "1"
  else:
    return false

proc artefactName(version: int): string =
  case version
  of 1: "design_review.runs"
  of 2: "design_review.start_run"
  else: "<unknown artefact for migration " & $version & ">"

proc applyMigrationFile(cfg: ReviewConfig; mig: MigrationFile) =
  ## Run the SQL file as the migrator role.  We invoke ``psql -f``
  ## rather than reading the SQL into Nim and ``exec``-ing it, because
  ## the migrations use psql meta-commands (``\i lib.sql``,
  ## ``\set ON_ERROR_STOP``) that the libpq protocol does not parse.
  ##
  ## ``-1`` wraps the whole file in a single implicit transaction —
  ## same guarantee the spec requires.
  let psql = findExe("psql")
  if psql.len == 0:
    raise newException(InitError,
      "isonim-review init: ``psql`` not on PATH; required to apply " &
      "migrations that contain ``\\i`` meta-commands")
  let args = @[
    "-h", cfg.db.host,
    "-p", $cfg.db.port,
    "-U", cfg.db.migratorUser,
    "-d", cfg.db.database,
    "-v", "ON_ERROR_STOP=1",
    "-1",
    "-f", mig.name,
  ]
  let workDir = mig.path.parentDir
  var p = startProcess(psql,
    workingDir = workDir,
    args = args,
    options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  let output = p.outputStream.readAll()
  let exitCode = p.waitForExit()
  if exitCode != 0:
    raise newException(InitError,
      "isonim-review init: psql -f " & mig.name &
      " failed (exit " & $exitCode & "):\n" & output)

proc cmdInit*(cfg: ReviewConfig; migDir: string = "";
              stdoutOut: File = stdout): int =
  ## Implements ``isonim-review init``.  Returns 0 on success, non-zero
  ## on any drift / dirty-state failure.  Prints progress to
  ## ``stdoutOut`` for the tests to assert on.
  let dir =
    if migDir.len > 0: migDir
    else: getCurrentDir() / "db" / "migrations"
  var files: seq[MigrationFile]
  try:
    files = listMigrationFiles(dir)
  except InitError as e:
    stderr.writeLine(e.msg)
    return 2
  if files.len == 0:
    stdoutOut.writeLine("isonim-review init: no migration files found in " & dir)
    return 0

  let connStr = connectionString(cfg, role = "migrator")
  var db: DbConn
  try:
    db = open("", "", "", connStr)
  except DbError as e:
    stderr.writeLine("isonim-review init: cannot connect to " & connStr &
      ": " & e.msg)
    return 3
  defer: db.close()

  try:
    ensureMigrationsTable(db)
  except DbError as e:
    stderr.writeLine("isonim-review init: cannot create schema_migrations: " & e.msg)
    return 4

  # Build a {version: (sha)} map from existing rows for quick lookup.
  var applied: seq[tuple[version: int; sha: string]]
  for row in db.fastRows(sql"""
      SELECT version, COALESCE(content_sha, '') FROM public.schema_migrations
      ORDER BY version"""):
    var v: int
    discard parseInt(row[0], v, 0)
    applied.add (v, row[1])

  proc findRecorded(v: int): int =
    for i, r in applied:
      if r.version == v: return i
    -1

  var appliedThisRun = 0
  for mig in files:
    let idx = findRecorded(mig.version)
    if idx >= 0:
      let recordedSha = applied[idx].sha
      if recordedSha.len > 0 and recordedSha != mig.contentSha:
        stderr.writeLine("isonim-review init: migration " & $mig.version &
          " content hash mismatch (was: " & recordedSha &
          ", now: " & mig.contentSha &
          ") — investigate or rebuild from empty DB")
        return 5
      stdoutOut.writeLine("[init] skip " & mig.name &
        " (version=" & $mig.version & " already applied)")
      continue
    # Dirty-state check: row missing but artefact present.
    if artefactExists(db, mig.version):
      stderr.writeLine("isonim-review init: schema state inconsistent: " &
        "migration " & $mig.version & " missing but `" &
        artefactName(mig.version) & "` exists")
      return 6
    stdoutOut.writeLine("[init] apply " & mig.name &
      " (version=" & $mig.version & ")")
    try:
      applyMigrationFile(cfg, mig)
    except InitError as e:
      stderr.writeLine(e.msg)
      return 7
    db.exec(sql"""
      INSERT INTO public.schema_migrations (version, content_sha)
      VALUES (?, ?)""", $mig.version, mig.contentSha)
    inc appliedThisRun

  if appliedThisRun == 0:
    stdoutOut.writeLine("[init] no migrations to apply")
  else:
    stdoutOut.writeLine("[init] applied " & $appliedThisRun & " migration(s)")
  return 0
