import unittest
import std/strutils
import isonim/server/http_types
import faststreams/inputs as fsInputs
import faststreams/outputs as fsOutputs

suite "Zero-Copy HTTP Types":
  test "path equality comparison":
    let req = newHttpRequest("/api/users")
    check req.pathIs("/api/users")
    check not req.pathIs("/api/posts")
    check not req.pathIs("/api/user")  # substring mismatch
    check not req.pathIs("")

    # Empty path
    let emptyReq = newHttpRequest("")
    check emptyReq.pathIs("")
    check not emptyReq.pathIs("/")

  test "path starts with":
    let req = newHttpRequest("/api/users/42/profile")
    check req.pathStartsWith("/api")
    check req.pathStartsWith("/api/users")
    check not req.pathStartsWith("/admin")
    check req.pathStartsWith("")  # everything starts with empty
    check not req.pathStartsWith("/api/users/42/profile/extra")  # longer than path

  test "header lookup case insensitive":
    let req = newHttpRequest("/", hmGet, @[
      ("content-type", "application/json"),
      ("X-Request-Id", "abc123")
    ])
    check req.headerIs("Content-Type", "application/json")
    check req.headerIs("content-type", "application/json")
    check req.headerIs("CONTENT-TYPE", "application/json")
    check req.hasHeader("X-Request-Id")
    check not req.hasHeader("X-Missing")

  test "header iteration zero copy":
    let req = newHttpRequest("/", hmGet, @[
      ("Host", "example.com"),
      ("Accept", "text/html")
    ])
    var count = 0
    req.forHeaders proc(name, value: openArray[byte]) =
      count += 1
      # Can access name and value as openArray[byte] within the callback
      # but cannot store them — they borrow from the request
    check count == 2

  test "path and method access":
    let req = newHttpRequest("/api/users")
    check req.pathIs("/api/users")
    check req.httpMethod == hmGet

    let postReq = newHttpRequest("/api/users", hmPost)
    check postReq.httpMethod == hmPost
    check postReq.pathIs("/api/users")

  test "explicit owned copies":
    let req = newHttpRequest("/api/users", hmGet, @[
      ("Content-Type", "application/json")
    ])
    let owned = req.pathString()
    check owned == "/api/users"
    # owned is a regular string — can be stored, used later
    let headerVal = req.headerString("Content-Type")
    check headerVal == "application/json"
    check req.headerString("Missing") == ""

  test "response header writing":
    let resp = newHttpResponse()
    resp.statusCode = 200
    resp.writeHeader("Content-Type", "text/html")
    resp.writeHeader("X-Custom", "value")

    let headers = resp.getResponseHeaders()
    check headers.len == 2
    check headers[0] == ("Content-Type", "text/html")
    check headers[1] == ("X-Custom", "value")

    # Write body
    resp.writeBody("Hello, World!")
    check resp.getResponseBody() == "Hello, World!"
    check resp.headersSent == true

    # Cannot write more headers after body
    expect ValueError:
      resp.writeHeader("Too-Late", "value")

  test "request body as input stream":
    let req = newHttpRequest("/api/data", hmPost, @[], "Hello, Body!")
    let stream = req.body
    # Read from the stream
    var buf: array[20, byte]
    var bytesRead = 0
    while fsInputs.readable(stream, 1):
      buf[bytesRead] = fsInputs.read(stream)
      bytesRead += 1
      if bytesRead >= 12: break
    check bytesRead == 12
    var bodyStr = ""
    for i in 0 ..< bytesRead:
      bodyStr.add(char(buf[i]))
    check bodyStr == "Hello, Body!"

  test "JSON body from input stream":
    # Simulate JSON body
    let jsonBody = """{"name": "Alice", "age": 30}"""
    let req = newHttpRequest("/api/users", hmPost, @[
      ("Content-Type", "application/json")
    ], jsonBody)
    # Read body into string from stream
    var bodyStr = ""
    let stream = req.body
    while fsInputs.readable(stream, 1):
      bodyStr.add(char(fsInputs.read(stream)))
    check "Alice" in bodyStr
    check "30" in bodyStr

  test "empty body stream":
    let req = newHttpRequest("/api/empty", hmGet)
    let stream = req.body
    # Empty body should not be readable
    var bytesRead = 0
    while fsInputs.readable(stream, 1):
      discard fsInputs.read(stream)
      bytesRead += 1
    check bytesRead == 0

  test "response body as output stream":
    let resp = newHttpResponse()
    resp.statusCode = 200
    resp.writeHeader("Content-Type", "text/plain")

    # Write to the response body stream
    let stream = resp.body
    fsOutputs.write(stream, "Hello from ")
    fsOutputs.write(stream, "OutputStream!")

    check resp.getResponseBody() == "Hello from OutputStream!"

  test "streaming response with writeBody":
    let resp = newHttpResponse()
    resp.writeBody("chunk1")
    resp.writeBody("chunk2")
    # In dev mode, all chunks accumulate
    check resp.getResponseBody() == "chunk1chunk2"
