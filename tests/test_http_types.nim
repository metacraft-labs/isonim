import unittest
import std/strutils
import isonim/server/http_types
import isonim/server/handler
import isonim/server/render_stream
import isonim/dsl/ui
import isonim/ssr/escape
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

suite "Router":
  test "handler receives request":
    var router = newRouter()
    var handlerCalled = false
    var receivedPath = ""
    var receivedMethod = hmGet

    router.get "/api/users", proc(req: HttpRequest, resp: HttpResponse) =
      handlerCalled = true
      receivedPath = req.pathString()
      receivedMethod = req.httpMethod
      resp.statusCode = 200
      resp.writeBody("ok")

    let req = newHttpRequest("/api/users", hmGet)
    let resp = newHttpResponse()
    router.dispatch(req, resp)

    check handlerCalled
    check receivedPath == "/api/users"
    check receivedMethod == hmGet
    check resp.statusCode == 200
    check resp.getResponseBody() == "ok"

  test "handler writes response":
    var router = newRouter()
    router.get "/hello", proc(req: HttpRequest, resp: HttpResponse) =
      resp.statusCode = 200
      resp.writeHeader("Content-Type", "text/html")
      resp.writeBody("<h1>Hello</h1>")

    let req = newHttpRequest("/hello", hmGet)
    let resp = newHttpResponse()
    router.dispatch(req, resp)

    check resp.statusCode == 200
    check resp.getResponseBody() == "<h1>Hello</h1>"
    let headers = resp.getResponseHeaders()
    check headers.len >= 1

  test "router not found":
    var router = newRouter()
    router.get "/exists", proc(req: HttpRequest, resp: HttpResponse) =
      resp.writeBody("found")

    let req = newHttpRequest("/does-not-exist", hmGet)
    let resp = newHttpResponse()
    router.dispatch(req, resp)

    check resp.statusCode == 404
    check "Not Found" in resp.getResponseBody()

suite "renderToStream":
  test "test_render_to_stream_matches_string":
    # Render a component to string
    let htmlString = ui:
      tdiv(class = "container"):
        h1: text "Hello"
        p: text "World"

    # Render same component to OutputStream
    let output = fsOutputs.memoryOutput()
    renderComponentToStream(output.s):
      tdiv(class = "container"):
        h1: text "Hello"
        p: text "World"
    let streamResult = fsOutputs.getOutput(output.s, string)

    check htmlString == streamResult
    check "Hello" in streamResult
    check "container" in streamResult

  test "test_render_to_stream_writes_directly":
    let output = fsOutputs.memoryOutput()
    let html = ui:
      tdiv:
        span: text "direct"
    renderToStream(output.s, html)
    let result = fsOutputs.getOutput(output.s, string)
    check result == html
    check "direct" in result

suite "uiWrite (streaming SSR codegen)":
  test "test_stream_codegen_matches_string_codegen":
    # String mode
    let htmlString = ui:
      tdiv(class = "container"):
        h1: text "Hello"
        p: text "World"

    # Stream mode (zero-copy codegen)
    let output = fsOutputs.memoryOutput()
    uiWrite(output.s):
      tdiv(class = "container"):
        h1: text "Hello"
        p: text "World"
    let streamResult = fsOutputs.getOutput(output.s, string)

    check htmlString == streamResult

  test "test_stream_codegen_with_dynamic_content":
    let name = "Alice"
    let age = 30

    let htmlString = ui:
      tdiv:
        span: text name
        span: text $age

    let output = fsOutputs.memoryOutput()
    uiWrite(output.s):
      tdiv:
        span: text name
        span: text $age
    let streamResult = fsOutputs.getOutput(output.s, string)

    check htmlString == streamResult
    check "Alice" in streamResult
    check "30" in streamResult

  test "test_stream_codegen_with_conditional":
    let visible = true

    let output = fsOutputs.memoryOutput()
    uiWrite(output.s):
      tdiv:
        if visible:
          p: text "shown"
        else:
          p: text "hidden"
    let result = fsOutputs.getOutput(output.s, string)
    check "shown" in result
    check "hidden" notin result

  test "test_stream_codegen_with_loop":
    let items = @["a", "b", "c"]

    let output = fsOutputs.memoryOutput()
    uiWrite(output.s):
      ul:
        for item in items:
          li: text item
    let result = fsOutputs.getOutput(output.s, string)
    check "<li>" in result
    check "a" in result
    check "b" in result
    check "c" in result

  test "test_stream_codegen_void_elements":
    let output = fsOutputs.memoryOutput()
    uiWrite(output.s):
      tdiv:
        br
        hr
        input(`type` = "text", name = "q")
    let result = fsOutputs.getOutput(output.s, string)
    check "<br />" in result
    check "<hr />" in result
    check "type=\"text\"" in result

  test "test_renderComponentToStream_uses_stream_codegen":
    let output = fsOutputs.memoryOutput()
    renderComponentToStream(output.s):
      tdiv(class = "test"):
        h1: text "Stream!"
    let result = fsOutputs.getOutput(output.s, string)
    check "<div" in result
    check "test" in result
    check "Stream!" in result

  test "test_stream_codegen_escapes_without_allocation":
    # Verify that special HTML characters are correctly escaped
    # through the streaming path (writeEscapedHtml, no intermediate string)
    let output = fsOutputs.memoryOutput()
    uiWrite(output.s):
      tdiv:
        p: text "<script>alert('xss')</script>"
        span: text "Tom & Jerry"
        a(href = "/search?q=\"test\""): text "link"
    let result = fsOutputs.getOutput(output.s, string)
    # Text content escaped
    check "&lt;script&gt;" in result
    check "&amp;" in result
    check "<script>" notin result  # raw script tag must NOT appear
    # Attribute values escaped
    check "&quot;" in result

  test "test_writeEscapedHtml_direct":
    # Test the writeEscapedHtml proc directly on a memory output stream
    let output = fsOutputs.memoryOutput()
    writeEscapedHtml(output.s, "Hello <world> & \"friends\"")
    let result = fsOutputs.getOutput(output.s, string)
    check result == "Hello &lt;world&gt; &amp; \"friends\""

  test "test_writeEscapedAttr_direct":
    let output = fsOutputs.memoryOutput()
    writeEscapedAttr(output.s, "value with \"quotes\" & ampersand")
    let result = fsOutputs.getOutput(output.s, string)
    check result == "value with &quot;quotes&quot; &amp; ampersand"
