## Scripted transport is the public deterministic backend used by framework
## tests. The regression enters the actual public requestJson GET no-body path;
## it does not replace browser fetch, Promise or compiler functionality.
import std/[asyncjs, jsffi, json]
import nim_everywhere/[platform, async_compat]
import isonim/core/nondet
import isonim/server/[rpc_client, policy]

var calls = 0
var body, url, httpMethod: string
proc setup(rejects: bool) =
  calls = 0
  body = "not observed"
  url = ""
  httpMethod = ""
  let selected = newTestBackend()
  selected.fetchResponse = proc(request: HttpRequest): PlatformFuture[HttpResponse] =
    inc calls
    body = request.body
    url = request.url
    httpMethod = request.httpMethod.httpMethodName()
    if rejects:
      return newFailedFuture[HttpResponse]("planned scripted rejection")
    newCompletedFuture(HttpResponse(status: 200, body: "{\"ok\":true}"))
  install(selected)
proc publicGet(): Future[cstring] {.async.} =
  let value = await requestJson("GET", "/scripted-get", "", false, csNone)
  return ($value).cstring
proc directEmpty(): Future[JsObject] =
  browserFetch("GET", "/scripted-empty", "", "csrf", "context", "", nil)
proc directBody(): Future[JsObject] =
  browserFetch("POST", "/scripted-body", "payload", "csrf", "context", "text/plain", nil)
proc observe(): JsObject =
  JsObject{calls: calls, body: body.cstring, url: url.cstring,
    httpMethod: httpMethod.cstring, dispatch: backend().dispatchSequence.int}
{.emit: "globalThis.scriptedRpcBody={setup:`setup`,publicGet:`publicGet`,directEmpty:`directEmpty`,directBody:`directBody`,observe:`observe`};".}
