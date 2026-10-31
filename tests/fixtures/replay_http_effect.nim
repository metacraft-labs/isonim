## Exact public/raw effect ceilings; including production exposes raw bindings.
import std/jsffi
import nim_everywhere/[platform, raw_nondet]
include ../../src/isonim/core/private/replay_http
const httpBoundary {.intdefine.} = 0
when defined(httpReject):
  proc check(h:ReplayHttpPrimitives; x:JsObject; request:HttpRequest) {.tags:[].} =
    when httpBoundary == 0: discard prepare(x)
    elif httpBoundary == 1: discard fetchRaw(h.linkage,"/",x)
    elif httpBoundary == 2: discard newInternalReplayHttp(x)
    elif httpBoundary == 3: discard replayHttp(h,request)
    else: discard replayBrowserFetch(h,"GET","/",nil,"","","",nil)
else:
  proc check(h:ReplayHttpPrimitives; x:JsObject; request:HttpRequest) {.tags:[RawNondet].} =
    when httpBoundary == 0: discard prepare(x)
    elif httpBoundary == 1: discard fetchRaw(h.linkage,"/",x)
    elif httpBoundary == 2: discard newInternalReplayHttp(x)
    elif httpBoundary == 3: discard replayHttp(h,request)
    else: discard replayBrowserFetch(h,"GET","/",nil,"","","",nil)
proc keep(h:ReplayHttpPrimitives;x:JsObject;request:HttpRequest) {.exportc:"rhEffect".} = check(h,x,request)
