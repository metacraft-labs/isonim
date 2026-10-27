## Diagnostic only: actual published seams, no intercepted platform calls.
import std/[asyncjs, jsffi]
import nim_everywhere/[platform, async_compat]
import nim_everywhere/http as neHttp
import isonim/core/nondet

proc ordinary(url: cstring): Future[JsObject] {.async.} =
  let response = await nondet.fetch(HttpRequest(url: $url))
  var header = ""
  for value in response.headers:
    if value.name == "x-xr-proof": header = value.value
  return JsObject{status: response.status, body: response.body.cstring,
    header: header.cstring, dispatch: backend().dispatchSequence.int}
proc rpc(url: cstring; signal: JsObject): Future[JsObject] {.async.} =
  let response = await browserFetch("GET", url, nil, "csrf", "context", "", signal)
  return JsObject{status: response.status, body: response.text,
    dispatch: backend().dispatchSequence.int}
proc count(): int = backend().dispatchSequence.int
proc reset() = install(newRealBackend(1))
proc raw(url: cstring; init: JsObject): Future[JsObject] =
  neHttp.fetchBrowserResponseRaw(rawBackendAccess, url, init)
proc scripted(rejects: bool): Future[JsObject] {.async.} =
  let b = newTestBackend()
  b.fetchResponse = proc(request: HttpRequest): PlatformFuture[HttpResponse] =
    if rejects: return newFailedFuture[HttpResponse]("scripted failure")
    newCompletedFuture(HttpResponse(status: 201, body: "ready"))
  install(b)
  let value = await nondet.fetch(HttpRequest(url: "/not-network"))
  return JsObject{status: value.status, body: value.body.cstring,
    dispatch: b.dispatchSequence.int}
proc scriptedRpc(rejects: bool): Future[JsObject] {.async.} =
  let b = newTestBackend()
  b.fetchResponse = proc(request: HttpRequest): PlatformFuture[HttpResponse] =
    if rejects: return newFailedFuture[HttpResponse]("scripted failure")
    newCompletedFuture(HttpResponse(status: 201, body: "ready"))
  install(b)
  return await rpc("/not-network", nil)
{.emit: "globalThis.xrRequest = {ordinary: `ordinary`, rpc: `rpc`, raw: `raw`, count: `count`, reset: `reset`, scripted: `scripted`, scriptedRpc: `scriptedRpc`};".}
