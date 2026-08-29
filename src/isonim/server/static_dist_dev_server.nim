## Live-reload dev server for **code-authored isonim static sites**.
##
## A code-authored isonim site (its pages/components are Nim *code* compiled
## into a static exporter, not data files rendered at request time) can't
## hot-swap a single edited module in-process the way `server/dev_server.nim`
## reloads markdown *content*. Picking up an edit requires recompiling. So the
## dev loop here re-runs the exact static-export pipeline the site ships and
## reloads the browser — what you see in dev is byte-for-byte what the deployed
## `dist/` serves.
##
## `staticDistDevServer(...)` runs a single long-lived process that
##
##   1. serves the exported static site out of a `dist/` directory over HTTP,
##   2. watches the site's source roots for edits,
##   3. re-runs the site's real static-export command on any change, and
##   4. pushes a WebSocket live-reload signal so every open browser tab
##      refreshes to the freshly rendered bytes. A broken source shows a
##      full-page error overlay and auto-recovers on fix.
##
## This is the shared implementation the isonim static sites consume so each
## repo's `src/dev.nim` is a few lines of config rather than a copied server.
##
## The WebSocket handshake (`wsAcceptKey`) + text-frame encoder
## (`encodeWsTextFrame`) implement RFC 6455 and are exported so sites and tests
## can verify them against the spec's own test vectors. Everything here is on
## the Nim stdlib only (`std/asynchttpserver` + friends) — no new dependency on
## the isonim core surface.
##
## Usage (a site's `src/dev.nim`):
##   import isonim/server/static_dist_dev_server
##   staticDistDevServer(
##     distDir = "dist",
##     rebuildCommand = @["nim", "c", "-r", "--mm:orc", "-d:isServer",
##                        "-d:release", "--hints:off", "src/static_export.nim"],
##     watchRoots = @["src"],
##     siteName = "Metacraft Labs website")

import std/[asynchttpserver, asyncdispatch, asyncnet, os, strutils, uri,
            tables, times, osproc, streams, sha1, base64, mimetypes]

const
  wsGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    ## RFC 6455 §1.3 magic GUID appended to the client key before hashing.
  defaultLiveReloadPath* = "/__isonim_livereload"
  defaultReloadMessage* = "reload"
  defaultWatchExts* = @[".nim", ".js", ".css", ".woff2", ".woff", ".ttf",
                        ".svg", ".png", ".jpg", ".jpeg", ".webp", ".ico"]
    ## File extensions the poll watcher treats as source changes.

# ---------------------------------------------------------------------------
# WebSocket (RFC 6455) — pure handshake + frame encoding. Exported so sites
# and tests can verify against the spec's own vectors.
# ---------------------------------------------------------------------------

proc wsAcceptKey*(clientKey: string): string =
  ## RFC 6455 §1.3 accept-key: base64(SHA1(clientKey & magic GUID)).
  let hex = $secureHash(clientKey & wsGuid)
  var raw = newString(20)
  for i in 0 ..< 20:
    raw[i] = chr(parseHexInt(hex[i*2 .. i*2+1]))
  base64.encode(raw)

proc encodeWsTextFrame*(payload: string): string =
  ## Encode a server->client, unmasked, single text frame (RFC 6455 §5.2).
  result = newStringOfCap(payload.len + 10)
  result.add chr(0x81)                       # FIN + text opcode
  let n = payload.len
  if n <= 125:
    result.add chr(n)
  elif n <= 0xFFFF:
    result.add chr(126); result.add chr((n shr 8) and 0xFF); result.add chr(n and 0xFF)
  else:
    result.add chr(127)
    for shift in countdown(56, 0, 8): result.add chr((n shr shift) and 0xFF)
  result.add payload

proc isWebSocketUpgrade*(req: Request): bool =
  ## True when `req` is a valid RFC 6455 upgrade handshake.
  if not req.headers.hasKey("upgrade"): return false
  if "websocket" notin req.headers["upgrade"].toLowerAscii: return false
  req.headers.hasKey("sec-websocket-key")

