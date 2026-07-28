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
  ## `DocsConfig`, and the Metacraft token CSS served over its `assets/` +
  ## `static/` dirs. Exposed (not just inlined below) so a test can drive the
  ## exact wiring `just dev-docs` runs without binding a socket.
  let tokensCss = emitTokensCss(metacraftDocsTokenLayer(), designSystemTokens())
  newDevServer(contentDir = contentDir, cfg = isonimDocsConfig(),
               assetsDirs = assetsDirs, docsTokensCss = tokensCss)

when isMainModule:
  let port = if paramCount() >= 1: parseInt(paramStr(1)) else: 8000
  let server = newDocsDevServer()
  stdout.writeLine "IsoNim docs dev server -> http://localhost:" & $port &
    "  (watching content/, live reload on; Ctrl-C to stop)"
  stdout.flushFile()
  waitFor serve(server, port)
