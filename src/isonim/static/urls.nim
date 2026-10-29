## isonim/static/urls -- the URL and XML-text helpers every static-site
## artifact shares (canonical links, the sitemap, `robots.txt`), and the web
## origins that remote images and a Content-Security-Policy name.
##
## Pure string work with no `std/os` or `std/uri`, so it behaves
## identically on `nim c` and `nim js`. Moved from isonim-docs
## (`src/core/config.nim`'s `joinSiteUrl` and `src/build_site.nim`'s
## sitemap escaper), which now re-export it.

import std/strutils

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

# --- Web origins --------------------------------------------------------------
#
# An origin is a scheme, host and port (RFC 6454 §4,
# https://www.rfc-editor.org/rfc/rfc6454#section-4), serialised as
# `scheme://host[:port]` (§6.2) with the scheme and host in lower case and
# the scheme's default port left out. This is the form a CSP host-source
# names (https://www.w3.org/TR/CSP3/#grammardef-host-source), so an origin
# written by `parseWebOrigin` can be put in a policy as it is. Only `http`
# and `https` are web origins here; hosts are DNS names, IPv4 addresses or
# bracketed IPv6 literals.

proc splitOrigin(url: string): tuple[ok: bool, origin, rest: string] =
  ## The origin of an absolute `http`/`https` URL and what follows it (the
  ## path, query and fragment). `ok` is false for anything else, and for a
  ## URL whose authority has user information, an empty or malformed host or
  ## an invalid port.
  let lower = url.toLowerAscii
  var scheme = ""
  for candidate in ["https", "http"]:
    if lower.len > candidate.len + 3 and lower[0 ..< candidate.len + 3] == candidate & "://":
      scheme = candidate
      break
  if scheme.len == 0: return
  let start = scheme.len + 3
  var stop = start
  while stop < url.len and url[stop] notin {'/', '?', '#'}: inc stop
  let authority = lower[start ..< stop]
  result.rest = url[stop .. ^1]
  if authority.len == 0 or '@' in authority: return
  var host = authority
  var port = ""
  if host[0] == '[':
    var close = -1
    for i, c in host:
      if c == ']':
        close = i
        break
    if close < 0: return
    for c in host[1 ..< close]:
      if c notin {'0' .. '9', 'a' .. 'f', ':', '.'}: return
    if close + 1 < host.len:
      if host[close + 1] != ':': return
      port = host[close + 2 .. ^1]
    host = host[0 .. close]
  else:
    var colon = -1
    for i, c in host:
      if c == ':':
        colon = i
        break
    if colon >= 0:
      port = host[colon + 1 .. ^1]
      host = host[0 ..< colon]
    for c in host:
      if c notin {'a' .. 'z', '0' .. '9', '-', '.'}: return
    if host.len == 0 or host[0] in {'-', '.'} or host[^1] == '-': return
    if host[^1] == '.': host = host[0 ..< host.len - 1]
    if host.len == 0: return
  if port.len > 0:
    var value = 0
    for c in port:
      if c notin {'0' .. '9'} or value > 65535: return
      value = value * 10 + ord(c) - ord('0')
    if value == 0 or value > 65535: return
    if (scheme == "https" and value == 443) or (scheme == "http" and value == 80): port = ""
    else: port = $value
  result.ok = true
  result.origin = scheme & "://" & host & (if port.len > 0: ":" & port else: "")

proc webOrigin*(url: string): string =
  ## The serialised origin of an absolute `http`/`https` URL
  ## (`HTTPS://CDN.Example.net:443/a.png` -> `https://cdn.example.net`), or
  ## "" for anything else: a relative or protocol-relative reference, a
  ## `data:` URL, another scheme, or a malformed authority.
  let parts = splitOrigin(url.strip)
  if parts.ok: parts.origin else: ""

proc parseWebOrigin*(value: string): string =
  ## `value` as a serialised origin (see `webOrigin`), for configuration
  ## that lists the origins a site may load from. A trailing `/` is allowed;
  ## a path, query, fragment, user information, another scheme or a
  ## malformed host or port raises `ValueError`.
  let parts = splitOrigin(value)
  if not parts.ok or parts.rest notin ["", "/"]:
    raise newException(ValueError, "not an http or https origin (scheme://host[:port]): " & value)
  parts.origin
