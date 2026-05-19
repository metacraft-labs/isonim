## REV-M8 — HTTP handlers for the layout-persistence routes.
##
## REV-M7 landed ``list-history``, ``fetch-run``, ``get-capture-png``
## and ``brief-has-history``.  REV-M8 adds three more endpoints — the
## layout persistence surface the gallery overlay (REV-M7's
## ``gallery_overlay.nim``) save / load / promote path needs:
##
##   POST /api/design-review/save-layout
##     Body: {briefId, scope, ownerUserId, name, layout, expectedVersion,
##            layoutId? (optional — null/absent means INSERT)}
##     → Calls ``design_review.save_gallery_layout``.  On success
##       responds with the layout row JSON returned by the routine
##       (layout_id, brief_id, scope, owner_user_id, name, layout,
##       version).  On the optimistic-concurrency conflict the routine
##       raises ``SQLSTATE D5101 / layout_version_conflict``: we
##       translate to ``409`` with
##       ``{error: "layout_version_conflict", current: <current row>}``
##       so the editor can pop the resolution dialog.
##
##   POST /api/design-review/promote-layout
##     Body: {layoutId, actor}
##     → Calls ``design_review.promote_layout``.  Returns the new
##       workspace-scope row (we fetch it via ``list_layouts`` so the
##       UI can swap to it directly without a follow-up request).
##
##   GET /api/design-review/list-layouts?briefId=<id>&userId=<id>
##     → Calls ``design_review.list_layouts``.  Returns a JSON array.
##       ``userId`` may be empty to list only workspace-scope rows.
##
## Error / response contract mirrors ``api_handlers.nim``:
##   * 400 for missing / malformed required params.
##   * 404 for "layout not found" (e.g. promote_layout on an unknown id).
##   * 409 for ``layout_version_conflict`` (with the current row body).
##   * 500 generic ``{"error":"internal_error"}`` on any other DB failure
##     — stderr gets the raw message; the wire never sees SQL.

import std/[asyncdispatch, asynchttpserver, json, strutils, tables]

import db_connector/db_postgres

import ./api_handlers
import ./db

# ---------------------------------------------------------------------------
# Body parsing.  ``asynchttpserver`` hands us ``req.body`` as a string;
# every POST endpoint here takes JSON.  Empty / malformed payloads come
# back as ``400 invalid_json``.
# ---------------------------------------------------------------------------

proc parseBody(req: Request): JsonNode =
  if req.body.len == 0:
    return newJNull()
  try:
    result = parseJson(req.body)
  except JsonParsingError:
    result = nil

proc fieldStr(node: JsonNode; key: string): string =
  if node == nil or node.kind != JObject: return ""
  if not node.hasKey(key): return ""
  let v = node[key]
  case v.kind
  of JString: v.getStr
  of JNull:   ""
  else:       ""

proc fieldIntOpt(node: JsonNode; key: string): tuple[present: bool; value: int] =
  if node == nil or node.kind != JObject:
    return (false, 0)
  if not node.hasKey(key): return (false, 0)
  let v = node[key]
  case v.kind
  of JInt:  (true, v.getInt)
  of JNull: (false, 0)
  else:     (false, 0)

proc fieldJson(node: JsonNode; key: string): JsonNode =
  if node == nil or node.kind != JObject: return nil
  if not node.hasKey(key): return nil
  node[key]

# ---------------------------------------------------------------------------
# SQL escape — same defence-in-depth pattern api_handlers.nim uses.  The
# stored routines validate every parameter; this just keeps malicious
# quotes from breaking out of literal strings before they reach plpgsql.
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

# ---------------------------------------------------------------------------
# Conflict-current-row lookup.  When ``save_gallery_layout`` raises the
# version-conflict SQLSTATE we want to return the *current* row so the
# editor's conflict dialog can show the user what's now live.  We pull
# it through ``list_layouts`` with a generous filter then narrow to the
# layout_id; this avoids granting a per-layout SELECT to the app role.
# ---------------------------------------------------------------------------

