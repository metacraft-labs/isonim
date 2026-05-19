## REV-M7 — HTTP handlers for ``/api/design-review/*`` routes.
##
## Mounted by ``tools/isonim_review/cmd_serve.nim`` via the
## ``registerHandler`` extension point REV-M4 left for us.  The
## handlers translate stored-procedure calls into JSON responses the
## editor's gallery overlay can consume.
##
## Routes:
##
##   GET /api/design-review/list-history?briefId=<id>&limit=<n>&offset=<n>
##       Calls ``design_review.list_history``.  Returns a JSON array
##       of run summaries (most-recent-first).  Defaults: limit=50,
##       offset=0.
##
##   GET /api/design-review/fetch-run?runId=<uuid>
##       Calls ``design_review.fetch_run``.  Returns a JSON object
##       with the assembled run + its captures + reports.
##
##   GET /api/design-review/get-capture-png?id=<capture_id>
##       Looks up the capture row, reads the PNG bytes from the
##       configured capture store, and streams them with
##       ``Content-Type: image/png`` and ``Cache-Control: immutable,
##       max-age=31536000`` (content-addressed → infinite cache).
##
##   GET /api/design-review/brief-has-history?briefId=<id>
##       Returns ``{hasHistory: bool, runCount: int}`` — the cheap
##       probe the editor uses to decide whether to surface the
##       ``🕘`` button.
##
## Error contract:
##   * 400 with ``{"error": "..."}`` when a required query param is
##     missing or malformed.
##   * 404 when the requested capture row or run does not exist (no
##     body leak — the message is generic).
##   * 500 with a generic ``{"error": "internal_error"}`` on any DB
##     failure.  The full message is logged to stderr; we never
##     surface raw SQL to the caller.

import std/[asyncdispatch, asynchttpserver, json, os, strutils, tables, uri]

import db_connector/db_postgres

import ./capture_store
import ./db

# ---------------------------------------------------------------------------
# Query-string parsing — ``asynchttpserver`` hands us the raw query as
# part of ``req.url`` (an ``stdlib`` ``Uri``).  We do not depend on
# ``decodeQuery`` ordering here: every endpoint reads named params,
# nothing positional.
# ---------------------------------------------------------------------------

proc parseQueryParams*(query: string): Table[string, string] =
  ## Parses ``a=b&c=d`` into a string→string table.  Empty values are
  ## preserved as empty strings so the handlers can distinguish "absent"
  ## from "empty".  Percent decoding via stdlib's ``decodeUrl``.
  result = initTable[string, string]()
  if query.len == 0:
    return
  for kv in query.split('&'):
    if kv.len == 0: continue
    let eq = kv.find('=')
    if eq < 0:
      result[decodeUrl(kv)] = ""
    else:
      result[decodeUrl(kv[0 ..< eq])] = decodeUrl(kv[eq + 1 .. ^1])

proc queryFor*(req: Request): Table[string, string] =
  parseQueryParams(req.url.query)

# ---------------------------------------------------------------------------
# Response helpers — uniform headers so the gallery UI's fetch calls
# don't have to sniff the bytes.
# ---------------------------------------------------------------------------

proc respondJson*(req: Request; code: HttpCode; body: JsonNode) {.async, gcsafe.} =
  let headers = newHttpHeaders([
    ("Content-Type", "application/json"),
    ("Cache-Control", "no-store"),
    ("Access-Control-Allow-Origin", "*"),
  ])
  await req.respond(code, $body, headers)

proc respondError*(req: Request; code: HttpCode; message: string) {.async, gcsafe.} =
  let body = %* {"error": message}
  await respondJson(req, code, body)

proc respondPng*(req: Request; pngBody: string) {.async, gcsafe.} =
  ## Stream PNG bytes with the immutable cache header.  Content-
  ## addressed → safe to cache forever; ``max-age=31536000`` is the
  ## one-year value the gallery overlay relies on for tile thumbnails.
  let headers = newHttpHeaders([
    ("Content-Type", "image/png"),
    ("Cache-Control", "immutable, max-age=31536000"),
    ("Content-Length", $pngBody.len),
    ("Access-Control-Allow-Origin", "*"),
  ])
  await req.respond(Http200, pngBody, headers)

# ---------------------------------------------------------------------------
# SQL helpers.  Numeric inputs are parsed in Nim before interpolation
# so the prepared/escaped path stays SQL-injection-free; string inputs
# (briefId, runId, captureId) are validated as UUID syntax or escaped
# via the standard ``''`` doubling.
# ---------------------------------------------------------------------------

