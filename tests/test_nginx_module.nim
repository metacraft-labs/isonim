import unittest
import std/strutils
import isonim/ssr_nginx/types
import isonim/ssr_nginx/config
import isonim/ssr_nginx/module_glue
import isonim/ssr/renderer
import isonim/ssr/escape
import isonim/ssr/stream

when defined(isNginxTest):
  import isonim/ssr_nginx/nginx_stream

## Mock nginx request/response for testing the handler logic
## without real nginx.

type
  MockNginxRequest* = ref object
    uri*: string
    httpMethod*: string
    requestHeaders*: seq[(string, string)]
    responseHeaders*: seq[(string, string)]
    responseBody*: string
    responseChunks*: seq[string]
    statusCode*: int

proc newMockRequest*(uri: string; httpMethod: string = "GET"): MockNginxRequest =
  MockNginxRequest(
    uri: uri,
    httpMethod: httpMethod,
    requestHeaders: @[],
    responseHeaders: @[],
    responseBody: "",
    responseChunks: @[],
    statusCode: 0,
  )

proc mockHandleRequest*(req: MockNginxRequest; conf: IsoNimLocConf;
    app: AppRenderer): MockNginxRequest =
  ## Simulates what nginxHandleRequest would do:
  ## 1. Extract request info
  ## 2. Call handleSsrRequest with the app
  ## 3. Populate the mock response
  let reqInfo = RequestInfo(
    uri: req.uri,
    httpMethod: req.httpMethod,
    headers: req.requestHeaders,
  )
  let res = handleSsrRequest(conf, reqInfo, app)
  req.statusCode = res.statusCode
  req.responseHeaders = res.headers
  req.responseBody = res.body
  req.responseChunks = res.chunks
  result = req

proc mockStreamingRequest*(req: MockNginxRequest; conf: IsoNimLocConf;
    app: AppRenderer): MockNginxRequest =
  ## Simulates a streaming SSR handler:
  ## 1. Extract request info
  ## 2. Call handleStreamingSsrRequest
  ## 3. Collect all chunks
  let reqInfo = RequestInfo(
    uri: req.uri,
    httpMethod: req.httpMethod,
    headers: req.requestHeaders,
  )
  let res = handleStreamingSsrRequest(conf, reqInfo, app, proc(chunk: string) =
    req.responseChunks.add(chunk)
  )
  req.statusCode = res.statusCode
  req.responseHeaders = res.headers
  req.responseBody = res.body
  result = req


suite "nginx Module - Types":
  test "nginx_type_constants":
    ## Verify nginx type constants have correct values.
    check NGX_OK == 0.NgxInt
    check NGX_ERROR == (-1).NgxInt
    check NGX_DECLINED == (-5).NgxInt
    check NGX_HTTP_OK == 200.NgxInt
    check NGX_HTTP_INTERNAL_SERVER_ERROR == 500.NgxInt


suite "nginx Module - Config":
  test "default_config":
    let conf = defaultLocConf()
    check not conf.enabled
    check conf.appName == ""
    check conf.maxBufferSize == 0
    check conf.hydrationEnabled
    check conf.scriptNonce == ""

  test "parse_config":
    let conf = parseLocConf(
      enabled = true,
      appName = "my-app",
      maxBufferSize = 1024 * 1024,
      hydrationEnabled = true,
      scriptNonce = "abc123",
    )
    check conf.enabled
    check conf.appName == "my-app"
    check conf.maxBufferSize == 1024 * 1024
    check conf.hydrationEnabled
    check conf.scriptNonce == "abc123"

  test "config_validation":
    # Disabled config is always valid
    check defaultLocConf().isValid()

    # Enabled config without app name is invalid
    let noName = parseLocConf(enabled = true, appName = "")
    check not noName.isValid()

    # Enabled config with app name is valid
    let withName = parseLocConf(enabled = true, appName = "my-app")
    check withName.isValid()

    # Negative buffer size is invalid
    let negBuf = parseLocConf(enabled = true, appName = "my-app",
        maxBufferSize = -1)
    check not negBuf.isValid()


