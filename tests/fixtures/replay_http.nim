## Actual imported private Replay operations. The trusted harness supplies the
## genuine existing owner context; this fixture creates no cursor or allocator.
import std/jsffi
import nim_everywhere/[async_compat, platform, raw_nondet]
import isonim/core/private/replay_http {.all.}
var replayNetwork: ReplayHttpPrimitives
proc observedReplayLinkage(value: ReplayHttpPrimitives): JsObject
    {.importjs: "(function(h){if(!h||!Object.prototype.hasOwnProperty.call(h,'linkage')||!h.linkage||h.linkage.window!==window||typeof h.linkage.fetch!=='function')throw new Error('fixture expected actual private Replay HTTP linkage shape');return h.linkage;})(#)", tags:[RawNondet].}
proc rpInit(context: JsObject) {.exportc:"rpInit".} =
  replayNetwork=newInternalReplayHttp(context)
proc rpHttp(url,body:cstring):PlatformFuture[HttpResponse] {.exportc:"rpHttp".} =
  replayHttp(replayNetwork,HttpRequest(url: $url,httpMethod:hmPost,body: $body,
    headers: @[HttpHeader(name:"X-Duplicate",value:"first"),HttpHeader(name:"X-Duplicate",value:"last"),HttpHeader(name:"Content-Type",value:"text/plain")]))
proc rpRpc(url,body:cstring;signal,extra:JsObject):PlatformFuture[JsObject] {.exportc:"rpRpc".} =
  replayBrowserFetch(replayNetwork,"POST",url,body,"csrf","context","text/plain",signal,extra)
proc rpRaw(url:cstring;init:JsObject):PlatformFuture[JsObject] {.exportc:"rpRaw".} =
  fetchRaw(observedReplayLinkage(replayNetwork),url,init)
proc rpPreparedFetch():JsObject {.exportc:"rpPreparedFetch".} = observedReplayLinkage(replayNetwork).fetch

# Public selection/Record references and Replay primitives share one Nim graph.
# Import the unchanged functional fixture; production modules remain real imports.
import ./record_http as recordFixture

import isonim/core/clock
proc rpSelectedClock():ClockBase {.exportc:"rpSelectedClock".} = currentClock
