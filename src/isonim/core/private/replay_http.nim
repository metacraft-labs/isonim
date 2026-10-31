## Fixed owner fetch composition for trusted backend preparation. The caller
## owns the genuine owner context, captured-original pairing and scrub policy.
## This module neither selects a backend nor owns public settlement dispatch.
when defined(js) and defined(isonimInternalReplayHttp):
  import std/jsffi
  import nim_everywhere/[async_compat, platform, raw_nondet]
  import nim_everywhere/http as neHttp
  import ./rpc_http

  type ReplayHttpPrimitives* = ref object
    linkage: JsObject

  proc prepare(context: JsObject): JsObject
      {.importjs: """(function(c){
var m=require('\x40codetracer/boundary-shim/dist/browser/replay/net.js');
if(!c||!c.w||c.w.window!==c.w||typeof c.w.Window!=='function'||!(c.w instanceof c.w.Window)||!c.replay||c.replay.protocol!==1||['next','registerTask','onTask','offTask','status'].some(function(k){return typeof c.replay[k]!=='function';})||!c.orig||typeof c.orig.fetch!=='function'||typeof c.orig.Response!=='function'||typeof c.holes!=='function'||typeof c.nextTaskId!=='function'||typeof c.nextReqId!=='function')throw new TypeError('internal Replay HTTP requires actual Window, Replay cursor, captured fetch/Response and owner context');
var f=m.createFrameworkReplayFetch(c);
return Object.freeze({window:c.w,fetch:f});
})(#)""", tags: [RawNondet].}

  proc newInternalReplayHttp*(context: JsObject): ReplayHttpPrimitives {.tags: [RawNondet].} =
    ## Reusing the exact owner context reuses its realm preparation. Validation
    ## checks linkage only; it cannot prove original capture or sensitive policy.
    ReplayHttpPrimitives(linkage: prepare(context))

  proc fetchRaw(linkage: JsObject; url: cstring; init: JsObject): PlatformFuture[JsObject]
      {.importjs: "(function(c,u,i){return c.fetch.call(c.window,u,i);})(#,#,#)", tags: [RawNondet].}

  proc replayHttp*(http: ReplayHttpPrimitives;
      request: HttpRequest): PlatformFuture[HttpResponse] {.tags: [RawNondet].} =
    ## Retain the native buffered facade's conversion and executor boundaries.
    let parts = prepareHttpRequestRaw(rawBackendAccess, request)
    result = newPromise proc(resolve: proc(response: HttpResponse)) =
      let init = buildHttpRequestInitRaw(rawBackendAccess, parts)
      let pending = fetchRaw(http.linkage, parts.url, init)
      projectHttpResponseRaw(rawBackendAccess, pending, resolve)

  proc replayBrowserFetch*(http: ReplayHttpPrimitives;
      httpMethod, url, body, csrf, context, contentType: cstring;
      signal: JsObject; extra: JsObject = nil): PlatformFuture[JsObject] {.tags: [RawNondet].} =
    ## RPC deliberately keeps synchronous construction/fetch faults synchronous
    ## and retains its distinct abort/error and response metadata projection.
    let init = buildRpcRequestInitRaw(rawBackendAccess, httpMethod, body, csrf,
      context, contentType, signal, extra)
    let pending = fetchRaw(http.linkage, url, init)
    projectRpcResponseRaw(rawBackendAccess, pending, signal)
