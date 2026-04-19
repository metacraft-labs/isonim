## Async client for the mock DB service.
## Makes queries and returns parsed JSON responses.

import std/[asyncdispatch, asyncnet, json, strutils]

type
  DbClient* = ref object
    host: string
    port: int

proc newDbClient*(host: string = "127.0.0.1", port: int = 9876): DbClient =
  DbClient(host: host, port: port)

proc query*(client: DbClient, queryStr: string): Future[JsonNode] {.async.} =
  ## Send a query to the mock DB and return the response.
  ## Each query opens a new connection (simple, no pooling).
  let sock = newAsyncSocket()
  await sock.connect(client.host, Port(client.port))
  await sock.send(queryStr & "\n")
  let response = await sock.recvLine()
  sock.close()
  if response.len > 0:
    result = parseJson(response)
  else:
    result = %*{"error": "empty response"}
