## test_manifest_mapped_exceptions (isonim-routing-server-functions.md,
## "Mapped Exceptions").
##
## The application maps exception types to statuses
## (`serverHooks.mappedExceptions`, `mapException[E]`), and the route
## manifest's dispatch and `dispatchRpc` answer a mapped exception raised
## before the response is committed with that status, `Retry-After` and
## `Cache-Control: private, no-store`, instead of `500`.  This test serves the
## manifest below in-process (a context of its own, no body writer: the host
## without a writer of "Streaming Pages") and checks, for each place an
## exception can reach the pipeline:
##
## * a `Page`-returning page, a streaming page before its shell (HTML and
##   JSON variant), a data entry, an `any` entry, a server function, the
##   canonicalization hook and the session resolver of the policy stage:
##   a mapped exception is its status with `Retry-After`, `private,
##   no-store` and the pipeline's JSON body, nothing the handler set or
##   queued is kept, and it is not kept on `ctx.failure`;
## * the mapping is by type: a subtype is mapped by its parent's entry, the
##   first matching entry wins (a subtype listed first gets its own), and an
##   unrelated type that has the same name as a mapped one is not mapped;
## * an unmapped exception is still `500 internal` (kept on `ctx.failure`)
##   from a handler, and still propagates from the hook and the resolver;
## * after a streaming page's commit point (its shell) a mapped exception
##   propagates out of the app exactly as an unmapped one: the status stays
##   the committed 200, no `Retry-After` is added and no error body is
##   appended;
## * `mapException` refuses non-error statuses, an empty error and a
##   negative `retryAfter` at startup, and `CatchableError` and
##   `RouteNotFound` at compile time.
##
## Vacuity guard: every handler, the hook and the resolver count the
## exceptions they raise, and each mapped answer is checked against that
## count, so a 503 that the handler never caused cannot pass; the same
## handler with an unmapped exception answers 500, and with none answers
## its page (the negative control), so the status is the mapping's doing.
##
## Falsifying mutations (tests/routing/run_streaming_mutants.sh, the
## `mapped-*` mutants, this test built against a mutated copy of src/): the
## mapping ignored (`failBeforeCommit` without it), the mapping applied
## after a streaming page's commit point (the committed branch treating a
## mapped exception as answered), `Retry-After` dropped, and the type test
## replaced by a comparison of names.
##
## No mocks: the dispatch, the handlers and the hooks are real; the only
## thing absent is the server, as in t_manifest_streaming_buffered.nim
## (t_manifest_streaming.nim checks the same through nginx).  No timing.

import std/[unittest, asyncdispatch, json, options, strutils]
import isonim/routing/[manifest, route_dispatch]
import isonim/server/[context, rpc, pragma]
import mapping_other

type
  Overloaded* = object of CatchableError
    ## Mapped: 503, `Retry-After: 1`.
  QuotaExceeded* = object of Overloaded
    ## Mapped before its parent: 429, `Retry-After: 7`.
  StillOverloaded* = object of Overloaded
    ## Not mapped itself: its parent's entry answers it.
  Throttled* = object of CatchableError
    ## Mapped without `Retry-After`: 503 only.

  MapRequest* = object
    id*: int
    mode*: Option[string]

  CanonRequest* = object
    slug*: string
    id*: int
    mode*: Option[string]

  MapResponse* = object
    id*: int
    note*: string

routeManifest MappedRoute:
  page   mPage,   "/m/p/:id", MapRequest, MapResponse, json = true
  page   mStream, "/m/s/:id", MapRequest, MapResponse, stream = true, json = true
  get    mData,   "/m/d/:id", MapRequest, MapResponse
  any    mAny,    "/m/any/:id", csrf = csrfAnon
  page   mCanon,  "/m/c/:slug/:id", CanonRequest, MapResponse,
         canonical = ccTopicSlug
  page   mAuth,   "/m/auth/:id", MapRequest, MapResponse, auth = aSession

var raised: int
  ## Exceptions the handlers, the hook and the resolver raised.

