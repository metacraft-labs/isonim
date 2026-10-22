## isonim/static -- the static-site primitives every IsoNim site generator
## shares (isonim-docs, isonim-blog, a hand-written `static_export.nim`):
##
## - `isonim/static/exporter`: `exportSite(pages, outDir)`, clean URLs,
##   deterministic order, atomic output (C only);
## - `isonim/static/sitemap` and `isonim/static/robots`;
## - `isonim/static/head`: canonical, OpenGraph, Twitter, JSON-LD and
##   `theme-color` in the page `<head>`;
## - `isonim/static/scripts`: the script policy (`spNone` emits no
##   executable script) and a checker for built HTML;
## - `isonim/static/csp`: Content-Security-Policy with inline-script hashes;
## - `isonim/static/assets`: hashed asset names, `asset-manifest.json`,
##   CSS purge (C only);
## - `isonim/static/buildinfo`: `build.json`;
## - `isonim/static/urls`: `joinSiteUrl`, `xmlEscape`.
##
## Importing this module imports all of them (the C-only ones only on the
## C target). Nothing else in `isonim` imports them, so they cost nothing
## unless a site uses them.

import ./static/[urls, sitemap, robots, head, scripts, csp, buildinfo]
export urls, sitemap, robots, head, scripts, csp, buildinfo

when not defined(js):
  import ./static/[assets, exporter]
  export assets, exporter
