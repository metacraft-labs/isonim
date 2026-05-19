## REV-M8 — ``isonim-review layouts`` subcommand.
##
## Three sub-subcommands:
##
##   isonim-review layouts ls --brief <id> [--user <id>] [--json]
##       List layouts for the brief.  ``--user`` is optional — without
##       it the listing is workspace-scope only.
##
##   isonim-review layouts save --brief <id> --name <name>
##                              --layout <path-to-json>
##                              [--scope user|workspace]
##                              [--user <id>] [--layout-id <uuid>]
##                              [--expected-version <int>]
##       Insert or update a layout row.  ``--layout`` points at a
##       file whose content becomes the ``layout`` JSONB payload.
##
##   isonim-review layouts promote --layout-id <uuid> --actor <name>
##       Promote a user-scope layout into a new workspace-scope row.
##
## All three call the matching ``design_review.*`` routines via the
## same ``ReviewDb`` connection ``cmd_serve`` uses.  The CLI accepts
## the same ``--config``/``--migrations`` flags as the other
## subcommands so a single config file drives the entire surface.

import std/[json, os, strutils]

import db_connector/db_postgres

import isonim/editor/design_review/db as dr_db
import ./config

# ---------------------------------------------------------------------------
# Tiny SQL helpers — borrowed from api_handlers.nim.
# ---------------------------------------------------------------------------

proc escSql(s: string): string =
  s.replace("'", "''")

proc looksLikeUuid(s: string): bool =
  if s.len != 36: return false
  for i, ch in s:
    if i in [8, 13, 18, 23]:
      if ch != '-': return false
    else:
      if not (ch in {'0'..'9', 'a'..'f', 'A'..'F'}): return false
  true

proc openDb(cfg: ReviewConfig): ReviewDb =
  ## Open a connection respecting the CLI's environment overrides.
  ## ``openReviewDb(env=true)`` honours ``ISONIM_REVIEW_PG*`` exactly
  ## like ``cmd_serve``.
  result = openReviewDb(env = true)

# ---------------------------------------------------------------------------
# layouts ls
# ---------------------------------------------------------------------------

proc cmdLayoutsLs*(cfg: ReviewConfig; briefId, userId: string;
                  asJson: bool = false): int =
  if briefId.len == 0:
    stderr.writeLine("isonim-review layouts ls: --brief <id> required")
    return 2
  var db: ReviewDb
  try:
    db = openDb(cfg)
  except CatchableError as e:
    stderr.writeLine("isonim-review layouts ls: open: " & e.msg)
    return 2
  defer: db.close()
  try:
    db.asApp()
    let userLit =
      if userId.len == 0: "NULL"
      else: "'" & escSql(userId) & "'"
    let stmt = "SELECT design_review.list_layouts('" & escSql(briefId) &
               "', " & userLit & ")::text"
    let rows = db.conn.getAllRows(sql(stmt))
    var arr = newJArray()
    for row in rows:
      if row.len == 0 or row[0].len == 0: continue
      try:
        arr.add parseJson(row[0])
      except JsonParsingError:
        discard
    if asJson:
      echo $arr
    else:
      if arr.len == 0:
        echo "(no layouts)"
      else:
        echo "scope     | name             | version | layout_id"
        echo "----------+------------------+---------+-------------------------------------"
        for r in arr:
          let scope = r{"scope"}.getStr.alignLeft(9)
          let name  = r{"name"}.getStr.alignLeft(16)
          let ver   = align($(r{"version"}.getInt), 7)
          let lid   = r{"layout_id"}.getStr
          echo scope & " | " & name & " | " & ver & " | " & lid
    return 0
  except CatchableError as e:
    stderr.writeLine("isonim-review layouts ls: " & e.msg)
    return 1

# ---------------------------------------------------------------------------
# layouts save
# ---------------------------------------------------------------------------

