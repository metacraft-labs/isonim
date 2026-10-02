## test_route_manifest_generates_dispatch_clients_forms_and_tests (IFP-M2).
##
## The manifest of tests/nginx/fixture_manifest.nim declares a page, data
## routes, mutations, a progressive `action` with a no-JS form, the `rpc`
## mount of the fixture's server functions, and between them every CSRF,
## cache and authentication policy.  This test checks that each entry
## produces its server dispatch, its browser client, its form and its
## policy tests, and runs the generated policy tests against real nginx
## with the real ngx-isonim module serving that manifest
## (build/nginx-fixture, `just build-nginx-fixture`).
##
## Vacuity guard: every entry has its dispatch (a request to it is
## answered by its handler), client (compiled for the JS target), form
## (progressive entries) and policy tests; the generated policy tests pass
## against nginx; the policy runner fails on a violated expectation; a
## no-JS form submission ends in a 303 to the entry's target.
##
## Authentication before canonicalization (URL-Schema.md §5.2 item 4): the
## staff-only `rTopic` has a `canonical` policy, and the fixture's hook
## redirects the generated sample path (not canonical) with a 301.  Its
## generated `pcAuthBeforeCanonical` tests (no credentials: 401; a user
## session: 403; no `Location` either way) pass, and the same request with
## staff credentials is the hook's 301, so the check is not vacuous.  The
## falsifying mutation `canonical-first` of tests/nginx/run_mutants.sh
## (the hook before authentication) runs this test against that module
## (`ISONIM_NGINX_MODULE`) and it fails at those tests.
##
## Negative control: a state-changing entry declared with csrfNone (or with
## no CSRF policy, or an unknown exemption) fails to compile; the same
## entries with valid policies compile.
##
## No mocks: the nginx, the module and the HTTP requests are real.
##
## Build with -d:isonimRpcPrefix=/api/v1/rpc (the fixture's mount); the
## `test-nginx` recipe does.

import std/[unittest, os, osproc, strutils, httpclient, json, net, times,
            monotimes, sequtils]
import isonim/routing/[manifest, route_tests]
import nginx/fixture_manifest

const
  repoRoot = currentSourcePath().parentDir.parentDir
  fixtureDir = repoRoot / "build/nginx-fixture"

# --------------------------------------------------------------------------
# The fixture nginx
# --------------------------------------------------------------------------

type Fixture = object
  prefix, pidFile, errorLog: string
  port: int

proc readNginxBin(): string =
  for line in readFile(fixtureDir / "env.sh").splitLines:
    if line.startsWith("NGINX_BIN="):
      return line["NGINX_BIN=".len .. ^1]

proc freePort(): int =
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  result = int(s.getLocalAddr()[1])
  s.close()

proc startFixture(): Fixture =
  # ISONIM_NGINX_MODULE: another module build (run_mutants.sh's mutants).
  let module = getEnv("ISONIM_NGINX_MODULE", fixtureDir / "ngx_http_isonim_module.so")
  if not fileExists(module) or not fileExists(fixtureDir / "env.sh"):
    raise newException(IOError, "the nginx fixture is not built: run " &
      "`just build-nginx-fixture` (needs the ngx-isonim sibling checkout)")
  result.prefix = getTempDir() / ("isonim-route-manifest-" & $getCurrentProcessId())
  removeDir(result.prefix)
  for d in ["client_body", "proxy", "fastcgi", "uwsgi", "scgi"]:
    createDir(result.prefix / d)
  result.port = freePort()
  result.pidFile = result.prefix / "nginx.pid"
  result.errorLog = result.prefix / "error.log"
  let conf = result.prefix / "nginx.conf"
  let (text, code) = execCmdEx("bash " & quoteShell(repoRoot / "tests/nginx/fixture_conf.sh") &
    " " & quoteShell(result.prefix) & " " & $result.port & " " & quoteShell(module) &
    " " & quoteShell(fixtureDir / "www"))
  doAssert code == 0, text
  writeFile(conf, text)
  let start = execShellCmd(quoteShell(readNginxBin()) & " -c " & quoteShell(conf) &
    " -p " & quoteShell(result.prefix) & " -e " & quoteShell(result.errorLog) &
    " < /dev/null > " & quoteShell(result.prefix / "start.log") & " 2>&1")
  doAssert start == 0, readFile(result.prefix / "start.log")
  let deadline = getMonoTime() + initDuration(seconds = 10)
  while true:
    let s = newSocket()
    try:
      s.connect("127.0.0.1", Port(result.port), timeout = 200)
      s.close()
      break
    except CatchableError:
      s.close()
      doAssert getMonoTime() < deadline, "nginx did not open its port"

