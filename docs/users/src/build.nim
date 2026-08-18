## ../isonim/docs/users -- thin SSG entry (M1 corrective deliverable 4;
## metacraft-theme M2 deliverable 1's wiring).
##
## Calls the framework's own `buildSite` with this site's `content/` dir
## and its own `DocsConfig`, passing NO explicit manifest -- letting the
## framework's own default (`buildManifestFromContent`) auto-discover the
## route table from real IsoNim content, end to end.
##
## metacraft-theme M2: the CodeTracer docs theme's token layer
## (`theme_tokens.metacraftDocsTokenLayer`) is emitted to CSS and PREPENDED
## onto `assets/style.css` via `buildSite(docsTokensCss = ...)`, and the
## vendored theme binaries (Geist woff2, logo, search glyph) under `static/`
## are copied verbatim into `public/assets/` AFTER the hash/purge pass so
## the stylesheet's `url(/assets/...)` refs resolve to real files.

when defined(js):
  {.error: "build.nim is a C-target (SSG) entry; not for the JS target".}

import docs_scaffold
import ./docs_config
import ./theme_tokens

when isMainModule:
  # The framework `buildDocsSite` scaffold: SSG build + design-system token CSS
  # prepended onto the composed stylesheet (framework default + this site's
  # `assets/overrides.css`) + `static/` copied verbatim.
  let n = buildDocsSite(isonimDocsConfig(),
                        docsTokensCss = metacraftDocsTokensCss())
  echo "SSG: rendered ", n, " static pages into ./public/"
