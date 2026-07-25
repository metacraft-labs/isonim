## ../isonim/docs/users -- thin SSG entry (M1 corrective deliverable 4).
##
## Calls the framework's own `buildSite` with this site's `content/` dir
## and its own `DocsConfig`, passing NO explicit manifest -- letting the
## framework's own default (`buildManifestFromContent`) auto-discover the
## route table from real IsoNim content, end to end.

when defined(js):
  {.error: "build.nim is a C-target (SSG) entry; not for the JS target".}

import build_site
import ./docs_config

when isMainModule:
  let n = buildSite(contentDir = "content", cfg = isonimDocsConfig())
  echo "SSG: rendered ", n, " static pages into ./public/"
