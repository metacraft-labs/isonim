## `dispatchRpc`: the server side of server functions over HTTP, run
## in-process on requests built here (the HTTP transport is ngx-isonim's,
## tested against real nginx there and in tests/browser).
##
## Covers the order of the pipeline (lookup and method, body, auth, CSRF,
## client context, handler), each refusal's status and body, the
## response's cache headers, the echoed context header, redirect-after-POST
## for no-JS forms, and that handlers run concurrently on the event loop.

import std/[unittest, json, strutils, asyncdispatch, times, monotimes]
import isonim/server/[rpc, pragma, context]

type Who = object
  subject: string
  csrf: string

proc echoArgs(a: int; s: string): Future[string] {.server.} =
  return $a & ":" & s

proc whoAmI(ctx: RequestContext): Future[Who] {.server(auth = aSession).} =
  return Who(subject: ctx.session.subject, csrf: $ctx.csrf)

proc staffOnly(): Future[bool] {.server(auth = aStaff).} =
  return true

proc adminOnly(): Future[bool] {.server(auth = aAdmin).} =
  return true

proc signed(): Future[bool] {.server(auth = aSignature, csrf = csrfExempt("billing-webhook")).} =
  return true

proc anon(x: int): Future[int] {.server(auth = aPublic, csrf = csrfAnon).} =
  return x * 2

proc failing(): Future[int] {.server.} =
  raise newException(IOError, "disk on fire")

proc slow(ms: int): Future[string] {.server.} =
  await sleepAsync(ms)
  return "slow done"

proc fast(): Future[string] {.server.} =
  return "fast done"

proc subscribe(email: string): Future[bool] {.action(target = "/thanks").} =
  return true

proc vote(id: int): Future[int] {.action.} =
  return id

proc setCookieFn(ctx: RequestContext): Future[bool] {.server.} =
  ctx.response.setCookie("seen", "1")
  ctx.response.status = 201
  return true

const host = "forum.test"
const origin = "https://forum.test"

proc request(path: string; body = ""; httpMethod = "POST";
             headers: seq[(string, string)] = @[];
             contentType = "application/json"; browser = true;
             token = "sess-tok"; cookies = "sid=alice"): RequestContext =
  ## A request as a browser's generated client sends it, unless the
  ## arguments say otherwise.
  var h = @[("Host", host)]
  if contentType.len > 0: h.add(("Content-Type", contentType))
  if browser:
    h.add(("Origin", origin))
    h.add(("Sec-Fetch-Site", "same-origin"))
    h.add((contextHeaderName, "inc-1:3"))
  if token.len > 0: h.add((csrfHeaderName, token))
  if cookies.len > 0: h.add(("Cookie", cookies))
  for x in headers:
    var replaced = false
    for i in 0 ..< h.len:
      if cmpIgnoreCase(h[i][0], x[0]) == 0:
        h[i] = x
        replaced = true
    if not replaced: h.add x
  var kept: seq[(string, string)]
  for x in h:
    if x[1].len > 0: kept.add x
  newRequestContext(newSsrRequest(httpMethod, path, path, "", kept,
                                  "127.0.0.1", body))

proc run(ctx: RequestContext): RequestContext =
  waitFor dispatchRpc(ctx)
  ctx

proc errorOf(ctx: RequestContext): string =
  parseJson(ctx.responseBody)["error"].getStr

proc installHooks() =
  serverHooks = ServerHooks(
    resolveSession: proc(req: SsrRequest): Future[Session] {.async.} =
      case req.cookie("sid")
      of "alice": return Session(subject: "alice", csrfToken: "sess-tok")
      of "sam": return Session(subject: "sam", staff: true, csrfToken: "sess-tok")
      of "ada": return Session(subject: "ada", admin: true, csrfToken: "sess-tok")
      else: return nil,
    verifySignature: proc(ctx: RequestContext; route: string): Future[bool] {.async.} =
      return ctx.request.header("X-Signature") == "good:" & route)

const echoUrl = "/api/test_rpc_dispatch/echoArgs"

