## test_manifest_json_variant_cache_override_and_handler_404 (IFP-M26 of
## isonim-specs milestones/2026-10-02-isonim-forum-prerequisites).
##
## The route manifest of negotiation_manifest.nim, served by real nginx with
## the real ngx-isonim module (the nginx fixture, tests/nginx/README.md;
## `just build-nginx-fixture`), over HTTP:
##
## * a page with a JSON variant answers `Page.data` as JSON for `.json` on
##   its last path parameter and for `Accept: application/json`, with
##   `Vary` naming `Accept`;
## * its canonicalization hook redirects one target with `cpPrivateNoStore`
##   (a per-response policy) and another with the entry's default, and the
##   two redirects carry exactly their policies' headers;
## * its handler raises not-found for a third target: 404, `Cache-Control:
##   private, no-store` and the pipeline's error body, exactly the hook's
##   `coNotFound` and keeping nothing the handler set;
## * an `any` entry answers with its declared default's headers, takes a
##   stricter declared override and refuses a weaker one, exactly as a page
##   does;
## * the manifest's generated policy tests (JSON variants and the declared
##   per-response policy included) pass against the server.
##
## Vacuity guard: the HTML request of the same page answers its HTML with
## the embedded data (so the JSON answers are the variant's, not the
## page's default), and the default-policy redirect carries `private,
## no-cache, must-revalidate` with the policy's `Vary` (so the no-store
## redirect's headers are the override's).
##
## Negative control: the hook of a `cpPrivateNoStore` entry that asks for
## `cpPrivateRevalidate` is refused; the response stays no-store, the hook
## sees `false`, and the server's `onCachePolicyRefused` hook records the
## refusal (read back over HTTP from `/neg/refusals`).  Likewise a handler
## that asks to relax a response the hook made no-store, and one asking for
## a policy its entry does not declare.
##
## Falsifying mutation: applying the entry's headers after the override
## (the dispatch before IFP-M26) leaves the no-store redirect with
## `private, no-cache, must-revalidate` and fails "the two redirects carry
## their policies' headers"; tests/routing/run_negotiation_mutants.sh
## builds that module (`override-overwritten`), four more on the refusal
## logic (`weaker-accepted`, `strictness-vs-entry`, `undeclared-accepted`,
## `refusal-unreported`), one against the vacuity guard (`json-always`)
## and one dropping the `any` dispatch's `beginCachePolicy`
## (`any-without-entry-policy`: every `any` response no-store and every
## override refused),
## and runs this test against each (`ISONIM_NGINX_MODULE`), expecting it to
## fail at the named test.
##
## No mocks: the nginx, the module, the dispatch and the HTTP requests are
## real.

import std/[unittest, httpclient, json, strutils, sequtils, algorithm, os,
            osproc]
import isonim/routing/[manifest, route_tests]
import ../nginx/fixture_server
import negotiation_manifest

const
  noStoreHeaders = cacheHeaders(cpPrivateNoStore)
  revalidateHeaders = cacheHeaders(cpPrivateRevalidate)
  # Headers the transport adds, which say nothing about the dispatch.
  transportHeaders = ["date", "server", "content-length", "connection",
                      "keep-alive", "transfer-encoding"]

type Answer = object
  status: int
  headers: seq[(string, string)]   ## lower-cased names, sorted, transport
                                   ## headers left out
  body: string

proc header(a: Answer; name: string): string =
  for (k, v) in a.headers:
    if k == name.toLowerAscii: return v
  ""

proc has(a: Answer; name: string): bool =
  a.headers.anyIt(it[0] == name.toLowerAscii)

proc fetch(f: Fixture; path: string; accept = ""; httpMethod = HttpGet;
           cookie = ""): Answer =
  let client = newHttpClient(maxRedirects = 0, timeout = 30_000)
  defer: client.close()
  var h = newHttpHeaders()
  if accept.len > 0: h["Accept"] = accept
  if cookie.len > 0: h["Cookie"] = cookie
  let r = client.request(f.baseUrl & path, httpMethod = httpMethod, headers = h)
  result.status = r.code.int
  result.body = r.body
  for k, v in r.headers.pairs:
    if k.toLowerAscii notin transportHeaders:
      result.headers.add((k.toLowerAscii, v))
  result.headers.sort()

proc refusalsOf(f: Fixture): seq[string] =
  let r = f.fetch("/neg/refusals")
  doAssert r.status == 200, r.body
  for x in parseJson(r.body)["refusals"]:
    result.add x.getStr

