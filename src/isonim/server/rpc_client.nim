## isonim/server/rpc_client.nim
##
## The browser side of server functions and route manifest clients: a
## non-blocking `fetch` call that returns a `Future[T]` (a JS Promise).
##
## Every request
##
## * carries `X-CSRF-Token` (from the page's `csrf-token` meta tag) and
##   `X-Isonim-Context` (client_context.nim);
## * captures the client context when it is sent and, when the response
##   arrives, drops it if the context changed under its scope
##   (URL-Schema.md §5.4): a dropped response never settles the returned
##   future, so the caller's continuation never runs and no signal, cache or
##   storage changes; the dropped-response hooks see it;
## * when navigation-scoped, is aborted when the navigation changes.
##
## A non-2xx response rejects the future with `RpcError` (its status and
## body); a network failure with `RpcError` of status 0.
##
## JS target only.  There is no synchronous variant: the browser's main
## thread never waits for the network.

when not defined(js):
  {.error: "isonim/server/rpc_client is the browser client (JS target only)".}

import std/[asyncjs, json, jsffi]
import policy
import ../routing/client_context

export asyncjs, json, client_context

type
  RpcError* = object of CatchableError
    ## A server function or route answered with a non-2xx status.
    status*: int   ## the HTTP status; 0 for a network failure
    body*: string  ## the response body (`{"error": ...}` for framework errors)

proc newRpcError(status: int; body, url: string): ref RpcError =
  result = newException(RpcError,
    (if status == 0: "network failure calling " & url
     else: "HTTP " & $status & " from " & url) &
    (if body.len > 0: ": " & body else: ""))
  result.status = status
  result.body = body

proc rawFetch(httpMethod, url, body: cstring; csrf, context: cstring;
              contentType: cstring; signal: JsObject): Future[JsObject] =
  ## Resolves with `{status, text}`; never rejects.  A network failure is
  ## status 0; an abort is status -1 wherever in the chain it lands: before
  ## the response headers (`fetch` rejects) or after them, while the body
  ## is read (`text()` rejects).  The final `catch` covers the whole chain,
  ## so an `AbortError` never reaches the caller as an exception.
  {.emit: """
  var headers = {"X-CSRF-Token": `csrf`, "X-Isonim-Context": `context`};
  if (`contentType` !== "") headers["Content-Type"] = `contentType`;
  var init = {method: `httpMethod`, headers: headers, credentials: "same-origin"};
  if (`body` !== null) init.body = `body`;
  if (`signal`) init.signal = `signal`;
  `result` = fetch(`url`, init)
    .then(function (r) {
      return r.text().then(function (t) { return {status: r.status, text: t}; });
    })
    .catch(function (e) {
      var aborted = (e && e.name === "AbortError") || (`signal` && `signal`.aborted);
      return {status: aborted ? -1 : 0, text: String(e)};
    });
  """.}

proc neverSettles(): Future[void] =
  ## A future that never completes: awaiting it ends the async proc
  ## without resuming its caller.
  newPromise(proc(resolve: proc()) = discard)

proc requestJson*(httpMethod, url: string; body: string; hasBody: bool;
                  scope: ContextScope;
                  contentType = "application/json"): Future[JsonNode] {.async.} =
  ## Sends one request and returns the parsed JSON response, subject to
  ## the context check of `scope`.
  let captured = clientContext()
  let signal = if scope == csNavigation: navigationSignal() else: nil
  let outcome = await rawFetch(cstring(httpMethod), cstring(url),
    (if hasBody: cstring(body) else: nil),
    cstring(csrfToken()), cstring(contextHeaderValue()),
    cstring(if hasBody: contentType else: ""), signal)
  let status = outcome.status.to(int)
  let text = $outcome.text.to(cstring)
  let reason = staleReason(captured, scope)
  if reason.len > 0 or status == -1:
    reportDropped(DroppedResponse(httpMethod: httpMethod, url: url,
      status: status, scope: scope,
      reason: (if reason.len > 0: reason else: "navigation"), body: text))
    await neverSettles()
  if status < 200 or status > 299:
    raise newRpcError(status, text, url)
  result = if text.len == 0: newJNull() else: parseJson(text)

proc rpcCall*[T](url: string; args: JsonNode;
                 scope: ContextScope): Future[T] {.async.} =
  ## Calls a server function: `POST` with the arguments as a JSON object.
  let node = await requestJson("POST", url, $args, true, scope)
  result = to(node, T)
