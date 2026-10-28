## Fixed native RPC construction/projection shared by trusted backend code.
## This module owns no transport selection, clock or settlement dispatch. Keep
## it independent of nondet so private backend implementations can reuse it.
when defined(js):
  import std/jsffi
  import nim_everywhere/[async_compat, raw_nondet]

  proc buildRpcRequestInitRaw*(access: RawBackendAccess;
      httpMethod, body, csrf, context, contentType: cstring;
      signal: JsObject): JsObject {.tags: [RawNondet].} =
    ## Preserve original object construction and synchronous getter/setter faults.
    ## In particular, an explicit empty body differs from a nil cstring body.
    {.emit: """
    var headers = {"X-CSRF-Token": `csrf`, "X-Isonim-Context": `context`};
    if (`contentType` !== "") headers["Content-Type"] = `contentType`;
    `result` = {method: `httpMethod`, headers: headers, credentials: "same-origin"};
    if (`body` !== null) `result`.body = `body`;
    if (`signal`) `result`.signal = `signal`;
    """.}

  proc projectRpcResponseRaw*(access: RawBackendAccess;
      pending: PlatformFuture[JsObject]; signal: JsObject): PlatformFuture[JsObject]
      {.tags: [RawNondet].} =
    ## Return the original chain, consuming the native body exactly once.
    ## Catch covers headers, body and projection; synchronous init/fetch faults
    ## precede this operation and retain their original synchronous behavior.
    {.emit: """
    `result` = `pending`
      .then(function (r) {
        return r.text().then(function (t) { return {status: r.status, text: t}; });
      })
      .catch(function (e) {
        var aborted = (e && e.name === "AbortError") || (`signal` && `signal`.aborted);
        return {status: aborted ? -1 : 0, text: String(e)};
      });
    """.}
