## Compile the actual owning source, exposing its existing private native path
## only in this fixture. No copied construction/projection implementation.
## JS tests justify narrow fault injection and also exercise real local HTTP.
include ../src/isonim/core/nondet

proc resetRpc() = install(newRealBackend(1))
proc rpcDispatches(): int = backend().dispatchSequence.int
proc facadeRpc(httpMethod, url, body, csrf, context, contentType: cstring;
    signal: JsObject): Future[JsObject] =
  browserFetch(httpMethod, url, body, csrf, context, contentType, signal)
proc rawRpc(httpMethod, url, body, csrf, context, contentType: cstring;
    signal: JsObject): Future[JsObject] =
  rawBrowserFetch(httpMethod, url, body, csrf, context, contentType, signal)
{.emit: "globalThis.rpcProbe = {reset: `resetRpc`, count: `rpcDispatches`, facade: `facadeRpc`, raw: `rawRpc`};".}

when defined(extractedRpcComposition):
  proc composeRpc(httpMethod, url, body, csrf, context, contentType: cstring;
      signal: JsObject): Future[JsObject] =
    let init = buildRpcRequestInitRaw(rawBackendAccess, httpMethod, body, csrf,
      context, contentType, signal)
    let pending = neHttp.fetchBrowserResponseRaw(rawBackendAccess, url, init)
    projectRpcResponseRaw(rawBackendAccess, pending, signal)
  {.emit: "rpcProbe.composition = `composeRpc`;".}

when defined(rawRpcInitEffectCeiling):
  proc component() {.tags: [].} =
    discard buildRpcRequestInitRaw(rawBackendAccess, "GET", nil, "", "", "", nil)
  component()
when defined(rawRpcProjectEffectCeiling):
  proc component() {.tags: [].} =
    discard projectRpcResponseRaw(rawBackendAccess, Future[JsObject](nil), nil)
  component()
when defined(extractedRpcComposition):
  proc trustedRpc() {.tags: [RawNondet].} =
    let init = buildRpcRequestInitRaw(rawBackendAccess, "GET", nil, "", "", "", nil)
    discard init
    discard projectRpcResponseRaw(rawBackendAccess, Future[JsObject](nil), nil)
