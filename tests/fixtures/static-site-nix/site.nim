## A minimal static-site exporter built on `isonim/static`, used as the
## fixture of the flake's hermetic builder (`lib.<system>.buildStaticSite`,
## `nix/static-site.nix`) and its `checks.<system>.static-site-fixture`.
##
## It turns every `pages/<name>.txt` into a page (`index` -> `/`, `about`
## -> `/about`, anything else -> `/posts/<name>`), with the SEO head under
## the `spNone` script policy, then writes the sitemap (each page's
## `lastmod` is the build date taken from `SOURCE_DATE_EPOCH`), robots.txt
## and build.json. Nothing in the output depends on the wall clock or on
## the order the file system lists `pages/` in.
##
## Usage: `site [outDir]` from the directory holding `pages/`; `outDir`
## defaults to `public`. `SOURCE_DATE_EPOCH` must be set.

import std/[os, strutils, times]
import isonim/static
import isonim/ssr/escape

const baseUrl = "https://example.org"

proc routeFor(name: string): string =
  case name
  of "index": "/"
  of "about": "/about"
  else: "/posts/" & name

proc renderPage(route, body: string): string =
  var head = DocumentHead(title: formatPageTitle(if route == "/": "" else: route, "Example"),
    description: body.strip, stylesheetHref: "/assets/style.css", siteName: "Example",
    canonicalUrl: joinSiteUrl(baseUrl, route),
    ogType: (if route.startsWith("/posts/"): "article" else: "website"),
    themeColors: @[ThemeColor(color: "#ffffff", media: "(prefers-color-scheme: light)"),
                   ThemeColor(color: "#111111", media: "(prefers-color-scheme: dark)")])
  head.jsonLd = articleJsonLd(head, if route.startsWith("/posts/"): "BlogPosting" else: "WebPage")
  "<!doctype html><html lang=\"en\">" & renderPageHeadHtml(head, [], spNone) &
    "<body><main><p>" & escapeHtml(body.strip) & "</p></main></body></html>\n"

proc main() =
  let outDir = if paramCount() >= 1: paramStr(1) else: "public"
  let epoch = sourceDateEpochFromEnv()
  if epoch < 0:
    raise newException(ValueError, "SOURCE_DATE_EPOCH must be set for a reproducible build")
  let buildDate = fromUnix(epoch).utc.format("yyyy-MM-dd")
  var pages: seq[SitePage]
  for f in readTreeFiles("pages"):
    let name = f.path.splitFile.name
    let route = routeFor(name)
    pages.add SitePage(route: route, html: renderPage(route, f.content), lastmod: buildDate)
  let files = @[
    SiteFile(path: "sitemap.xml", content: renderSitemap(sitemapEntriesFor(pages, baseUrl))),
    SiteFile(path: "robots.txt", content: renderRobots(sitemapUrlFor(baseUrl))),
    SiteFile(path: "assets/style.css",
             content: ":root{color-scheme:light dark}body{font-family:system-ui}\n"),
  ]
  let report = exportSite(pages, outDir, files)
  discard writeBuildInfo(outDir, SiteBuildInfo(generator: "isonim static-site fixture",
    sourceRevision: getEnv("ISONIM_SITE_REVISION"), sourceDateEpoch: epoch))
  echo "exported ", report.pages.len, " pages and ", report.files.len - report.pages.len,
    " files to ", outDir

when isMainModule:
  main()
