## isonim/web/hmr_livereload.nim
##
## LiveReload protocol transport for IsoNim HMR.
##
## LiveReload (https://github.com/livereload/livereload-js) is a
## de-facto standard for development-mode reload signalling. It
## ships with `livereload`, `gulp-livereload`, `browser-sync`, Rails
## (`rack-livereload`), Django (`django-livereload-server`), and a
## long tail of static-site generators. Servers expose a WebSocket
## endpoint (port 35729 by default) and the client speaks a tiny
## JSON-over-WS protocol.
##
## Protocol summary (see https://github.com/livereload/livereload-protocol):
##
##   1. Client connects, sends a `hello` with its own version list
##      and a list of protocols it supports. Server replies with its
##      own `hello`. Either side may close if the intersection of
##      protocol versions is empty.
##
##   2. Server sends `reload` messages: `{command: "reload",
##      path: "<absolute or basename>", liveCSS: <bool>,
##      liveImg: <bool>}`. The `path` is what was modified.
##
##   3. Client decides what to do:
##      - .css: swap the matching `<link>` tag's href (the classic
##        "fine-grained" path that keeps page state intact).
##      - anything else (including .js): trigger a bundle reload
##        via `applyBundleByScriptTag` against the user-supplied
##        bundle URL. The isonim slot system handles the rest.
##
## What this transport intentionally does *not* implement:
##
## - `alert` server-to-client messages (LiveReload's overlay UI):
##   isonim doesn't ship an overlay; users can hook `onError` to
##   surface alerts wherever they prefer.
## - `info` client-to-server messages on every page navigation:
##   purely cosmetic, server-side log noise.
## - LiveReload's "snipver"-style protocol negotiation history:
##   any modern server speaks v7, and we advertise that.

when not defined(js):
  {.error: "isonim/web/hmr_livereload requires the JS backend".}

when not defined(isonimHmr):
  {.error: "isonim/web/hmr_livereload requires `-d:isonimHmr`".}

import std/jsffi
import isonim/web/hmr_transport
# hmr_css_watch is reused for the link.href swap pattern when
# the server tells us a stylesheet changed.
import isonim/web/hmr_css_watch

export hmr_transport

type
  LiveReloadTransport* = ref object of HmrTransport
    url*: cstring
      ## WebSocket URL. Defaults to `ws://<host>:35729/livereload`
      ## which is the LiveReload-server convention.
    bundleUrl*: cstring
      ## URL used by `applyBundleByScriptTag` when the server tells
      ## us a non-CSS file changed. Typically the same relative URL
      ## the initial `<script>` tag uses.
    socket: JsObject
    isConnected: bool

# ---------------------------------------------------------------------------
# JS interop
# ---------------------------------------------------------------------------

var globalJs {.importjs: "globalThis".}: JsObject

proc newJsWebSocket(url: cstring): JsObject
  {.importjs: "(new WebSocket(#))".}

proc jsNull(): JsObject {.importjs: "(null)".}

proc parseJsonStr(s: cstring): JsObject
  {.importjs: "JSON.parse(#)".}

proc stringifyJson(obj: JsObject): cstring
  {.importjs: "JSON.stringify(#)".}

proc consoleError(msg: cstring) {.importjs: "console.error(#)".}

# ---------------------------------------------------------------------------
# Path classification
# ---------------------------------------------------------------------------

proc endsWithJs(s, suffix: cstring): bool =
  ## Caller-side endsWith for cstring; std/jsffi's importjs `#`
  ## placeholders are sequential, so a regex match across the same
  ## arg twice would need an emit body. Easier to inline.
  var ok: bool
  {.emit: [ok, " = (typeof ", s,
    " === 'string' && ", s, ".endsWith(", suffix, "));"].}
  ok

proc isCssPath(path: cstring): bool =
  endsWithJs(path, cstring".css")

# ---------------------------------------------------------------------------
# Construction + lifecycle
# ---------------------------------------------------------------------------

proc newLiveReloadTransport*(
    url: cstring = cstring"ws://localhost:35729/livereload";
    bundleUrl: cstring = cstring"/main.js"): LiveReloadTransport =
  LiveReloadTransport(
    url: url,
    bundleUrl: bundleUrl,
    socket: jsNull(),
    isConnected: false)

# `hello` payload we emit on connect. The `command` and
# `protocols` fields are spelled exactly the way LiveReload
# servers expect them (see livereload-protocol/README.md).
proc helloPayload(): cstring =
  cstring("""{"command":"hello","protocols":""" &
    """["http://livereload.com/protocols/official-7"],""" &
    """"ver":"isonim-hmr"}""")

