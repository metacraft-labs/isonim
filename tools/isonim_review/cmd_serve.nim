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

import std/[asyncdispatch, asynchttpserver, json, os, posix, strutils,
            tables, times]

import nim_agents

import ./config
import ./cmd_db_health

import isonim/editor/design_review/agent_routes
import isonim/editor/design_review/api_handlers
import isonim/editor/design_review/api_handlers_briefs
import isonim/editor/design_review/api_handlers_layouts
import isonim/editor/design_review/campaign_routes
import isonim/editor/design_review/capture_store
import isonim/editor/design_review/db as dr_db
import isonim/editor/design_review/log_setup

logScope:
  topics = "daemon"

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
    agentRegistry*: AgentRegistry
    campaignRegistry*: CampaignRegistry

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
  ##
  ## Phase C — the ACP backend kind is derived from ``[agent].backend``
  ## (validated by :proc:`loadConfig`) so the registry knows which
  ## stdio server to spawn when a session is requested.
  let dir =
    if migDir.len > 0: migDir
    else: getCurrentDir() / "db" / "migrations"
  let backend = agentBackendKind(cfg)
  # Follow-up 2 — per-backend model selection.  Compose the daemon's
  # ``[agent].extra_args`` (legacy, free-form) with the per-backend
  # model-flag tail returned by :proc:`codexExtraArgs` /
  # :proc:`claudeExtraArgs`.  The model flag goes *after* legacy extra
  # args so an operator who already added ``-c model=...`` by hand in
  # ``[agent].args`` keeps their value (last ``-c key=value`` wins in
  # codex-acp's argv parser).
  var resolvedExtraArgs = cfg.agent.extraArgs
  var resolvedModel = ""
  case backend
  of aakCodex:
    resolvedExtraArgs.add codexExtraArgs(cfg)
    resolvedModel = cfg.agent.codex.model
  of aakClaude:
    resolvedExtraArgs.add claudeExtraArgs(cfg)
    resolvedModel = cfg.agent.claude.model
  of aakCustom:
    discard
  let resolvedAssistantPath = resolveAssistantPromptPath(cfg)
  result = ReviewServer(
    cfg: cfg,
    migDir: dir,
    server: newAsyncHttpServer(),
    handlers: initOrderedTable[string, HandlerProc](),
    bindAddr: cfg.server.bindAddr,
    port: cfg.server.port,
    stopRequested: false,
    onLifecycle: nil,
    agentRegistry: newAgentRegistry(
      extraArgs = resolvedExtraArgs,
      backend = backend,
      customCmd = cfg.agent.command,
      customArgs = cfg.agent.args,
      assistantPromptPath = resolvedAssistantPath,
      primerEnabled = cfg.agent.primerEnabled,
      workspaceRoot = cfg.workspace.root),
  )
  info "review server constructed", agentBackend = $backend,
    customCmd = cfg.agent.command, model = resolvedModel,
    extraArgs = resolvedExtraArgs,
    assistantPromptPath = resolvedAssistantPath,
    primerEnabled = cfg.agent.primerEnabled

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
  let startedAt = epochTime()
  info "http request", topics = "http",
    httpMethod = $req.reqMethod, path = path
  # CORS preflight — Chromium fires an OPTIONS before any POST with
  # ``Content-Type: application/json``.  Handle it uniformly for every
  # ``/api/design-review/*`` route so the per-handler logic stays clean.
  if req.reqMethod == HttpOptions and
     (path.startsWith("/api/design-review/") or
      path.startsWith("/api/agent/") or
      path.startsWith("/api/campaign/")):
    await respondCorsPreflight(req)
    info "http response", topics = "http", path = path, status = 204,
      durationMs = int((epochTime() - startedAt) * 1000)
    return
  if path == "/health":
    await healthHandler(srv, req)
    info "http response", topics = "http", path = path, status = 200,
      durationMs = int((epochTime() - startedAt) * 1000)
    return
  if srv.handlers.hasKey(path):
    await srv.handlers[path](req)
    info "http response", topics = "http", path = path,
      durationMs = int((epochTime() - startedAt) * 1000)
    return
  if path.startsWith("/api/design-review/"):
    await notImplementedHandler(req)
    info "http response", topics = "http", path = path, status = 501,
      durationMs = int((epochTime() - startedAt) * 1000)
    return
  await notFoundHandler(req)
  info "http response", topics = "http", path = path, status = 404,
    durationMs = int((epochTime() - startedAt) * 1000)