proc cmdLayoutsSave*(cfg: ReviewConfig;
                    briefId, name, layoutPath, scope, userId,
                    layoutId: string;
                    expectedVersion: int;
                    hasExpectedVersion: bool): int =
  if briefId.len == 0:
    stderr.writeLine("isonim-review layouts save: --brief <id> required")
    return 2
  if name.len == 0:
    stderr.writeLine("isonim-review layouts save: --name <name> required")
    return 2
  if layoutPath.len == 0:
    stderr.writeLine("isonim-review layouts save: --layout <path> required")
    return 2
  if not fileExists(layoutPath):
    stderr.writeLine("isonim-review layouts save: layout file not found: " &
      layoutPath)
    return 2
  let actualScope = if scope.len == 0: "user" else: scope
  if actualScope notin ["user", "workspace"]:
    stderr.writeLine("isonim-review layouts save: --scope must be 'user' or 'workspace'")
    return 2
  if actualScope == "user" and userId.len == 0:
    stderr.writeLine("isonim-review layouts save: --user <id> required for scope=user")
    return 2
  if layoutId.len > 0 and not looksLikeUuid(layoutId):
    stderr.writeLine("isonim-review layouts save: --layout-id must be a UUID")
    return 2
  let layoutJson = readFile(layoutPath)
  try:
    discard parseJson(layoutJson)
  except JsonParsingError as e:
    stderr.writeLine("isonim-review layouts save: layout file is not valid JSON: " & e.msg)
    return 2

  var db: ReviewDb
  try:
    db = openDb(cfg)
  except CatchableError as e:
    stderr.writeLine("isonim-review layouts save: open: " & e.msg)
    return 2
  defer: db.close()
  try:
    db.asApp()
    let layoutLit = layoutJson.replace("'", "''")
    let layoutIdLit =
      if layoutId.len == 0: "NULL::uuid"
      else: "'" & escSql(layoutId) & "'::uuid"
    let ownerLit =
      if actualScope == "workspace" or userId.len == 0: "NULL"
      else: "'" & escSql(userId) & "'"
    let expectedLit =
      if hasExpectedVersion: $expectedVersion
      else: "NULL"
    let stmt = "SELECT design_review.save_gallery_layout(" &
               layoutIdLit & ", '" & escSql(briefId) & "', '" &
               escSql(actualScope) & "', " & ownerLit & ", '" &
               escSql(name) & "', '" & layoutLit & "'::jsonb, " &
               expectedLit & ")::text"
    let raw = db.conn.getValue(sql(stmt))
    if raw.len == 0:
      stderr.writeLine("isonim-review layouts save: empty response")
      return 1
    echo raw
    return 0
  except DbError as e:
    if "layout_version_conflict" in e.msg:
      stderr.writeLine("isonim-review layouts save: version conflict (stale --expected-version)")
      return 3
    stderr.writeLine("isonim-review layouts save: " & e.msg)
    return 1
  except CatchableError as e:
    stderr.writeLine("isonim-review layouts save: " & e.msg)
    return 1

# ---------------------------------------------------------------------------
# layouts promote
# ---------------------------------------------------------------------------

proc cmdLayoutsPromote*(cfg: ReviewConfig; layoutId, actor: string): int =
  if layoutId.len == 0:
    stderr.writeLine("isonim-review layouts promote: --layout-id <uuid> required")
    return 2
  if not looksLikeUuid(layoutId):
    stderr.writeLine("isonim-review layouts promote: --layout-id must be a UUID")
    return 2
  if actor.len == 0:
    stderr.writeLine("isonim-review layouts promote: --actor <name> required")
    return 2

  var db: ReviewDb
  try:
    db = openDb(cfg)
  except CatchableError as e:
    stderr.writeLine("isonim-review layouts promote: open: " & e.msg)
    return 2
  defer: db.close()
  try:
    db.asApp()
    let stmt = "SELECT design_review.promote_layout('" & escSql(layoutId) &
               "'::uuid, '" & escSql(actor) & "')::text"
    let newId = db.conn.getValue(sql(stmt))
    if newId.len == 0:
      stderr.writeLine("isonim-review layouts promote: empty response")
      return 1
    echo newId
    return 0
  except DbError as e:
    if "does not exist" in e.msg:
      stderr.writeLine("isonim-review layouts promote: layout not found")
      return 4
    if "is not scope=user" in e.msg:
      stderr.writeLine("isonim-review layouts promote: source layout is not scope=user")
      return 4
    stderr.writeLine("isonim-review layouts promote: " & e.msg)
    return 1
  except CatchableError as e:
    stderr.writeLine("isonim-review layouts promote: " & e.msg)
    return 1
