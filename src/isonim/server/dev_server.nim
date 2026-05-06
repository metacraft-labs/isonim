## Dev server adapter for IsoNim.
##
## Bridges std/asynchttpserver's Request to our HttpRequest/HttpResponse
## types. The handler itself is synchronous — async dispatch comes in a
## later milestone.
##
## In addition to the request/response router adapter, this module
## provides a minimal HMR coordinator:
##
##   - `/__isonim/hmr` — Server-Sent Events stream the browser
##     subscribes to. We send `update` events when a new bundle is
##     ready, `error` events when a rebuild fails.
##
##   - `/__isonim/trigger` — POST endpoint that triggers a rebuild.
##     Useful for an external file-watcher (entr / fswatch / a Nim
##     watcher) to call when source files change. Returns 200 once the
##     rebuild started; the SSE channel reports success/failure.
##
## A built-in poll-based file watcher is provided via
## `serveRouterHmr(... watchPaths = @[...])` — it scans for `.nim` files
## under the given paths and triggers a rebuild on mtime change. For
## production-quality watching use an external tool and the trigger
## endpoint; the built-in poll is intended for "just works" out of the
## box during development.

import std/[asynchttpserver, asyncdispatch, asyncfile, asyncnet, uri, os, osproc,
            streams, strutils, tables, times]
import http_types, handler

# ---------------------------------------------------------------------------
# Method conversion
# ---------------------------------------------------------------------------

proc toHttpMethod(m: asynchttpserver.HttpMethod): http_types.HttpMethod =
  case m
  of HttpGet: hmGet
  of HttpPost: hmPost
  of HttpPut: hmPut
  of HttpDelete: hmDelete
  of HttpPatch: hmPatch
  of HttpHead: hmHead
  of HttpOptions: hmOptions
  else: hmGet

proc adaptRequest(req: asynchttpserver.Request): HttpRequest =
  var headerPairs: seq[(string, string)] = @[]
  for key, val in req.headers.pairs:
    headerPairs.add((key, val))
  newHttpRequest(
    path = req.url.path.decodeUrl,
    httpMethod = toHttpMethod(req.reqMethod),
    headers = headerPairs,
    bodyData = req.body,
  )

# ---------------------------------------------------------------------------
# Plain (non-HMR) router adapter — unchanged from before.
# ---------------------------------------------------------------------------

proc serveRouter*(router: Router, port: int = 8080) =
  let server = newAsyncHttpServer()
  let routerLocal = router
  proc handler(req: asynchttpserver.Request) {.async, gcsafe.} =
    let httpReq = adaptRequest(req)
    let httpResp = newHttpResponse()
    # Router.dispatch performs an indirect call (registered handlers).
    # The compiler can't prove gcsafe statically; trust at the cast.
    {.cast(gcsafe).}:
      routerLocal.dispatch(httpReq, httpResp)
    var headers = newHttpHeaders()
    for (name, value) in httpResp.getResponseHeaders():
      headers[name] = value
    let body = httpResp.getResponseBody()
    await req.respond(HttpCode(httpResp.statusCode), body, headers)
  echo "Dev server running at http://localhost:" & $port
  waitFor server.serve(Port(port), handler)

# ---------------------------------------------------------------------------
# HMR-aware dev server
# ---------------------------------------------------------------------------

type
  RebuildResult = object
    ok: bool
    bundleUrl: string
    errorMsg: string

  HmrServer* = ref object
    ## Holds the live SSE clients and the rebuild config so the trigger
    ## endpoint and the optional poll watcher both have a shared
    ## handle to broadcast through.
    clients: seq[asynchttpserver.Request]
    bundlePath: string         ## URL path the browser fetches the bundle on
    rebuildCommand: seq[string] ## argv to invoke `nim js ... -o:bundleFile entrySrc`
    bundleFile: string         ## Local file the rebuild produces (served as bundlePath)
    watchPaths: seq[string]    ## Roots to scan for .nim mtime changes (poll watcher)
    pollIntervalMs: int

proc newHmrServer*(
    rebuildCommand: seq[string];
    bundleFile: string;
    bundlePath: string = "/main.js";
    watchPaths: seq[string] = @[];
    pollIntervalMs: int = 1000): HmrServer =
  HmrServer(
    clients: @[],
    bundlePath: bundlePath,
    rebuildCommand: rebuildCommand,
    bundleFile: bundleFile,
    watchPaths: watchPaths,
    pollIntervalMs: pollIntervalMs,
  )

proc broadcastSse(s: HmrServer; event, data: string) {.async, gcsafe.} =
  ## Push an SSE event to every connected client. We can't share a Request's
  ## response writer past the original handler return, so this writes
  ## directly using the underlying client socket via `req.client`.
  var alive: seq[asynchttpserver.Request] = @[]
  let frame = "event: " & event & "\n" &
              "data: " & data.replace("\n", "\\n") & "\n\n"
  for c in s.clients:
    try:
      await c.client.send(frame)
      alive.add(c)
    except CatchableError:
      # Client gone — drop it from the list.
      discard
  s.clients = alive

