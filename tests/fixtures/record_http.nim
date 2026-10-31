## Real private owner operations. Replay-only composition reuses the existing
## owner callable and production projection helpers, never a simulated cursor.
import std/jsffi
import nim_everywhere/[async_compat, platform, raw_nondet]
import nim_everywhere/http as neHttp
import isonim/core/private/record_http {.all.}
import isonim/core/private/rpc_http
var network: RecordHttpPrimitives
# Only this trusted fixture observes the emitted private object field. The
# functional operations below still call the actual imported production module.
proc observedLinkage(value: RecordHttpPrimitives): JsObject
    {.importjs: "(function(h){if(!h||!Object.prototype.hasOwnProperty.call(h,'linkage')||!h.linkage||h.linkage.window!==window||typeof h.linkage.fetch!=='function')throw new Error('fixture expected actual private Record HTTP linkage shape');return h.linkage;})(#)", tags: [RawNondet].}
proc init(context: JsObject) {.exportc:"rhInit".} =
  network = newInternalRecordHttp(context)
proc buffered(url,body:cstring):PlatformFuture[HttpResponse] {.exportc:"rhHttp".} =
  recordHttp(network,HttpRequest(url: $url,httpMethod:hmPost,body: $body,
    headers: @[HttpHeader(name:"X-Duplicate",value:"first"),HttpHeader(name:"X-Duplicate",value:"last"),HttpHeader(name:"Content-Type",value:"text/plain")]))
proc rpc(url,body:cstring;signal,extra:JsObject):PlatformFuture[JsObject] {.exportc:"rhRpc".} =
  recordBrowserFetch(network,"POST",url,body,"csrf","context","text/plain",signal,extra)
proc supplied(fetch:JsObject;url:cstring;init:JsObject):PlatformFuture[JsObject] {.importjs:"#.call(window,#,#)",tags:[RawNondet].}
proc replayBuffered(fetch:JsObject;url,body:cstring):PlatformFuture[HttpResponse] {.exportc:"rhReplayHttp".} =
  let parts=prepareHttpRequestRaw(rawBackendAccess,HttpRequest(url: $url,httpMethod:hmPost,body: $body,
    headers: @[HttpHeader(name:"X-Duplicate",value:"first"),HttpHeader(name:"X-Duplicate",value:"last"),HttpHeader(name:"Content-Type",value:"text/plain")]))
  result=newPromise proc(resolve:proc(r:HttpResponse)) =
    let init=buildHttpRequestInitRaw(rawBackendAccess,parts)
    projectHttpResponseRaw(rawBackendAccess,supplied(fetch,parts.url,init),resolve)
proc replayRpc(fetch:JsObject;url,body:cstring;signal,extra:JsObject):PlatformFuture[JsObject] {.exportc:"rhReplayRpc".} =
  let init=buildRpcRequestInitRaw(rawBackendAccess,"POST",body,"csrf","context","text/plain",signal,extra)
  projectRpcResponseRaw(rawBackendAccess,supplied(fetch,url,init),signal)
proc view(response:HttpResponse):JsObject {.exportc:"rhView".} =
  var headers:seq[JsObject]
  for h in response.headers:
    let name=h.name.cstring
    let value=h.value.cstring
    headers.add(JsObject{name:name,value:value})
  JsObject{status:response.status,text:response.body.cstring,headers:headers}
import isonim/core/private/record_timers
var timers:RecordTimerPrimitives
proc timerInit(w,r,o:JsObject) {.exportc:"rhTimerInit".} = timers=newInternalRecordTimers(w,r,o)
proc timer(cb:proc()) {.exportc:"rhTimer".} = discard recordTimeout(timers,1,cb)
import std/asyncjs
import isonim/core/nondet
proc publicHttp(url:cstring):Future[JsObject] {.exportc:"rhPublicHttp",async.} =
  let r=await nondet.fetch(HttpRequest(url: $url))
  return JsObject{status:r.status,text:r.body.cstring,dispatch:backend().dispatchSequence.int}
proc publicRpc(url:cstring):Future[JsObject] {.exportc:"rhPublicRpc",async.} =
  let r=await nondet.browserFetch("GET",url,nil,"csrf","context","",nil)
  return JsObject{status:r.status,text:r.text,dispatch:backend().dispatchSequence.int}
proc publicSelect(scripted:bool) {.exportc:"rhPublicSelect".} =
  if scripted:
    let b=newTestBackend()
    b.fetchResponse=proc(request:HttpRequest):PlatformFuture[HttpResponse] =
      newCompletedFuture(HttpResponse(status:218,body:"scripted"))
    nondet.install(b)
  else:nondet.install(newRealBackend(1))
proc dispatch():int {.exportc:"rhDispatch".} = backend().dispatchSequence.int

# Deliberate private test visibility observes the exact raw returned Promise;
# these fixture exports do not add production capabilities.
proc rawPending(url: cstring; init: JsObject): PlatformFuture[JsObject]
    {.exportc: "rhRaw".} =
  fetchRaw(observedLinkage(network), url, init)

import nim_everywhere/fake_time
import nim_everywhere/time as neTime

type NetworkCustomClock = ref object of ClockBase
method now(clock: NetworkCustomClock): float64 = 321
proc customSelect() {.exportc: "rhCustomSelect".} =
  let clock = NetworkCustomClock(scripted: true)
  clock.fetchResponse = proc(request: HttpRequest): PlatformFuture[HttpResponse] =
    newCompletedFuture(HttpResponse(status: 219, body: "custom"))
  nondet.install(clock)

var fakeContext: FakeAsyncContext
var fakeFired: int
proc fakeStart() {.exportc: "rhFakeStart".} =
  fakeContext = newFakeAsyncContext()
  fakeContext.advance(17)
  fakeContext.install()
  fakeFired = 0
  discard neTime.scheduleAt(2, proc() = inc fakeFired)
proc fakeState(): JsObject {.exportc: "rhFakeState".} =
  let selected = currentClock of NetworkCustomClock
  let milliseconds = neTime.monotonicNowMs().int
  JsObject{selected: selected, milliseconds: milliseconds,
    fired: fakeFired, dispatch: backend().dispatchSequence.int}
proc fakeAdvance() {.exportc: "rhFakeAdvance".} = fakeContext.advance(2)
proc fakeEnd() {.exportc: "rhFakeEnd".} = fakeContext.uninstall()

proc preparedFetch(): JsObject {.exportc: "rhPreparedFetch".} = observedLinkage(network).fetch
