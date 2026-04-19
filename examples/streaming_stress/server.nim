## Streaming stress test server.
## Serves /streaming-page with async DB-backed streaming responses.

import std/[asynchttpserver, asyncdispatch, strutils, os]
import isonim/server/http_types
import db_client, streaming_handler

proc main() =
  let dbPort = if paramCount() >= 1: parseInt(paramStr(1)) else: 9876
  let httpPort = if paramCount() >= 2: parseInt(paramStr(2)) else: 8090

  let dbClient = newDbClient(port = dbPort)

  let server = newAsyncHttpServer()

  proc handler(req: Request) {.async.} =
    let path = req.url.path

    case path
    of "/streaming-page":
      # Create our HttpRequest/HttpResponse wrappers
      var headerPairs: seq[(string, string)] = @[]
      for key, val in req.headers.pairs:
        headerPairs.add((key, val))
      let httpReq = newHttpRequest(path, hmGet, headerPairs)
      let httpResp = newHttpResponse()

      await handleStreamingPage(httpReq, httpResp, dbClient)

      let body = httpResp.getResponseBody()
      let headers = newHttpHeaders({"Content-Type": "text/html; charset=utf-8"})
      await req.respond(Http200, body, headers)

    of "/health":
      await req.respond(Http200, "ok")

    else:
      await req.respond(Http404, "Not Found")

  echo "Streaming stress test server on port ", httpPort
  echo "  DB service expected on port ", dbPort
  echo "  GET /streaming-page for the streaming test"
  echo "  GET /health for health check"
  waitFor server.serve(Port(httpPort), handler)

when isMainModule:
  main()
