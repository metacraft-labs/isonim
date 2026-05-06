## tests/browser/hmr_transport_fixture/server.nim
##
## A standalone Nim binary that serves the transport fixture and
## exposes the HMR endpoints. The test starts this via Playwright's
## `webServer` config.
##
## The router serves index.html for `/` and falls through to the
## `serveRouterHmr` for everything else. The bundle is served at
## `/main.js`; events at `/__isonim/hmr`; trigger at `/__isonim/trigger`.

import std/[os, strutils]
import isonim/server/dev_server
import isonim/server/handler
import isonim/server/http_types

proc main() =
  let here = currentSourcePath().parentDir()
  let bundleFile = here / "main.js"

  # The "rebuild" is just `cp after.js main.js`. That stand-in lets the
  # test drive the loop without invoking nim js.
  let rebuildCmd = @["cp", here / "after.js", bundleFile]

  let hmr = newHmrServer(
    rebuildCommand = rebuildCmd,
    bundleFile = bundleFile,
    bundlePath = "/main.js",
    watchPaths = @[],   # no built-in watcher; test triggers manually
  )

  var router = newRouter()
  router.get "/", proc(req: HttpRequest, resp: HttpResponse) =
    let html = readFile(here / "index.html")
    resp.statusCode = 200
    resp.writeHeader("content-type", "text/html; charset=utf-8")
    resp.writeBody(html)

  let portStr = getEnv("HMR_TRANSPORT_PORT", "8083")
  let port = parseInt(portStr)

  serveRouterHmr(router, hmr, port = port, enableWatcher = false)

main()
