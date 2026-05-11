## isonim/web/hmr_css_watch.nim
##
## CSS LiveReload transport for IsoNim HMR.
##
## Stylesheet edits never need a JS slot rewrite — they just need the
## browser to refetch the file. This module watches a local CSS file
## via Node's `fs.watch` (same pattern as `hmr_fs_watch.nim`) and on
## change rewrites the matching `<link rel="stylesheet">` tag's `href`
## to a cache-busted URL. The browser refetches and applies the new
## styles without a full page reload, preserving DOM state, focus,
## and in-flight transitions.
##
## Compared with the bundle-watching JS transport, the CSS variant
## does not propagate through any reactive cascade — the swap is
## purely a `link.href = newUrl` assignment. That makes this module
## independent of the slot system; it can be used in isonim apps that
## opt out of `{.uiComponent.}` HMR but still want stylesheet
## live-reload.
##
## The pattern is the one LiveReload (livereload-js) uses for CSS
## updates. We avoid removing the old `<link>` and adding a new one
## (which would briefly leave the page unstyled while the new sheet
## downloads); instead we attach a fresh `<link>` first, wait for its
## `load` event, then update the original tag's href and detach the
## clone. Browsers de-duplicate concurrent requests for the same URL,
## so the network cost is one fetch.

when not defined(js):
  {.error: "isonim/web/hmr_css_watch requires the JS backend".}

when not defined(isonimHmr):
  {.error: "isonim/web/hmr_css_watch requires `-d:isonimHmr`".}

import std/jsffi

type
  CssWatcher* = ref object
    ## Handle for a single CSS file watcher. `disconnect()` tears down
    ## the underlying `fs.watchFile` poll and the pending debounce
    ## timer.
    bundleFile*: cstring
    linkSelector*: cstring
      ## CSS selector identifying the `<link>` tag to update on each
      ## change. Typically `link[href*="<filename>"]` or a more
      ## specific selector.
    debounceMs*: int
    pollIntervalMs*: int
    fsHandle: JsObject
    isConnected: bool
    pendingTimer: JsObject
    onError*: proc(msg: cstring)
    onUpdate*: proc(href: cstring)
      ## Optional callback invoked with the new (cache-busted) href
      ## after a successful swap. Useful for tests / overlays.

# ---------------------------------------------------------------------------
# JS interop helpers
# ---------------------------------------------------------------------------

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
  ## Polling-based watcher. See the matching note in
  ## `hmr_fs_watch.nim` — build systems that replace files via
  ## atomic rename (Tup, Stylus's own out-file dance) defeat
  ## inotify-backed `fs.watch`, so we poll via `fs.watchFile`.

proc fsUnwatchFile(fs, path: JsObject)
  {.importjs: "#.unwatchFile(#)".}

proc watchOptionsJs(persistent: bool; interval: int): JsObject
  {.importjs: "({persistent: #, interval: #})".}

proc statsAreEqual(a, b: JsObject): bool =
  ## importjs `#` placeholders are sequential — using the same arg
  ## twice needs an emit body.
  {.emit: [result,
    " = (", a, ".mtimeMs === ", b, ".mtimeMs && ",
    a, ".size === ", b, ".size);"].}

# Browser-side helpers — these run in the renderer's window context.

proc querySelectorJs(selector: cstring): JsObject
  {.importjs: "document.querySelector(#)".}

proc createElementJs(tag: cstring): JsObject
  {.importjs: "document.createElement(#)".}

proc appendChildToHead(node: JsObject)
  {.importjs: "document.head.appendChild(#)".}

proc removeNodeJs(node: JsObject) =
  ## Importjs `#` placeholders are sequential — referencing the same
  ## param twice forces an emit body.
  {.emit: ["if (", node, ".parentNode) ", node, ".parentNode.removeChild(", node, ");"].}

proc setAttrJs(node: JsObject; name, value: cstring)
  {.importjs: "#.setAttribute(#, #)".}

proc getAttrJs(node: JsObject; name: cstring): cstring
  {.importjs: "(#.getAttribute(#) || '')".}

proc onLoadJs(node: JsObject; cb: JsObject)
  {.importjs: "#.addEventListener('load', #)".}

proc onErrorJs(node: JsObject; cb: JsObject)
  {.importjs: "#.addEventListener('error', #)".}

proc dateNowJs(): cstring =
  ## Patterns without `#` placeholders are rejected by importjs as
  ## "no pattern" — emit body it is.
  {.emit: [result, " = String(Date.now());"].}

# ---------------------------------------------------------------------------
# Cache-busted URL construction
# ---------------------------------------------------------------------------