# ----- Run loop ------------------------------------------------------------

proc acceptLoop(srv: ReviewServer;
                cb: proc (req: Request): Future[void] {.closure, gcsafe.})
                {.async.} =
  ## Re-implementation of ``AsyncHttpServer.serve`` minus the ``listen``
  ## call (we listen explicitly in ``runReviewServer`` so we can resolve
  ## the OS-assigned port for the test-fixture READY handshake before
  ## any client can connect).  Uses the public ``acceptRequest`` helper
  ## so we don't depend on private ``processClient`` symbols.
  while true:
    if srv.server.shouldAcceptRequest():
      await srv.server.acceptRequest(cb)
    else:
      poll()

proc runReviewServer*(srv: ReviewServer) =
  ## Start the server and block until SIGTERM / SIGINT.  This is the
  ## entrypoint invoked from the ``serve`` subcommand.
  ##
  ## Bind / listen happens *before* the ``listening on ...`` line is
  ## emitted so the line is only printed once the socket is genuinely
  ## reachable.  Immediately after a successful ``listen`` we also
  ## print a ``READY <port>`` line to stderr — this is the
  ## test-fixture handshake (see
  ## ``tests/helpers/campaign_routes_fixture.nim`` etc.) and replaces
  ## the previous TOCTOU port-pick + curl-poll pattern.  Production
  ## callers never parse the READY line; it is informational and
  ## always emitted (the cost is one ``writeLine`` per process boot).
  installSignalHandlers()

  # Bind & listen up-front so we can resolve the actual port the OS
  # assigned (when the operator passes ``ISONIM_REVIEW_PORT=0``,
  # ``srv.port`` is 0 here and ``getPort`` returns the chosen port).
  srv.server.listen(Port(srv.port), srv.bindAddr)
  srv.port = int(srv.server.getPort())

  # READY handshake for test fixtures — must be the first stderr line
  # of the form ``READY <port>``.  Goes to stderr so it doesn't
  # collide with the editor's stdout JSON protocols.
  stderr.writeLine("READY " & $srv.port)
  stderr.flushFile()

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

  asyncCheck acceptLoop(srv, cb)

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

