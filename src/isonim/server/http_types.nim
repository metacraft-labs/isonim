## Zero-copy HTTP request/response types for IsoNim.
##
## Request headers are accessed via openArray[byte] — borrowed views that
## cannot be stored, preventing use-after-free. Response body uses a
## FastStreams OutputStream; request body is a FastStreams InputStream.
## In nginx mode, these would be replaced by pointers into nginx pool memory.
##
## Since Nim 2.2 does not support openArray as a return type, zero-copy
## access is provided via:
##   - Callback procs: `withPath`, `withHeader`, `forHeaders`
##   - Comparison procs: `pathIs`, `pathStartsWith`, `headerIs`, `headerStartsWith`
##   - Owned-copy procs: `pathString`, `headerString` (clearly marked as allocating)

import std/strutils
import faststreams/inputs as fsInputs
import faststreams/outputs as fsOutputs

type
  HttpMethod* = enum
    hmGet = "GET"
    hmPost = "POST"
    hmPut = "PUT"
    hmDelete = "DELETE"
    hmPatch = "PATCH"
    hmHead = "HEAD"
    hmOptions = "OPTIONS"

  # Internal header storage for the dev-server backend.
  # In nginx mode, these would be replaced by pointers into nginx pool memory.
  HeaderEntry = object
    name: string
    value: string

  HttpHeadersKind = enum
    hkOwned   # Dev server: headers stored as owned Nim strings

  HttpHeaders* = object
    case kind: HttpHeadersKind
    of hkOwned:
      entries: seq[HeaderEntry]

  HttpRequest* = object
    pathStr: string             # Owned storage (dev server) or borrowed (nginx)
    methodVal: HttpMethod
    hdrs: HttpHeaders
    bodyStream: fsInputs.InputStreamHandle  # FastStreams InputStream for request body

  HttpResponseKind = enum
    rkDev     # Dev server: collects output into string

  HttpResponse* = ref object
    statusCode*: int
    bodyStream: fsOutputs.OutputStreamHandle  # FastStreams OutputStream for response body
    case kind: HttpResponseKind
    of rkDev:
      responseHeaders: seq[HeaderEntry]
    headersSent*: bool

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc newHttpRequest*(
    path: string, httpMethod: HttpMethod = hmGet,
    headers: seq[(string, string)] = @[],
    bodyData: string = ""): HttpRequest =
  ## Create an HttpRequest for testing or dev-server use.
  var entries: seq[HeaderEntry]
  for (n, v) in headers:
    entries.add(HeaderEntry(name: n, value: v))
  HttpRequest(
    pathStr: path,
    methodVal: httpMethod,
    hdrs: HttpHeaders(kind: hkOwned, entries: entries),
    bodyStream: fsInputs.memoryInput(bodyData)
  )

proc newHttpResponse*(): HttpResponse =
  HttpResponse(
    statusCode: 200,
    bodyStream: fsOutputs.memoryOutput(),
    kind: rkDev,
    responseHeaders: @[],
    headersSent: false
  )

# ---------------------------------------------------------------------------
# Request/Response — body stream access
# ---------------------------------------------------------------------------

proc body*(req: HttpRequest): fsInputs.InputStream =
  ## The request body as a FastStreams InputStream.
  ## Read lazily — no buffering of the entire body.
  req.bodyStream

proc body*(resp: HttpResponse): fsOutputs.OutputStream =
  ## The response body as a FastStreams OutputStream.
  ## Serializers write directly to this stream.
  resp.bodyStream

# ---------------------------------------------------------------------------
# Request — zero-copy access via callbacks
# ---------------------------------------------------------------------------

proc withPath*(req: HttpRequest, callback: proc(path: openArray[byte])) =
  ## Access the request path as a borrowed byte view via callback.
  ## The openArray borrows from the request — it cannot escape the callback.
  if req.pathStr.len > 0:
    callback(req.pathStr.toOpenArrayByte(0, req.pathStr.len - 1))
  else:
    callback(default(array[0, byte]))

proc httpMethod*(req: HttpRequest): HttpMethod =
  req.methodVal

proc withHeader*(
    req: HttpRequest, name: string,
    callback: proc(value: openArray[byte])) =
  ## Access a header value as a borrowed byte view via callback.
  ## The callback is invoked only if the header is found (case-insensitive).
  case req.hdrs.kind
  of hkOwned:
    for entry in req.hdrs.entries:
      if cmpIgnoreCase(entry.name, name) == 0:
        callback(entry.value.toOpenArrayByte(0, entry.value.len - 1))
        return

