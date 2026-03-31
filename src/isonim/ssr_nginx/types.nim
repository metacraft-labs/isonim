## isonim/ssr_nginx/types.nim
##
## nginx C API type bindings.
## These are opaque types representing nginx internal structures.
## The actual definitions come from nginx headers at compile time.

type
  NgxHttpRequest* = ptr object  ## opaque nginx request
  NgxBuf* = ptr object          ## nginx buffer
  NgxChain* = ptr object        ## nginx buffer chain
  NgxPool* = ptr object         ## nginx memory pool
  NgxInt* = cint
  NgxUint* = cuint

const
  ## nginx return codes.
  NGX_OK*: NgxInt = 0
  NGX_ERROR*: NgxInt = -1
  NGX_DECLINED*: NgxInt = -5

  ## HTTP status codes.
  NGX_HTTP_OK*: NgxInt = 200
  NGX_HTTP_INTERNAL_SERVER_ERROR*: NgxInt = 500