proc wsHandshakeResponse*(clientKey: string): string =
  ## The `101 Switching Protocols` response bytes for a handshake `clientKey`.
  "HTTP/1.1 101 Switching Protocols\r\n" &
  "Upgrade: websocket\r\n" &
  "Connection: Upgrade\r\n" &
  "Sec-WebSocket-Accept: " & wsAcceptKey(clientKey) & "\r\n\r\n"

# ---------------------------------------------------------------------------
# Live-reload client + error overlay — the injected browser bytes.
# ---------------------------------------------------------------------------

proc liveReloadClientScript*(wsPath: string): string =
  ## Tiny client every served page embeds: opens a WS, reloads on any message,
  ## and auto-reconnects with a short backoff (so a reload survives a rebuild).
  """<script>(function(){
  function connect(){
    try{
      var proto = location.protocol === "https:" ? "wss:" : "ws:";
      var ws = new WebSocket(proto + "//" + location.host + """" & wsPath & """");
      ws.onmessage = function(){ location.reload(); };
      ws.onclose = function(){ setTimeout(connect, 1000); };
    }catch(e){ setTimeout(connect, 1000); }
  }
  connect();
})();</script>"""

proc injectLiveReload*(html, wsPath: string): string =
  ## Insert the live-reload client just before `</body>` (or append if absent).
  let script = liveReloadClientScript(wsPath)
  let idx = html.rfind("</body>")
  if idx >= 0: html[0 ..< idx] & script & html[idx .. ^1]
  else: html & script

proc renderErrorOverlay*(message, siteName: string;
                         wsPath = defaultLiveReloadPath): string =
  ## Full-page overlay shown when a rebuild fails, retaining the live-reload
  ## client so the moment the source is fixed the page reloads to real content.
  let safe = message.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))
  """<!DOCTYPE html><html><head><meta charset="utf-8">""" &
  """<title>Build error — """ & siteName & """</title></head>""" &
  """<body style="margin:0;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;background:#1b1b1f;color:#e6e6e6">""" &
  """<div style="padding:2rem;max-width:70rem;margin:0 auto">""" &
  """<div style="color:#ff5c5c;font-size:1.4rem;font-weight:700;margin-bottom:.5rem">Static export failed</div>""" &
  """<div style="color:#9a9a9a;margin-bottom:1rem">""" & siteName &
  """ dev server — fix the error below and save; this page reloads automatically.</div>""" &
  """<pre style="white-space:pre-wrap;background:#2a2a2f;padding:1rem;border-radius:6px;border-left:4px solid #ff5c5c;overflow:auto">""" &
  safe & """</pre></div>""" &
  liveReloadClientScript(wsPath) &
  """</body></html>"""

# ---------------------------------------------------------------------------
# Reload hub — transport-agnostic fan-out.
# ---------------------------------------------------------------------------

type
  ReloadHub* = ref object
    subscribers: seq[ref seq[string]]

proc newReloadHub*(): ReloadHub = ReloadHub(subscribers: @[])

proc subscribe*(hub: ReloadHub): ref seq[string] =
  result = new(seq[string])
  result[] = @[]
  hub.subscribers.add result

proc unsubscribe*(hub: ReloadHub; q: ref seq[string]) =
  let idx = hub.subscribers.find(q)
  if idx >= 0: hub.subscribers.delete idx

proc broadcast*(hub: ReloadHub; msg: string) =
  for q in hub.subscribers: q[].add msg

# ---------------------------------------------------------------------------
# Server config + state.
# ---------------------------------------------------------------------------

type
  StaticDistDevServer* = ref object
    ## Config + live state for one dev-server instance. Construct with
    ## `newStaticDistDevServer` (or use the all-in-one `staticDistDevServer`).
    distDir*: string             ## directory the exporter writes / we serve
    rebuildCommand*: seq[string] ## argv of the real static-export pipeline
    watchRoots*: seq[string]     ## source roots scanned for edits
    watchExts*: seq[string]      ## extensions that count as a source change
    liveReloadPath*: string      ## WS endpoint path
    reloadMessage*: string       ## WS payload sent on reload
    siteName*: string            ## branding for the error overlay
    pollIntervalMs*: int         ## watcher poll interval
    # live state
    hub: ReloadHub
    lastError: string            ## non-empty => last export failed; serve overlay
    snapshot: Table[string, Time]
    mimes: MimeDB

