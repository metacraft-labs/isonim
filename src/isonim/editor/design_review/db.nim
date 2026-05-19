## REV-M3 — thin ``std/db_postgres`` wrapper for the design-review database.
##
## Why a wrapper at all: keeps the rest of the codebase decoupled from the
## stdlib ``DbConn`` type, so a future swap to ``ndb/postgres`` or another
## driver doesn't ripple through every caller.  Also centralises connection
## string construction and the role-switch idiom.
##
## Connection-string resolution:
##   1. ``$ISONIM_REVIEW_DB`` if set (any libpq-compatible URI).
##   2. Otherwise constructed from ``$ISONIM_REVIEW_PGHOST``,
##      ``$ISONIM_REVIEW_PGPORT`` (default 5533), and the literal database
##      ``isonim_design_review``.  The default form matches the dev cluster
##      defined in ``isonim/process-compose.yaml`` so a developer running
##      ``just dev-pg-start`` can immediately ``openReviewDb()`` in code.
##
## Role helpers ``asApp`` / ``asMigrator`` issue ``SET ROLE`` against the
## current connection so the same ``DbConn`` can hop between the two roles
## inside tests without paying the connect cost twice.

## NOTE on the Postgres client choice: REV-M3 originally specified
## ``std/db_postgres`` (sync, stdlib).  Nim 2.x relocated that module to
## the external ``db_connector`` package, and the ``nimble install
## db_connector`` flow currently segfaults on darwin under the dev
## environment shipped with this repo.  We therefore vendor the upstream
## ``db_connector`` source tree at ``isonim/vendor/db_connector/`` and
## import ``db_connector/db_postgres`` here — semantically identical to
## the deprecated stdlib import, and on the same source line if Nim ever
## re-merges it back into stdlib.

import db_connector/db_postgres
import std/[os, strutils]

type
  ReviewDb* = ref object
    conn*: DbConn

const
  DefaultPort = 5533
  DefaultDatabase = "isonim_design_review"

proc resolveConnectionString*(env: bool = true): string =
  ## Resolves the connection URI from the environment.  Exposed so tests
  ## and the process-compose harness can preview / log it before
  ## opening a connection.
  if env:
    let explicit = getEnv("ISONIM_REVIEW_DB")
    if explicit.len > 0:
      return explicit
  let host = (if env: getEnv("ISONIM_REVIEW_PGHOST") else: "")
  let hostStr = if host.len > 0: host else: "127.0.0.1"
  var port = DefaultPort
  if env:
    let pstr = getEnv("ISONIM_REVIEW_PGPORT")
    if pstr.len > 0:
      try: port = parseInt(pstr)
      except ValueError: discard
  result = "postgres://" & hostStr & ":" & $port & "/" & DefaultDatabase

proc openReviewDb*(env: bool = true): ReviewDb =
  ## Opens a connection.  Reads ``$ISONIM_REVIEW_DB`` first; otherwise
  ## constructs ``postgres://127.0.0.1:5533/isonim_design_review`` (or
  ## overridden via ``$ISONIM_REVIEW_PGHOST`` / ``$ISONIM_REVIEW_PGPORT``).
  ##
  ## The connection inherits whatever user / password is in the URI, or
  ## (when missing) defaults to the OS user under ``trust`` auth — which
  ## is how the userspace dev cluster is set up.
  let connStr = resolveConnectionString(env)
  let conn = open("", "", "", connStr)
  result = ReviewDb(conn: conn)

proc setRole*(db: ReviewDb; role: string): ReviewDb {.discardable.} =
  ## ``SET ROLE`` is idempotent — Postgres is happy to switch the role
  ## of an existing session repeatedly.  We quote the role name
  ## manually since ``db_postgres`` parameters apply only to DML.
  if role.len == 0:
    raise newException(ValueError, "setRole: role must be non-empty")
  # Reject anything that isn't a bareword identifier.  Defence-in-depth
  # against ROLE-string injection even though the only call sites pass
  # literals.
  for ch in role:
    if not (ch in {'a'..'z', 'A'..'Z', '0'..'9', '_'}):
      raise newException(ValueError,
        "setRole: role contains invalid character: " & $ch)
  db.conn.exec(sql("SET ROLE " & role))
  result = db

proc asApp*(db: ReviewDb): ReviewDb {.discardable.} =
  ## Sets ROLE design_review_app.  Idempotent.
  setRole(db, "design_review_app")

proc asMigrator*(db: ReviewDb): ReviewDb {.discardable.} =
  ## Sets ROLE design_review_migrator.  Idempotent.
  setRole(db, "design_review_migrator")

proc resetRole*(db: ReviewDb): ReviewDb {.discardable.} =
  ## ``RESET ROLE`` — useful when a test wants to switch back to the
  ## original session role after probing app-role behaviour.
  db.conn.exec(sql("RESET ROLE"))
  result = db

proc close*(db: ReviewDb) =
  if db != nil and db.conn != nil:
    db.conn.close()