proc rebuildOnce(s: HmrServer): RebuildResult {.gcsafe.} =
  ## Synchronously runs the configured rebuild command. We don't try to
  ## be clever about incremental compilation — Nim's nimcache already
  ## makes second-and-later builds reasonably fast.
  if s.rebuildCommand.len == 0:
    return RebuildResult(ok: false, errorMsg: "no rebuild command configured")
  let cmd = s.rebuildCommand[0]
  let args = s.rebuildCommand[1 .. ^1]
  let p = startProcess(cmd, args = args, options = {poUsePath, poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  if code == 0:
    RebuildResult(ok: true, bundleUrl: s.bundlePath)
  else:
    RebuildResult(ok: false, errorMsg: output)

proc triggerRebuild*(s: HmrServer) {.async, gcsafe.} =
  ## Run the rebuild command and broadcast the outcome to all SSE
  ## clients. Errors are reported as `error` events so the browser can
  ## display them; success is reported as an `update` event with the
  ## bundle URL.
  let r = rebuildOnce(s)
  if r.ok:
    await s.broadcastSse("update", r.bundleUrl)
  else:
    await s.broadcastSse("error", r.errorMsg)

# ---------------------------------------------------------------------------
# Built-in poll-based file watcher
# ---------------------------------------------------------------------------

proc collectMtimes(s: HmrServer): Table[string, Time] =
  result = initTable[string, Time]()
  for root in s.watchPaths:
    if not dirExists(root):
      continue
    for path in walkDirRec(root):
      if path.endsWith(".nim"):
        try:
          result[path] = getLastModificationTime(path)
        except CatchableError:
          discard

proc watchLoop(s: HmrServer) {.async.} =
  ## Poll-based mtime watcher. Cross-platform but coarse — fine for a
  ## dev environment where you save a file every few seconds. For a
  ## faster loop use an external watcher (entr / fswatch) and call
  ## `/__isonim/trigger` directly.
  var lastSeen = collectMtimes(s)
  while true:
    await sleepAsync(s.pollIntervalMs)
    let current = collectMtimes(s)
    var changed = false
    for path, mt in current:
      if mt != lastSeen.getOrDefault(path):
        changed = true
        break
    if not changed:
      # Also detect deletions
      for path in lastSeen.keys:
        if path notin current:
          changed = true
          break
    lastSeen = current
    if changed:
      await s.triggerRebuild()

# ---------------------------------------------------------------------------
# HTTP handlers
# ---------------------------------------------------------------------------

proc serveBundle(s: HmrServer; req: asynchttpserver.Request) {.async, gcsafe.} =
  if not fileExists(s.bundleFile):
    await req.respond(Http404, "bundle not found at " & s.bundleFile)
    return
  let f = openAsync(s.bundleFile, fmRead)
  let body = await f.readAll()
  f.close()
  var headers = newHttpHeaders()
  headers["content-type"] = "text/javascript; charset=utf-8"
  headers["cache-control"] = "no-store, must-revalidate"
  await req.respond(Http200, body, headers)

proc handleSse(s: HmrServer; req: asynchttpserver.Request) {.async, gcsafe.} =
  ## Holds the connection open and registers the request as a client.
  ## We don't return from this handler — the asynchttpserver keeps
  ## the socket alive until the client disconnects.
  let preamble =
    "HTTP/1.1 200 OK\r\n" &
    "content-type: text/event-stream\r\n" &
    "cache-control: no-store\r\n" &
    "connection: keep-alive\r\n" &
    "x-accel-buffering: no\r\n" &
    "\r\n" &
    ": connected\n\n"
  await req.client.send(preamble)
  s.clients.add(req)
  # Block forever — keeps the socket alive. asynchttpserver will tear
  # down its own state when the client disconnects (handler exits when
  # we yield indefinitely; this is a known asynchttpserver limitation,
  # so for production use a more capable server. For dev it's fine.)
  while not req.client.isClosed:
    await sleepAsync(15000)
    try:
      await req.client.send(": keepalive\n\n")
    except CatchableError:
      break

proc serveRouterHmr*(
    router: Router;
    hmr: HmrServer;
    port: int = 8080;
    enableWatcher: bool = true) =
  ## Drop-in replacement for `serveRouter` that adds three HMR-aware
  ## endpoints alongside whatever the user's router exposes:
  ##
  ##   GET  /__isonim/hmr        — SSE stream of update/error events.
  ##   POST /__isonim/trigger    — Force a rebuild. Useful for external watchers.
  ##   GET  <hmr.bundlePath>     — Serves the latest built bundle.
  ##
  ## All other URLs fall through to `router.dispatch`.
  let server = newAsyncHttpServer()
  let hmrLocal = hmr  # local copy so the closure capture is gcsafe-evaluable
  let routerLocal = router
  proc handler(req: asynchttpserver.Request) {.async, gcsafe.} =
    let path = req.url.path.decodeUrl
    if path == "/__isonim/hmr" and req.reqMethod == HttpGet:
      await handleSse(hmrLocal, req)
      return
    if path == "/__isonim/trigger" and req.reqMethod == HttpPost:
      asyncCheck hmrLocal.triggerRebuild()
      await req.respond(Http202, "rebuild started")
      return
    if path == hmrLocal.bundlePath and req.reqMethod == HttpGet:
      await serveBundle(hmrLocal, req)
      return

    # Fall through to the user's router for any other path.
    let httpReq = adaptRequest(req)
    let httpResp = newHttpResponse()
    {.cast(gcsafe).}:
      routerLocal.dispatch(httpReq, httpResp)
    var headers = newHttpHeaders()
    for (name, value) in httpResp.getResponseHeaders():
      headers[name] = value
    await req.respond(HttpCode(httpResp.statusCode), httpResp.getResponseBody(), headers)

  echo "Dev server (HMR) running at http://localhost:" & $port
  echo "  bundle:  " & hmr.bundlePath
  echo "  events:  /__isonim/hmr"
  echo "  trigger: POST /__isonim/trigger"
  if enableWatcher and hmr.watchPaths.len > 0:
    asyncCheck watchLoop(hmr)
  waitFor server.serve(Port(port), handler)