proc newStaticDistDevServer*(
    rebuildCommand: seq[string];
    distDir = "dist";
    watchRoots = @["src"];
    watchExts = defaultWatchExts;
    siteName = "isonim site";
    liveReloadPath = defaultLiveReloadPath;
    reloadMessage = defaultReloadMessage;
    pollIntervalMs = 300): StaticDistDevServer =
  StaticDistDevServer(
    distDir: distDir,
    rebuildCommand: rebuildCommand,
    watchRoots: watchRoots,
    watchExts: watchExts,
    liveReloadPath: liveReloadPath,
    reloadMessage: reloadMessage,
    siteName: siteName,
    pollIntervalMs: pollIntervalMs,
    hub: newReloadHub(),
    lastError: "",
    snapshot: initTable[string, Time](),
    mimes: newMimetypes())

# ---------------------------------------------------------------------------
# Rebuild — run the real export pipeline and record any failure.
# ---------------------------------------------------------------------------

proc runExport(s: StaticDistDevServer) =
  ## Runs the configured static-export command, capturing output. On success
  ## clears `lastError`; on failure records it for the overlay. Either way the
  ## caller broadcasts a reload so the browser re-fetches.
  if s.rebuildCommand.len == 0:
    s.lastError = "no rebuild command configured"
    return
  stdout.writeLine "[dev] rebuilding " & s.distDir & "/ …"
  stdout.flushFile()
  let p = startProcess(s.rebuildCommand[0], args = s.rebuildCommand[1 .. ^1],
                       options = {poUsePath, poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  if code == 0:
    s.lastError = ""
    stdout.writeLine "[dev] rebuilt ok"
  else:
    s.lastError = output
    stdout.writeLine "[dev] export FAILED (see browser overlay)"
  stdout.flushFile()

# ---------------------------------------------------------------------------
# File watcher — mtime snapshot + diff (cross-platform, no fs-event dep).
# ---------------------------------------------------------------------------

proc watchedFile(s: StaticDistDevServer; path: string): bool =
  path.splitFile.ext.toLowerAscii in s.watchExts

proc snapshotSources(s: StaticDistDevServer): Table[string, Time] =
  result = initTable[string, Time]()
  for root in s.watchRoots:
    if not dirExists(root): continue
    for path in walkDirRec(root):
      if s.watchedFile(path):
        try: result[path] = getLastModificationTime(path)
        except CatchableError: discard

proc changed(prev, cur: Table[string, Time]): bool =
  for path, mt in cur:
    if mt != prev.getOrDefault(path): return true
  for path in prev.keys:
    if path notin cur: return true
  false

# ---------------------------------------------------------------------------
# Static file serving out of the dist dir with clean-URL mapping.
# ---------------------------------------------------------------------------

proc resolveFile(s: StaticDistDevServer; urlPath: string): string =
  ## Maps a request path to a file under `distDir`, honouring clean URLs.
  ## Returns "" if nothing matches (404). Rejects `..` traversal.
  var p = urlPath
  let q = p.find('?')
  if q >= 0: p = p[0 ..< q]
  p = p.decodeUrl
  if "\x00" in p or ".." in p: return ""
  if p == "/" or p.len == 0: return s.distDir / "index.html"
  let rel = p.strip(chars = {'/'})
  let direct = s.distDir / rel
  if fileExists(direct): return direct                 # asset / real file
  let clean = s.distDir / rel / "index.html"
  if fileExists(clean): return clean                   # clean-URL page
  if fileExists(direct & "/index.html"): return direct & "/index.html"
  ""

proc contentTypeFor(s: StaticDistDevServer; file: string): string =
  let ext = file.splitFile.ext.toLowerAscii
  case ext
  of ".html": "text/html; charset=utf-8"
  of ".css": "text/css; charset=utf-8"
  of ".js": "text/javascript; charset=utf-8"
  of ".woff2": "font/woff2"
  of ".woff": "font/woff"
  of ".svg": "image/svg+xml"
  else: s.mimes.getMimetype(ext.strip(chars = {'.'}), "application/octet-stream")

# ---------------------------------------------------------------------------
# Async driver.
# ---------------------------------------------------------------------------

proc serveWebSocket(s: StaticDistDevServer; req: Request) {.async.} =
  let client = req.client
  await client.send(wsHandshakeResponse(req.headers["sec-websocket-key"]))
  let q = s.hub.subscribe()
  try:
    while not client.isClosed:
      if q[].len > 0:
        let msgs = q[]
        q[].setLen 0
        for m in msgs: await client.send(encodeWsTextFrame(m))
      else:
        await sleepAsync(50)
  finally:
    s.hub.unsubscribe q

proc processRequest(s: StaticDistDevServer; req: Request) {.async.} =
  let path = req.url.path
  if path == s.liveReloadPath and isWebSocketUpgrade(req):
    await serveWebSocket(s, req)
    return
  if path == s.liveReloadPath:
    await req.respond(Http200, s.siteName & " live-reload endpoint")
    return
  let file = s.resolveFile(req.url.path)
  if file.len == 0:
    let notFound = injectLiveReload(
      "<!DOCTYPE html><html><body><h1>404</h1></body></html>", s.liveReloadPath)
    await req.respond(Http404, notFound,
      newHttpHeaders({"Content-Type": "text/html; charset=utf-8"}))
    return
  let ct = s.contentTypeFor(file)
  var body = readFile(file)
  if ct.startsWith("text/html"):
    if s.lastError.len > 0:
      body = renderErrorOverlay(s.lastError, s.siteName, s.liveReloadPath)
    else:
      body = injectLiveReload(body, s.liveReloadPath)
  await req.respond(Http200, body,
    newHttpHeaders({"Content-Type": ct, "Cache-Control": "no-store"}))

proc watchLoop(s: StaticDistDevServer) {.async.} =
  while true:
    await sleepAsync(s.pollIntervalMs)
    let cur = s.snapshotSources()
    if changed(s.snapshot, cur):
      s.snapshot = cur
      runExport(s)
      # settle: adopt the post-build snapshot so the exporter's own writes
      # under distDir (outside watchRoots anyway) never re-trigger.
      s.snapshot = s.snapshotSources()
      s.hub.broadcast(s.reloadMessage)

proc serve*(s: StaticDistDevServer; port = 8080; host = "127.0.0.1") {.async.} =
  ## Run the dev server: initial export, then serve + watch until cancelled.
  var http = newAsyncHttpServer()
  http.listen(Port(port), host)
  # Initial export so distDir is fresh, then take the baseline snapshot.
  runExport(s)
  s.snapshot = s.snapshotSources()
  asyncCheck watchLoop(s)
  while true:
    if http.shouldAcceptRequest():
      await http.acceptRequest(proc(req: Request) {.async, gcsafe.} =
        {.cast(gcsafe).}:
          await processRequest(s, req))
    else:
      await sleepAsync(20)

proc staticDistDevServer*(
    rebuildCommand: seq[string];
    distDir = "dist";
    watchRoots = @["src"];
    watchExts = defaultWatchExts;
    siteName = "isonim site";
    liveReloadPath = defaultLiveReloadPath;
    port = 8080;
    host = "127.0.0.1";
    pollIntervalMs = 300) =
  ## All-in-one: construct a `StaticDistDevServer` and run it (blocks).
  ## The single entry point a site's `src/dev.nim` calls.
  let s = newStaticDistDevServer(
    rebuildCommand = rebuildCommand,
    distDir = distDir,
    watchRoots = watchRoots,
    watchExts = watchExts,
    siteName = siteName,
    liveReloadPath = liveReloadPath,
    pollIntervalMs = pollIntervalMs)
  stdout.writeLine s.siteName & " dev server -> http://" & host & ":" &
    $port & "  (watching " & s.watchRoots.join(", ") &
    ", live reload on; Ctrl-C to stop)"
  stdout.flushFile()
  waitFor serve(s, port, host)
