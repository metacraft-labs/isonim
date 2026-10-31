## Fixed owner fetch composition for trusted backend preparation. The caller
## owns the genuine owner context, captured-original pairing and scrub policy.
## This module neither selects a backend nor owns public settlement dispatch.
when defined(js) and defined(isonimInternalRecordHttp):
  import std/jsffi
  import nim_everywhere/[async_compat, platform, raw_nondet]
  import nim_everywhere/http as neHttp
  import ./rpc_http

  type RecordHttpPrimitives* = ref object
    linkage: JsObject

  proc prepare(context: JsObject): JsObject
      {.importjs: """(function(c){
var m=require('\x40codetracer/boundary-shim/dist/browser/seams-net.js');
var R=require('\x40codetracer/boundary-shim/dist/browser/recorder.js').Recorder;
if(!c||!c.w||c.w.window!==c.w||typeof c.w.Window!=='function'||!(c.w instanceof c.w.Window)||!(c.rec instanceof R)||!c.orig||typeof c.orig.fetch!=='function'||!c.sensitive||typeof c.holes!=='function'||typeof c.refuseOnce!=='function')throw new TypeError('internal Record HTTP requires actual Window, Recorder, captured fetch and owner context');
var f=m.createRecordFetch(c);
return Object.freeze({window:c.w,fetch:f});
})(#)""", tags: [RawNondet].}

  proc newInternalRecordHttp*(context: JsObject): RecordHttpPrimitives {.tags: [RawNondet].} =
    ## Reusing the exact owner context reuses its realm preparation. Validation
    ## checks linkage only; it cannot prove original capture or sensitive policy.
    RecordHttpPrimitives(linkage: prepare(context))

  proc fetchRaw(linkage: JsObject; url: cstring; init: JsObject): PlatformFuture[JsObject]
      {.importjs: "(function(c,u,i){return c.fetch.call(c.window,u,i);})(#,#,#)", tags: [RawNondet].}

  proc recordHttp*(http: RecordHttpPrimitives;
      request: HttpRequest): PlatformFuture[HttpResponse] {.tags: [RawNondet].} =
    ## Retain the native buffered facade's conversion and executor boundaries.
    let parts = prepareHttpRequestRaw(rawBackendAccess, request)
    result = newPromise proc(resolve: proc(response: HttpResponse)) =
      let init = buildHttpRequestInitRaw(rawBackendAccess, parts)
      let pending = fetchRaw(http.linkage, parts.url, init)
      projectHttpResponseRaw(rawBackendAccess, pending, resolve)

  proc recordBrowserFetch*(http: RecordHttpPrimitives;
      httpMethod, url, body, csrf, context, contentType: cstring;
      signal: JsObject; extra: JsObject = nil): PlatformFuture[JsObject] {.tags: [RawNondet].} =
    ## RPC deliberately keeps synchronous construction/fetch faults synchronous
    ## and retains its distinct abort/error and response metadata projection.
    let init = buildRpcRequestInitRaw(rawBackendAccess, httpMethod, body, csrf,
      context, contentType, signal, extra)
    let pending = fetchRaw(http.linkage, url, init)
    projectRpcResponseRaw(rawBackendAccess, pending, signal)
