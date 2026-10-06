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

import std/[asyncjs, json]
import ../server/rpc_client
import route_spec

export rpc_client, route_spec

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
    node = await requestJson(httpMethod, url, $bodyJson(req, pathNames), true,
                             scope)
  result = to(node, Resp)
