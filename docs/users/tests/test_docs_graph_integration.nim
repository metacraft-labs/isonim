## ../isonim/docs/users -- real content/ dir integration check
## (C-target only).
##
## Moved here from isonim-docs' own
## `tests/docs/test_docs_graph_integration_renderroute.nim` (M1
## corrective deliverable 4): proves the content loader, routing,
## navigation, and references all agree on this site's own real content
## graph and `docsRouteManifest()`.

import std/[unittest, os, strutils]
import core/content
import core/routes
import core/navigation_vm
import core/references
import "../../../../isonim-docs/src/ssr" as frameworkSsr
import ../src/docs_config

suite "docs integration -- the real content/ dir: content loader, routing, navigation, and references agree (Tier 3, C-target)":
  test "loadContentEntries, docsRouteManifest, buildNavPages, validateContentGraph, and renderRoute all agree on the exact same real pages":
    let repoRoot = currentSourcePath().parentDir().parentDir()
    let contentDir = repoRoot / "content"
    let manifest = docsRouteManifest()

    var boundCount = 0
    for entry in manifest.entries:
      if entry.status == rsOk: inc boundCount

    check loadContentEntries(contentDir).len == boundCount

    validateContentGraph(contentDir, manifest)

    let navPages = buildNavPages(manifest,
      proc(contentPath: string): ContentEntry = loadContentEntry(contentDir, contentPath))
    check navPages.len == boundCount

    for entry in manifest.entries:
      if entry.status != rsOk: continue
      let (status, html) = frameworkSsr.renderRoute(entry.canonicalPath, contentDir, manifest, isonimDocsConfig())
      check status == 200
      check html.contains("<nav id=\"docs-region-nav\" class=\"docs-nav\">")
