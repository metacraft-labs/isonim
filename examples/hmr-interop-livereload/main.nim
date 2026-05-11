## examples/hmr-interop-livereload/main.nim
##
## A tiny app that installs the LiveReload transport. The whole
## file's only purpose is to prove that when a LiveReload-protocol
## server sends `{"command": "reload", "path": "..."}` over its
## WebSocket, this isonim runtime reacts the right way:
##
##   - For a `.css` path the matching <link>'s href gets a cache-bust
##     query and the browser refetches.
##   - For anything else the configured bundle URL is reloaded via
##     applyBundleByScriptTag — the same path the SSE transport
##     takes.

when not defined(js):
  {.error: "LiveReload demo requires the JS backend".}

import std/jsffi
import isonim/web/hmr_livereload

# Bake a marker into globalThis so the Playwright spec can detect
# the bundle reload. The "version" string is part of the build
# output; the test swaps main.js for one with a different version
# before asking the LiveReload server to send the reload signal.
const buildVersion = "v1-initial"

var globalJs {.importjs: "globalThis".}: JsObject
globalJs["__ct_livereload_build"] = toJs(cstring(buildVersion))

discard installLiveReloadTransport(
  url = cstring"ws://localhost:35729/livereload",
  bundleUrl = cstring"main.js")