proc escSql(s: string): string =
  ## Defence-in-depth ``''`` escape for any string that lands inside a
  ## single-quoted literal.  The DB-side routines validate non-empty
  ## input themselves; this just keeps malicious quotes from breaking
  ## out of the literal.
  s.replace("'", "''")

proc looksLikeUuid(s: string): bool =
  if s.len != 36: return false
  for i, ch in s:
    if i in [8, 13, 18, 23]:
      if ch != '-': return false
    else:
      if not (ch in {'0'..'9', 'a'..'f', 'A'..'F'}): return false
  true

proc parseIntDefault(s: string; default, minVal, maxVal: int): int =
  if s.len == 0: return default
  try:
    let v = parseInt(s)
    if v < minVal: return minVal
    if v > maxVal: return maxVal
    v
  except ValueError:
    default

# ---------------------------------------------------------------------------
# Handler implementations.  Each one takes a ``ReviewDb`` plus the
# request — they're closed over by the ``mountDesignReviewRoutes``
# wrapper below before they reach ``registerHandler``.
# ---------------------------------------------------------------------------

proc listHistory*(db: ReviewDb; req: Request) {.async, gcsafe.} =
  let q = queryFor(req)
  let briefId = q.getOrDefault("briefId")
  if briefId.len == 0:
    await respondError(req, Http400, "briefId required")
    return
  let limit = parseIntDefault(q.getOrDefault("limit"), 50, 0, 1000)
  let offset = parseIntDefault(q.getOrDefault("offset"), 0, 0, high(int) div 2)

  try:
    db.asApp()
    let stmt = "SELECT design_review.list_history('" & escSql(briefId) &
               "', " & $limit & ", " & $offset & ")::text"
    let rows = db.conn.getAllRows(sql(stmt))
    var arr = newJArray()
    for row in rows:
      if row.len == 0 or row[0].len == 0:
        continue
      try:
        arr.add parseJson(row[0])
      except JsonParsingError:
        # Skip malformed JSON rather than 500ing — the DB shouldn't
        # ever return a non-JSONB SETOF row here, but if it did, one
        # bad row shouldn't poison the whole list.
        discard
    await respondJson(req, Http200, arr)
  except DbError as e:
    stderr.writeLine("api_handlers.listHistory: DB error: " & e.msg)
    await respondError(req, Http500, "internal_error")
  except CatchableError as e:
    stderr.writeLine("api_handlers.listHistory: " & e.msg)
    await respondError(req, Http500, "internal_error")

proc fetchRun*(db: ReviewDb; req: Request) {.async, gcsafe.} =
  let q = queryFor(req)
  let runId = q.getOrDefault("runId")
  if runId.len == 0:
    await respondError(req, Http400, "runId required")
    return
  if not looksLikeUuid(runId):
    await respondError(req, Http400, "runId must be a UUID")
    return

  try:
    db.asApp()
    let stmt = "SELECT design_review.fetch_run('" & escSql(runId) & "'::uuid)::text"
    let raw =
      try: db.conn.getValue(sql(stmt))
      except DbError as e:
        if "does not exist" in e.msg:
          await respondError(req, Http404, "run not found")
          return
        raise
    if raw.len == 0:
      await respondError(req, Http404, "run not found")
      return
    let body =
      try: parseJson(raw)
      except JsonParsingError:
        await respondError(req, Http500, "internal_error")
        return
    await respondJson(req, Http200, body)
  except DbError as e:
    stderr.writeLine("api_handlers.fetchRun: DB error: " & e.msg)
    await respondError(req, Http500, "internal_error")
  except CatchableError as e:
    stderr.writeLine("api_handlers.fetchRun: " & e.msg)
    await respondError(req, Http500, "internal_error")

