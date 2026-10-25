## isonim/server/response_body.nim
##
## The response body writer a server hands to what it runs: a streaming
## SSR renderer, an async app, and through `RequestContext.bodyWriter` the
## route manifest's streaming pages (isonim-routing-server-functions.md,
## "Streaming Pages").  It lives in IsoNim, not in the server, so that the
## route dispatch can write to it; `ngx-isonim` (src/response_body.nim)
## creates it over its transport.
##
## `write` queues bytes and `flush` sends what is queued.  On a streaming
## transport the first `flush` also sends the status line and headers
## (committing the response), and each flush puts its bytes on the wire
## immediately (as HTTP chunks).  On a buffered transport `flush` does
## nothing and the whole body goes out, with `Content-Length`, at the end.
##
## A write fails with:
##
## * `ResponseTooLargeError` when the body would exceed the server's limit
##   (`ngx-isonim`: `isonim_ssr_max_buffer_size`);
## * `ClientConnectionError` when the server could not send (the client
##   went away, or the request has ended);
## * `ValueError` when the response is a redirect (redirects carry no body).
##
## Callers should let these propagate: the server turns them into a `500`
## (nothing sent yet) or a terminated response (headers already sent).
##
## Built with `-d:useFaststreams` (the `ngx-isonim` module), `outputStream`
## exposes the same writer as a faststreams `OutputStream` over
## nim-faststreams' nginx adapter, so IsoNim's `renderToStream` writes
## straight into the response.

when defined(useFaststreams) and not defined(isNginxTest):
  import faststreams/[outputs, nginx_adapters]
  export outputs

type
  ResponseTooLargeError* = object of CatchableError
    ## The body would exceed `isonim_ssr_max_buffer_size`.

  ClientConnectionError* = object of IOError
    ## nginx failed to send the response (usually: the client went away).

  ResponseBody* = ref object
    writeImpl: proc(data: openArray[char])
    flushImpl: proc()
    failure*: ref CatchableError
      ## The original error when a write through `outputStream` failed
      ## (faststreams only lets IOError through its callbacks).
    when defined(useFaststreams) and not defined(isNginxTest):
      fsHandle: OutputStreamHandle
      fsCreated: bool

proc newResponseBody*(writeImpl: proc(data: openArray[char]);
                      flushImpl: proc()): ResponseBody =
  ## Used by the transport (serve.nim).
  ResponseBody(writeImpl: writeImpl, flushImpl: flushImpl)

proc write*(b: ResponseBody; data: openArray[char]) =
  b.writeImpl(data)

proc write*(b: ResponseBody; data: string) =
  b.writeImpl(data.toOpenArray(0, data.high))

proc flush*(b: ResponseBody) =
  b.flushImpl()

when defined(useFaststreams) and not defined(isNginxTest):
  proc outputStream*(b: ResponseBody): OutputStream =
    ## A faststreams view of this body.  Each faststreams flush is a
    ## `write` followed by a `flush`.  Errors keep their type in
    ## `b.failure`; faststreams sees them as IOError.
    if not b.fsCreated:
      let body = b
      proc flushCb(data: openArray[byte]) {.gcsafe, raises: [IOError].} =
        {.cast(gcsafe).}:
          try:
            if data.len > 0:
              let chars = cast[ptr UncheckedArray[char]](unsafeAddr data[0])
              body.writeImpl(chars.toOpenArray(0, data.high))
            body.flushImpl()
          except Exception as e:
            # The writer's closures carry no effect annotation, so the
            # compiler sees `Exception`; only IOError may leave here.
            if body.failure.isNil and e of CatchableError:
              body.failure = (ref CatchableError)(e)
            if e of IOError:
              raise (ref IOError)(e)
            raise newException(IOError, e.msg, e)
      b.fsHandle = nginxOutput(flushCb, nil)
      b.fsCreated = true
    b.fsHandle.s
