## isonim/server/response.nim
##
## How server code shapes the HTTP response.
##
## Every renderer gets an `SsrResponse` next to the request, and every
## server function and route handler gets one in its `RequestContext`
## (context.nim).  Before the first body byte leaves the server it may set:
##
## * the status code (`status=`);
## * the content type (`contentType=`, default `text/html; charset=utf-8`);
## * response headers (`setHeader`, `addHeader`), e.g. `Cache-Control`,
##   `Vary` and `Content-Security-Policy`;
## * cookies (`setCookie`, one `Set-Cookie` header each);
## * a redirect (`redirect`, status 301, 302, 303, 307 or 308).
##
## "Before the first byte" is enforced: the buffered transport sends
## nothing until the renderer returns, and the streaming transport sends the
## status line and headers on the renderer's first flush.  From then on the
## response is *committed*, and every setter raises `ResponseCommittedError`.
##
## Each response also owns a CSP nonce (`cspNonce`): 128 bits from the
## operating system's CSPRNG, generated on first use and never shared with
## another response.  The module puts it on the hydration bootstrap
## `<script>`; the renderer puts the same value in its
## `Content-Security-Policy` header (`cspNonceSource` gives the
## `'nonce-…'` source expression).
##
## Header names and values are validated, so a value taken from the request
## cannot split the response (CRLF injection).

import std/[strutils, sysrand, base64, options]

const
  defaultContentType* = "text/html; charset=utf-8"
  cspNonceBytes* = 16
    ## 128 bits, the minimum CSP Level 3 recommends for a nonce
    ## (https://www.w3.org/TR/CSP3/#security-nonces).
  redirectStatuses* = [301, 302, 303, 307, 308]

type
  ResponseCommittedError* = object of CatchableError
    ## A setter was called after the status and headers were sent.

  SameSite* = enum
    sameSiteUnset   ## no SameSite attribute
    sameSiteLax = "Lax"
    sameSiteStrict = "Strict"
    sameSiteNone = "None"

  CookieOptions* = object
    ## The attributes of one `Set-Cookie` header (RFC 6265 §4.1.1).
    path*: string
    domain*: string
    maxAge*: Option[int]   ## seconds; 0 or negative expires the cookie now
    expires*: string       ## an HTTP-date, written as given
    secure*: bool
    httpOnly*: bool
    sameSite*: SameSite

  SsrResponse* = ref object
    ## The response a renderer or handler shapes.  Created by the server per
    ## request.
    status: int
    contentType: string
    headers: seq[(string, string)]
    location: string
    nonce: string
    committed: bool

# Headers the module owns.  Content-Length and Transfer-Encoding follow from
# the transport; the hop-by-hop ones are nginx's; Content-Type and Location
# have their own setters so they cannot be set twice.
const reservedHeaders = [
  "content-length", "transfer-encoding", "connection", "keep-alive",
  "upgrade", "te", "trailer", "content-type", "location",
]

proc newSsrResponse*(): SsrResponse =
  SsrResponse(status: 200, contentType: defaultContentType)

proc checkNotCommitted(r: SsrResponse) =
  if r.committed:
    raise newException(ResponseCommittedError,
      "the response status and headers were already sent")