proc exactlyPolicy(a: Answer; headers: openArray[(string, string)]): bool =
  ## The answer carries each of the policy's headers with its value and no
  ## cache header the policy does not have.
  for name in ["cache-control", "pragma", "expires", "vary"]:
    var want = ""
    for (k, v) in headers:
      if k.toLowerAscii == name: want = v
    if a.header(name) != want:
      echo "    ", name, ": '", a.header(name), "', expected '", want, "'"
      return false
  true

proc nimCompile(file: string): tuple[ok: bool, output: string] =
  ## Compiles a manifest fixture of tests/fixtures (front end and code
  ## generation; nothing is linked or run).
  let (output, code) = execCmdEx("nim c --compileOnly --hints:off --path:" &
    quoteShell(repoRoot / "src") & " " & quoteShell(repoRoot / "tests/fixtures" / file))
  (code == 0, output)

proc pageData(html: string): JsonNode =
  let open = "<script type=\"application/json\" id=\"" & pageDataScriptId & "\">"
  let at = html.find(open)
  doAssert at >= 0, "no embedded page data in " & html
  let start = at + open.len
  parseJson(html[start ..< html.find("</script>", start)])

suite "test_manifest_json_variant_cache_override_and_handler_404":
  test "a weaker override, or json where it cannot apply, does not compile":
    let weaker = nimCompile("manifest_override_weaker.nim")
    check not weaker.ok
    check "weaker than the entry's cache policy" in weaker.output
    let notPage = nimCompile("manifest_json_not_page.nim")
    check not notPage.ok
    check "`json` applies to page entries only" in notPage.output
    let noParam = nimCompile("manifest_json_no_param.nim")
    check not noParam.ok
    check "ends in a :param segment" in noParam.output
    let ok = nimCompile("manifest_negotiation_ok.nim")
    check ok.ok
    if not ok.ok: echo ok.output

  let fixture = startFixture("isonim-manifest-negotiation")

  test "the manifest declares the JSON variants and the override":
    check spec(nArticle).json and spec(nPlain).json
    check spec(nArticle).cacheOverrides == @[cpPrivateNoStore]
    check spec(nLocked).cache == cpPrivateNoStore
    check not spec(nLocked).json and spec(nLocked).cacheOverrides.len == 0

  test "vacuity guard: the HTML request answers the page's HTML with its data":
    let html = fixture.fetch("/neg/a/article-2/2")
    check html.status == 200
    check html.header("content-type").startsWith("text/html")
    check "<h1>article 2</h1>" in html.body
    check pageData(html.body) == %*{"id": 2, "title": "article 2"}
    # The same URL also answers JSON, so even the HTML answer varies on Accept.
    check html.header("vary") == revalidateHeaders[1][1] & ", Accept"
    check html.header("cache-control") == cacheControl(cpPrivateRevalidate)
    # A browser's navigation Accept and */* are HTML (a tie is HTML).
    for accept in ["text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                   "*/*", "application/json;q=0.5, text/html"]:
      let a = fixture.fetch("/neg/a/article-2/2", accept = accept)
      check a.header("content-type").startsWith("text/html")

  test "the page as .json and with Accept: application/json answers Page.data":
    for (path, accept) in [("/neg/a/article-2/2.json", ""),
                           ("/neg/a/article-2/2", "application/json"),
                           ("/neg/a/article-2/2", "text/html;q=0.5, application/json")]:
      let a = fixture.fetch(path, accept)
      check a.status == 200
      check a.header("content-type") == "application/json"
      check parseJson(a.body) == %*{"id": 2, "title": "article 2"}
      check "Accept" in a.header("vary").split(", ")
      check a.header("vary") == revalidateHeaders[1][1] & ", Accept"
      check a.exactlyPolicy(@[revalidateHeaders[0],
        ("Vary", revalidateHeaders[1][1] & ", Accept")])
    # A page without a hook, likewise; HEAD is answered as GET.
    let plain = fixture.fetch("/neg/p/4.json")
    check plain.status == 200 and parseJson(plain.body) == %*{"id": 4}
    let head = fixture.fetch("/neg/p/4.json", httpMethod = HttpHead)
    check head.status == 200
    check head.header("content-type") == "application/json"
    # A page without `json` keeps .json in its parameter: not an int, 400.
    check fixture.fetch("/neg/locked/4.json").status == 400

  test "the two redirects carry their policies' headers":
    # The private target: the hook's cpPrivateNoStore, exactly.
    let priv = fixture.fetch("/neg/a/old-slug/5")
    check priv.status == 301
    check priv.header("location") == "/neg/a/article-5/5"
    check priv.exactlyPolicy(noStoreHeaders)
    # Vacuity guard: the public target gets the entry's default, exactly.
    let pub = fixture.fetch("/neg/a/old-slug/2")
    check pub.status == 301
    check pub.header("location") == "/neg/a/article-2/2"
    check pub.header("cache-control") == "private, no-cache, must-revalidate"
    check pub.exactlyPolicy(revalidateHeaders)
    # The JSON variant keeps its suffix on the redirect (the hook's
    # keepPageVariant); the policy is the same.
    let privJson = fixture.fetch("/neg/a/old-slug/5.json")
    check privJson.status == 301
    check privJson.header("location") == "/neg/a/article-5/5.json"
    check privJson.exactlyPolicy(noStoreHeaders)
    let pubJson = fixture.fetch("/neg/a/old-slug/2", accept = "application/json")
    check pubJson.status == 301
    check pubJson.header("location") == "/neg/a/article-2/2"   # no suffix asked
    check pubJson.exactlyPolicy(revalidateHeaders)
    # The private target's page itself is no-store too (the hook's policy
    # reaches the handler's response), with Vary: Accept for the variant.
    let page = fixture.fetch("/neg/a/article-5/5.json")
    check page.status == 200
    check parseJson(page.body) == %*{"id": 5, "title": "article 5"}
    check page.exactlyPolicy(@[noStoreHeaders[0], noStoreHeaders[1],
                               noStoreHeaders[2], ("Vary", "Accept")])
    # An override lasts one response: the next public one is the default.
    check fixture.fetch("/neg/a/old-slug/2").exactlyPolicy(revalidateHeaders)

  test "the handler's not-found is the pipeline's 404, exactly as coNotFound":
    let raised = fixture.fetch("/neg/a/article-3/3")
    check raised.status == 404
    check raised.header("cache-control") == errorCacheControl
    check raised.header("content-type") == "application/json"
    check parseJson(raised.body) == %*{"error": "not_found"}
    check not raised.has("x-handler-probe")      # nothing the handler set
    check not raised.has("set-cookie")
    check not raised.has("vary") and not raised.has("pragma")
    # The hook's coNotFound for a target the caller may not see.
    let hidden = fixture.fetch("/neg/a/article-13/13")
    check hidden.status == 404
    check not hidden.has("x-hook-probe")         # nothing the hook set
    check not hidden.has("location")
    # The same answer, header for header and byte for byte.
    check raised.headers == hidden.headers
    check raised.body == hidden.body
    # Its JSON variant and HEAD are the same 404.
    let raisedJson = fixture.fetch("/neg/a/article-3/3.json")
    check raisedJson.status == 404 and raisedJson.headers == hidden.headers
    let raisedHead = fixture.fetch("/neg/a/article-3/3", httpMethod = HttpHead)
    check raisedHead.status == 404 and not raisedHead.has("location")
    # An `any` handler's raise is the same answer.
    let raw = fixture.fetch("/neg/raw/3")
    check raw.status == 404
    check raw.headers == hidden.headers and raw.body == hidden.body
    check fixture.fetch("/neg/raw/4").body == "raw 4"   # vacuity: it serves

  test "negative control: a weaker or undeclared override is refused and reported":
    let before = fixture.refusalsOf()
    # The hook of a cpPrivateNoStore entry asks for cpPrivateRevalidate.
    let locked = fixture.fetch("/neg/locked/1")
    check locked.status == 200
    check locked.header("x-override") == "refused"
    check locked.exactlyPolicy(noStoreHeaders)
    # The handler asks to relax a response its hook made no-store.
    let relaxed = fixture.fetch("/neg/a/article-5/5")
    check relaxed.status == 200
    check relaxed.header("x-handler-override") == "refused"
    check relaxed.header("cache-control") == cacheControl(cpPrivateNoStore)
    # A handler asks for a policy its entry does not declare (stricter, but
    # not in the manifest, so not in its generated tests either).
    let undeclared = fixture.fetch("/neg/p/7")
    check undeclared.status == 200
    check undeclared.header("x-handler-override") == "refused"
    check undeclared.header("cache-control") == cacheControl(cpPrivateRevalidate)
    let reported = fixture.refusalsOf()
    check reported.len == before.len + 3
    check reported[before.len .. ^1] == @[
      "cpPrivateRevalidate kept cpPrivateNoStore at /neg/locked/1",
      "cpPrivateRevalidate kept cpPrivateNoStore at /neg/a/article-5/5",
      "cpPrivateNoStore kept cpPrivateRevalidate at /neg/p/7"]

  test "an any entry answers with its own policy and its declared overrides":
    let before = fixture.refusalsOf()
    # Vacuity guard: the entry's default, exactly (not the pipeline's
    # no-store, not the page entries' private revalidation).
    let plain = fixture.fetch("/neg/rc/1")
    check plain.status == 200 and plain.body == "rc 1"
    check not plain.has("x-handler-override")
    check plain.exactlyPolicy(cacheHeaders(cpMediaRevalidate))
    # A stricter declared override is accepted and its headers written.
    let stricter = fixture.fetch("/neg/rc/2")
    check stricter.status == 200 and stricter.body == "rc 2"
    check stricter.header("x-handler-override") == "accepted"
    check stricter.exactlyPolicy(revalidateHeaders)
    # Negative control: after no-store, the declared but weaker
    # cpPrivateRevalidate is refused; the response stays no-store.
    let relaxed = fixture.fetch("/neg/rc/4")
    check relaxed.status == 200
    check relaxed.header("x-handler-override") == "accepted,refused"
    check relaxed.exactlyPolicy(noStoreHeaders)
    # cpNone, weaker than the entry's default, is refused: the default stays.
    let weaker = fixture.fetch("/neg/rc/6")
    check weaker.status == 200
    check weaker.header("x-handler-override") == "refused"
    check weaker.exactlyPolicy(cacheHeaders(cpMediaRevalidate))
    let reported = fixture.refusalsOf()
    check reported.len == before.len + 2
    check reported[before.len .. ^1] == @[
      "cpPrivateRevalidate kept cpPrivateNoStore at /neg/rc/4",
      "cpNone kept cpMediaRevalidate at /neg/rc/6"]

  test "the generated policy tests pass, JSON variants and override included":
    let env = PolicyEnv(baseUrl: fixture.baseUrl,
      cacheOverridePath: proc(t: RoutePolicyTest): string =
        (if t.route == "nArticle" and t.overridePolicy == cpPrivateNoStore:
           "/neg/a/article-5/5"
         elif t.route == "nRawCached" and t.overridePolicy == cpPrivateRevalidate:
           "/neg/rc/2"
         elif t.route == "nRawCached" and t.overridePolicy == cpPrivateNoStore:
           "/neg/rc/4"
         else: ""))
    let tests = policyTests(NegotiationRoute)
    var counts: array[PolicyCheck, int]
    var failures: seq[string]
    for t in tests:
      inc counts[t.check]
      let failure = env.runPolicyTest(t)
      if failure.len > 0: failures.add failure
    for f in failures: echo "    ", f
    check failures.len == 0
    echo "    ", tests.len, " policy tests: ", counts
    proc checksOf(route: string): seq[PolicyCheck] =
      for t in tests:
        if t.route == route: result.add t.check
    check pcJsonSuffix in checksOf("nArticle") and pcJsonAccept in checksOf("nArticle")
    check pcJsonSuffix in checksOf("nPlain") and pcJsonAccept in checksOf("nPlain")
    check checksOf("nArticle").countIt(it == pcCacheOverride) == 1
    # An `any` entry: only its declared overrides, one test each.
    check checksOf("nRawCached") == @[pcCacheOverride, pcCacheOverride]
    check checksOf("nRaw").len == 0
    check pcJsonSuffix notin checksOf("nLocked") and pcCacheOverride notin checksOf("nLocked")
    # The runner's own guards: wrong expectations are reported.
    for t in tests:
      if t.route == "nPlain" and t.check == pcJsonSuffix:
        var wrong = t
        wrong.path = "/neg/p/4"          # the HTML answer is not the variant
        check "application/json" in env.runPolicyTest(wrong)
      if t.route == "nArticle" and t.check == pcCacheOverride:
        var wrong = t
        let noPath = PolicyEnv(baseUrl: fixture.baseUrl)
        check "names no request" in noPath.runPolicyTest(wrong)
        let pubEnv = PolicyEnv(baseUrl: fixture.baseUrl,
          cacheOverridePath: proc(t: RoutePolicyTest): string = "/neg/a/article-2/2")
        check "Cache-Control" in pubEnv.runPolicyTest(wrong)
      if t.route == "nPlain" and t.check == pcCache:
        var wrong = t
        wrong.accept = "application/json"   # JSON where the HTML is expected
        check "was not answered with its HTML" in env.runPolicyTest(wrong)

  fixture.stop()
