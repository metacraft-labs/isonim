## isonim/routing/route_client.nim
##
## The typed browser client `routeManifest` generates for each data and
## mutation entry (JS target): `callRoute` sends the request object
## (path parameters in the path; the other fields in the query for `GET`,
## as a JSON body otherwise) with the CSRF and context headers, and decodes
## the typed response.  Responses whose context went stale are dropped
## (rpc_client.nim, URL-Schema.md §5.4).

when not defined(js):
  {.error: "isonim/routing/route_client is the browser client (JS target only)".}

import std/[asyncjs, json, jsffi, options]
import ../server/rpc_client
import route_spec, json_decode

export rpc_client, route_spec, json_decode

const jsonAccept = "application/json"

proc bodyText[T](req: T; exclude: seq[string]): string =
  ## The request's fields other than `exclude` as a JSON object (an unset
  ## `Option` left out), as route_spec.nim's `bodyJson` builds it, but
  ## serialized by the browser (json_decode.nim, `toJsAny`).
  let obj = newJsObject()
  for name, value in req.fieldPairs:
    if name notin exclude:
      when value is Option:
        if value.isSome: obj[cstring(name)] = toJsAny(value.get)
      else:
        obj[cstring(name)] = toJsAny(value)
  jsonStringify(obj)

proc callRoute*[Req, Resp](httpMethod, pattern: string; req: Req;
                           scope: ContextScope): Future[Resp] {.async.} =
  let pathNames = patternParams(pattern)
  var url = buildPath(pattern, req)
  var node: JsonNode
  if httpMethod in ["GET", "HEAD", "DELETE"]:
    let q = queryString(req, pathNames)
    if q.len > 0:
      url.add '?' & q
    node = await requestJson(httpMethod, url, "", false, scope)
  else:
    node = await requestJson(httpMethod, url, bodyText(req, pathNames), true,
                             scope)
  result = fromJsonLite[Resp](node)

proc callPageData*[Req, Resp](pattern: string; req: Req;
                              scope: ContextScope): Future[Resp] {.async.} =
  ## A page's JSON variant (`json = true`): the page's own URL with
  ## `Accept: application/json`, so it works whether or not the pattern
  ## takes a `.json` suffix.
  let pathNames = patternParams(pattern)
  var url = buildPath(pattern, req)
  let q = queryString(req, pathNames)
  if q.len > 0:
    url.add '?' & q
  let node = await requestJson("GET", url, "", false, scope,
                               accept = jsonAccept)
  result = fromJsonLite[Resp](node)

proc pageDataAt*[Resp](url: string; scope = csNavigation): Future[Resp] {.async.} =
  ## The JSON variant of the page at `url` (a path and query a client router
  ## already has, e.g. a link's), decoded as the page entry's `Resp`: the
  ## request `<name>Data` would send for the request `url` names.
  let node = await requestJson("GET", url, "", false, scope, accept = jsonAccept)
  result = fromJsonLite[Resp](node)