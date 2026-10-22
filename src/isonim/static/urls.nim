## isonim/static/urls -- the URL and XML-text helpers every static-site
## artifact shares (canonical links, the sitemap, `robots.txt`).
##
## Pure string work with no `std/os` or `std/uri`, so it behaves
## identically on `nim c` and `nim js`. Moved from isonim-docs
## (`src/core/config.nim`'s `joinSiteUrl` and `src/build_site.nim`'s
## sitemap escaper), which now re-export it.

proc joinSiteUrl*(baseUrl, routePath: string): string =
  ## Joins a site's `baseUrl` (e.g. `"https://example.com"`) with a route
  ## path into the absolute URL that canonical links, OpenGraph tags and
  ## the sitemap cite. A route path without a leading `/` gets one, and an
  ## empty one is `/`; trailing slashes on `baseUrl` are dropped so the
  ## join never doubles them. With no `baseUrl` it returns the
  ## root-relative path unchanged: the library never invents a host it
  ## was not given.
  var p = routePath
  if p.len == 0: p = "/"
  if p[0] != '/': p = "/" & p
  if baseUrl.len == 0:
    return p
  var b = baseUrl
  while b.len > 1 and b[^1] == '/':
    b = b[0 ..< b.len - 1]
  b & p

proc xmlEscape*(s: string): string =
  ## Escapes the five XML special characters for text and attribute
  ## content (the sitemap's `<loc>` and `<lastmod>` values). See
  ## https://www.w3.org/TR/xml/#syntax.
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    of '\'': result.add "&apos;"
    else: result.add c
