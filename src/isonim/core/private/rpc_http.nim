## Fixed native RPC construction/projection shared by trusted backend code.
## This module owns no transport selection, clock or settlement dispatch. Keep
## it independent of nondet so private backend implementations can reuse it.
when defined(js):
  import std/jsffi
  import nim_everywhere/[async_compat, raw_nondet]

  proc buildRpcRequestInitRaw*(access: RawBackendAccess;
      httpMethod, body, csrf, context, contentType: cstring;
      signal: JsObject; extra: JsObject = nil): JsObject {.tags: [RawNondet].} =
    ## Preserve original object construction and synchronous getter/setter faults.
    ## In particular, an explicit empty body differs from a nil cstring body.
    ## The context hint is `Isonim-Context` (server/policy.nim
    ## `contextHeaderName`; URL-Schema.md §5.4): outside the edge's `X-Isonim-*`
    ## strip list and without the `X-` prefix (RFC 6648). `extra` (an object of
    ## header names to values, or nil) adds request headers after the fixed
    ## ones, in its own key order: rpc_client.nim's `Isonim-After` and
    ## `Idempotency-Key`.
    {.emit: """
    var headers = {"X-CSRF-Token": `csrf`, "Isonim-Context": `context`};
    if (`contentType` !== "") headers["Content-Type"] = `contentType`;
    if (`extra`) for (var k in `extra`) headers[k] = `extra`[k];
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
    ## The projection is `{status, text, retryAfter, commit}`: `retryAfter` is
    ## the response's `Retry-After` (RFC 9110 §10.2.3), `commit` its
    ## `Isonim-Commit` (server/policy.nim `commitHeaderName`), each "" when
    ## absent or when the chain failed. Both are read synchronously inside the
    ## existing body continuation, so no Promise turn is added.
    {.emit: """
    `result` = `pending`
      .then(function (r) {
        return r.text().then(function (t) {
          return {status: r.status, text: t, retryAfter: r.headers.get("Retry-After") || "",
                  commit: r.headers.get("Isonim-Commit") || ""};
        });
      })
      .catch(function (e) {
        var aborted = (e && e.name === "AbortError") || (`signal` && `signal`.aborted);
        return {status: aborted ? -1 : 0, text: String(e), retryAfter: "", commit: ""};
      });
    """.}
