## ../isonim/docs/users -- M1 corrective deliverable 4's declared
## Verification test (C-target only).
##
## Proves this site's own `content/` dir, addressed purely via the
## framework's auto-discovery (no explicit manifest passed anywhere --
## `ssr.nim`'s own `renderRoute` wrapper never supplies one either),
## renders all 11 real IsoNim pages, each with its own real title and
## this site's own branding, end to end.

import std/[unittest, os, strutils]
import core/routes
import core/content
import ../src/ssr

suite "IsoNim docs site -- auto-discovered routes all render (Tier 3, C-target)":
  test "every real content/ page auto-discovers to a route that renders 200 with its own title":
    let repoRoot = currentSourcePath().parentDir().parentDir()
    let contentDir = repoRoot / "content"
    let manifest = buildManifestFromContent(contentDir)
    let entries = loadContentEntries(contentDir)

    check entries.len == 11
    check manifest.entries.len == entries.len

    for entry in manifest.entries:
      check entry.status == rsOk
      check entry.meta.title.len > 0
      let (status, html) = renderRoute(entry.canonicalPath, contentDir)
      check status == 200
      check html.contains(entry.meta.title)
      check html.contains("IsoNim Docs") # this site's own DocsConfig branding
