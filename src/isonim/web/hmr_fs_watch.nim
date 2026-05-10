## isonim/web/hmr_fs_watch.nim
##
## Node `fs.watch` transport for IsoNim HMR. Designed for runtimes
## where the JS bundle the browser is executing comes from a local file
## (Electron renderer with Node integration, or anything else where
## `globalThis.require('fs')` works).
##
## The user's build pipeline rebuilds the bundle on its own schedule —
## Tup, the Nim compiler, an external watcher, anything. This transport
## merely watches the file for change events and, when one fires, asks
## `applyBundleByScriptTag` to reload the bundle. The newly-loaded
## bundle's top-level `{.uiComponent.}`-emitted registrations propagate
## factory updates through the slot system; mounts whose factories see
## a changed slot re-render, the rest of the page is untouched.
##
## Compared with the SSE transport, this one needs no external server.
## It is the right fit for Electron-style apps where there is no dev
## HTTP server in the picture — only a local bundle file getting
## rewritten by the build system.
##
## Coalescing: rapid successive change events (Tup may rewrite the
## bundle in two passes; some filesystems emit per-block notifications)
## are coalesced into a single reload via a small debounce window so
## the browser doesn't repeatedly load half-written bundles. The
## window is configurable; the default of 80 ms works for both
## Tup-driven and direct `nim js` rebuilds in practice.

when not defined(js):
  {.error: "isonim/web/hmr_fs_watch requires the JS backend".}

when not defined(isonimHmr):
  {.error: "isonim/web/hmr_fs_watch requires `-d:isonimHmr`".}

import std/jsffi
import isonim/web/hmr_transport

export hmr_transport

type
  FsWatchTransport* = ref object of HmrTransport
    bundleFile*: cstring
      ## Filesystem path to the bundle to watch (e.g. an absolute
      ## path or one resolved against `process.cwd()`).
    bundleUrl*: cstring
      ## URL the browser uses to load the new bundle. May differ from
      ## `bundleFile` (e.g. when the bundle is served at a relative
      ## URL while the watch path is absolute on disk).
    debounceMs*: int
      ## Coalescing window for change events. The first event arms a
      ## one-shot timer; subsequent events within the window reset it.
    watcher: JsObject     # active fs.FSWatcher handle, or null
    pendingTimer: JsObject

# Reading `globalThis.require` rather than top-level `require()` lets
# the bundle compile in non-Electron browser environments (require may
# be undefined). The connect() method asserts at runtime.
proc requireFn(name: cstring): JsObject
  {.importjs: "(globalThis.require && globalThis.require(#))".}

proc setTimeoutJs(cb: JsObject; ms: int): JsObject
  {.importjs: "setTimeout(#, #)".}

proc clearTimeoutJs(handle: JsObject)
  {.importjs: "clearTimeout(#)".}

proc jsNull(): JsObject {.importjs: "(null)".}

proc isFunctionJs(x: JsObject): bool
  {.importjs: "(typeof # === 'function')".}

proc fsWatch(fs, path, callback: JsObject): JsObject
  {.importjs: "#.watch(#, {persistent: false}, #)".}
  ## Wraps Node's `fs.watch(path, options, listener)`. We pass
  ## `persistent: false` so this watcher does not keep the renderer
  ## process alive on its own — the Electron lifetime is what should
  ## drive the renderer.

proc fsWatcherClose(watcher: JsObject)
  {.importjs: "#.close()".}

proc newFsWatchTransport*(
    bundleFile: cstring;
    bundleUrl: cstring;
    debounceMs: int = 80): FsWatchTransport =
  FsWatchTransport(
    bundleFile: bundleFile,
    bundleUrl: bundleUrl,
    debounceMs: debounceMs,
    watcher: jsNull(),
    pendingTimer: jsNull())

method connect*(t: FsWatchTransport) =
  ## Open the fs.watch handle. Idempotent — if a watcher is already
  ## active, return immediately. We require Node integration; fail
  ## loud via `onError` if `globalThis.require` is missing instead of
  ## silently no-op'ing, since a user installing this transport in a
  ## pure-browser context probably has a config bug they want to know
  ## about.
  if not t.watcher.isNil and not t.watcher.isUndefined:
    return

  let fs = requireFn(cstring"fs")
  let isAvailable = not fs.isNil and not fs.isUndefined and isFunctionJs(fs["watch"])
  if not isAvailable:
    if t.onError != nil:
      t.onError(cstring("[isonim hmr_fs_watch] fs.watch unavailable — " &
        "needs Node integration (Electron renderer, or browser with " &
        "nodeIntegration enabled)"))
    return

  proc fireUpdate() =
    if t.onUpdate != nil:
      t.onUpdate(t.bundleUrl)

  proc onChange(ev: JsObject; filename: JsObject) =
    # Debounce: arm a one-shot timer; reset it on every subsequent
    # event within the window. Only the final event in a flurry
    # triggers `onUpdate`, so a half-written bundle never makes it to
    # the browser.
    if not t.pendingTimer.isNil and not t.pendingTimer.isUndefined:
      clearTimeoutJs(t.pendingTimer)
    t.pendingTimer = setTimeoutJs(toJs(proc() =
      t.pendingTimer = jsNull()
      fireUpdate()
    ), t.debounceMs)

  t.watcher = fsWatch(fs, toJs(t.bundleFile), toJs(onChange))
  if t.onConnected != nil:
    t.onConnected()

method disconnect*(t: FsWatchTransport) =
  if not t.pendingTimer.isNil and not t.pendingTimer.isUndefined:
    clearTimeoutJs(t.pendingTimer)
    t.pendingTimer = jsNull()
  if t.watcher.isNil or t.watcher.isUndefined:
    return
  fsWatcherClose(t.watcher)
  t.watcher = jsNull()
  if t.onDisconnected != nil:
    t.onDisconnected()

proc installFsWatchTransport*(
    bundleFile: cstring;
    bundleUrl: cstring;
    debounceMs: int = 80): FsWatchTransport =
  ## Convenience wrapper: build the transport, route `onUpdate` through
  ## the default `applyBundleByScriptTag`, connect, and return the
  ## handle so the caller can `disconnect()` later if needed.
  result = newFsWatchTransport(bundleFile, bundleUrl, debounceMs)
  installTransport(result)
