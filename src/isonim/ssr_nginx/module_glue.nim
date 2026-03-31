## isonim/ssr_nginx/module_glue.nim
##
## nginx content handler and module registration.
## This file is compiled as part of the nginx module .so
##
## The handler is called by nginx for configured routes. It runs
## renderToStream (or renderToString) and writes the output through
## nginx's output chain via the OutputStream abstraction.

import isonim/ssr_nginx/types
import isonim/ssr_nginx/config
import isonim/ssr/stream
import isonim/ssr/renderer
import isonim/ssr/markers

when not defined(isNginxTest):
  import isonim/ssr_nginx/nginx_stream

type
  AppRenderer* = proc(): string
    ## Application render function. Returns the HTML string for the page.

  RequestInfo* = object
    ## Extracted request information passed to the app.
    uri*: string
    httpMethod*: string
    headers*: seq[(string, string)]

  HandlerResult* = object
    ## Result of handling a request.
    statusCode*: int
    headers*: seq[(string, string)]
    body*: string
    chunks*: seq[string]

proc handleSsrRequest*(conf: IsoNimLocConf; reqInfo: RequestInfo;
    app: AppRenderer): HandlerResult =
  ## Core SSR handler logic, independent of nginx.
  ## This is testable without nginx headers.
  ##
  ## 1. Validates configuration
  ## 2. Calls renderToString with the app
  ## 3. Optionally appends hydration script
  ## 4. Returns the complete response
  if not conf.isValid():
    return HandlerResult(
      statusCode: NGX_HTTP_INTERNAL_SERVER_ERROR.int,
      body: "IsoNim SSR: invalid configuration",
    )

  var html: string
  try:
    html = renderToString(app)
  except CatchableError:
    return HandlerResult(
      statusCode: NGX_HTTP_INTERNAL_SERVER_ERROR.int,
      body: "IsoNim SSR: render error",
    )

  # Append hydration script if enabled
  if conf.hydrationEnabled:
    html = html & generateHydrationScript(nonce = conf.scriptNonce)

  result = HandlerResult(
    statusCode: NGX_HTTP_OK.int,
    headers: @[
      ("Content-Type", "text/html; charset=utf-8"),
    ],
    body: html,
    chunks: @[html],
  )

proc handleStreamingSsrRequest*(conf: IsoNimLocConf; reqInfo: RequestInfo;
    app: AppRenderer;
    onChunk: proc(chunk: string)): HandlerResult =
  ## Streaming SSR handler. Renders the app and calls onChunk for each
  ## piece of output. This simulates what the real nginx handler would
  ## do: write each chunk to an ngx_buf_t and flush via output_filter.
  if not conf.isValid():
    return HandlerResult(
      statusCode: NGX_HTTP_INTERNAL_SERVER_ERROR.int,
      body: "IsoNim SSR: invalid configuration",
    )

  var chunks: seq[string] = @[]
  let stream = newCallbackOutputStream(proc(data: string) =
    chunks.add(data)
    onChunk(data)
  )

  var html: string
  try:
    html = renderToString(app)
  except CatchableError:
    return HandlerResult(
      statusCode: NGX_HTTP_INTERNAL_SERVER_ERROR.int,
      body: "IsoNim SSR: render error",
    )

  # Write the rendered HTML to the stream
  stream.write(html)

  # Append hydration script if enabled
  if conf.hydrationEnabled:
    let script = generateHydrationScript(nonce = conf.scriptNonce)
    stream.write(script)
    html = html & script

  stream.flush()

  result = HandlerResult(
    statusCode: NGX_HTTP_OK.int,
    headers: @[
      ("Content-Type", "text/html; charset=utf-8"),
    ],
    body: html,
    chunks: chunks,
  )

when not defined(isNginxTest):
  ## Real nginx entry point. Exported as C function for the nginx module.
  proc nginxHandleRequest*(req: NgxHttpRequest): NgxInt {.exportc, cdecl.} =
    ## Called by nginx for configured routes.
    ## In a real deployment, this would:
    ## 1. Extract request info from ngx_http_request_t
    ## 2. Look up the app renderer from module config
    ## 3. Create an nginx-backed OutputStream
    ## 4. Call handleSsrRequest or handleStreamingSsrRequest
    ## 5. Return the appropriate nginx status code
    return NGX_OK
