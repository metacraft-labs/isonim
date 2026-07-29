## Live-reloading dev server for the IsoNim docs site.
##
## Serves this site's own `content/` plus its themed assets -- `assets/style.css`
## with the Metacraft token CSS prepended, and the `static/` fonts & icons (the
## same dirs `build.nim` maps into `public/assets/`) -- over HTTP, and watches
## `content/` so any add/edit/remove hot-reloads every open browser tab (via the
## framework's `dev_server` WebSocket live-reload channel).
##
## Note: `basePath` (set on the BUILT site for GitHub project-Pages hosting) is a
## `buildSite`-only URL transform. The dev server renders root-relative URLs via
## `renderRoute`, so everything resolves at http://localhost:<port>/ with no
## prefix -- the dev experience is byte-for-byte the served look, sans subpath.
##
## Driven by `just dev-docs` (server) + `just open-docs` (browser). Optional first arg is
## the port (default 8000).

import std/[os, strutils, asyncdispatch]
import dev_server
import core/docs_tokens
import ./docs_config
import ./theme_tokens

export dev_server

proc newDocsDevServer*(contentDir = "content";
                       assetsDirs = @["assets", "static"]): DevServer =
  ## Constructs this site's themed live-reload dev server: its own `content/`,
  ## `DocsConfig`, and the shared design-system token CSS served over its
  ## `assets/` + `static/` dirs. The tokens are read LIVE (and the token file is
  ## watched), so editing the shared design system hot-reloads the theme with no
  ## rebuild. Exposed so a test can drive the exact `just dev-docs` wiring
  ## without binding a socket.
  newDevServer(contentDir = contentDir, cfg = isonimDocsConfig(),
               assetsDirs = assetsDirs,
               docsTokensCss = docsTokensCssLive(),
               tokensCssProvider = (proc(): string = docsTokensCssLive()),
               watchPaths = @[docsDesignSystemPath])

when isMainModule:
  let port = if paramCount() >= 1: parseInt(paramStr(1)) else: 8000
  # host: 2nd arg or AH_DEV_HOST env; default loopback (pass 0.0.0.0 for LAN).
  let host =
    if paramCount() >= 2: paramStr(2)
    elif existsEnv("AH_DEV_HOST"): getEnv("AH_DEV_HOST")
    else: "127.0.0.1"
  let server = newDocsDevServer()
  stdout.writeLine "IsoNim docs dev server -> http://" & host & ":" & $port &
    "  (watching content/ + shared design system, live reload on; Ctrl-C to stop)"
  stdout.flushFile()
  waitFor serve(server, port, host = host)
