## Mock database service for the streaming stress test.
## Listens on a TCP port, accepts queries as line-delimited text,
## responds with mock JSON data after a random short delay.

import std/[asyncdispatch, asyncnet, json, random, strutils, os]

proc handleClient(client: AsyncSocket) {.async.} =
  while true:
    let line = await client.recvLine()
    if line.len == 0: break

    # Simulate DB query delay (50-200ms)
    let delay = rand(50..200)
    await sleepAsync(delay)

    # Respond with mock data based on query
    let query = line.strip()
    var response: JsonNode
    case query
    of "users":
      response = %*{"rows": [
        {"id": 1, "name": "Alice", "email": "alice@example.com"},
        {"id": 2, "name": "Bob", "email": "bob@example.com"},
        {"id": 3, "name": "Charlie", "email": "charlie@example.com"}
      ], "count": 3, "query": query, "delay_ms": delay}
    of "orders":
      response = %*{"rows": [
        {"id": 101, "product": "Widget A", "amount": 29.99},
        {"id": 102, "product": "Widget B", "amount": 49.99}
      ], "count": 2, "query": query, "delay_ms": delay}
    of "stats":
      response = %*{"total_users": 1000, "total_orders": 5000,
          "revenue": 150000.0, "query": query, "delay_ms": delay}
    of "inventory":
      response = %*{"items": [
        {"sku": "W-001", "stock": 42},
        {"sku": "W-002", "stock": 17}
      ], "count": 2, "query": query, "delay_ms": delay}
    of "analytics":
      response = %*{"pageviews": 50000, "unique_visitors": 12000,
          "bounce_rate": 0.35, "query": query, "delay_ms": delay}
    else:
      response = %*{"error": "unknown query", "query": query}

    await client.send($response & "\n")

proc startMockDb*(port: int = 9876) {.async.} =
  let server = newAsyncSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(port))
  server.listen()
  echo "MockDB listening on port ", port

  while true:
    let client = await server.accept()
    asyncCheck handleClient(client)

when isMainModule:
  let port = if paramCount() >= 1: parseInt(paramStr(1)) else: 9876
  randomize()
  echo "Starting mock DB on port ", port
  asyncCheck startMockDb(port)
  runForever()
