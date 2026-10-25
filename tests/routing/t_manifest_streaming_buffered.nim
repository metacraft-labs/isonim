## test_manifest_streaming_page_buffered (IFP-M30 of isonim-specs
## milestones/2026-10-02-isonim-forum-prerequisites).
##
## The streaming pages of streaming_manifest.nim on a host that sets no
## body writer (`ctx.bodyWriter` nil: an in-process server, or one that does
## not stream).  isonim-routing-server-functions.md, "Streaming Pages",
## "Hosts": such a host gets the same bytes in `ctx.responseBody`, and the
## commit-point rules apply just the same.  t_manifest_streaming.nim covers
## the streaming host (nginx with ngx-isonim); this test runs the same
## handlers (streaming_app.nim) in-process, calling the manifest's app with
## a context of its own:
##
## * the first flush commits: while the page awaits its read (a socket this
##   test holds), the response is committed, carries the `pageHeaders`
##   hook's CSP and `X-Page-Hook`, the entry's cache policy and the content
##   type, and the buffered body holds the shell and nothing after it; the
##   page data, the bootstrap with the CSP header's nonce and the tail
##   follow;
## * after the commit `setCachePolicy` is refused and reported, a header
##   setter raises `ResponseCommittedError`, and an exception (`RouteNotFound`
##   or any other) propagates out of the app;
## * before the commit `RouteNotFound` is the 404, an exception the 500,
##   `RpcBadRequest` the 400, a redirect the redirect (no body;
##   `page.flush()` on it raises `ValueError`), each with none of the
##   queued HTML;
## * the JSON variants are answered whole, without the hook's headers;
## * no bootstrap where the host disables hydration; a custom `page.tail`.
##
## Vacuity guard: the context really has no writer (`bodyWriter.isNil`) and
## the hook really ran on the shell (`X-Page-Hook: sFeed` at the commit).
##
## Negative control: the `Page`-returning entry of the same manifest, served
## the same way, gets the same hook headers but is never committed by the
## dispatch (only a transport commits it).
##
## Falsifying mutations (tests/routing/run_streaming_mutants.sh, the
## `buffered-*` mutants, each this test built against a mutated copy of
## src/): the `pageHeaders` hook skipped when the host provides no writer
## (fails the vacuity guard), and the response left uncommitted at the first
## flush on such a host (fails the commit-point and after-commit tests).
##
## No mocks: the dispatch, the handlers and the gate socket are real; the
## only thing absent is the server, which is the case under test.  No
## timing bounds: every wait is for an event, with a deadline that only
## turns a hang into a failure.

import std/[unittest, asyncdispatch, asyncnet, net, json, strutils]
import isonim/routing/[manifest, route_dispatch]
import isonim/server/context
import isonim/ssr/markers
import streaming_app

const
  deadlineMs = 20_000
    ## Only turns a hang into a failure.
  bootstrapMarker = "window._$HY"

var refusals: seq[string]

proc recordRefusal(ctx: RequestContext; requested, kept: CachePolicy) =
  refusals.add $requested & " kept " & $kept & " at " & ctx.request.path

proc installHooks() =
  serverHooks = ServerHooks(onCachePolicyRefused: recordRefusal,
                            pageHeaders: streamingPageHeaders)

proc newCtx(target: string; headers: seq[(string, string)] = @[];
            hydration = true): RequestContext =
  ## A context as a host without a writer makes it.
  let q = target.find('?')
  let path = if q < 0: target else: target[0 ..< q]
  let query = if q < 0: "" else: target[q + 1 .. ^1]
  result = newRequestContext(newSsrRequest("GET", path, target, query,
                                           headers, "127.0.0.1"))
  result.hydration = hydration

proc serve(ctx: RequestContext): ref CatchableError =
  ## Runs the manifest's app on `ctx`: what it raised (nil when nothing).
  try:
    waitFor streamingApp()(ctx)
  except CatchableError as e:
    return e

proc serve(target: string; headers: seq[(string, string)] = @[];
           hydration = true): (RequestContext, ref CatchableError) =
  let ctx = newCtx(target, headers, hydration)
  (ctx, serve(ctx))

proc nonceOf(csp: string): string =
  ## The nonce of `script-src 'nonce-<n>'`.
  let at = csp.find("'nonce-")
  if at < 0: return ""
  let start = at + "'nonce-".len
  csp[start ..< csp.find('\'', start)]