proc getCapturePng*(db: ReviewDb; store: CaptureStore;
                    req: Request) {.async, gcsafe.} =
  ## We look up the capture row through a small SECURITY DEFINER
  ## helper read on the ``captures`` table — but the design_review
  ## routines do not expose a per-capture fetch endpoint.  Rather
  ## than add a new routine in this milestone, we go through
  ## ``fetch_run`` (which is the same path REV-M6 uses to look up
  ## per-run brief ids without a direct SELECT grant) by way of a
  ## small app-role probe that JOINs the parent run.
  let q = queryFor(req)
  let captureId = q.getOrDefault("id")
  if captureId.len == 0:
    await respondError(req, Http400, "id required")
    return
  if not looksLikeUuid(captureId):
    await respondError(req, Http400, "id must be a UUID")
    return

  try:
    db.asApp()
    # ``fetch_capture`` is the small SECURITY DEFINER routine REV-M7
    # added in migration 003.  It returns the capture row keyed by
    # primary key so we don't have to scan the parent run's capture
    # set just to translate ``capture_id`` → ``png_sha256``.
    let stmt = "SELECT design_review.fetch_capture('" &
               escSql(captureId) & "'::uuid)::text"
    let raw =
      try: db.conn.getValue(sql(stmt))
      except DbError as e:
        if "does not exist" in e.msg:
          await respondError(req, Http404, "capture not found")
          return
        stderr.writeLine("api_handlers.getCapturePng: fetch_capture: " & e.msg)
        await respondError(req, Http500, "internal_error")
        return
    if raw.len == 0:
      await respondError(req, Http404, "capture not found")
      return
    let row =
      try: parseJson(raw)
      except JsonParsingError:
        await respondError(req, Http500, "internal_error")
        return
    var sha = ""
    var pngPath = ""
    if "png_sha256" in row: sha = row["png_sha256"].getStr
    if "png_path" in row: pngPath = row["png_path"].getStr
    if sha.len == 0 and pngPath.len == 0:
      await respondError(req, Http404, "capture not found")
      return

    var body = ""
    # Try the canonical store path first (sha → store/aa/<sha>.png).
    if store != nil and sha.len > 0:
      let storePath = store.pathFor(sha)
      if fileExists(storePath):
        body = readFile(storePath)
    # Fall back to the stored png_path if the store handed back nothing
    # (e.g. tests that pre-populated arbitrary paths instead of going
    # through ``put``).
    if body.len == 0 and pngPath.len > 0 and fileExists(pngPath):
      body = readFile(pngPath)

    if body.len == 0:
      await respondError(req, Http404, "capture bytes unavailable")
      return
    await respondPng(req, body)
  except CatchableError as e:
    stderr.writeLine("api_handlers.getCapturePng: " & e.msg)
    await respondError(req, Http500, "internal_error")

proc briefHasHistory*(db: ReviewDb; req: Request) {.async, gcsafe.} =
  let q = queryFor(req)
  let briefId = q.getOrDefault("briefId")
  if briefId.len == 0:
    await respondError(req, Http400, "briefId required")
    return

  try:
    db.asApp()
    # ``list_history`` with a generous limit gives us the exact count
    # in one routine call.  For briefs with >1000 runs we'll under-
    # report, but the UI only needs the boolean — exact counts beyond
    # 1000 aren't relevant to the ``🕘`` button decision.
    let stmt = "SELECT design_review.list_history('" & escSql(briefId) &
               "', 1000, 0)::text"
    let rows = db.conn.getAllRows(sql(stmt))
    var count = 0
    for row in rows:
      if row.len > 0 and row[0].len > 0:
        inc count
    let body = %* {
      "hasHistory": count > 0,
      "runCount": count,
    }
    await respondJson(req, Http200, body)
  except DbError as e:
    stderr.writeLine("api_handlers.briefHasHistory: DB error: " & e.msg)
    await respondError(req, Http500, "internal_error")
  except CatchableError as e:
    stderr.writeLine("api_handlers.briefHasHistory: " & e.msg)
    await respondError(req, Http500, "internal_error")

# ---------------------------------------------------------------------------
# Route registration entrypoint.  ``cmd_serve.nim`` calls this after
# building its ``ReviewServer`` but before ``runReviewServer`` blocks
# on the loop.  The DB connection + store are owned by the server and
# live for its lifetime.
# ---------------------------------------------------------------------------

type
  HandlerProcRaw* = proc (req: Request): Future[void] {.async, gcsafe.}

proc makeListHistory*(db: ReviewDb): HandlerProcRaw =
  let capturedDb = db
  result = proc (req: Request): Future[void] {.async, gcsafe.} =
    await listHistory(capturedDb, req)

proc makeFetchRun*(db: ReviewDb): HandlerProcRaw =
  let capturedDb = db
  result = proc (req: Request): Future[void] {.async, gcsafe.} =
    await fetchRun(capturedDb, req)

proc makeGetCapturePng*(db: ReviewDb; store: CaptureStore): HandlerProcRaw =
  let capturedDb = db
  let capturedStore = store
  result = proc (req: Request): Future[void] {.async, gcsafe.} =
    await getCapturePng(capturedDb, capturedStore, req)

proc makeBriefHasHistory*(db: ReviewDb): HandlerProcRaw =
  let capturedDb = db
  result = proc (req: Request): Future[void] {.async, gcsafe.} =
    await briefHasHistory(capturedDb, req)