proc fetchCurrentLayoutRow(db: ReviewDb; layoutId: string): JsonNode =
  ## Resolve one row by primary key via ``design_review.fetch_layout``
  ## (migration 004).  The SECURITY DEFINER routine is the only path
  ## that yields a single layout by id without granting the app role
  ## direct SELECT on the base table.  Returns ``JNull`` when the row
  ## doesn't exist or any DB error fires — the conflict path falls back
  ## to ``current: null`` and the editor still 409s safely.
  result = newJNull()
  if layoutId.len == 0: return
  try:
    db.asApp()
    let stmt = "SELECT design_review.fetch_layout('" & escSql(layoutId) &
               "'::uuid)::text"
    let raw =
      try: db.conn.getValue(sql(stmt))
      except DbError: ""
    if raw.len == 0: return
    try:
      result = parseJson(raw)
    except JsonParsingError:
      discard
  except CatchableError:
    discard

# ---------------------------------------------------------------------------
# Handler implementations.
# ---------------------------------------------------------------------------

proc saveLayout*(db: ReviewDb; req: Request) {.async, gcsafe.} =
  if req.reqMethod != HttpPost:
    await respondError(req, Http405, "method_not_allowed")
    return
  let body = parseBody(req)
  if body == nil:
    await respondError(req, Http400, "invalid_json")
    return

  let briefId = fieldStr(body, "briefId")
  let scope   = fieldStr(body, "scope")
  let ownerId = fieldStr(body, "ownerUserId")
  let name    = fieldStr(body, "name")
  let layout  = fieldJson(body, "layout")
  let expV    = fieldIntOpt(body, "expectedVersion")
  let layoutId = fieldStr(body, "layoutId")

  if briefId.len == 0:
    await respondError(req, Http400, "briefId required")
    return
  if scope != "user" and scope != "workspace":
    await respondError(req, Http400, "scope must be 'user' or 'workspace'")
    return
  if name.len == 0:
    await respondError(req, Http400, "name required")
    return
  if layout == nil:
    await respondError(req, Http400, "layout required")
    return
  if scope == "user" and ownerId.len == 0:
    await respondError(req, Http400, "ownerUserId required for user scope")
    return
  if layoutId.len > 0 and not looksLikeUuid(layoutId):
    await respondError(req, Http400, "layoutId must be a UUID")
    return

  let layoutLit = ($layout).replace("'", "''")
  let layoutIdLit =
    if layoutId.len == 0: "NULL::uuid"
    else: "'" & escSql(layoutId) & "'::uuid"
  let ownerLit =
    if scope == "workspace" or ownerId.len == 0: "NULL"
    else: "'" & escSql(ownerId) & "'"
  let expectedLit =
    if expV.present: $expV.value
    else: "NULL"

  let stmt = "SELECT design_review.save_gallery_layout(" &
             layoutIdLit & ", '" & escSql(briefId) & "', '" &
             escSql(scope) & "', " & ownerLit & ", '" & escSql(name) &
             "', '" & layoutLit & "'::jsonb, " & expectedLit & ")::text"
  try:
    db.asApp()
    let raw = db.conn.getValue(sql(stmt))
    if raw.len == 0:
      await respondError(req, Http500, "internal_error")
      return
    let resp =
      try: parseJson(raw)
      except JsonParsingError:
        await respondError(req, Http500, "internal_error")
        return
    await respondJson(req, Http200, resp)
  except DbError as e:
    let msg = e.msg
    if "layout_version_conflict" in msg:
      # Stale ``expectedVersion`` — surface the current row so the UI
      # can show a useful "reload-or-overwrite?" dialog.
      var current = newJNull()
      if layoutId.len > 0:
        current = fetchCurrentLayoutRow(db, layoutId)
      let body = %* {
        "error": "layout_version_conflict",
        "current": current,
      }
      await respondJson(req, Http409, body)
      return
    stderr.writeLine("api_handlers_layouts.saveLayout: DB error: " & msg)
    await respondError(req, Http500, "internal_error")
  except CatchableError as e:
    stderr.writeLine("api_handlers_layouts.saveLayout: " & e.msg)
    await respondError(req, Http500, "internal_error")