const shellHtml = "<!doctype html><html><body><h1 id=\"shell\">shell</h1>"

proc fail(mode: string) =
  ## Raises what `mode` names; nothing for "ok" or "".
  case mode
  of "", "ok": return
  of "overloaded":
    inc raised
    raise newException(Overloaded, "instance i-1 has 4 transactions in flight")
  of "quota":
    inc raised
    raise newException(QuotaExceeded, "quota")
  of "still":
    inc raised
    raise newException(StillOverloaded, "still overloaded")
  of "throttled":
    inc raised
    raise newException(Throttled, "throttled")
  of "samename":
    inc raised
    raise newException(mapping_other.Overloaded, "same name, other type")
  of "unmapped":
    inc raised
    raise newException(ValueError, "an unmapped error")
  else:
    raise newException(AssertionDefect, "unknown mode " & mode)

proc markHandler(ctx: RequestContext) =
  ## What a handler sets before it fails: none of it may be kept.
  ctx.response.setHeader("X-Handler-Set", "1")
  ctx.response.setCookie("handler", "1", CookieOptions(path: "/"))

proc pageHandler(ctx: RequestContext;
                 req: MapRequest): Future[Page[MapResponse]] {.async.} =
  ctx.markHandler()
  fail(req.mode.get(""))
  return Page[MapResponse](html: shellHtml & "<p>page</p></body></html>",
                           data: MapResponse(id: req.id, note: "page"))

proc streamHandler(ctx: RequestContext; req: MapRequest;
                   page: PageStream): Future[MapResponse] {.async.} =
  let mode = req.mode.get("")
  if not mode.endsWith("-after"):
    ctx.markHandler()
    page.write("<p>leaked before the shell</p>")
    fail(mode)
  page.shell(shellHtml)
  await sleepAsync(0)
  if mode.endsWith("-after"):
    fail(mode[0 ..< mode.len - "-after".len])
  page.write("<p id=\"rest\">rest</p>")
  return MapResponse(id: req.id, note: "stream")

proc dataHandler(ctx: RequestContext;
                 req: MapRequest): Future[MapResponse] {.async.} =
  ctx.markHandler()
  fail(req.mode.get(""))
  return MapResponse(id: req.id, note: "data")

proc anyHandler(ctx: RequestContext): Future[void] {.async.} =
  ctx.markHandler()
  fail(ctx.request.queryParam("mode", ""))
  ctx.respondJson(200, "{\"any\":true}")

proc canonHandler(ctx: RequestContext;
                  req: CanonRequest): Future[Page[MapResponse]] {.async.} =
  return Page[MapResponse](html: shellHtml & "</body></html>",
                           data: MapResponse(id: req.id, note: "canon"))

proc authHandler(ctx: RequestContext;
                 req: MapRequest): Future[Page[MapResponse]] {.async.} =
  return Page[MapResponse](html: shellHtml & "</body></html>",
                           data: MapResponse(id: req.id, note: "auth"))

proc mappedRpc(mode: string): Future[int] {.server(auth = aPublic,
                                                     csrf = csrfAnon).} =
  fail(mode)
  return 7

proc canonicalize(ctx: RequestContext; route: string;
                  policy: CanonicalPolicy): Future[CanonicalOutcome] {.async.} =
  ctx.response.setHeader("X-Hook-Set", "1")
  fail(ctx.request.queryParam("hook", ""))
  return canonicalContinue()

proc resolve(req: SsrRequest): Future[Session] {.async.} =
  let sid = req.cookie("sid")
  if sid == "alice":
    return Session(subject: "alice", csrfToken: "tok")
  fail(sid)
  return nil

let app = manifestApp(MappedRouteHandlers(
  mPage: pageHandler, mStream: streamHandler, mData: dataHandler,
  mAny: anyHandler, mCanon: canonHandler, mAuth: authHandler))