proc scriptNonce(body: string): string =
  ## The nonce attribute of the hydration bootstrap script.
  let at = body.find(bootstrapMarker)
  if at < 0: return ""
  let tag = body.rfind("<script", last = at)
  let n = body.find("nonce=\"", tag)
  if n < 0 or n > at: return ""
  body[n + 7 ..< body.find('"', n + 7)]

proc pageData(html: string): JsonNode =
  let open = "<script type=\"application/json\" id=\"" & pageDataScriptId & "\">"
  let at = html.find(open)
  if at < 0: return newJNull()
  let start = at + open.len
  parseJson(html[start ..< html.find("</script>", start)])

const revalidate = cacheHeaders(cpPrivateRevalidate)

installHooks()

suite "test_manifest_streaming_page_buffered":
  test "vacuity guard: the first flush commits a writerless response with the hook's headers; the rest, the page data and the bootstrap follow":
    let gate = newAsyncSocket()
    gate.setSockOpt(OptReuseAddr, true)
    gate.bindAddr(Port(0), "127.0.0.1")
    gate.listen()
    let gatePort = int(gate.getLocalAddr()[1])
    let ctx = newCtx("/stream/f/1?gate=" & $gatePort)
    check ctx.bodyWriter.isNil
    let accepting = gate.accept()
    let running = streamingApp()(ctx)
    # The page connects to the gate after its shell, and then awaits one
    # byte: what the response is while it waits is the commit point's.
    check waitFor accepting.withTimeout(deadlineMs)
    check ctx.response.committed
    check ctx.response.contentType == "text/html; charset=utf-8"
    check ctx.response.header("X-Page-Hook") == "sFeed"
    let csp = ctx.response.header("Content-Security-Policy")
    check csp.startsWith("script-src 'nonce-")
    check ctx.response.header("Cache-Control") == revalidate[0][1]
    check ctx.response.header("Vary") == revalidate[1][1] & ", Accept"
    check "id=\"shell\"" in ctx.responseBody
    check "rest:" notin ctx.responseBody
    check not running.finished
    if accepting.finished and not accepting.failed:
      let peer = accepting.read
      waitFor peer.send("Z")
      peer.close()
    check waitFor running.withTimeout(deadlineMs)
    gate.close()
    check running.finished and not running.failed
    let body = ctx.responseBody
    check ctx.response.status == 200
    check "<p id=\"rest\">rest:Z</p>" in body
    check pageData(body) == %*{"id": 1, "items": ["a", "Z"]}
    let dataAt = body.find("id=\"" & pageDataScriptId & "\"")
    let bootAt = body.find(bootstrapMarker)
    check body.find("id=\"body-end\"") < dataAt
    check dataAt >= 0 and bootAt > dataAt
    check body.endsWith(defaultPageTail)
    check nonceOf(csp).len == 24
    check scriptNonce(body) == nonceOf(csp)

  test "a per-response policy set before the shell is the committed one":
    let (ctx, err) = serve("/stream/f/2")
    check err.isNil
    check ctx.response.header("X-Early-Override") == "true"
    for (k, v) in cacheHeaders(cpPrivateNoStore):
      if k != "Vary":
        check ctx.response.header(k) == v
    check ctx.response.header("Vary") == "Accept"

  test "after the shell: setCachePolicy is refused and reported, a header setter raises ResponseCommittedError":
    let before = refusals.len
    let (ctx, err) = serve("/stream/f/4")
    check err.isNil
    check ctx.response.committed
    check "<p id=\"late-override\">false</p>" in ctx.responseBody
    check "<p id=\"late-header\">ResponseCommittedError</p>" in ctx.responseBody
    check ctx.response.header("Cache-Control") == revalidate[0][1]
    check ctx.response.header("X-Late") == ""
    check refusals.len == before + 1
    check refusals[^1] == "cpPrivateNoStore kept cpPrivateRevalidate at /stream/f/4"

  test "after the shell: RouteNotFound and errors propagate out of the app":
    for (id, raised) in [(6, "RouteNotFound"), (7, "sFeed 7 raised after its shell")]:
      let (ctx, err) = serve("/stream/f/" & $id)
      check not err.isNil
      if not err.isNil:
        check raised in $err.name & " " & err.msg
        check (id == 6) == (err of RouteNotFound)
      check ctx.response.committed
      check ctx.response.status == 200
      check "id=\"shell\"" in ctx.responseBody
      check "rest:" notin ctx.responseBody
      check not ctx.responseBody.endsWith(defaultPageTail)

  test "before the shell: RouteNotFound is the 404, an error the 500, RpcBadRequest the 400, with none of the page":
    for (id, status, answer) in [
        (3, 404, %*{"error": "not_found"}),
        (5, 500, %*{"error": "internal"}),
        (12, 400, %*{"error": "bad_request", "detail": "sFeed 12 is a bad request"})]:
      let (ctx, err) = serve("/stream/f/" & $id)
      check err.isNil
      check ctx.response.status == status
      check not ctx.response.committed
      check ctx.response.contentType == "application/json"
      check ctx.response.header("Cache-Control") == errorCacheControl
      let got = parseJson(ctx.responseBody)
      check got["error"] == answer["error"]
      # A debug build's asyncdispatch appends the async traceback to the
      # re-raised exception's message, so the detail starts with it (the
      # nginx test, a release build, checks it exactly).
      check got.hasKey("detail") == answer.hasKey("detail")
      if answer.hasKey("detail"):
        check got["detail"].getStr.startsWith(answer["detail"].getStr)
      check "leaked" notin ctx.responseBody
      check ctx.response.header("Content-Security-Policy") == ""
      check ctx.response.header("X-Page-Hook") == ""

  test "before the shell: a redirect has the entry's policy and no body; flushing it raises ValueError":
    for id in [10, 11]:
      let (ctx, err) = serve("/stream/f/" & $id)
      check err.isNil
      check ctx.response.status == 302
      check ctx.response.location == streamingRedirectTarget
      check not ctx.response.committed
      check ctx.responseBody.len == 0
      check ctx.response.header("Cache-Control") == revalidate[0][1]
      check ctx.response.header("X-Page-Hook") == ""
      check ctx.response.header("X-Flush-Refused") ==
        (if id == 11: "ValueError" else: "")

  test "a page that never flushes is answered whole, committed by the dispatch only at the end":
    let (ctx, err) = serve("/stream/f/8")
    check err.isNil
    check not ctx.response.committed   # no flush: the host sends it whole
    check ctx.response.header("X-Page-Hook") == "sFeed"
    check nonceOf(ctx.response.header("Content-Security-Policy")) ==
      scriptNonce(ctx.responseBody)
    check pageData(ctx.responseBody) == %*{"id": 8, "items": ["a", "-"]}

  test "the JSON variant is answered whole, without the hook's headers":
    for (target, hdrs) in [("/stream/f/1.json", newSeq[(string, string)]()),
                           ("/stream/f/1", @[("Accept", "application/json")])]:
      let (ctx, err) = serve(target, hdrs)
      check err.isNil
      check not ctx.response.committed
      check ctx.response.contentType == "application/json"
      check parseJson(ctx.responseBody) == %*{"id": 1, "items": ["a", "-"]}
      check ctx.response.header("Cache-Control") == revalidate[0][1]
      check ctx.response.header("Vary") == revalidate[1][1] & ", Accept"
      check ctx.response.header("Content-Security-Policy") == ""
      check ctx.response.header("X-Page-Hook") == ""

  test "no bootstrap where the host disables hydration; a custom tail is written last":
    let (off, err) = serve("/stream/f/1", hydration = false)
    check err.isNil
    check pageData(off.responseBody) == %*{"id": 1, "items": ["a", "-"]}
    check bootstrapMarker notin off.responseBody
    check off.responseBody.endsWith("</script>" & defaultPageTail)
    let (tailed, err2) = serve("/stream/f/13")
    check err2.isNil
    check tailed.responseBody.endsWith(customTail)
    check tailed.responseBody.count("</body></html>") == 1
    check tailed.responseBody.find(bootstrapMarker) <
      tailed.responseBody.find("id=\"custom-tail\"")

  test "negative control: the Page entry gets the same hook headers and is not committed by the dispatch":
    let (streamed, err1) = serve("/stream/f/1")
    let (whole, err2) = serve("/stream/w/1")
    check err1.isNil and err2.isNil
    check streamed.response.committed
    check not whole.response.committed
    check whole.response.header("X-Page-Hook") == "sWhole"
    check nonceOf(whole.response.header("Content-Security-Policy")).len == 24
    for name in ["Cache-Control", "Vary"]:
      check whole.response.header(name) == streamed.response.header(name)
    check pageData(whole.responseBody) == pageData(streamed.responseBody)
