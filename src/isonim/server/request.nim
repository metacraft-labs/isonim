## isonim/server/request.nim
##
## The HTTP request as IsoNim server code sees it: renderers, server
## functions and the route manifest's dispatch all receive this one type
## (a renderer directly, server functions and route handlers through their
## `RequestContext`, see context.nim).
##
## A server builds one `SsrRequest` per HTTP request.  ngx-isonim builds it
## from nginx's own parse of the request (`ngx_http_request_t`).  It carries
## what an application needs to route and to authenticate: the method, the
## path, the raw URI and query, every request header in arrival order, the
## cookies, the `Host` header, the client address and, for a request that
## has one, the body.
##
## The values are copies: they stay valid after the renderer or handler
## returns, and it may keep them.
##
## Parsing follows the standards the values come from:
##
## * query strings: the application/x-www-form-urlencoded parser of the URL
##   Standard (https://url.spec.whatwg.org/#urlencoded-parsing): `&`
##   separates pairs, the first `=` splits name from value, `+` is a space
##   and `%XX` is a byte.  A malformed `%` escape is kept literally.
## * cookies: RFC 6265 §5.4 (https://www.rfc-editor.org/rfc/rfc6265#section-5.4),
##   pairs separated by `;`, with optional whitespace and an optional pair of
##   double quotes around the value.  HTTP/2 clients may send several
##   `Cookie` headers (RFC 9113 §8.2.3); they are read in order.

import std/strutils

type
  SsrRequest* = ref object
    ## One HTTP request, as nginx parsed it.
    httpMethod*: string
      ## The request method as sent (`GET`, `HEAD`, ...).
    path*: string
      ## nginx's `r->uri`: the path, percent-decoded and normalized
      ## (`/a/../b` is `/b`), without the query.  This is what routes match.
    rawUri*: string
      ## nginx's `r->unparsed_uri`: the request target exactly as sent,
      ## including the query.
    query*: string
      ## nginx's `r->args`: the raw query string, without the `?`.
    headers*: seq[(string, string)]
      ## Every request header, in arrival order, names as sent.
    host*: string
      ## The `Host` header as sent (with the port, if the client sent one);
      ## empty when the request had none.
    clientAddr*: string
      ## The client address as text (nginx's `addr_text`), e.g. `127.0.0.1`.
    queryParams*: seq[(string, string)]
      ## The decoded query parameters, in order; repeated names repeat.
    cookies*: seq[(string, string)]
      ## The cookies from every `Cookie` header, in order.
    body*: string
      ## The request body, read in full before the handler runs (ngx-isonim
      ## reads it only at `isonim_rpc` locations; elsewhere it is empty).

proc fromHex(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

proc decodeFormComponent*(s: string): string =
  ## Decodes one name or value of an application/x-www-form-urlencoded
  ## string: `+` becomes a space and `%XX` a byte.  A `%` that does not
  ## start a valid escape is kept as is, as the URL Standard's
  ## percent-decode does.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '+':
      result.add ' '
      inc i
    elif c == '%' and i + 2 <= s.high and
        fromHex(s[i + 1]) >= 0 and fromHex(s[i + 2]) >= 0:
      result.add chr(fromHex(s[i + 1]) * 16 + fromHex(s[i + 2]))
      inc i, 3
    else:
      result.add c
      inc i

proc parseQuery*(query: string): seq[(string, string)] =
  ## Parses a raw query string (no leading `?`) into decoded pairs.
  ## Empty pairs (`a=1&&b=2`) are skipped; a pair without `=` has an empty
  ## value.
  for part in query.split('&'):
    if part.len == 0:
      continue
    let eq = part.find('=')
    if eq < 0:
      result.add((decodeFormComponent(part), ""))
    else:
      result.add((decodeFormComponent(part[0 ..< eq]),
                  decodeFormComponent(part[eq + 1 .. ^1])))

proc parseCookieHeader*(value: string; into: var seq[(string, string)]) =
  ## Appends the cookies of one `Cookie` header value to `into`.
  ## Pairs without `=` or with an empty name are ignored (RFC 6265 §5.2
  ## step 2 and 5 applied to the request side).
  for part in value.split(';'):
    let pair = part.strip(chars = {' ', '\t'})
    let eq = pair.find('=')
    if eq <= 0:
      continue
    let name = pair[0 ..< eq].strip(chars = {' ', '\t'})
    var val = pair[eq + 1 .. ^1].strip(chars = {' ', '\t'})
    if val.len >= 2 and val[0] == '"' and val[^1] == '"':
      val = val[1 .. ^2]
    if name.len > 0:
      into.add((name, val))

proc newSsrRequest*(httpMethod, path, rawUri, query: string;
                    headers: seq[(string, string)];
                    clientAddr: string; body = ""): SsrRequest =
  ## Builds a request and derives `host`, `queryParams` and `cookies` from
  ## the raw values.
  result = SsrRequest(
    httpMethod: httpMethod,
    path: path,
    rawUri: rawUri,
    query: query,
    headers: headers,
    clientAddr: clientAddr,
    queryParams: parseQuery(query),
    body: body,
  )
  for (name, value) in headers:
    if cmpIgnoreCase(name, "Host") == 0 and result.host.len == 0:
      result.host = value
    elif cmpIgnoreCase(name, "Cookie") == 0:
      parseCookieHeader(value, result.cookies)

proc header*(req: SsrRequest; name: string): string =
  ## The first header named `name` (case-insensitive), or "".
  for (k, v) in req.headers:
    if cmpIgnoreCase(k, name) == 0:
      return v
  ""

proc hasHeader*(req: SsrRequest; name: string): bool =
  for (k, _) in req.headers:
    if cmpIgnoreCase(k, name) == 0:
      return true
  false

proc headerValues*(req: SsrRequest; name: string): seq[string] =
  ## Every header named `name` (case-insensitive), in arrival order.
  for (k, v) in req.headers:
    if cmpIgnoreCase(k, name) == 0:
      result.add v

proc cookie*(req: SsrRequest; name: string): string =
  ## The first cookie named `name` (case-sensitive, as RFC 6265 compares
  ## names), or "".
  for (k, v) in req.cookies:
    if k == name:
      return v
  ""

proc hasCookie*(req: SsrRequest; name: string): bool =
  for (k, _) in req.cookies:
    if k == name:
      return true
  false

proc queryParam*(req: SsrRequest; name: string; default = ""): string =
  ## The first query parameter named `name`, or `default`.
  for (k, v) in req.queryParams:
    if k == name:
      return v
  default

proc hasQueryParam*(req: SsrRequest; name: string): bool =
  for (k, _) in req.queryParams:
    if k == name:
      return true
  false

proc mediaType*(req: SsrRequest): string =
  ## The media type of the body (`Content-Type` without its parameters),
  ## lower-cased; "" when the request has no `Content-Type`.
  let ct = req.header("Content-Type")
  let semi = ct.find(';')
  result = (if semi < 0: ct else: ct[0 ..< semi]).strip().toLowerAscii()

proc isSafeMethod*(httpMethod: string): bool =
  ## GET, HEAD and OPTIONS: the methods that must not change state
  ## (RFC 9110 §9.2.1), so CSRF checks do not apply to them.
  httpMethod in ["GET", "HEAD", "OPTIONS"]