suite "dispatchRpc — routing and bodies":
  setup: installHooks()

  test "a JSON call answers 200 with the result and no-store caching":
    let c = run request(echoUrl, """{"a": 7, "s": "x"}""")
    check c.response.status == 200
    check c.response.contentType == "application/json"
    check parseJson(c.responseBody).getStr == "7:x"
    check c.response.header("Cache-Control") == "private, no-cache, no-store, must-revalidate"
    check c.response.header("Pragma") == "no-cache"
    check c.response.header(contextHeaderName) == "inc-1:3"   # echoed
    check c.csrf == cvVerified

  test "an unknown endpoint, or a path outside the prefix, is 404":
    check run(request("/api/test_rpc_dispatch/nope", "{}")).response.status == 404
    check run(request("/api/echoArgs", "{}")).response.status == 404
    check run(request("/other/test_rpc_dispatch/echoArgs", "{}")).response.status == 404

  test "only POST is allowed (405 with Allow)":
    let c = run request(echoUrl, httpMethod = "GET", contentType = "")
    check c.response.status == 405
    check c.response.header("Allow") == "POST"
    check c.response.header("Cache-Control") == errorCacheControl

  test "malformed bodies and arguments are 400":
    check run(request(echoUrl, "{not json")).response.status == 400
    check run(request(echoUrl, "[1, 2]")).response.status == 400
    check run(request(echoUrl, """{"a": 1}""")).response.status == 400
    check run(request(echoUrl, """{"a": "x", "s": "y"}""")).response.status == 400
    let unknown = run request(echoUrl, """{"a": 1, "s": "y", "z": 0}""")
    check unknown.response.status == 400
    check "unknown argument 'z'" in unknown.responseBody
    check run(request(echoUrl, "a=1", contentType = "text/plain")).response.status == 400

  test "a handler that raises is 500, and the error is kept for the log":
    let c = run request("/api/test_rpc_dispatch/failing", "{}")
    check c.response.status == 500
    check c.errorOf == "internal"
    check "disk on fire" notin c.responseBody   # not leaked to the client
    check c.failure != nil and c.failure.msg.startsWith("disk on fire")
    check c.response.header("Cache-Control") == errorCacheControl

  test "handlers may shape the response":
    let c = run request("/api/test_rpc_dispatch/setCookieFn", "{}")
    check c.response.status == 201
    check c.response.header("Set-Cookie") == "seen=1"

suite "dispatchRpc — authentication":
  setup: installHooks()

  test "aSession: no session is 401, a session reaches the handler":
    let none = run request("/api/test_rpc_dispatch/whoAmI", "{}", cookies = "")
    check none.response.status == 401
    check none.errorOf == "unauthenticated"
    let c = run request("/api/test_rpc_dispatch/whoAmI", "{}")
    check c.response.status == 200
    check parseJson(c.responseBody) == %*{"subject": "alice", "csrf": "verified"}

  test "aStaff and aAdmin: a session without the role is 403":
    check run(request("/api/test_rpc_dispatch/staffOnly", "{}")).response.status == 403
    check run(request("/api/test_rpc_dispatch/staffOnly", "{}", cookies = "sid=sam")).response.status == 200
    check run(request("/api/test_rpc_dispatch/staffOnly", "{}", cookies = "sid=ada")).response.status == 200
    check run(request("/api/test_rpc_dispatch/adminOnly", "{}", cookies = "sid=sam")).response.status == 403
    check run(request("/api/test_rpc_dispatch/adminOnly", "{}", cookies = "sid=ada")).response.status == 200

  test "aSignature: the application's verifier decides":
    let url = "/api/test_rpc_dispatch/signed"
    check run(request(url, "{}", browser = false, token = "")).response.status == 401
    let ok = run request(url, "{}", browser = false, token = "",
      headers = @[("X-Signature", "good:test_rpc_dispatch/signed")])
    check ok.response.status == 200
    check ok.csrf == cvExempt
    serverHooks.verifySignature = nil   # no verifier: always refused
    check run(request(url, "{}", browser = false, token = "",
      headers = @[("X-Signature", "good:test_rpc_dispatch/signed")])).response.status == 401

suite "dispatchRpc — CSRF (isonim-auth.md §2.5)":
  setup: installHooks()

  proc csrfOf(c: RequestContext): string =
    check c.response.status == 403
    check c.errorOf == "csrf"
    parseJson(c.responseBody)["detail"].getStr

  test "csrfSession: Origin, Sec-Fetch-Site and the token are all required":
    check csrfOf(run request(echoUrl, """{"a":1,"s":""}""",
      headers = @[("Origin", "")])) == "bad-origin"
    check csrfOf(run request(echoUrl, """{"a":1,"s":""}""",
      headers = @[("Origin", "https://evil.test")])) == "bad-origin"
    check csrfOf(run request(echoUrl, """{"a":1,"s":""}""",
      headers = @[("Sec-Fetch-Site", "cross-site")])) == "bad-fetch-site"
    check csrfOf(run request(echoUrl, """{"a":1,"s":""}""",
      headers = @[("Sec-Fetch-Site", "")])) == "bad-fetch-site"
    check csrfOf(run request(echoUrl, """{"a":1,"s":""}""", token = "")) == "missing-token"
    check csrfOf(run request(echoUrl, """{"a":1,"s":""}""", token = "sess-tox")) == "bad-token"
    check csrfOf(run request(echoUrl, """{"a":1,"s":""}""", cookies = "")) == "no-session"
    # Negative control: all present and right.
    check run(request(echoUrl, """{"a":1,"s":""}""")).response.status == 200

  test "csrfAnon: the token must equal the anonymous CSRF cookie":
    let url = "/api/test_rpc_dispatch/anon"
    let c = anonCsrfCookieName & "=anon-tok"
    check run(request(url, """{"x":2}""", cookies = c, token = "anon-tok")).response.status == 200
    check csrfOf(run request(url, """{"x":2}""", cookies = c, token = "other")) == "bad-token"
    check csrfOf(run request(url, """{"x":2}""", cookies = "", token = "anon-tok")) == "missing-token"

  test "the _csrf form field is accepted in place of the header":
    let c = run request(echoUrl, "a=3&s=f&_csrf=sess-tok", token = "",
      contentType = "application/x-www-form-urlencoded")
    check c.response.status == 200
    check parseJson(c.responseBody).getStr == "3:f"

  test "allowedOrigins replaces the Host comparison":
    serverHooks.allowedOrigins = @["https://other.test"]
    check csrfOf(run request(echoUrl, """{"a":1,"s":""}""")) == "bad-origin"
    check run(request(echoUrl, """{"a":1,"s":""}""",
      headers = @[("Origin", "https://other.test")])).response.status == 200