proc installHooks() =
  serverHooks = ServerHooks(
    resolveSession: resolve,
    mappedExceptions: @[
      mapException[QuotaExceeded](429, "quota", retryAfter = 7),
      mapException[Overloaded](503, "unavailable", retryAfter = 1),
      mapException[Throttled](503, "throttled")])
  canonicalizer = canonicalize

proc newCtx(target: string; httpMethod = "GET";
            headers: seq[(string, string)] = @[]; body = ""): RequestContext =
  let q = target.find('?')
  let path = if q < 0: target else: target[0 ..< q]
  let query = if q < 0: "" else: target[q + 1 .. ^1]
  newRequestContext(newSsrRequest(httpMethod, path, target, query, headers,
                                  "127.0.0.1", body))

proc serve(target: string; headers: seq[(string, string)] = @[]):
    (RequestContext, ref CatchableError) =
  ## Runs the manifest's app: the context and what the app raised.
  let ctx = newCtx(target, headers = headers)
  try:
    waitFor app(ctx)
  except CatchableError as e:
    return (ctx, e)
  (ctx, nil)

proc rpcCall(mode: string): RequestContext =
  ## The server function, as a browser's generated client calls it.
  result = newCtx(rpcPrefix & "/t_manifest_mapped_exceptions/mappedRpc",
    httpMethod = "POST", body = $(%*{"mode": mode}), headers = @[
      ("Host", "example.test"), ("Origin", "https://example.test"),
      ("Sec-Fetch-Site", "same-origin"), ("Content-Type", "application/json"),
      (csrfHeaderName, "anon-tok"), ("Cookie", anonCsrfCookieName & "=anon-tok")])
  waitFor dispatchRpc(result)

proc isMapped(ctx: RequestContext; status = 503; error = "unavailable";
              retryAfter = "1"): bool =
  ## The mapped answer, exactly: status, Retry-After, no-store, the
  ## pipeline's JSON, nothing the handler or hook set, no failure kept.
  result = ctx.response.status == status and
    ctx.response.header("Retry-After") == retryAfter and
    ctx.response.header("Cache-Control") == errorCacheControl and
    ctx.response.contentType == "application/json" and
    parseJson(ctx.responseBody) == %*{"error": error} and
    ctx.response.header("X-Handler-Set").len == 0 and
    ctx.response.header("X-Hook-Set").len == 0 and
    ctx.response.header("Set-Cookie").len == 0 and
    "leaked" notin ctx.responseBody and
    ctx.failure.isNil
  if not result:
    echo "  not the mapped answer: ", ctx.response.status, " ",
      ctx.response.headers, " ", ctx.responseBody,
      (if ctx.failure.isNil: "" else: " failure: " & ctx.failure.msg)

proc isInternal(ctx: RequestContext): bool =
  ## The unmapped answer: 500 internal, the error kept for the log.
  ctx.response.status == 500 and
    parseJson(ctx.responseBody) == %*{"error": "internal"} and
    ctx.response.header("Retry-After").len == 0 and
    not ctx.failure.isNil

installHooks()

