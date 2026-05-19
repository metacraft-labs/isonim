## REV-M4 — ``isonim-review serve`` subcommand.
##
## Long-running HTTP daemon that REV-M7 / REV-M8 will mount the
## ``/api/design-review/*`` endpoints on.  At this milestone the
## daemon only needs:
##
##   * ``GET /health`` — returns the same JSON the ``db-health --json``
##     subcommand emits, with status 200 if every DB probe is green
##     and status 503 otherwise (caller can still parse the JSON to
##     see which probe failed).
##   * any other ``/api/design-review/*`` route returns 501 with a
##     pointer to the milestone that will land it.
##
## Implementation choice — ``std/asynchttpserver`` over ``httpbeast``:
## the milestone budget is "no new deps unless we have to" and a stub
## daemon doesn't stress the async runtime.  REV-M7 can switch
## transports without changing the route registration API.
##
## Extensibility: ``registerHandler`` lets REV-M7 wire its routes
## against the same server before ``runReviewServer`` blocks.  The
## handler signature mirrors ``asynchttpserver``'s default — bare
## request → response.
##
## Graceful shutdown: ``handleSignals`` traps SIGINT and SIGTERM, sets
## ``server.stopRequested``, and ``runReviewServer`` exits its loop on
## the next request boundary.  No fancy connection drain — this is a
## stub.

import std/[asyncdispatch, asynchttpserver, json, os, posix, strutils, tables]

import ./config
import ./cmd_db_health

type
  HandlerProc* = proc (req: Request): Future[void] {.async, gcsafe.}

  ReviewServer* = ref object
    cfg*: ReviewConfig
    migDir*: string
    server*: AsyncHttpServer
    handlers*: OrderedTable[string, HandlerProc]
    bindAddr*: string
    port*: int
    stopRequested*: bool
    onLifecycle*: proc(message: string) {.gcsafe.}

# ----- Lifecycle signal handling -------------------------------------------

var GlobalStopFlag {.threadvar.}: bool
  ## The signal handler can't reach into the ReviewServer instance
  ## directly (signal callbacks are C-level, no closure context), so
  ## we route the flag through a threadvar.  ``runReviewServer`` polls
  ## it after every accepted request and propagates the value back
  ## onto ``server.stopRequested`` before deciding to bail.

proc onTerm(sig: cint) {.noconv.} =
  GlobalStopFlag = true

proc installSignalHandlers*() =
  ## Trap SIGTERM and SIGINT so a Ctrl-C or ``kill -TERM`` from the
  ## supervisor brings the daemon down cleanly.
  var sa: Sigaction
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = 0
  sa.sa_handler = onTerm
  discard sigaction(SIGTERM, sa, nil)
  discard sigaction(SIGINT, sa, nil)

# ----- Public construction API ---------------------------------------------

proc newReviewServer*(cfg: ReviewConfig; migDir: string = ""): ReviewServer =
  ## Build (do not start) a server bound to the configured address.
  ## REV-M7 will call ``registerHandler`` between ``new`` and ``run``
  ## to wire its routes in.
  let dir =
    if migDir.len > 0: migDir
    else: getCurrentDir() / "db" / "migrations"
  result = ReviewServer(
    cfg: cfg,
    migDir: dir,
    server: newAsyncHttpServer(),
    handlers: initOrderedTable[string, HandlerProc](),
    bindAddr: cfg.server.bindAddr,
    port: cfg.server.port,
    stopRequested: false,
    onLifecycle: nil,
  )

proc registerHandler*(srv: ReviewServer; route: string; handler: HandlerProc) =
  ## Mount ``handler`` at the *exact* path ``route``.  REV-M7 will use
  ## this to attach ``GET /api/design-review/list-history`` etc.  We
  ## deliberately match on exact paths — query strings are stripped
  ## before lookup so ``/health?ts=...`` still resolves.
  srv.handlers[route] = handler

