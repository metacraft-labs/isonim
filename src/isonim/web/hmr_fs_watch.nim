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
    pollIntervalMs*: int
      ## `fs.watchFile` polling interval. The renderer polls
      ## `stat(bundleFile)` this often, so a smaller value reduces
      ## HMR latency at the cost of a tiny background CPU bump.
    fsHandle: JsObject    ## cached `require('fs')` for disconnect
    isConnected: bool
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

proc fsWatchFile(fs, path, options, callback: JsObject)
  {.importjs: "#.watchFile(#, #, #)".}
  ## Wraps Node's `fs.watchFile(path, options, listener)`. We use
  ## the *polling* variant rather than the more famous inotify-based
  ## `fs.watch` because build systems (Tup, makefiles using
  ## atomic-rename, even editors writing via tmp+rename) replace the
  ## target file by renaming a sibling into place. inotify's handle
  ## tracks the *inode*, not the *path*: after a rename it stays
  ## attached to the orphaned old inode and never sees changes to
  ## the new file at the same path. `fs.watchFile` polls
  ## `stat(path)` on an interval and is rename-robust by
  ## construction. Default 250 ms polling interval — fast enough
  ## that an HMR cycle still feels instant, slow enough that the
  ## background cost is negligible.

proc fsUnwatchFile(fs, path: JsObject)
  {.importjs: "#.unwatchFile(#)".}

proc fsReadFileSync(fs, path, encoding: JsObject): cstring
  {.importjs: "#.readFileSync(#, #)".}

# document handle shared with hmr_transport.
var documentJsLocal {.importjs: "document".}: JsObject

proc applyBundleByInlineScript*(fs: JsObject; bundleFile: cstring;
                                onApplied: proc() = nil;
                                onApplyError: proc(msg: cstring) = nil) =
  ## Apply a new bundle by reading the local file via Node `fs` and
  ## injecting it as an inline `<script>` element. This sidesteps
  ## two failure modes the `<script src=URL?v=…>` approach hits:
  ##
  ## - file:// URLs with a query string fail to resolve under some
  ##   Electron + Chromium versions (the file system has no concept
  ##   of a query; if the renderer's URL handler doesn't strip it
  ##   before stat()ing, the request 404s).
  ## - Loading the same URL twice on a real HTTP server can be
  ##   served from the browser cache; the cache-bust query is the
  ##   only defence, and it's unreliable in the first case.
  ##
  ## Inline content is always fresh — every script tag has new
  ## source text and runs unconditionally.
  ##
  ## ENOENT handling: build systems (notably Tup) can move the
  ## target file aside during a rebuild, then rename the new file
  ## back into place. `fs.watchFile`'s poll may fire on the
  ## intermediate state when the path doesn't resolve. Swallow the
  ## ENOENT here; the next mtime change (from the rename completion)
  ## will trigger another reload and succeed.
  let content =
    try:
      fsReadFileSync(fs, toJs(bundleFile), toJs(cstring"utf8"))
    except CatchableError as err:
      if onApplyError != nil:
        onApplyError(cstring"[isonim hmr] read failed: " & cstring(err.msg))
      return
  let script = documentJsLocal.createElement(cstring"script")
  script["type"] = toJs(cstring"text/javascript")
  script["text"] = toJs(content)
  discard documentJsLocal["head"].appendChild(script)
  if onApplied != nil:
    onApplied()

proc newFsWatchTransport*(
    bundleFile: cstring;
    bundleUrl: cstring;
    debounceMs: int = 80;
    pollIntervalMs: int = 250): FsWatchTransport =
  FsWatchTransport(
    bundleFile: bundleFile,
    bundleUrl: bundleUrl,
    debounceMs: debounceMs,
    pollIntervalMs: pollIntervalMs,
    fsHandle: jsNull(),
    isConnected: false,
    pendingTimer: jsNull())

proc watchOptionsJs(persistent: bool; interval: int): JsObject
  {.importjs: "({persistent: #, interval: #})".}

proc statsAreEqual(a, b: JsObject): bool =
  ## importjs `#` placeholders are sequential — using the same arg
  ## twice needs an emit body.
  {.emit: [result,
    " = (", a, ".mtimeMs === ", b, ".mtimeMs && ",
    a, ".size === ", b, ".size);"].}

method connect*(t: FsWatchTransport) =
  ## Install the `fs.watchFile` poll. Idempotent — if already
  ## connected, return immediately. We require Node integration;
  ## fail loud via `onError` if `globalThis.require` is missing
  ## rather than silently no-op'ing.
  if t.isConnected:
    return

  let fs = requireFn(cstring"fs")
  let isAvailable =
    not fs.isNil and not fs.isUndefined and isFunctionJs(fs["watchFile"])
  if not isAvailable:
    if t.onError != nil:
      t.onError(cstring("[isonim hmr_fs_watch] fs.watchFile unavailable — " &
        "needs Node integration (Electron renderer, or browser with " &
        "nodeIntegration enabled)"))
    return

  proc fireUpdate() =
    if t.onUpdate != nil:
      t.onUpdate(t.bundleUrl)

  proc onPoll(curr: JsObject; prev: JsObject) =
    # `fs.watchFile`'s listener fires on every poll, even when the
    # stats are unchanged. Compare mtime + size to find the real
    # changes before arming the debounce timer.
    if statsAreEqual(curr, prev):
      return
    if not t.pendingTimer.isNil and not t.pendingTimer.isUndefined:
      clearTimeoutJs(t.pendingTimer)
    t.pendingTimer = setTimeoutJs(toJs(proc() =
      t.pendingTimer = jsNull()
      fireUpdate()
    ), t.debounceMs)

  let opts = watchOptionsJs(false, t.pollIntervalMs)
  fsWatchFile(fs, toJs(t.bundleFile), opts, toJs(onPoll))
  t.fsHandle = fs
  t.isConnected = true
  if t.onConnected != nil:
    t.onConnected()

method disconnect*(t: FsWatchTransport) =
  if not t.pendingTimer.isNil and not t.pendingTimer.isUndefined:
    clearTimeoutJs(t.pendingTimer)
    t.pendingTimer = jsNull()
  if not t.isConnected:
    return
  fsUnwatchFile(t.fsHandle, toJs(t.bundleFile))
  t.fsHandle = jsNull()
  t.isConnected = false
  if t.onDisconnected != nil:
    t.onDisconnected()

proc installFsWatchTransport*(
    bundleFile: cstring;
    bundleUrl: cstring;
    debounceMs: int = 80;
    pollIntervalMs: int = 250): FsWatchTransport =
  ## Convenience wrapper: build the transport, install a node-fs-based
  ## inline-script `onUpdate` that sidesteps file:// + cache-bust
  ## query string fragility, connect, and return the handle so the
  ## caller can `disconnect()` later if needed. The `bundleUrl`
  ## argument is kept for symmetry with the SSE transport's interface
  ## but is not used by this onUpdate path (the bundle is read by
  ## absolute filesystem path).
  let transport = newFsWatchTransport(
    bundleFile, bundleUrl, debounceMs, pollIntervalMs)
  let fs = requireFn(cstring"fs")
  if not fs.isNil and not fs.isUndefined:
    let bf = transport.bundleFile
    transport.onUpdate = proc(unusedUrl: cstring) =
      applyBundleByInlineScript(fs, bf)
  result = transport
  installTransport(result)