suite "test_manifest_mapped_exceptions":
  test "vacuity guard and negative control: unmapped is 500, none is the page":
    raised = 0
    let (ok, okErr) = serve("/m/p/1?mode=ok")
    check okErr.isNil and ok.response.status == 200
    check "<p>page</p>" in ok.responseBody
    check raised == 0
    let (bad, badErr) = serve("/m/p/1?mode=unmapped")
    check badErr.isNil and bad.isInternal()
    check not bad.failure.isNil and bad.failure.msg.startsWith("an unmapped error")
    check raised == 1

  test "a Page-returning page: a mapped exception is its status with Retry-After and no-store":
    raised = 0
    let (c, e) = serve("/m/p/1?mode=overloaded")
    check e.isNil and c.isMapped()
    let (j, je) = serve("/m/p/1.json?mode=overloaded")
    check je.isNil and j.isMapped()
    check raised == 2

  test "a streaming page before its shell: the mapped status, none of the queued HTML, not committed":
    raised = 0
    let (c, e) = serve("/m/s/1?mode=overloaded")
    check e.isNil and c.isMapped()
    check not c.response.committed
    check c.response.header("Vary").len == 0
    let (j, je) = serve("/m/s/1.json?mode=overloaded")
    check je.isNil and j.isMapped()
    let (u, ue) = serve("/m/s/1?mode=unmapped")
    check ue.isNil and u.isInternal()
    check "leaked" notin u.responseBody
    check raised == 3

  test "a streaming page after its shell: a mapped exception propagates as an unmapped one does":
    raised = 0
    for mode in ["overloaded-after", "unmapped-after"]:
      let (c, e) = serve("/m/s/1?mode=" & mode)
      check not e.isNil
      check c.response.committed
      check c.response.status == 200
      check c.response.contentType == "text/html; charset=utf-8"
      check c.response.header("Retry-After").len == 0
      check "id=\"shell\"" in c.responseBody
      check "rest" notin c.responseBody and "\"error\"" notin c.responseBody
      check c.failure.isNil
    let (m, me) = serve("/m/s/1?mode=overloaded-after")
    check not me.isNil and me of Overloaded
    check not me.isNil and
      me.msg.startsWith("instance i-1 has 4 transactions in flight")
    check raised == 3

  test "a data entry and an any entry: the mapped status":
    raised = 0
    let (d, de) = serve("/m/d/1?mode=overloaded")
    check de.isNil and d.isMapped()
    let (a, ae) = serve("/m/any/1?mode=overloaded")
    check ae.isNil and a.isMapped()
    let (u, ue) = serve("/m/d/1?mode=unmapped")
    check ue.isNil and u.isInternal()
    check raised == 3

  test "a server function: the mapped status; unmapped is still 500":
    raised = 0
    check rpcCall("ok").response.status == 200
    check rpcCall("overloaded").isMapped()
    check rpcCall("unmapped").isInternal()
    check raised == 2

  test "the canonicalization hook and the session resolver: the mapped status; unmapped still propagates":
    raised = 0
    let (h, he) = serve("/m/c/topic-1/1?hook=overloaded")
    check he.isNil and h.isMapped()
    let (hu, hue) = serve("/m/c/topic-1/1?hook=unmapped")
    check hue of ValueError
    let (s, se) = serve("/m/auth/1", @[("Cookie", "sid=overloaded")])
    check se.isNil and s.isMapped()
    let (su, sue) = serve("/m/auth/1", @[("Cookie", "sid=unmapped")])
    check sue of ValueError
    let (sok, soke) = serve("/m/auth/1", @[("Cookie", "sid=alice")])
    check soke.isNil and sok.response.status == 200
    check raised == 4
    discard hu
    discard su

  test "the mapping is by type: subtypes, the first match, and a same-named type":
    raised = 0
    let (q, qe) = serve("/m/d/1?mode=quota")
    check qe.isNil and q.isMapped(status = 429, error = "quota", retryAfter = "7")
    let (s, se) = serve("/m/d/1?mode=still")
    check se.isNil and s.isMapped()
    let (t, te) = serve("/m/d/1?mode=throttled")
    check te.isNil and t.isMapped(error = "throttled", retryAfter = "")
    let (n, ne) = serve("/m/d/1?mode=samename")
    check ne.isNil and n.isInternal()
    check not n.failure.isNil and n.failure of mapping_other.Overloaded
    check raised == 4

  test "mapException refuses what is not an error answer":
    expect ValueError:
      discard mapException[Overloaded](200, "ok")
    expect ValueError:
      discard mapException[Overloaded](302, "moved")
    expect ValueError:
      discard mapException[Overloaded](600, "x")
    expect ValueError:
      discard mapException[Overloaded](503, "")
    expect ValueError:
      discard mapException[Overloaded](503, "x", retryAfter = -1)
    check compiles(mapException[Overloaded](503, "x"))
    check not compiles(mapException[CatchableError](503, "x"))
    check not compiles(mapException[RouteNotFound](503, "x"))
