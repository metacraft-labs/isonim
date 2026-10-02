## isonim/routing/route_spec.nim
##
## The runtime description of a route manifest entry (`RouteSpec`), and
## the helpers the generated code of `routeManifest` (manifest.nim) shares
## on both targets: building a path from a request object, and sample
## requests for the generated policy tests.

import std/[strutils, json, options]
import ../server/policy

export policy

type
  RouteKind* = enum
    rkPage    ## an SSR page (`page`): the response is a `Page[T]`
    rkApi     ## a data or mutation route (`get`, `post`, ..., `action`)
    rkRpc     ## the mount of the server functions (`rpc`)
    rkAny     ## a raw handler for every method (`any`)

  RouteSpec* = object
    ## One manifest entry, as declared (defaults applied).
    name*: string            ## the enum member, e.g. "rTopic"
    kind*: RouteKind
    httpMethod*: string      ## GET, POST, PUT, PATCH, DELETE; "*" for `any`
    path*: string            ## the pattern, e.g. "/t/:slug/:id"
    prefix*: bool            ## matches the path and everything below it
    requestType*: string     ## the request type's name ("" for rpc / any)
    responseType*: string    ## the response type's name (for pages, of T
                             ## in Page[T])
    auth*: AuthPolicy
    csrf*: CsrfPolicy
    cache*: CachePolicy
    canonical*: CanonicalPolicy
    contextScope*: ContextScope
    progressive*: bool       ## a POST a no-JS form may submit
    target*: string          ## where a no-JS form submission is redirected

  Page*[T] = object
    ## What a page handler returns: the HTML of the page, and the data the
    ## SSR document embeds for hydration
    ## (`<script type="application/json" id="isonim-page-data">`).
    html*: string
    data*: T

const pageDataScriptId* = "isonim-page-data"

proc patternParams*(pattern: string): seq[string] =
  ## The `:param` names of a pattern, in order.
  for seg in pattern.split('/'):
    if seg.len > 1 and seg[0] == ':':
      result.add seg[1 .. ^1]

proc encodePathSegment*(s: string): string =
  ## Percent-encodes one path segment (RFC 3986 unreserved characters are
  ## kept).
  for c in s:
    if c in {'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'}:
      result.add c
    else:
      result.add '%' & toHex(ord(c), 2)

proc encodeQueryComponent*(s: string): string =
  ## application/x-www-form-urlencoded encoding of a name or value.
  for c in s:
    if c in {'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '*'}:
      result.add c
    elif c == ' ':
      result.add '+'
    else:
      result.add '%' & toHex(ord(c), 2)

proc paramText[F](value: F): string =
  when F is string: value
  elif F is Option: (if value.isSome: paramText(value.get) else: "")
  else: $value

proc fieldValues*[T](req: T): seq[(string, string)] =
  ## The scalar fields of a request object as text (an unset `Option` is
  ## left out; a `seq` gives one pair per element).
  for name, value in req.fieldPairs:
    when value is seq:
      for v in value:
        result.add((name, paramText(v)))
    elif value is Option:
      if value.isSome:
        result.add((name, paramText(value.get)))
    elif value is object or value is tuple or value is ref:
      discard
    else:
      result.add((name, paramText(value)))

proc buildPath*[T](pattern: string; req: T): string =
  ## The path of `pattern` with each `:param` replaced by the request's
  ## field of that name.
  let values = fieldValues(req)
  for seg in pattern.split('/'):
    if seg.len == 0:
      continue
    result.add '/'
    if seg[0] == ':':
      var found = false
      for (k, v) in values:
        if k == seg[1 .. ^1]:
          result.add encodePathSegment(v)
          found = true
          break
      if not found:
        raise newException(ValueError, "the request has no field for :" &
          seg[1 .. ^1] & " of " & pattern)
    else:
      result.add seg
  if result.len == 0:
    result = "/"

proc queryString*[T](req: T; exclude: openArray[string]): string =
  ## The request's fields other than `exclude` as a query string (no `?`).
  for (k, v) in fieldValues(req):
    if k notin exclude:
      if result.len > 0: result.add '&'
      result.add encodeQueryComponent(k) & "=" & encodeQueryComponent(v)

proc bodyJson*[T](req: T; exclude: openArray[string]): JsonNode =
  ## The request's fields other than `exclude` as a JSON object.
  result = newJObject()
  for name, value in req.fieldPairs:
    if name notin exclude:
      when value is Option:
        if value.isSome:
          result[name] = %value.get
      else:
        result[name] = %value

# --------------------------------------------------------------------------
# Samples for the generated policy tests
# --------------------------------------------------------------------------

proc sampleText[F](): string =
  when F is string: "sample"
  elif F is bool: "true"
  elif F is enum: $low(F)
  elif F is SomeNumber: "1"
  elif F is Option: sampleText[typeof(default(F).get)]()
  else: "1"

proc samplePath*[T](pattern: string): string =
  ## `pattern` with each `:param` filled with a value valid for the
  ## request field's type.
  var dummy: T
  var values: seq[(string, string)]
  for name, value in dummy.fieldPairs:
    values.add((name, sampleText[typeof(value)]()))
  for seg in pattern.split('/'):
    if seg.len == 0:
      continue
    result.add '/'
    if seg[0] == ':':
      var v = "1"
      for (k, s) in values:
        if k == seg[1 .. ^1]: v = s
      result.add encodePathSegment(v)
    else:
      result.add seg
  if result.len == 0:
    result = "/"

proc sampleBody*[T](pattern: string): JsonNode =
  ## A JSON body with every non-path, non-optional field of `T` at a value
  ## valid for its type.
  let pathNames = patternParams(pattern)
  result = newJObject()
  var dummy: T
  for name, value in dummy.fieldPairs:
    if name notin pathNames:
      when value is Option:
        discard
      elif value is enum:
        result[name] = %($low(typeof(value)))
      elif value is string:
        result[name] = %"sample"
      else:
        result[name] = %value

proc sampleQuery*[T](pattern: string): string =
  ## The non-path, non-optional fields of `T` as a query string.
  let pathNames = patternParams(pattern)
  var dummy: T
  for name, value in dummy.fieldPairs:
    when value is Option or value is seq or value is object:
      discard
    else:
      if name notin pathNames:
        if result.len > 0: result.add '&'
        result.add encodeQueryComponent(name) & "=" &
          encodeQueryComponent(sampleText[typeof(value)]())

proc escapeScriptJson*(json: string): string =
  ## JSON safe inside a `<script>` element: `<` is escaped, so `</script>`
  ## cannot end the element early.
  json.replace("<", "\\u003c")

proc pageDataScript*(json: string): string =
  "<script type=\"application/json\" id=\"" & pageDataScriptId & "\">" &
    escapeScriptJson(json) & "</script>"