proc isTokenChar(c: char): bool =
  ## RFC 9110 §5.6.2 tchar.
  c in {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`',
        '|', '~', '0'..'9', 'a'..'z', 'A'..'Z'}

proc validateHeaderName(name: string) =
  if name.len == 0:
    raise newException(ValueError, "empty header name")
  for c in name:
    if not isTokenChar(c):
      raise newException(ValueError,
        "invalid character in header name: " & escape(name))

proc validateHeaderValue(value: string) =
  ## RFC 9110 §5.5: field-value is visible characters, spaces and tabs, and
  ## obs-text.  CR, LF, NUL and the other controls are rejected, which is
  ## what keeps a request-derived value from splitting the response.
  for c in value:
    if (c < ' ' and c != '\t') or c == '\x7F':
      raise newException(ValueError,
        "invalid character in header value: " & escape(value))

proc validateUserHeader(name, value: string) =
  validateHeaderName(name)
  validateHeaderValue(value)
  if name.toLowerAscii in reservedHeaders:
    raise newException(ValueError,
      "header '" & name & "' is set by the module; use contentType= or " &
      "redirect, or let the transport set it")

# --------------------------------------------------------------------------
# Status, content type, headers
# --------------------------------------------------------------------------

proc status*(r: SsrResponse): int = r.status

proc `status=`*(r: SsrResponse; code: int) =
  ## Sets the status code: 200-599 (1xx are interim responses and cannot
  ## be the final status).
  r.checkNotCommitted()
  if code < 200 or code > 599:
    raise newException(ValueError, "invalid response status: " & $code)
  r.status = code

proc contentType*(r: SsrResponse): string = r.contentType

proc `contentType=`*(r: SsrResponse; value: string) =
  r.checkNotCommitted()
  validateHeaderValue(value)
  if value.len == 0:
    raise newException(ValueError, "empty content type")
  r.contentType = value

proc headers*(r: SsrResponse): seq[(string, string)] =
  ## The headers set so far, in order (without Content-Type and Location).
  r.headers

proc header*(r: SsrResponse; name: string): string =
  ## The first header named `name` (case-insensitive), or "".
  for (k, v) in r.headers:
    if cmpIgnoreCase(k, name) == 0:
      return v
  ""

proc removeHeader*(r: SsrResponse; name: string) =
  r.checkNotCommitted()
  var kept: seq[(string, string)]
  for h in r.headers:
    if cmpIgnoreCase(h[0], name) != 0:
      kept.add h
  r.headers = kept

proc addHeader*(r: SsrResponse; name, value: string) =
  ## Appends a header, keeping any of the same name (e.g. a second `Vary`).
  r.checkNotCommitted()
  validateUserHeader(name, value)
  r.headers.add((name, value))

proc setHeader*(r: SsrResponse; name, value: string) =
  ## Sets a header, replacing every header of the same name.
  r.checkNotCommitted()
  validateUserHeader(name, value)
  r.removeHeader(name)
  r.headers.add((name, value))

# --------------------------------------------------------------------------
# Cookies
# --------------------------------------------------------------------------

proc isCookieOctet(c: char): bool =
  ## RFC 6265 §4.1.1 cookie-octet: US-ASCII except controls, whitespace,
  ## DQUOTE, comma, semicolon and backslash.
  c == '\x21' or c in '\x23'..'\x2B' or c in '\x2D'..'\x3A' or
    c in '\x3C'..'\x5B' or c in '\x5D'..'\x7E'

proc validateAttrValue(attr, value: string) =
  for c in value:
    if c < ' ' or c == '\x7F' or c == ';':
      raise newException(ValueError,
        "invalid character in cookie " & attr & ": " & escape(value))

proc formatSetCookie*(name, value: string;
                      opts: CookieOptions = CookieOptions()): string =
  ## Formats a `Set-Cookie` value (RFC 6265 §4.1).  Raises ValueError for a
  ## name that is not a token or a value outside cookie-octet: encode such
  ## values (e.g. base64url) before setting them.
  if name.len == 0:
    raise newException(ValueError, "empty cookie name")
  for c in name:
    if not isTokenChar(c):
      raise newException(ValueError,
        "invalid character in cookie name: " & escape(name))
  for c in value:
    if not isCookieOctet(c):
      raise newException(ValueError,
        "invalid character in cookie value: " & escape(value))
  result = name & "=" & value
  if opts.path.len > 0:
    validateAttrValue("Path", opts.path)
    result.add "; Path=" & opts.path
  if opts.domain.len > 0:
    validateAttrValue("Domain", opts.domain)
    result.add "; Domain=" & opts.domain
  if opts.maxAge.isSome:
    result.add "; Max-Age=" & $opts.maxAge.get
  if opts.expires.len > 0:
    validateAttrValue("Expires", opts.expires)
    result.add "; Expires=" & opts.expires
  if opts.secure:
    result.add "; Secure"
  if opts.httpOnly:
    result.add "; HttpOnly"
  if opts.sameSite != sameSiteUnset:
    result.add "; SameSite=" & $opts.sameSite

proc setCookie*(r: SsrResponse; name, value: string;
                opts: CookieOptions = CookieOptions()) =
  ## Adds one `Set-Cookie` header.
  r.checkNotCommitted()
  r.headers.add(("Set-Cookie", formatSetCookie(name, value, opts)))

# --------------------------------------------------------------------------
# Redirects
# --------------------------------------------------------------------------

proc redirect*(r: SsrResponse; location: string; status = 302) =
  ## Turns the response into a redirect: the status, a `Location` header
  ## and no body.  Headers and cookies set before or after still go out with
  ## it.  A body the renderer returns or writes is not sent.
  r.checkNotCommitted()
  if status notin redirectStatuses:
    raise newException(ValueError,
      "redirect status must be 301, 302, 303, 307 or 308, got " & $status)
  if location.len == 0:
    raise newException(ValueError, "empty redirect location")
  validateHeaderValue(location)
  r.status = status
  r.location = location

proc isRedirect*(r: SsrResponse): bool = r.location.len > 0

proc location*(r: SsrResponse): string = r.location

# --------------------------------------------------------------------------
# CSP nonce
# --------------------------------------------------------------------------

proc generateCspNonce*(): string =
  ## 128 bits from the OS CSPRNG (getrandom(2) on Linux), base64-encoded
  ## (24 characters, CSP base64-value syntax).  Raises OSError if the
  ## kernel cannot provide randomness; the request then fails with 500
  ## rather than going out with a guessable nonce.
  let bytes = urandom(cspNonceBytes)
  if bytes.len != cspNonceBytes:
    raise newException(OSError, "the CSPRNG returned too few bytes")
  base64.encode(bytes)

proc cspNonce*(r: SsrResponse): string =
  ## This response's CSP nonce, generated on first use.
  if r.nonce.len == 0:
    r.nonce = generateCspNonce()
  r.nonce

proc cspNonceSource*(r: SsrResponse): string =
  ## The CSP source expression for this response's nonce, for a
  ## `script-src` directive: `'nonce-<value>'`.
  "'nonce-" & r.cspNonce & "'"

# --------------------------------------------------------------------------
# Used by the transport (serve.nim)
# --------------------------------------------------------------------------

proc committed*(r: SsrResponse): bool = r.committed

proc markCommitted*(r: SsrResponse) =
  ## Called by the transport once the status and headers are sent.
  r.committed = true

proc wireHeaders*(r: SsrResponse): seq[(string, string)] =
  ## The headers to send, including `Location` for a redirect.
  result = r.headers
  if r.location.len > 0:
    result.add(("Location", r.location))