proc stop(f: Fixture) =
  if fileExists(f.pidFile):
    discard execCmd("kill -TERM " & readFile(f.pidFile).strip)

proc baseUrl(f: Fixture): string = "http://127.0.0.1:" & $f.port

# --------------------------------------------------------------------------
# The policy environment: the fixture's sessions and signatures
# (tests/nginx/fixture_app.nim)
# --------------------------------------------------------------------------

proc sid(c: Credentials): string =
  case c
  of crUser: "user"
  of crStaff: "staff"
  of crAdmin: "admin"
  else: ""

proc policyEnv(f: Fixture): PolicyEnv =
  PolicyEnv(
    baseUrl: f.baseUrl,
    cookies: proc(c: Credentials): string =
      (if sid(c).len > 0: "sid=" & sid(c) else: ""),
    sessionCsrfToken: proc(c: Credentials): string =
      (if sid(c).len > 0: "csrf-" & sid(c) else: ""),
    signatureHeaders: proc(t: RoutePolicyTest): seq[(string, string)] =
      @[("X-Signature", "valid-" & t.route.split(':')[0])],
    contextHeader: "inc-1:0")

proc nimCompile(file: string; js = false): tuple[ok: bool, output: string] =
  ## Compiles a fixture (front end and code generation; nothing is linked
  ## or run).
  let cmd =
    if js: "nim js --hints:off -d:isonimRpcPrefix=/api/v1/rpc -o:" &
           quoteShell(getTempDir() / "isonim-manifest-probe.js")
    else: "nim c --compileOnly --hints:off"
  let (output, code) = execCmdEx(cmd & " --path:" & quoteShell(repoRoot / "src") &
    " " & quoteShell(repoRoot / "tests/fixtures" / file))
  (code == 0, output)

# --------------------------------------------------------------------------