suite "dispatchRpc — client context (URL-Schema.md §5.4)":
  setup: installHooks()

  test "a stale incarnation is 409 context_stale":
    serverHooks.currentIncarnation = proc(): string = "inc-2"
    let c = run request(echoUrl, """{"a":1,"s":""}""")
    check c.response.status == 409
    check c.errorOf == "context_stale"
    check c.response.header(contextHeaderName) == "inc-1:3"
    serverHooks.currentIncarnation = proc(): string = "inc-1"
    check run(request(echoUrl, """{"a":1,"s":""}""")).response.status == 200
    let malformed = run request(echoUrl, """{"a":1,"s":""}""",
      headers = @[(contextHeaderName, "garbage")])
    check malformed.response.status == 409

suite "dispatchRpc — redirect-after-POST":
  setup: installHooks()

  test "a no-JS form submission of an action is 303 to its target":
    let c = run request("/api/test_rpc_dispatch/subscribe", "email=a%40b&_csrf=sess-tok",
      browser = false, token = "",
      contentType = "application/x-www-form-urlencoded",
      headers = @[("Origin", origin), ("Sec-Fetch-Site", "same-origin")])
    check c.response.status == 303
    check c.response.location == "/thanks"
    check c.responseBody == ""

  test "without a target: the same-origin Referer, else /":
    proc post(referer: string): RequestContext =
      run request("/api/test_rpc_dispatch/vote", "id=4&_csrf=sess-tok",
        browser = false, token = "",
        contentType = "application/x-www-form-urlencoded",
        headers = @[("Origin", origin), ("Sec-Fetch-Site", "same-origin"),
                    ("Referer", referer)])
    check post("https://forum.test/t/topic/4?page=2#post-3").response.location == "/t/topic/4?page=2"
    check post("https://evil.test/x").response.location == "/"
    check post("").response.location == "/"

  test "the same action called by the generated client answers JSON":
    let c = run request("/api/test_rpc_dispatch/subscribe", """{"email":"a@b"}""")
    check c.response.status == 200
    check c.responseBody == "true"

  test "a server function that is not an action never redirects":
    let c = run request(echoUrl, "a=5&s=q&_csrf=sess-tok",
      browser = false, token = "",
      contentType = "application/x-www-form-urlencoded",
      headers = @[("Origin", origin), ("Sec-Fetch-Site", "same-origin")])
    check c.response.status == 200

suite "dispatchRpc — asynchronous handlers":
  setup: installHooks()

  test "a slow server function does not hold up a fast one":
    let slowCtx = request("/api/test_rpc_dispatch/slow", """{"ms": 200}""")
    let fastCtx = request("/api/test_rpc_dispatch/fast", "{}")
    let start = getMonoTime()
    let slowF = dispatchRpc(slowCtx)
    check not slowF.finished          # suspended in sleepAsync
    let fastF = dispatchRpc(fastCtx)
    var fastDoneAt, slowDoneAt: Duration
    while not (slowF.finished and fastF.finished):
      poll(5)
      if fastF.finished and fastDoneAt == Duration(): fastDoneAt = getMonoTime() - start
      if slowF.finished and slowDoneAt == Duration(): slowDoneAt = getMonoTime() - start
    check fastCtx.responseBody == "\"fast done\""
    check slowCtx.responseBody == "\"slow done\""
    check fastDoneAt < initDuration(milliseconds = 100)
    check slowDoneAt >= initDuration(milliseconds = 200)
