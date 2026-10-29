## isonim/server/rpc_client.nim
##
## The browser side of server functions and route manifest clients: a
## non-blocking `fetch` call that returns a `Future[T]` (a JS Promise).
##
## Every request
##
## * carries `X-CSRF-Token` (from the page's `csrf-token` meta tag) and
##   `Isonim-Context` (client_context.nim);
## * carries `Isonim-After` while the client holds a commit position from
##   the last 60 s, and keeps the position a successful response's
##   `Isonim-Commit` names (client_context.nim, read-your-writes);
## * captures the client context when it is sent and, when the response
##   arrives, drops it if the context changed under its scope
##   (URL-Schema.md §5.4): a dropped response never settles the returned
##   future, so the caller's continuation never runs and no signal, cache or
##   storage changes; the dropped-response hooks see it;
## * when navigation-scoped, is aborted when the navigation changes.
##
## * when state-changing (any method but `GET` and `HEAD`), carries an
##   `Idempotency-Key`: a fresh version 4 UUID per call (nondet.randomUuid),
##   the same on its one resend; the server deduplicates a write by it
##   (pilot-projects/isonim-forum/IsoNim-Forum.md §3.8.5, "Idempotency");
## * when state-changing and answered `503` with a `Retry-After` in seconds
##   (0 to `maxRetryAfterSeconds`), is resent once after that delay with the
##   same key, unless the context went stale in the meantime (the resend
##   would then act for another account, so the response is dropped as
##   stale instead). A `Retry-After` that is absent, a date or out of range
##   is not waited for: the `503` rejects as any non-2xx does. This is the
##   client's half of the forum's `IF001`/`IF002` row and of "channel lost
##   after sending" (§3.8.5): the server never resends a write it cannot
##   reroute, the client does, and the key makes it at most once.
##
## A non-2xx response rejects the future with `RpcError` (its status, body
## and `Retry-After`); a network failure with `RpcError` of status 0.
##
## JS target only.  There is no synchronous variant: the browser's main
## thread never waits for the network.

when not defined(js):
  {.error: "isonim/server/rpc_client is the browser client (JS target only)".}

import std/[asyncjs, json, jsffi, strutils]
import policy
import ../core/nondet as nondet
import ../routing/[client_context, json_decode]

export asyncjs, json, jsffi, client_context, json_decode

type
  RpcError* = object of CatchableError
    ## A server function or route answered with a non-2xx status.
    status*: int   ## the HTTP status; 0 for a network failure
    body*: string  ## the response body (`{"error": ...}` for framework errors)
    retryAfter*: string  ## the response's `Retry-After`, "" when absent

const maxRetryAfterSeconds* = 60
  ## The longest `Retry-After` a write waits for before its one resend.

proc newRpcError(status: int; body, url: string; retryAfter = ""): ref RpcError =
  result = newException(RpcError,
    (if status == 0: "network failure calling " & url
     else: "HTTP " & $status & " from " & url) &
    (if body.len > 0: ": " & body else: ""))
  result.status = status
  result.body = body
  result.retryAfter = retryAfter

proc retryAfterSeconds*(value: string): int =
  ## `Retry-After` as delta-seconds (RFC 9110 §10.2.3) within
  ## 0..`maxRetryAfterSeconds`, or -1 (absent, an HTTP-date, out of range).
  let v = value.strip
  if v.len == 0 or v.len > 4: return -1
  for c in v:
    if c notin {'0'..'9'}: return -1
  result = parseInt(v)
  if result > maxRetryAfterSeconds: result = -1

proc isStateChanging*(httpMethod: string): bool =
  httpMethod != "GET" and httpMethod != "HEAD"

proc delayMs(ms: int): Future[void] =
  ## Resolves after `ms` on the page's clock (nondet.scheduleAt).
  newPromise(proc(resolve: proc()) = discard nondet.scheduleAt(float64(ms), resolve))


proc neverSettles(): Future[void] =
  ## A future that never completes: awaiting it ends the async proc
  ## without resuming its caller.
  newPromise(proc(resolve: proc()) = discard)

const jsonMediaType = "application/json"

proc requestJson*(httpMethod, url: string; body: string; hasBody: bool;
                  scope: ContextScope;
                  contentType = "";
                  accept = ""): Future[JsonNode] {.async.} =
  ## Sends one request and returns the parsed JSON response, subject to
  ## the context check of `scope` (module doc: the idempotency key and the
  ## one resend of a write answered `503` with `Retry-After`). A body is
  ## sent as `contentType` ("": `application/json`); `accept`, when not "",
  ## is sent as `Accept`.
  let captured = clientContext()
  let signal = if scope == csNavigation: navigationSignal() else: nil
  let key = if isStateChanging(httpMethod): nondet.randomUuid() else: ""
  let after = afterHeaderC(nondet.nowMs())
  var extra: JsObject = nil
  if key.len > 0 or accept.len > 0 or after.len > 0:
    extra = newJsObject()
    if key.len > 0: extra["Idempotency-Key"] = cstring(key)
    if accept.len > 0: extra["Accept"] = cstring(accept)
    if after.len > 0: extra[afterHeaderName] = after
  var attempt = 0
  var status = 0
  var text, retryAfter: string
  var commit: cstring = ""
  while true:
    inc attempt
    let outcome = await nondet.browserFetch(cstring(httpMethod), cstring(url),
      (if hasBody: cstring(body) else: nil),
      cstring(csrfToken()), cstring(contextHeaderValue()),
      cstring(if not hasBody: "" elif contentType.len > 0: contentType else: jsonMediaType), signal, extra)
    status = outcome.status.to(int)
    text = $outcome.text.to(cstring)
    retryAfter = $outcome.retryAfter.to(cstring)
    commit = outcome.commit.to(cstring)
    let reason = staleReason(captured, scope)
    if reason.len > 0 or status == -1:
      reportDropped(DroppedResponse(httpMethod: httpMethod, url: url,
        status: status, scope: scope,
        reason: (if reason.len > 0: reason else: "navigation"), body: text,
        idempotencyKey: key))
      await neverSettles()
    if status == 503 and attempt == 1 and key.len > 0:
      let wait = retryAfterSeconds(retryAfter)
      if wait >= 0:
        await delayMs(wait * 1000)
        # A context change while waiting: the resend would carry the new
        # account's cookies, so it is not sent, and the response is dropped.
        let late = staleReason(captured, scope)
        if late.len > 0:
          reportDropped(DroppedResponse(httpMethod: httpMethod, url: url,
            status: status, scope: scope, reason: late, body: text,
            idempotencyKey: key))
          await neverSettles()
        continue
    break
  if status < 200 or status > 299:
    raise newRpcError(status, text, url, retryAfter)
  if commit.len > 0 and isStateChanging(httpMethod): noteCommitC(commit, nondet.nowMs())
  result = if text.len == 0: newJNull() else: parseJson(text)

proc rpcCall*[T](url: string; args: JsonNode;
                 scope: ContextScope): Future[T] {.async.} =
  ## Calls a server function: `POST` with the arguments as a JSON object.
  let node = await requestJson("POST", url, jsonText(args), true, scope)
  result = fromJsonLite[T](node)

proc rpcCallText*[T](url: string; body: string;
                     scope: ContextScope): Future[T] {.async.} =
  ## `rpcCall` with the arguments already serialized (the `{.server.}`
  ## stubs build them with `toJsAny`, json_decode.nim).
  let node = await requestJson("POST", url, body, true, scope)
  result = fromJsonLite[T](node)