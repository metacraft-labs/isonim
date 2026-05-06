## isonim/web/hmr_sse.nim
##
## Server-Sent Events transport for IsoNim HMR. The client opens an
## EventSource at a configurable URL (default `/__isonim/hmr`) and
## listens for two event names:
##
##   - `update`: data is the URL of a freshly-built bundle. The
##     transport calls `onUpdate` with that URL; the default
##     `applyBundleByScriptTag` action then loads it, which
##     re-runs the {.uiComponent.} registrations and propagates
##     factory updates through the slot system.
##   - `error`: data is a human-readable message (compile failure,
##     etc.). The transport calls `onError`.
##
## See `Hot-Module-Reload.md` for the full design and `dev_server.nim`
## for the matching server-side endpoint.

when not defined(js):
  {.error: "isonim/web/hmr_sse requires the JS backend".}

when not defined(isonimHmr):
  {.error: "isonim/web/hmr_sse requires `-d:isonimHmr`".}

import std/jsffi
import isonim/web/hmr_transport

export hmr_transport

type
  SseTransport* = ref object of HmrTransport
    url*: cstring
    eventSource: JsObject  # the live EventSource handle, or null

var globalJs {.importjs: "globalThis".}: JsObject

# Helper since std/jsffi exposes `jsundefined` but not `jsnull`.
proc jsNull(): JsObject {.importjs: "(null)".}

# EventSource requires the `new` operator; calling it as a function
# throws "Please use the 'new' operator". Bind a typed constructor.
proc newJsEventSource(url: cstring): JsObject
  {.importjs: "(new EventSource(#))".}

proc newSseTransport*(url: cstring = cstring"/__isonim/hmr"): SseTransport =
  SseTransport(url: url)

method connect*(t: SseTransport) =
  ## Opens the EventSource. Browser will auto-reconnect on transient
  ## failures (that's the EventSource contract). On permanent errors
  ## the `error` callback fires once and the connection stays in a
  ## reconnecting state — same browser default.
  if not t.eventSource.isNil and not t.eventSource.isUndefined:
    return  # already connected

  let es = newJsEventSource(t.url)
  t.eventSource = es

  proc onOpen(ev: JsObject) =
    if t.onConnected != nil: t.onConnected()

  proc onUpdate(ev: JsObject) =
    let bundleUrl = ev["data"].to(cstring)
    if t.onUpdate != nil: t.onUpdate(bundleUrl)

  proc onError(ev: JsObject) =
    let dataField = ev["data"]
    let msg =
      if dataField.isUndefined or dataField.isNull: cstring"sse connection error"
      else: dataField.to(cstring)
    if t.onError != nil: t.onError(msg)

  # `addEventListener` on EventSource expects (eventName, callback).
  # Use jsffi method-call dispatch to bind `this` = es.
  discard es.addEventListener(cstring"open", onOpen)
  discard es.addEventListener(cstring"update", onUpdate)
  discard es.addEventListener(cstring"error", onError)

method disconnect*(t: SseTransport) =
  if t.eventSource.isNil or t.eventSource.isUndefined:
    return
  discard t.eventSource.close()
  t.eventSource = jsNull()
  if t.onDisconnected != nil: t.onDisconnected()

# Convenience wrapper for the common case: `installSse()` from a user's
# main and forget about it.
proc installSseTransport*(url: cstring = cstring"/__isonim/hmr"): SseTransport =
  result = newSseTransport(url)
  installTransport(result)
