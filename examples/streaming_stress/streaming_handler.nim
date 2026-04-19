## Streaming HTTP handler that makes 5 DB sub-requests and
## streams response fragments as each completes.

import std/[asyncdispatch, json, strutils, times]
import isonim/server/http_types
import isonim/ssr/escape
import db_client

proc handleStreamingPage*(
    req: HttpRequest, resp: HttpResponse,
    dbClient: DbClient) {.async.} =
  ## Handler that streams page fragments after querying the DB.
  ## Each DB query is awaited (yields to event loop), then the
  ## result is rendered and flushed to the client.

  resp.statusCode = 200
  resp.writeHeader("Content-Type", "text/html; charset=utf-8")
  resp.writeHeader("Transfer-Encoding", "chunked")

  # Write the page header immediately
  resp.writeBody("<!DOCTYPE html><html><head><title>Streaming Page</title></head><body>")
  resp.writeBody("<h1>Streaming Dashboard</h1>")
  resp.flush()

  let queries = @["users", "orders", "stats", "inventory", "analytics"]

  for i, queryName in queries:
    # Await the DB query (this yields to the event loop)
    let startTime = cpuTime()
    let data = await dbClient.query(queryName)
    let elapsed = ((cpuTime() - startTime) * 1000).int

    # Render this section and stream it
    let section = "<section class=\"data-section\">" &
      "<h2>" & escapeHtml(queryName.capitalizeAscii()) & "</h2>" &
      "<p>Loaded in " & $elapsed & "ms</p>" &
      "<pre>" & escapeHtml($data) & "</pre>" &
      "</section>"

    resp.writeBody(section)
    resp.flush()

  # Write the page footer
  resp.writeBody("</body></html>")
  resp.flush()
