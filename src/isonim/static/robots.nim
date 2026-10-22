## isonim/static/robots -- `robots.txt` (RFC 9309,
## https://www.rfc-editor.org/rfc/rfc9309) with a `Sitemap:` line.
##
## Pure string work, identical on `nim c` and `nim js`. The default
## (`renderRobots(sitemapUrl)`) is the file isonim-docs and isonim.com
## have always written: allow everything, and point at the sitemap.

import std/strutils
import ./urls

type
  RobotsGroup* = object
    ## One group of rules for one user agent, in the order written.
    userAgent*: string     ## `*` for every crawler.
    allow*: seq[string]    ## Path prefixes crawlers may fetch.
    disallow*: seq[string] ## Path prefixes crawlers may not fetch.

proc defaultRobotsGroup*(): RobotsGroup =
  ## Every crawler may fetch everything.
  RobotsGroup(userAgent: "*", allow: @["/"])

proc checkRobotsValue(field, value: string) =
  ## A value with a line break would start a new record and silently
  ## change the policy, so it is refused rather than written.
  if '\n' in value or '\r' in value:
    raise newException(ValueError, "robots.txt: " & field &
      " must be a single line: " & escape(value))

proc renderRobots*(groups: openArray[RobotsGroup]; sitemapUrl = ""): string =
  ## The `robots.txt` text: each group's `User-agent:` line followed by its
  ## `Allow:` then `Disallow:` lines, groups separated by a blank line, and
  ## a final `Sitemap:` line when `sitemapUrl` is set. Raises `ValueError`
  ## for a value containing a line break.
  for i, g in groups:
    if i > 0: result.add "\n"
    checkRobotsValue("User-agent", g.userAgent)
    result.add "User-agent: " & g.userAgent & "\n"
    for p in g.allow:
      checkRobotsValue("Allow", p)
      result.add "Allow: " & p & "\n"
    for p in g.disallow:
      checkRobotsValue("Disallow", p)
      result.add "Disallow: " & p & "\n"
  if sitemapUrl.len > 0:
    checkRobotsValue("Sitemap", sitemapUrl)
    result.add "Sitemap: " & sitemapUrl & "\n"

proc renderRobots*(sitemapUrl: string): string =
  ## The default policy: `User-agent: *`, `Allow: /`, then the sitemap.
  renderRobots([defaultRobotsGroup()], sitemapUrl)

proc sitemapUrlFor*(baseUrl: string; sitemapPath = "/sitemap.xml"): string =
  ## The sitemap's URL on a site with `baseUrl` (root-relative when the
  ## site has none).
  joinSiteUrl(baseUrl, sitemapPath)