proc cacheBust(href: cstring): cstring =
  ## Returns `href` with a fresh `?v=<ms>` query parameter (or `&v=...`
  ## if the URL already has a query). Existing `v=...` parameters are
  ## NOT stripped — successive bursts produce successive params, which
  ## is harmless but slightly noisy. Browsers treat each version as a
  ## distinct cache entry, so this never returns a stale stylesheet.
  var hasQuery: bool
  {.emit: [hasQuery, " = (", href, ".indexOf('?') !== -1);"].}
  let separator: cstring =
    if hasQuery: cstring"&" else: cstring"?"
  result = href & separator & cstring"v=" & dateNowJs()

# ---------------------------------------------------------------------------
# Swap logic — swap-then-replace pattern
# ---------------------------------------------------------------------------

proc swapLinkHref*(linkNode: JsObject; newHref: cstring;
                    onDone: proc(href: cstring) = nil) =
  ## Fetch the new sheet via a clone, then atomically update the
  ## original link's href and detach the clone. Browsers reuse the
  ## already-cached stylesheet from the clone fetch when the original
  ## link's href changes, so the page never goes unstyled.
  let oldHref = getAttrJs(linkNode, cstring"href")
  if oldHref.len == 0:
    return

  let clone = createElementJs(cstring"link")
  setAttrJs(clone, cstring"rel", cstring"stylesheet")
  setAttrJs(clone, cstring"href", newHref)
  # Place after the original so cascade order is preserved if the
  # browser ever ends up applying both for a frame.
  proc afterLoad(ev: JsObject) =
    setAttrJs(linkNode, cstring"href", newHref)
    removeNodeJs(clone)
    if onDone != nil: onDone(newHref)
  proc afterError(ev: JsObject) =
    # Network failure or 404 — keep the old sheet in place. Removing
    # the broken clone avoids it lingering as a half-applied
    # alternate stylesheet.
    removeNodeJs(clone)
  onLoadJs(clone, toJs(afterLoad))
  onErrorJs(clone, toJs(afterError))
  appendChildToHead(clone)

# ---------------------------------------------------------------------------
# Watcher construction
# ---------------------------------------------------------------------------

proc newCssWatcher*(bundleFile, linkSelector: cstring;
                    debounceMs: int = 80;
                    pollIntervalMs: int = 250): CssWatcher =
  CssWatcher(
    bundleFile: bundleFile,
    linkSelector: linkSelector,
    debounceMs: debounceMs,
    pollIntervalMs: pollIntervalMs,
    fsHandle: jsNull(),
    isConnected: false,
    pendingTimer: jsNull())

proc connect*(t: CssWatcher) =
  ## Install the fs.watchFile poll. Idempotent.
  if t.isConnected:
    return

  let fs = requireFn(cstring"fs")
  let isAvailable =
    not fs.isNil and not fs.isUndefined and isFunctionJs(fs["watchFile"])
  if not isAvailable:
    if t.onError != nil:
      t.onError(cstring("[isonim hmr_css_watch] fs.watchFile unavailable — " &
        "needs Node integration (Electron renderer, or browser with " &
        "nodeIntegration enabled)"))
    return

  let linkNode = querySelectorJs(t.linkSelector)
  if linkNode.isNil or linkNode.isUndefined:
    if t.onError != nil:
      t.onError(cstring("[isonim hmr_css_watch] no element matches selector " & $t.linkSelector))
    return

  proc fireSwap() =
    let oldHref = getAttrJs(linkNode, cstring"href")
    let newHref = cacheBust(oldHref)
    proc onDone(h: cstring) =
      if t.onUpdate != nil: t.onUpdate(h)
    swapLinkHref(linkNode, newHref, onDone)

  proc onPoll(curr: JsObject; prev: JsObject) =
    if statsAreEqual(curr, prev):
      return
    if not t.pendingTimer.isNil and not t.pendingTimer.isUndefined:
      clearTimeoutJs(t.pendingTimer)
    t.pendingTimer = setTimeoutJs(toJs(proc() =
      t.pendingTimer = jsNull()
      fireSwap()
    ), t.debounceMs)

  let opts = watchOptionsJs(false, t.pollIntervalMs)
  fsWatchFile(fs, toJs(t.bundleFile), opts, toJs(onPoll))
  t.fsHandle = fs
  t.isConnected = true

proc disconnect*(t: CssWatcher) =
  if not t.pendingTimer.isNil and not t.pendingTimer.isUndefined:
    clearTimeoutJs(t.pendingTimer)
    t.pendingTimer = jsNull()
  if not t.isConnected:
    return
  fsUnwatchFile(t.fsHandle, toJs(t.bundleFile))
  t.fsHandle = jsNull()
  t.isConnected = false

proc installCssWatcher*(bundleFile, linkSelector: cstring;
                        debounceMs: int = 80;
                        pollIntervalMs: int = 250): CssWatcher =
  ## Convenience wrapper: build the watcher, connect, return the
  ## handle so the caller can `disconnect()` later if needed.
  result = newCssWatcher(bundleFile, linkSelector, debounceMs, pollIntervalMs)
  result.connect()
