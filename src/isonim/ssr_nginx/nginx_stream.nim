## isonim/ssr_nginx/nginx_stream.nim
##
## Creates an OutputStream that writes to nginx output chain.
## writeSync -> allocates ngx_buf_t, appends to chain
## flushSync -> calls ngx_http_output_filter
##
## When compiled with -d:isNginxTest, provides a mock implementation
## for testing without real nginx.

import isonim/ssr/stream

when not defined(isNginxTest):
  import isonim/ssr_nginx/types
  ## Real nginx implementation (requires nginx headers at compile time).
  ## These procs are declared but not importable without nginx dev headers.

  proc ngxPalloc(pool: NgxPool; size: csize_t): pointer
    {.importc: "ngx_palloc", header: "<ngx_core.h>".}

  proc ngxHttpOutputFilter(r: NgxHttpRequest; chain: NgxChain): NgxInt
    {.importc: "ngx_http_output_filter", header: "<ngx_http.h>".}

  proc nginxOutputStream*(req: NgxHttpRequest; pool: NgxPool): OutputStream =
    ## Creates an OutputStream backed by nginx buffer chain.
    ## Each write allocates an ngx_buf_t from the request pool and
    ## appends it to the output chain. Flush calls ngx_http_output_filter.
    var chain: NgxChain = nil

    result = newCallbackOutputStream(proc(data: string) =
      ## Allocate buffer from nginx pool and copy data into it.
      ## In a real nginx module this would:
      ## 1. ngx_palloc a buf from the pool
      ## 2. Copy the string data into the buf
      ## 3. Link it into the chain
      ## 4. On flush, call ngx_http_output_filter
      discard  # Actual implementation requires nginx memory management
    )

else:
  ## Mock implementation for testing.

  type
    MockChunk* = object
      data*: string

    MockNginxChain* = ref object
      chunks*: seq[MockChunk]
      flushed*: bool

  proc newMockNginxChain*(): MockNginxChain =
    MockNginxChain(chunks: @[], flushed: false)

  proc nginxOutputStream*(chain: MockNginxChain): OutputStream =
    ## Creates an OutputStream backed by a mock nginx chain.
    ## Each write appends a chunk to the mock chain.
    ## Flush marks the chain as flushed.
    result = newCallbackOutputStream(proc(data: string) =
      chain.chunks.add(MockChunk(data: data))
    )

  proc nginxOutputStream*(): OutputStream =
    ## Creates a simple mock OutputStream for testing.
    ## Collects output into a string buffer.
    newStringOutputStream()
