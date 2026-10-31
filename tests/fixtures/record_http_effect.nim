## Exact public/raw effect ceilings; including production exposes raw bindings.
import std/jsffi
import nim_everywhere/[platform, raw_nondet]
include ../../src/isonim/core/private/record_http
const httpBoundary {.intdefine.} = 0
when defined(httpReject):
  proc check(h:RecordHttpPrimitives; x:JsObject; request:HttpRequest) {.tags:[].} =
    when httpBoundary == 0: discard prepare(x)
    elif httpBoundary == 1: discard fetchRaw(h.linkage,"/",x)
    elif httpBoundary == 2: discard newInternalRecordHttp(x)
    elif httpBoundary == 3: discard recordHttp(h,request)
    else: discard recordBrowserFetch(h,"GET","/",nil,"","","",nil)
else:
  proc check(h:RecordHttpPrimitives; x:JsObject; request:HttpRequest) {.tags:[RawNondet].} =
    when httpBoundary == 0: discard prepare(x)
    elif httpBoundary == 1: discard fetchRaw(h.linkage,"/",x)
    elif httpBoundary == 2: discard newInternalRecordHttp(x)
    elif httpBoundary == 3: discard recordHttp(h,request)
    else: discard recordBrowserFetch(h,"GET","/",nil,"","","",nil)
proc keep(h:RecordHttpPrimitives;x:JsObject;request:HttpRequest) {.exportc:"rhEffect".} = check(h,x,request)
