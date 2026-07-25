## ../isonim/docs/users -- thin SSR entry (M1 corrective deliverable 4).
##
## Calls the framework's own `renderRoute` with this site's `content/`
## dir and its own `DocsConfig`, passing NO explicit manifest -- letting
## the framework's own default (`buildManifestFromContent`, M1 corrective
## deliverables 1+2) auto-discover the route table from real IsoNim
## content, end to end.

when defined(js):
  {.error: "ssr.nim is a C-target (server-side) entry point".}

import "../../../../isonim-docs/src/ssr" as frameworkSsr
import ./docs_config

proc renderRoute*(path: string; contentDir = "content"): tuple[status: int, html: string] =
  frameworkSsr.renderRoute(path, contentDir, cfg = isonimDocsConfig())

when isMainModule:
  ## A real HTTP dev server is M11's job (not yet built) -- this is a
  ## proof-of-life SSR smoke check: renders "/" and reports it, so
  ## `just serve` has something real to run today.
  let (status, html) = renderRoute("/")
  echo "SSR smoke: GET / -> ", status, " (", html.len, " bytes)"