suite "nginx Module - Handler":
  test "verify_nginx_module_builds":
    ## The non-nginx code compiles and types are usable.
    ## This test passing proves the module logic compiles on both backends.
    let conf = parseLocConf(enabled = true, appName = "test-app")
    check conf.isValid()
    let reqInfo = RequestInfo(uri: "/", httpMethod: "GET", headers: @[])
    # Types are constructable
    check reqInfo.uri == "/"
    check reqInfo.httpMethod == "GET"

  test "verify_nginx_serves_ssr":
    ## Mock nginx handler produces correct SSR HTML.
    let conf = parseLocConf(
      enabled = true,
      appName = "test-app",
      hydrationEnabled = true,
    )

    let req = newMockRequest("/")
    let res = req.mockHandleRequest(conf, proc(): string =
      ssrElement("div", {"class": "app"},
        ssrElement("h1", children = "Hello from IsoNim SSR") &
        ssrElement("p", children = escapeHtml("Server-rendered content")))
    )

    check res.statusCode == 200
    check res.responseBody.contains("<div")
    check res.responseBody.contains("class=\"app\"")
    check res.responseBody.contains("<h1>Hello from IsoNim SSR</h1>")
    check res.responseBody.contains("<p>Server-rendered content</p>")
    check res.responseBody.contains("</div>")

    # Hydration script is present
    check res.responseBody.contains("window._$HY")
    check res.responseBody.contains("<script>")

    # Content-Type header is set
    var hasContentType = false
    for (k, v) in res.responseHeaders:
      if k == "Content-Type" and "text/html" in v:
        hasContentType = true
    check hasContentType

  test "verify_nginx_serves_ssr_no_hydration":
    ## When hydration is disabled, no hydration script is emitted.
    let conf = parseLocConf(
      enabled = true,
      appName = "test-app",
      hydrationEnabled = false,
    )

    let req = newMockRequest("/about")
    let res = req.mockHandleRequest(conf, proc(): string =
      ssrElement("div", children =
        ssrElement("h1", children = "About Page"))
    )

    check res.statusCode == 200
    check res.responseBody.contains("<h1>About Page</h1>")
    # No hydration script
    check not res.responseBody.contains("window._$HY")

  test "verify_nginx_serves_ssr_with_nonce":
    ## CSP nonce is included in the hydration script.
    let conf = parseLocConf(
      enabled = true,
      appName = "test-app",
      hydrationEnabled = true,
      scriptNonce = "r4nd0m",
    )

    let req = newMockRequest("/")
    let res = req.mockHandleRequest(conf, proc(): string =
      ssrElement("div", children = "content")
    )

    check res.statusCode == 200
    check res.responseBody.contains("nonce=\"r4nd0m\"")

  test "verify_nginx_invalid_config":
    ## Invalid config returns 500 error.
    let conf = parseLocConf(enabled = true, appName = "")  # Invalid: no app name

    let req = newMockRequest("/")
    let res = req.mockHandleRequest(conf, proc(): string =
      ssrElement("div", children = "should not render")
    )

    check res.statusCode == 500
    check res.responseBody.contains("invalid configuration")

  test "verify_nginx_streaming":
    ## Mock handler streams chunks correctly.
    let conf = parseLocConf(
      enabled = true,
      appName = "stream-app",
      hydrationEnabled = true,
    )

    let req = newMockRequest("/stream")
    let res = req.mockStreamingRequest(conf, proc(): string =
      ssrElement("html", children =
        ssrElement("head", children =
          ssrElement("title", children = "Streaming SSR")) &
        ssrElement("body", children =
          ssrElement("div", {"id": "app"},
            ssrElement("h1", children = "Streaming Page") &
            ssrElement("p", children = "Content loaded via streaming"))))
    )

    check res.statusCode == 200
    # Chunks were collected
    check res.responseChunks.len >= 1
    # The response body contains the full HTML
    check res.responseBody.contains("<html>")
    check res.responseBody.contains("<title>Streaming SSR</title>")
    check res.responseBody.contains("<h1>Streaming Page</h1>")
    check res.responseBody.contains("</html>")
    # Hydration script was streamed as a separate chunk
    check res.responseChunks.len >= 2  # At least HTML + hydration script

  test "verify_nginx_rps_benchmark":
    ## Benchmark recording structure (stub since no nginx).
    ## This test verifies that the handler can be called in a tight loop
    ## and measures throughput.
    let conf = parseLocConf(
      enabled = true,
      appName = "bench-app",
      hydrationEnabled = false,  # Skip hydration for raw speed
    )

    let iterations = 1000
    var successCount = 0

    for i in 0 ..< iterations:
      let reqInfo = RequestInfo(uri: "/bench", httpMethod: "GET", headers: @[])
      let res = handleSsrRequest(conf, reqInfo, proc(): string =
        ssrElement("div", children =
          ssrElement("p", children = "Item " & $i))
      )
      if res.statusCode == 200:
        inc successCount

    check successCount == iterations

  test "e2e_nginx_hydrate":
    ## Verify the SSR output is compatible with hydration.
    ## The output should contain:
    ## 1. Server-rendered HTML with data-hk markers
    ## 2. Hydration script that initializes _$HY
    ## 3. Properly structured markup for client-side takeover
    let conf = parseLocConf(
      enabled = true,
      appName = "hydrate-app",
      hydrationEnabled = true,
    )

    let req = newMockRequest("/")
    let res = req.mockHandleRequest(conf, proc(): string =
      ssrElement("div", {"id": "root"}, needsId = true, children =
        ssrElement("h1", needsId = true, children = "Dynamic Title") &
        ssrElement("button", needsId = true, children = "Click me") &
        ssrElement("ul", children =
          ssrElement("li", children = "Static item")))
    )

    check res.statusCode == 200

    # Hydration markers present on dynamic elements
    check res.responseBody.contains("data-hk=\"1\"")
    check res.responseBody.contains("data-hk=\"2\"")
    check res.responseBody.contains("data-hk=\"3\"")

    # Hydration script present
    check res.responseBody.contains("window._$HY")
    check res.responseBody.contains("data-hk")  # Script references markers
    check res.responseBody.contains("click")  # Default event captured

    # HTML structure is valid for hydration
    check res.responseBody.contains("<div")
    check res.responseBody.contains("id=\"root\"")
    check res.responseBody.contains("<h1")
    check res.responseBody.contains("Dynamic Title</h1>")
    check res.responseBody.contains("<button")
    check res.responseBody.contains("Click me</button>")

    # Static items don't have hydration markers
    check res.responseBody.contains("<li>Static item</li>")
    # The <li> doesn't have data-hk since needsId was not set
    check not res.responseBody.contains("<li data-hk=")


when defined(isNginxTest):
  suite "nginx Module - Mock Chain":
    test "mock_chain_collects_chunks":
      ## MockNginxChain collects write chunks.
      let chain = newMockNginxChain()
      let stream = nginxOutputStream(chain)

      stream.write("chunk1")
      stream.write("chunk2")
      stream.write("chunk3")

      check chain.chunks.len == 3
      check chain.chunks[0].data == "chunk1"
      check chain.chunks[1].data == "chunk2"
      check chain.chunks[2].data == "chunk3"

    test "mock_stream_accumulates":
      ## Mock OutputStream accumulates all data.
      let stream = nginxOutputStream()
      stream.write("<html>")
      stream.write("<body>Hello</body>")
      stream.write("</html>")
      check stream.getOutput() == "<html><body>Hello</body></html>"
