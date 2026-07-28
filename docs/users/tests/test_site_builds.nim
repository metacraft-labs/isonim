## ../isonim/docs/users -- M1 corrective deliverable 4's declared
## Verification test (C-target only).
##
## Proves this site's own `content/` dir, addressed purely via the
## framework's auto-discovery (no explicit manifest passed anywhere --
## `ssr.nim`'s own `renderRoute` wrapper never supplies one either),
## renders all 12 real IsoNim pages, each with its own real title and
## this site's own branding, end to end.
##
## M1 corrective deliverable 5.2: a SECOND suite below drives the REAL
## on-disk `buildSite()` (the exact path `just build`/`src/build.nim`
## takes) into a temp dir and asserts the emitted `public/` -- the
## on-disk stylesheet-copy/hash/dangle path the in-memory `renderRoute`
## suite above never exercised, and which hid the original build breakage
## (declared `stylesheetHref` dangling because the site shipped no
## `assets/`). This closes that test-coverage gap so a broken build is
## caught by the suite, not by a manual `just build`.

import std/[unittest, os, strutils]
import core/routes
import core/content
import build_site          ## the framework's real on-disk SSG entry
import ../src/ssr
import ../src/docs_config  ## this site's own DocsConfig (isonimDocsConfig)

suite "IsoNim docs site -- auto-discovered routes all render (Tier 3, C-target)":
  test "every real content/ page auto-discovers to a route that renders 200 with its own title":
    let repoRoot = currentSourcePath().parentDir().parentDir()
    let contentDir = repoRoot / "content"
    let manifest = buildManifestFromContent(contentDir)
    let entries = loadContentEntries(contentDir)

    check entries.len == 12
    check manifest.entries.len == entries.len

    for entry in manifest.entries:
      check entry.status == rsOk
      check entry.meta.title.len > 0
      let (status, html) = renderRoute(entry.canonicalPath, contentDir)
      check status == 200
      check html.contains(entry.meta.title)
      check html.contains("CodeTracer Docs") # this site's own DocsConfig branding (metacraft-theme M2)

proc extractStylesheetHref(html: string): string =
  ## Pull the `href` out of the document's `<link rel="stylesheet" ...>`
  ## exactly as the browser would resolve it -- so the test asserts the
  ## real asset URL the shipped page points at, not an assumed name.
  const relMarker = "rel=\"stylesheet\""
  let relPos = html.find(relMarker)
  doAssert relPos >= 0, "emitted index.html has no <link rel=\"stylesheet\">"
  const hrefKey = "href=\""
  let hrefPos = html.find(hrefKey, relPos)
  doAssert hrefPos >= 0, "stylesheet <link> has no href"
  let start = hrefPos + hrefKey.len
  let stop = html.find('"', start)
  doAssert stop > start, "stylesheet href attribute is unterminated"
  html[start ..< stop]

suite "IsoNim docs site -- real on-disk buildSite() emits a non-dangling public/ (Tier 3, C-target)":
  test "buildSite() into a temp dir: build succeeds, index.html + referenced hashed stylesheet exist non-empty on disk":
    let repoRoot = currentSourcePath().parentDir().parentDir()
    let contentDir = repoRoot / "content"
    let assetsDir = repoRoot / "assets"
    let outDir = getTempDir() / "isonim_docs_users_ondisk_build"

    ## Drive the SAME entry `src/build.nim` uses -- this site's own
    ## `content/`, own `assets/`, own `DocsConfig` -- but into a temp
    ## `public/`, so the assertions below observe the real emitted site.
    let pageCount = buildSite(outDir = outDir, contentDir = contentDir,
                              cfg = isonimDocsConfig(), assetsDir = assetsDir)

    ## 1. Build exited success and rendered at least one real content page.
    check pageCount >= 1
    check pageCount == 12 # every real IsoNim content/ page (redirects excluded)

    ## 2. public/index.html exists on disk and is non-empty.
    let indexPath = outDir / "index.html"
    check fileExists(indexPath)
    let indexHtml = readFile(indexPath)
    check indexHtml.len > 0
    check indexHtml.contains("CodeTracer Docs") # a real content page really rendered (metacraft-theme M2)

    ## 3. The stylesheet the emitted page references exists on disk and is
    ## non-empty -- i.e. `stylesheetHref` is NOT dangling. The declared
    ## href is `/assets/style.css`; the build's hash+purge pipeline
    ## rewrites it to a content-hashed name, so what index.html points at
    ## must be that hashed file, present and non-empty in public/.
    let cssHref = extractStylesheetHref(indexHtml)
    check cssHref.startsWith("/assets/style.")
    check cssHref.endsWith(".css")
    check cssHref != "/assets/style.css" # proves the hash/purge pipeline ran
    let cssPath = outDir / cssHref[1 .. ^1] # strip leading '/' -> path under outDir
    check fileExists(cssPath)
    check getFileSize(cssPath) > 0 # the referenced hashed stylesheet does NOT dangle

    ## 4. At least one non-root real content page also landed on disk
    ## (guard against a build that emits only "/"): a known guide route.
    let guidePath = outDir / "guide" / "install-setup" / "index.html"
    check fileExists(guidePath)
    check getFileSize(guidePath) > 0

    removeDir(outDir) # temp-dir hygiene; buildSite itself also removeDir's on entry
