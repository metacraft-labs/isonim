## Dev server adapter for IsoNim.
##
## Bridges std/asynchttpserver's Request to our HttpRequest/HttpResponse types.
## The handler itself is synchronous — async dispatch comes in a later milestone.

import std/[asynchttpserver, asyncdispatch, uri]
import http_types, handler

proc toHttpMethod(m: asynchttpserver.HttpMethod): http_types.HttpMethod =
  case m
  of HttpGet: hmGet
  of HttpPost: hmPost
  of HttpPut: hmPut
  of HttpDelete: hmDelete
  of HttpPatch: hmPatch
  of HttpHead: hmHead
  of HttpOptions: hmOptions
  else: hmGet

proc adaptRequest(req: asynchttpserver.Request): HttpRequest =
  ## Convert asynchttpserver Request to our HttpRequest.
  var headerPairs: seq[(string, string)] = @[]
  for key, val in req.headers.pairs:
    headerPairs.add((key, val))

  newHttpRequest(
    path = req.url.path.decodeUrl,
    httpMethod = toHttpMethod(req.reqMethod),
    headers = headerPairs,
    bodyData = req.body
  )

proc serveRouter*(router: Router, port: int = 8080) =
  ## Start a dev server that dispatches requests via the router.
  let server = newAsyncHttpServer()

  proc handler(req: asynchttpserver.Request) {.async.} =
    let httpReq = adaptRequest(req)
    let httpResp = newHttpResponse()

    router.dispatch(httpReq, httpResp)

    # Collect response
    var headers = newHttpHeaders()
    for (name, value) in httpResp.getResponseHeaders():
      headers[name] = value

    let body = httpResp.getResponseBody()
    await req.respond(HttpCode(httpResp.statusCode), body, headers)

  echo "Dev server running at http://localhost:" & $port
  waitFor server.serve(Port(port), handler)