proc hasHeader*(req: HttpRequest, name: string): bool =
  ## Check whether a header exists (case-insensitive).
  case req.hdrs.kind
  of hkOwned:
    for entry in req.hdrs.entries:
      if cmpIgnoreCase(entry.name, name) == 0:
        return true
    return false

proc forHeaders*(
    req: HttpRequest,
    callback: proc(name, value: openArray[byte])) =
  ## Iterate all headers as borrowed byte views via callback.
  case req.hdrs.kind
  of hkOwned:
    for entry in req.hdrs.entries:
      callback(
        entry.name.toOpenArrayByte(0, entry.name.len - 1),
        entry.value.toOpenArrayByte(0, entry.value.len - 1)
      )

# ---------------------------------------------------------------------------
# Request — comparisons (no openArray escaping needed)
# ---------------------------------------------------------------------------

proc pathIs*(req: HttpRequest, expected: string): bool =
  ## Compare the request path to an expected string.
  req.pathStr == expected

proc pathStartsWith*(req: HttpRequest, prefix: string): bool =
  ## Check whether the request path starts with a prefix.
  req.pathStr.startsWith(prefix)

proc headerIs*(req: HttpRequest, name: string, expected: string): bool =
  ## Check whether a header value equals an expected string (case-insensitive name lookup).
  case req.hdrs.kind
  of hkOwned:
    for entry in req.hdrs.entries:
      if cmpIgnoreCase(entry.name, name) == 0:
        return entry.value == expected
    return false

proc headerStartsWith*(req: HttpRequest, name: string, prefix: string): bool =
  ## Check whether a header value starts with a prefix (case-insensitive name lookup).
  case req.hdrs.kind
  of hkOwned:
    for entry in req.hdrs.entries:
      if cmpIgnoreCase(entry.name, name) == 0:
        return entry.value.startsWith(prefix)
    return false

# ---------------------------------------------------------------------------
# Request — explicit owned copies (allocating)
# ---------------------------------------------------------------------------

proc pathString*(req: HttpRequest): string =
  ## Returns an owned copy of the request path. Allocates.
  req.pathStr

proc headerString*(req: HttpRequest, name: string): string =
  ## Returns an owned copy of a header value. Allocates.
  ## Returns "" if header not found.
  case req.hdrs.kind
  of hkOwned:
    for entry in req.hdrs.entries:
      if cmpIgnoreCase(entry.name, name) == 0:
        return entry.value
    return ""

# ---------------------------------------------------------------------------
# Response — header and body writing
# ---------------------------------------------------------------------------

proc writeHeader*(resp: HttpResponse, name, value: string) =
  ## Add a response header. Must be called before sendHeaders() or writeBody().
  if resp.headersSent:
    raise newException(ValueError, "Cannot write headers after sendHeaders()")
  case resp.kind
  of rkDev:
    resp.responseHeaders.add(HeaderEntry(name: name, value: value))

proc sendHeaders*(resp: HttpResponse) =
  ## Mark headers as sent. In dev mode, headers are collected and sent with
  ## the response. In nginx mode, this would call ngx_http_send_header.
  if resp.headersSent: return
  resp.headersSent = true

proc writeBody*(resp: HttpResponse, data: string) =
  ## Write string data to the response body stream.
  if not resp.headersSent:
    sendHeaders(resp)
  fsOutputs.write(resp.bodyStream, data)

proc writeBody*(resp: HttpResponse, data: openArray[byte]) =
  ## Write byte data to the response body stream.
  if not resp.headersSent:
    sendHeaders(resp)
  fsOutputs.write(resp.bodyStream, data)

proc flush*(resp: HttpResponse) =
  ## Flush the response body stream to the client.
  fsOutputs.flush(resp.bodyStream)

# ---------------------------------------------------------------------------
# Response — read-back (dev server / testing)
# ---------------------------------------------------------------------------

proc getResponseBody*(resp: HttpResponse): string =
  ## Get the collected response body (dev server mode).
  fsOutputs.getOutput(resp.bodyStream, string)

proc getResponseHeaders*(resp: HttpResponse): seq[(string, string)] =
  ## Get the collected response headers (dev server mode).
  case resp.kind
  of rkDev:
    for h in resp.responseHeaders:
      result.add((h.name, h.value))