method connect*(t: LiveReloadTransport) =
  ## Open the WebSocket. Idempotent. We don't auto-reconnect on
  ## close — the LiveReload contract doesn't require it, and an
  ## explicit reconnect is something a user might want to do
  ## anyway (e.g. after a dev server restart). Hooking `onclose`
  ## to `installTransport` with the same handle gets you a
  ## sticky reconnect in <5 lines.
  if t.isConnected:
    return

  let socket = newJsWebSocket(t.url)
  t.socket = socket

  proc onOpen(ev: JsObject) =
    discard t.socket.send(helloPayload())
    t.isConnected = true
    if t.onConnected != nil: t.onConnected()

  proc cssOnlyApply(path: cstring) =
    ## Server says a stylesheet changed. We don't know which
    ## `<link>` tag points at it — match by suffix. Reuse
    ## hmr_css_watch's swap-then-replace logic to avoid a
    ## briefly-unstyled flash.
    var matched: JsObject
    {.emit: ["""
      var s = """, path, """;
      var bn = (s.lastIndexOf('/') >= 0 ? s.substring(s.lastIndexOf('/') + 1) : s);
      """, matched, """ = document.querySelector('link[rel=\"stylesheet\"][href*=\"' + bn + '\"]');
    """].}
    if matched.isNil or matched.isUndefined:
      # No matching link tag — fall through to bundle reload.
      if t.onUpdate != nil: t.onUpdate(t.bundleUrl)
      return
    # Drive the swap directly via the helper exported from
    # hmr_css_watch — same code path the FsWatch CSS variant uses.
    var oldHref: cstring
    {.emit: [oldHref, " = ", matched, ".getAttribute('href') || '';"].}
    if oldHref.len == 0:
      return
    var newHref: cstring
    {.emit: [newHref,
      " = ", oldHref,
      " + (", oldHref, ".indexOf('?') !== -1 ? '&' : '?') + 'v=' + Date.now();"].}
    swapLinkHref(matched, newHref)

  proc onMessage(ev: JsObject) =
    let raw = ev["data"].to(cstring)
    var parsed: JsObject
    try:
      parsed = parseJsonStr(raw)
    except CatchableError as err:
      if t.onError != nil:
        t.onError(cstring"[isonim hmr_livereload] bad JSON: " & cstring(err.msg))
      return
    let command = parsed["command"]
    if command.isNil or command.isUndefined: return
    let cmd = command.to(cstring)
    if cmd == cstring"hello":
      # Server's hello — just an ack. Nothing else to do.
      return
    if cmd == cstring"reload":
      let pathField = parsed["path"]
      let path =
        if pathField.isNil or pathField.isUndefined: cstring""
        else: pathField.to(cstring)
      if isCssPath(path):
        cssOnlyApply(path)
      else:
        if t.onUpdate != nil:
          t.onUpdate(t.bundleUrl)
      return
    if cmd == cstring"alert":
      let msgField = parsed["message"]
      let msg =
        if msgField.isNil or msgField.isUndefined: cstring"<no message>"
        else: msgField.to(cstring)
      if t.onError != nil:
        t.onError(cstring"[livereload alert] " & msg)
      return

  proc onError(ev: JsObject) =
    if t.onError != nil:
      t.onError(cstring"[isonim hmr_livereload] websocket error")

  proc onClose(ev: JsObject) =
    t.isConnected = false
    t.socket = jsNull()
    if t.onDisconnected != nil: t.onDisconnected()

  discard socket.addEventListener(cstring"open", onOpen)
  discard socket.addEventListener(cstring"message", onMessage)
  discard socket.addEventListener(cstring"error", onError)
  discard socket.addEventListener(cstring"close", onClose)

method disconnect*(t: LiveReloadTransport) =
  if not t.isConnected:
    return
  discard t.socket.close()
  t.socket = jsNull()
  t.isConnected = false

proc installLiveReloadTransport*(
    url: cstring = cstring"ws://localhost:35729/livereload";
    bundleUrl: cstring = cstring"/main.js"): LiveReloadTransport =
  ## Build, install, return. The default URL matches the canonical
  ## LiveReload-server contract; pass a different one when running
  ## behind a proxy / non-standard port.
  result = newLiveReloadTransport(url, bundleUrl)
  installTransport(result)
