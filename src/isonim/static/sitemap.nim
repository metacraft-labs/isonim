## isonim/static/sitemap -- `sitemap.xml` in the sitemaps.org 0.9 format
## (https://www.sitemaps.org/protocol.html), with optional `<lastmod>`.
##
## Pure string work, identical on `nim c` and `nim js`. The writer emits
## entries in the order it is given: the caller owns the order, so a
## generator that wants a stable sitemap passes its routes in a stable
## order (`isonim/static/exporter.sitemapEntriesFor` hands them over sorted
## by route; isonim-docs passes its route manifest's order). Moved from
## isonim-docs' `writeSitemapAndRobots`, whose output this reproduces byte
## for byte when no entry carries a `lastmod`.

import std/strutils
import ./urls

type
  SitemapEntry* = object
    ## One `<url>` of the sitemap.
    loc*: string     ## The page's URL: absolute when the site has a base URL
                     ## (the protocol requires it), as `joinSiteUrl` builds it.
    lastmod*: string ## W3C Datetime (https://www.w3.org/TR/NOTE-datetime):
                     ## `YYYY-MM-DD`, or a date with a time and a zone
                     ## designator. Empty omits `<lastmod>`.

  SitemapError* = object of ValueError
    ## A `lastmod` that is not a W3C Datetime. Raised rather than written,
    ## because search engines ignore (or reject) a sitemap with a bad date.

const sitemapNamespace* = "http://www.sitemaps.org/schemas/sitemap/0.9"

proc allDigits(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if c notin {'0'..'9'}: return false
  true

proc isW3cDatetime*(s: string): bool =
  ## True when `s` is one of the W3C Datetime forms the sitemap protocol
  ## accepts for `<lastmod>`: `YYYY-MM-DD`, or `YYYY-MM-DDThh:mm[:ss[.s+]]`
  ## followed by `Z` or `+hh:mm`/`-hh:mm`. (The bare year and year-month
  ## forms are valid W3C Datetimes too, but a page's last modification is
  ## always at least a day, so they are refused as likely mistakes.)
  if s.len < 10: return false
  let date = s[0 ..< 10]
  if not (allDigits(date[0 .. 3]) and date[4] == '-' and allDigits(date[5 .. 6]) and
          date[7] == '-' and allDigits(date[8 .. 9])):
    return false
  let month = parseInt(date[5 .. 6])
  let day = parseInt(date[8 .. 9])
  let year = parseInt(date[0 .. 3])
  if year == 0 or month < 1 or month > 12 or day < 1: return false
  const monthDays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  let leap = year mod 4 == 0 and (year mod 100 != 0 or year mod 400 == 0)
  let limit = monthDays[month - 1] + (if month == 2 and leap: 1 else: 0)
  if day > limit: return false
  if s.len == 10: return true
  if s[10] != 'T': return false
  var rest = s[11 .. ^1]
  # The zone designator is mandatory once a time is present.
  var zoneOk = false
  if rest.endsWith("Z"):
    rest = rest[0 ..< rest.len - 1]
    zoneOk = true
  elif rest.len >= 6 and rest[^6] in {'+', '-'} and allDigits(rest[^5 .. ^4]) and
       rest[^3] == ':' and allDigits(rest[^2 .. ^1]):
    if parseInt(rest[^5 .. ^4]) > 23 or parseInt(rest[^2 .. ^1]) > 59: return false
    rest = rest[0 ..< rest.len - 6]
    zoneOk = true
  if not zoneOk: return false
  # hh:mm, hh:mm:ss or hh:mm:ss.fraction
  if rest.len < 5 or not (allDigits(rest[0 .. 1]) and rest[2] == ':' and allDigits(rest[3 .. 4])):
    return false
  if parseInt(rest[0 .. 1]) > 23 or parseInt(rest[3 .. 4]) > 59: return false
  if rest.len == 5: return true
  # The adopted W3C NOTE-datetime profile defines seconds as 00 through 59.
  if rest.len < 8 or rest[5] != ':' or not allDigits(rest[6 .. 7]) or parseInt(rest[6 .. 7]) > 59:
    return false
  if rest.len == 8: return true
  rest[8] == '.' and allDigits(rest[9 .. ^1])

proc renderSitemap*(entries: openArray[SitemapEntry]): string =
  ## The whole `sitemap.xml` document, one `<url>` line per entry in the
  ## order given. Raises `SitemapError` for a `lastmod` that is not a W3C
  ## Datetime.
  result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
    "<urlset xmlns=\"" & sitemapNamespace & "\">\n"
  for e in entries:
    result.add "  <url><loc>" & xmlEscape(e.loc) & "</loc>"
    if e.lastmod.len > 0:
      if not isW3cDatetime(e.lastmod):
        raise newException(SitemapError, "sitemap: lastmod of " & e.loc &
          " is not a W3C Datetime (YYYY-MM-DD or YYYY-MM-DDThh:mm[:ss]Z): '" &
          e.lastmod & "'")
      result.add "<lastmod>" & xmlEscape(e.lastmod) & "</lastmod>"
    result.add "</url>\n"
  result.add "</urlset>\n"

proc sitemapEntry*(baseUrl, routePath: string; lastmod = ""): SitemapEntry =
  ## The entry for one route: `routePath` joined onto `baseUrl`.
  SitemapEntry(loc: joinSiteUrl(baseUrl, routePath), lastmod: lastmod)