# ----- Built-in handlers ---------------------------------------------------

proc respond(req: Request; code: HttpCode;
              body: string; contentType = "application/json") {.async, gcsafe.} =
  ## Wrapper around ``respond`` that sets ``Content-Type`` uniformly so
  ## the gallery UI's fetch calls don't have to sniff the bytes.
  let headers = newHttpHeaders([
    ("Content-Type", contentType),
    ("Cache-Control", "no-store"),
  ])
  await req.respond(code, body, headers)

proc healthHandler(srv: ReviewServer; req: Request) {.async, gcsafe.} =
  let rep = collectHealth(srv.cfg, srv.migDir)
  let body = renderJson(rep)
  let code = if allGreen(rep): Http200 else: Http503
  await respond(req, code, body)

proc notImplementedHandler(req: Request) {.async, gcsafe.} =
  let path = req.url.path
  let body = $(%* {
    "error": "not_implemented",
    "path": path,
    "hint": "REV-M7/REV-M8 will populate the /api/design-review/* routes",
  })
  await respond(req, Http501, body)

proc notFoundHandler(req: Request) {.async, gcsafe.} =
  let body = $(%* {
    "error": "not_found",
    "path": req.url.path,
  })
  await respond(req, Http404, body)

# ----- Request dispatch ----------------------------------------------------

proc stripQuery(path: string): string =
  let q = path.find('?')
  if q < 0: path else: path[0 ..< q]

proc dispatch(srv: ReviewServer; req: Request) {.async, gcsafe.} =
  let path = stripQuery(req.url.path)
  if path == "/health":
    await healthHandler(srv, req)
    return
  if srv.handlers.hasKey(path):
    await srv.handlers[path](req)
    return
  if path.startsWith("/api/design-review/"):
    await notImplementedHandler(req)
    return
  await notFoundHandler(req)

# ----- Run loop ------------------------------------------------------------

proc runReviewServer*(srv: ReviewServer) =
  ## Start the server and block until SIGTERM / SIGINT.  This is the
  ## entrypoint invoked from the ``serve`` subcommand.
  installSignalHandlers()
  if srv.onLifecycle != nil:
    srv.onLifecycle("isonim-review serve: listening on http://" &
      srv.bindAddr & ":" & $srv.port)
  else:
    stderr.writeLine("isonim-review serve: listening on http://" &
      srv.bindAddr & ":" & $srv.port)

  proc cb(req: Request) {.async, gcsafe.} =
    try:
      await dispatch(srv, req)
    except CatchableError as e:
      stderr.writeLine("isonim-review serve: handler error on " &
        req.url.path & ": " & e.msg)
      try:
        await respond(req, Http500, $(%* {"error": e.msg}))
      except CatchableError:
        discard

  asyncCheck srv.server.serve(Port(srv.port), cb, address = srv.bindAddr)

  # Poll the global stop flag on the same async loop the server runs
  # on.  We don't block on accept() so SIGTERM gets serviced within
  # one poll quantum.
  while not srv.stopRequested:
    if GlobalStopFlag:
      srv.stopRequested = true
      break
    try:
      poll(50)
    except ValueError:
      # ``poll`` raises when the dispatcher has no work; sleep briefly
      # so we don't busy-loop while the server is between requests.
      sleep(50)
  srv.server.close()
  if srv.onLifecycle != nil:
    srv.onLifecycle("isonim-review serve: exiting cleanly")
  else:
    stderr.writeLine("isonim-review serve: exiting cleanly")

proc cmdServe*(cfg: ReviewConfig; migDir: string = ""): int =
  ## CLI entrypoint.  Returns 0 on a clean shutdown.
  let srv = newReviewServer(cfg, migDir)
  try:
    runReviewServer(srv)
    return 0
  except OSError as e:
    stderr.writeLine("isonim-review serve: bind/listen failed: " & e.msg)
    return 2