suite "test_route_manifest_generates_dispatch_clients_forms_and_tests":
  let specs = routeSpecs(FixtureRoute)
  let tests = policyTests(FixtureRoute)

  test "the manifest declares every CSRF, cache and auth policy":
    var csrfKinds: set[CsrfKind]
    var caches: set[CachePolicy]
    var auths: set[AuthPolicy]
    for s in specs:
      if s.kind != rkRpc:
        csrfKinds.incl s.csrf.kind
        caches.incl s.cache
        auths.incl s.auth
    check csrfKinds == {ckNone, ckSession, ckAnon, ckExempt}
    check caches == {low(CachePolicy) .. high(CachePolicy)}
    check auths == {low(AuthPolicy) .. high(AuthPolicy)}
    check specs.anyIt(it.kind == rkPage) and specs.anyIt(it.kind == rkRpc)
    check specs.anyIt(it.progressive)
    check spec(rSubscribe).target == "/thanks"
    check spec(rDelayed).contextScope == csAccount
    check spec(rDelayedNav).contextScope == csNavigation   # GET default
    check spec(rCreateItem).contextScope == csAccount      # mutation default
    check spec(rWebhook).csrf == csrfExempt("billing-webhook")

  test "each page and data entry has its dispatch handler and its path":
    # The handler fields are typed by the entry's request and response.
    check compiles(FixtureRouteHandlers().rHome)
    var h: FixtureRouteHandlers
    check typeof(h.rItem) is proc(ctx: RequestContext; req: ItemRequest): Future[ItemResponse]
    check typeof(h.rHome) is proc(ctx: RequestContext; req: HomeRequest): Future[Page[HomeResponse]]
    check not compiles(h.rRpc)        # the rpc mount dispatches server functions
    check rItemPath(ItemRequest(id: 42)) == "/api/v1/items/42"
    check rAssetPath(AssetRequest(name: "a b/c")) == "/api/v1/assets/a%20b%2Fc"
    check rHomePath(HomeRequest()) == "/"

  test "each entry has its browser client (compiled for the JS target)":
    let r = nimCompile("manifest_js_probe.nim", js = true)
    check r.ok
    if not r.ok: echo r.output

  test "each progressive entry has its form":
    let ctx = newRequestContext(newSsrRequest("GET", "/", "/", "", @[], "127.0.0.1"))
    let html = rSubscribeForm(ctx, SubscribeRequest(), "<button>Go</button>")
    let token = ctx.response.header("Set-Cookie").split(';')[0].split('=', 1)[1]
    check html == "<form action=\"/subscribe\" method=\"post\">" &
      "<input type=\"hidden\" name=\"_csrf\" value=\"" & token & "\">" &
      "<button>Go</button></form>"
    check not compiles(rCreateItemForm(ctx, CreateItemRequest(), ""))

  test "each entry has its policy tests":
    proc checksOf(route: string): set[PolicyCheck] =
      for t in tests:
        if t.route == route: result.incl t.check
    for s in specs:
      case s.kind
      of rkRpc, rkAny: discard
      of rkPage, rkApi:
        let c = checksOf(s.name)
        check pcCache in c
        check pcMethod in c
        if isStateChanging(s.httpMethod) and s.csrf.kind in {ckSession, ckAnon}:
          check {pcCsrf, pcOrigin} <= c
        if s.auth in {aSession, aStaff, aAdmin, aSignature}:
          check pcAuth in c
        if s.auth in {aStaff, aAdmin}:
          check pcRole in c
        if s.progressive:
          check pcNoJsForm in c
        if s.canonical != ccNone and s.auth in {aSession, aStaff, aAdmin, aSignature}:
          check pcAuthBeforeCanonical in c
    check spec(rTopic).canonical == ccTopicSlug
    check tests.countIt(it.route == "rTopic" and it.check == pcAuthBeforeCanonical) == 2
    # The rpc entry expands to one POST entry per server function.
    for fn in ["sum", "describe", "bodySize", "slowOp", "slowPending", "fastOp",
               "subscribeNews"]:
      let c = checksOf("rRpc:fixture_rpc/" & fn)
      check {pcMethod, pcCsrf, pcOrigin, pcCache} <= c
    check pcNoJsForm in checksOf("rRpc:fixture_rpc/subscribeNews")
    check tests.len >= 60

  test "negative control: a state-changing entry with csrfNone fails to compile":
    let none = nimCompile("manifest_csrf_none.nim")
    check not none.ok
    check "csrfNone is only valid for safe methods" in none.output
    let omitted = nimCompile("manifest_csrf_omitted.nim")
    check not omitted.ok
    check "must declare its CSRF policy" in omitted.output
    let exempt = nimCompile("manifest_csrf_exempt_unknown.nim")
    check not exempt.ok
    check "names no isonim-auth.md" in exempt.output
    let ok = nimCompile("manifest_csrf_ok.nim")
    check ok.ok
    if not ok.ok: echo ok.output

  let fixture = startFixture()
  let env = policyEnv(fixture)

  test "the generated policy tests pass against real nginx":
    var failures: seq[string]
    var counts: array[PolicyCheck, int]
    for t in tests:
      let failure = env.runPolicyTest(t)
      if failure.len > 0: failures.add failure
      inc counts[t.check]
    for f in failures: echo "    ", f
    check failures.len == 0
    echo "    ", tests.len, " policy tests: ", counts

  test "the policy runner fails on a violated expectation":
    # Vacuity guard of the runner: the same requests, wrong expectations.
    for t in tests:
      if t.route == "rItem" and t.check == pcCache:
        var wrong = t
        wrong.expectCacheControl = cacheControl(cpImmutable)
        check env.runPolicyTest(wrong).len > 0
      if t.route == "rCreateItem" and t.check == pcCsrf:
        var wrong = t
        wrong.sendCsrfToken = true        # now the request is valid: 200
        check env.runPolicyTest(wrong).len > 0
      if t.route == "rWho" and t.check == pcAuth:
        var wrong = t
        wrong.credentials = crUser        # now authenticated: 200
        check env.runPolicyTest(wrong).len > 0
      if t.route == "rTopic" and t.check == pcAuthBeforeCanonical and
          t.credentials == crNone:
        # Staff may see the topic: the hook answers the sample path with
        # its 301, which the check reports.
        var wrong = t
        wrong.credentials = crStaff
        let r = env.send(wrong)
        check r.status == 301
        check r.headers["Location"].toString == "/t/topic-1/1"
        # Even when its status is accepted, the Location is reported.
        var w = wrong
        w.expectStatus = @[301]
        check "Location" in env.runPolicyTest(w)

  test "authentication before canonicalization: the fixture's hook answers":
    # What the generated pcAuthBeforeCanonical tests rely on: with the
    # credentials the entry needs, the hook redirects the non-canonical
    # path, serves the canonical one and refuses a target the caller may
    # not see, revealing nothing.
    let client = newHttpClient(maxRedirects = 0)
    defer: client.close()
    let staff = newHttpHeaders({"Cookie": "sid=staff"})
    let wrongSlug = client.request(fixture.baseUrl & "/t/old-slug/5",
                                   httpMethod = HttpGet, headers = staff)
    check wrongSlug.code == Http301
    check wrongSlug.headers["Location"].toString == "/t/topic-5/5"
    check wrongSlug.headers["Cache-Control"].toString == cacheControl(cpPrivateRevalidate)
    let canonical = client.request(fixture.baseUrl & "/t/topic-5/5",
                                   httpMethod = HttpGet, headers = staff)
    check canonical.code == Http200
    let hidden = client.request(fixture.baseUrl & "/t/old-slug/13",
                                httpMethod = HttpGet, headers = staff)
    check hidden.code == Http404
    check not hidden.headers.hasKey("Location")
    # Without credentials the same wrong-slug URL is a 401: no redirect.
    let anon = client.request(fixture.baseUrl & "/t/old-slug/5", httpMethod = HttpGet)
    check anon.code == Http401
    check not anon.headers.hasKey("Location")

  test "a no-JS form submission ends in a 303 to the entry's target":
    # As a browser without JavaScript: load the page (anonymous CSRF
    # cookie, form with its _csrf field), submit the form.
    let client = newHttpClient(maxRedirects = 0)
    defer: client.close()
    let page = client.get(fixture.baseUrl & "/")
    check page.code == Http200
    let cookie = page.headers["Set-Cookie"].toString.split(';')[0]
    let body = page.body
    let at = body.find("name=\"_csrf\" value=\"")
    check at > 0
    let start = at + "name=\"_csrf\" value=\"".len
    let token = body[start ..< body.find('"', start)]
    check cookie == anonCsrfCookieName & "=" & token
    check "<form action=\"/subscribe\" method=\"post\">" in body
    var headers = newHttpHeaders({
      "Content-Type": "application/x-www-form-urlencoded",
      "Origin": fixture.baseUrl, "Sec-Fetch-Site": "same-origin",
      "Cookie": cookie})
    let r = client.request(fixture.baseUrl & "/subscribe", httpMethod = HttpPost,
      body = "email=reader%40example.test&_csrf=" & token, headers = headers)
    check r.code == Http303
    check r.headers["Location"].toString == "/thanks"
    check r.body == ""
    # The same entry called by the generated client (context header, JSON)
    # gets the JSON response instead.
    headers["Content-Type"] = "application/json"
    headers[csrfHeaderName] = token
    headers[contextHeaderName] = "inc-1:0"
    let j = client.request(fixture.baseUrl & "/subscribe", httpMethod = HttpPost,
      body = """{"email": "reader@example.test"}""", headers = headers)
    check j.code == Http200
    check parseJson(j.body) == %*{"subscribed": true}

  fixture.stop()
