## isonim/web/hmr_transport.nim
##
## Transport-adapter contract for IsoNim HMR.
##
## A *transport* is whatever delivers "the new bundle is ready" to the
## browser. The runtime doesn't care which one — it only needs the
## transport to:
##
##   - Tell the browser when a new bundle URL is available.
##   - Tell the runtime when something went wrong (compile error, etc.)
##     so it can be surfaced to the user.
##
## The actual mechanism by which slot factories get updated is the
## bundle re-evaluation: when the new bundle is loaded as a `<script>`,
## its top-level `{.uiComponent.}`-emitted registrations run again,
## which writes new factory pointers to slots whose hash changed.
## See `Hot-Module-Reload.md` for the design.
##
## Reference implementation: `hmr_sse.nim` (server-sent events).
## Other plug-ins worth writing: LiveReload (port 35729 protocol),
## Vite's WebSocket message format (so an IsoNim app can hot-reload
## under a Vite-orchestrated dev environment), or a Nim-native channel
## tunneled through the existing `dev_server.nim`.

when not defined(js):
  {.error: "isonim/web/hmr_transport requires the JS backend".}

when not defined(isonimHmr):
  {.error: "isonim/web/hmr_transport requires `-d:isonimHmr`".}

import std/jsffi

type
  HmrTransport* = ref object of RootObj
    ## Concrete transports inherit and override `connect` / `disconnect`.
    ## Callbacks are read at event time so they may be reassigned.
    onConnected*: proc()
    onUpdate*: proc(bundleUrl: cstring)
    onError*: proc(msg: cstring)
    onDisconnected*: proc()

method connect*(t: HmrTransport) {.base.} = discard
method disconnect*(t: HmrTransport) {.base.} = discard

# ---------------------------------------------------------------------------
# Default `onUpdate` action: fetch + evaluate a new bundle
# ---------------------------------------------------------------------------

var globalJs {.importjs: "globalThis".}: JsObject
var documentJs {.importjs: "document".}: JsObject

proc applyBundleByScriptTag*(
    url: cstring;
    onLoaded: proc() = nil;
    onLoadError: proc(msg: cstring) = nil) =
  ## The simplest "apply this bundle" strategy: append a `<script>` tag
  ## with a cache-busting query parameter. When the script loads its
  ## top-level statements run, including each `{.uiComponent.}`-emitted
  ## registration call. Slot factories whose hash changed get written;
  ## all the visible cascade happens there.
  ##
  ## Removing the tag from the document afterwards is optional — the
  ## browser holds the parsed JS regardless.
  # Build a cache-busting URL. JS-side string concat handles
  # number-to-string for the timestamp; doing it in Nim with toJs/.to
  # would yield "[object Object]" because JsObject doesn't auto-stringify.
  proc buildCacheBusted(base: cstring): cstring
    {.importjs: "(# + '?v=' + Date.now())".}
  let cacheBusted = buildCacheBusted(url)
  # `documentJs.createElement(...)` via the method-call macro keeps
  # `document` as the receiver. Reading `documentJs["createElement"]`
  # and calling that function value loses `this` and triggers
  # "Illegal invocation".
  let script = documentJs.createElement(cstring"script")
  script["src"] = toJs(cacheBusted)
  script["async"] = toJs(false)
  script["onload"] = toJs(proc() =
    if onLoaded != nil: onLoaded())
  script["onerror"] = toJs(proc() =
    if onLoadError != nil: onLoadError(cstring"failed to load bundle: " & cacheBusted))
  discard documentJs["head"].appendChild(script)

# ---------------------------------------------------------------------------
# Convenience: install a transport with the default onUpdate action.
# ---------------------------------------------------------------------------

proc installTransport*(t: HmrTransport) =
  ## If the user hasn't set `onUpdate`, install the default that loads
  ## the bundle by script tag. Then connect. Idempotent on the
  ## defaults — user-supplied callbacks are preserved.
  if t.onUpdate == nil:
    t.onUpdate = proc(bundleUrl: cstring) =
      applyBundleByScriptTag(bundleUrl)
  if t.onError == nil:
    t.onError = proc(msg: cstring) =
      let consoleError = globalJs["console"]["error"].to(proc(m: cstring))
      consoleError(cstring"[isonim hmr] " & msg)
  t.connect()