proc promoteLayout*(db: ReviewDb; req: Request) {.async, gcsafe.} =
  if req.reqMethod != HttpPost:
    await respondError(req, Http405, "method_not_allowed")
    return
  let body = parseBody(req)
  if body == nil:
    await respondError(req, Http400, "invalid_json")
    return

  let layoutId = fieldStr(body, "layoutId")
  let actor    = fieldStr(body, "actor")

  if layoutId.len == 0:
    await respondError(req, Http400, "layoutId required")
    return
  if not looksLikeUuid(layoutId):
    await respondError(req, Http400, "layoutId must be a UUID")
    return
  if actor.len == 0:
    await respondError(req, Http400, "actor required")
    return

  try:
    db.asApp()
    let stmt = "SELECT design_review.promote_layout('" & escSql(layoutId) &
               "'::uuid, '" & escSql(actor) & "')::text"
    let newId = db.conn.getValue(sql(stmt))
    if newId.len == 0:
      await respondError(req, Http500, "internal_error")
      return
    # Fetch the freshly-inserted workspace row so the UI can render it
    # without a follow-up request.  ``fetch_layout`` (migration 004) is
    # the only app-role-visible single-row read of the table.
    let newRow = fetchCurrentLayoutRow(db, newId)
    let briefId =
      if newRow.kind == JObject and newRow.hasKey("brief_id"):
        newRow["brief_id"].getStr
      else: ""
    let body = %* {
      "layout_id": newId,
      "brief_id": briefId,
      "current": newRow,
    }
    await respondJson(req, Http200, body)
  except DbError as e:
    let msg = e.msg
    if "does not exist" in msg:
      await respondError(req, Http404, "layout not found")
      return
    if "is not scope=user" in msg:
      await respondError(req, Http400, "layout is not scope=user")
      return
    stderr.writeLine("api_handlers_layouts.promoteLayout: DB error: " & msg)
    await respondError(req, Http500, "internal_error")
  except CatchableError as e:
    stderr.writeLine("api_handlers_layouts.promoteLayout: " & e.msg)
    await respondError(req, Http500, "internal_error")

proc listLayouts*(db: ReviewDb; req: Request) {.async, gcsafe.} =
  if req.reqMethod != HttpGet:
    await respondError(req, Http405, "method_not_allowed")
    return
  let q = queryFor(req)
  let briefId = q.getOrDefault("briefId")
  let userId  = q.getOrDefault("userId")
  if briefId.len == 0:
    await respondError(req, Http400, "briefId required")
    return

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
    await respondJson(req, Http200, arr)
  except DbError as e:
    stderr.writeLine("api_handlers_layouts.listLayouts: DB error: " & e.msg)
    await respondError(req, Http500, "internal_error")
  except CatchableError as e:
    stderr.writeLine("api_handlers_layouts.listLayouts: " & e.msg)
    await respondError(req, Http500, "internal_error")

# ---------------------------------------------------------------------------
# Route-factory wrappers — closure over ``db`` so cmd_serve.nim can wire
# them into ``ReviewServer.registerHandler``.
# ---------------------------------------------------------------------------

proc makeSaveLayout*(db: ReviewDb): HandlerProcRaw =
  let capturedDb = db
  result = proc (req: Request): Future[void] {.async, gcsafe.} =
    await saveLayout(capturedDb, req)

proc makePromoteLayout*(db: ReviewDb): HandlerProcRaw =
  let capturedDb = db
  result = proc (req: Request): Future[void] {.async, gcsafe.} =
    await promoteLayout(capturedDb, req)

proc makeListLayouts*(db: ReviewDb): HandlerProcRaw =
  let capturedDb = db
  result = proc (req: Request): Future[void] {.async, gcsafe.} =
    await listLayouts(capturedDb, req)