proc mountDesignReviewRoutes*(srv: ReviewServer) =
  ## Wire the REV-M7 ``/api/design-review/*`` handlers against ``srv``.
  ## Opens a long-lived ``ReviewDb`` connection and a ``CaptureStore``
  ## handle scoped to the configured store path; both live for the
  ## process lifetime — the daemon is the only user.
  let db = openReviewDb(env = true)
  # CMP-M5 — let the agent registry's primer query
  # ``design_review.list_campaigns`` so chat sessions land with an
  # up-to-date "Active campaigns" block.  Setter is a no-op when the
  # daemon is started with ``--agent-routes-only`` (no DB available).
  srv.agentRegistry.attachDb(db)
  let store =
    if srv.cfg.store.path.len > 0:
      try: newCaptureStore(srv.cfg.store.path)
      except CaptureStoreError:
        nil
    else:
      nil
  srv.registerHandler("/api/design-review/list-history",
                      makeListHistory(db))
  srv.registerHandler("/api/design-review/fetch-run",
                      makeFetchRun(db))
  srv.registerHandler("/api/design-review/get-capture-png",
                      makeGetCapturePng(db, store))
  srv.registerHandler("/api/design-review/brief-has-history",
                      makeBriefHasHistory(db))
  # REV-M8 — layout persistence.
  srv.registerHandler("/api/design-review/save-layout",
                      makeSaveLayout(db))
  srv.registerHandler("/api/design-review/promote-layout",
                      makePromoteLayout(db))
  srv.registerHandler("/api/design-review/list-layouts",
                      makeListLayouts(db))

  # TBAR-M5 — brief save-back to disk.  The handler owns its own
  # in-process ``BriefIndex`` (lazy-loaded from the workspace root)
  # because the design-review database doesn't carry the brief body
  # — only the parsed briefId is referenced from runs/captures.  The
  # handler writes the markdown verbatim and re-parses just that one
  # brief on success; it never makes a git commit.
  let briefStore = newDaemonBriefStore(srv.cfg.workspace.root)
  srv.registerHandler("/api/design-review/save-brief",
                      makeSaveBrief(briefStore, srv.cfg.workspace.root))

  # CMP-M2 — campaign storage + start/tick/stop handlers.  Re-uses the
  # ``ReviewDb`` connection (the campaign routines live in the same
  # schema) and binds to the daemon's :type:`AgentRegistry` so a
  # ``campaign start`` opens an ACP session against the same backend
  # that powers ``/api/agent/*``.
  let promptPath =
    if srv.cfg.workspace.root.len > 0:
      srv.cfg.workspace.root / "isonim" / OrchestratorPromptRelPath
    else:
      getCurrentDir() / OrchestratorPromptRelPath
  let resolvedPromptPath =
    if fileExists(promptPath): promptPath
    else: getCurrentDir() / OrchestratorPromptRelPath
  srv.campaignRegistry = newCampaignRegistry(srv.agentRegistry, db,
                                             resolvedPromptPath,
                                             idleTimeoutMs = srv.cfg.agent.campaignIdleTimeoutMs,
                                             hardDeadlineMs = srv.cfg.agent.campaignHardDeadlineMs)
  srv.registerHandler(CampaignStartRoute,
                      makeStartHandler(srv.campaignRegistry))
  srv.registerHandler(CampaignTickRoute,
                      makeTickHandler(srv.campaignRegistry))
  srv.registerHandler(CampaignStopRoute,
                      makeStopHandler(srv.campaignRegistry))
  srv.registerHandler(CampaignListRoute,
                      makeListHandler(srv.campaignRegistry))
  srv.registerHandler(CampaignFetchRoute,
                      makeFetchHandler(srv.campaignRegistry))
  srv.registerHandler(CampaignEventsRoute,
                      makeEventsHandler(srv.campaignRegistry))
  srv.registerHandler(CampaignInjectRoute,
                      makeInjectHandler(srv.campaignRegistry))
  srv.registerHandler(CampaignRefreshDocRoute,
                      makeRefreshDocHandler(srv.campaignRegistry))
  info "campaign routes mounted", topics = "daemon",
    promptPath = resolvedPromptPath

proc mountAgentRoutes*(srv: ReviewServer) =
  ## Phase B — wire the ``/api/agent/*`` endpoints against ``srv``.  Each
  ## handler bridges an HTTP call to the cached :type:`AgentRegistry`,
  ## which holds the live ACP transports.
  srv.registerHandler(AgentSessionsRoute,
                      makeSessionsHandler(srv.agentRegistry))
  srv.registerHandler(AgentPromptsRoute,
                      makePromptsHandler(srv.agentRegistry))
  srv.registerHandler(AgentCancelRoute,
                      makeCancelHandler(srv.agentRegistry))
  info "agent routes mounted", topics = "daemon",
    sessions = AgentSessionsRoute, prompts = AgentPromptsRoute,
    cancel = AgentCancelRoute

proc cmdServe*(cfg: ReviewConfig; migDir: string = "";
               agentRoutesOnly = false): int =
  ## CLI entrypoint.  Returns 0 on a clean shutdown.
  ##
  ## ``agentRoutesOnly`` skips ``mountDesignReviewRoutes`` (which opens
  ## a Postgres connection) so Phase B agent-route tests can spin up
  ## the daemon without a PG cluster.  Production callers always
  ## leave it ``false`` — the editor needs design-review APIs too.
  let srv = newReviewServer(cfg, migDir)
  if not agentRoutesOnly:
    try:
      mountDesignReviewRoutes(srv)
    except CatchableError as e:
      error "route mount failed", reason = e.msg
      stderr.writeLine("isonim-review serve: route mount failed: " & e.msg)
      return 2
  else:
    warn "design-review routes skipped (agentRoutesOnly=true)"
  mountAgentRoutes(srv)
  info "daemon starting", bindAddr = srv.bindAddr, port = srv.port,
    agentRoutesOnly = agentRoutesOnly
  try:
    runReviewServer(srv)
    info "daemon stopped"
    return 0
  except OSError as e:
    error "daemon bind failed", reason = e.msg
    stderr.writeLine("isonim-review serve: bind/listen failed: " & e.msg)
    return 2
