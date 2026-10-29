## test_manifest_streaming_page (IFP-M30 of isonim-specs
## milestones/2026-10-02-isonim-forum-prerequisites).
##
## The streaming pages of streaming_manifest.nim (isonim-routing-server-
## functions.md, "Streaming Pages"), served by real nginx with the real
## ngx-isonim module (the nginx fixture, tests/nginx/README.md;
## `just build-nginx-fixture`), read over a raw socket so that what arrives
## when is observable:
##
## * a streaming page flushes its shell, then awaits a read gated by a
##   socket this test holds: the shell arrives before the test lets the
##   read complete (the test accepts the handler's connection only after
##   it has the shell, so the order needs no timer), carrying the entry's
##   cache policy and the `pageHeaders` hook's CSP header, whose nonce is
##   the bootstrap script's; the rest, the page-data script, the bootstrap
##   and the tail follow, and the response ends;
## * a per-response policy set before the shell is the committed one; after
##   the shell `setCachePolicy` is refused (and reported) and the headers
##   are fixed; `RouteNotFound` or an error after the shell terminates the
##   response (logged), before it they are the pipeline's 404 and 500 with
##   none of the page, an exception the application mapped
##   (`serverHooks.mappedExceptions`) its status with `Retry-After` and
##   `private, no-store`, while after the shell it terminates the response
##   like any other, `RpcBadRequest` the 400 and a redirect the redirect
##   with the entry's policy and no body (`page.flush()` on it raising
##   `ValueError`); a page that never flushes is answered whole; a custom
##   `page.tail` is written last; the JSON variant is answered whole; no
##   bootstrap where the location disables hydration; HEAD carries the
##   headers only;
## * the generated policy tests of the streaming entries pass.
##
## Vacuity guard: the first test's assertions (chunked, the shell before
## the byte, the byte in the rest, the terminating chunk).
##
## Negative control: the `Page`-returning entry of the same manifest answers
## whole, with `Content-Length` and the same headers.
##
## Falsifying mutation: applying the entry's headers after the first flush
## (the response is already committed, so the shell goes out without them)
## fails the vacuity guard's header assertions;
## tests/routing/run_streaming_mutants.sh builds that module
## (`headers-after-flush`) and one per clause of the contract this test
## covers (listed in the script), and runs this test against each
## (`ISONIM_NGINX_MODULE`), expecting it to fail at the named test.  The
## same script runs t_manifest_streaming_buffered.nim (the host without a
## writer, in-process) against its own mutants.
##
## No mocks: the nginx, the module, the dispatch and the sockets are real.
## No timing bounds: every wait is for an event, with a deadline that only
## turns a hang into a failure.

import std/[unittest, asyncdispatch, asyncnet, net, httpclient, json,
            strutils, sequtils, os, osproc]
import isonim/routing/[manifest, route_tests]
import ../nginx/fixture_server
import streaming_manifest

const
  deadlineMs = 20_000
    ## Only turns a hang into a failure (the fixture's isonim_rpc_timeout
    ## for /stream/ is 30 s, so a response is never cut short by it first).
  bootstrapMarker = "window._$HY"

type
  Raw = ref object
    ## One HTTP/1.1 response read off a raw socket as it arrives.
    sock: AsyncSocket
    bytes: string          ## everything received so far
    closed: bool           ## the server closed the connection
    arrived: Future[void]  ## completed (and replaced) whenever bytes come

  Parsed = object
    headersDone: bool
    status: int
    headers: seq[(string, string)]  ## lower-cased names
    body: string                    ## the decoded body so far
    chunked: bool
    ended: bool                     ## the terminating chunk / all of
                                    ## Content-Length arrived

proc header(p: Parsed; name: string): string =
  for (k, v) in p.headers:
    if k == name.toLowerAscii: return v
  ""

proc has(p: Parsed; name: string): bool =
  p.headers.anyIt(it[0] == name.toLowerAscii)

proc parse(r: Raw): Parsed =
  let sep = r.bytes.find("\r\n\r\n")
  if sep < 0:
    return
  result.headersDone = true
  let lines = r.bytes[0 ..< sep].split("\r\n")
  result.status = parseInt(lines[0].split(' ')[1])
  for line in lines[1 .. ^1]:
    let c = line.find(':')
    if c > 0:
      result.headers.add((line[0 ..< c].strip.toLowerAscii, line[c + 1 .. ^1].strip))
  result.chunked = result.header("transfer-encoding").toLowerAscii == "chunked"
  var i = sep + 4
  if not result.chunked:
    result.body = r.bytes[i .. ^1]
    let cl = result.header("content-length")
    result.ended = cl.len > 0 and result.body.len >= parseInt(cl)
    return
  while true:
    let eol = r.bytes.find("\r\n", i)
    if eol < 0: return
    let size = fromHex[int](r.bytes[i ..< eol].split(';')[0].strip)
    if size == 0:
      result.ended = true
      return
    if r.bytes.len < eol + 2 + size + 2: return
    result.body.add r.bytes[eol + 2 ..< eol + 2 + size]
    i = eol + 2 + size + 2

proc reader(r: Raw) {.async.} =
  ## Receives until the server closes, telling waiters of every arrival.
  while true:
    var data = ""
    try:
      data = await r.sock.recv(65536)
    except CatchableError:
      data = ""                # a reset is a close too
    if data.len == 0:
      r.closed = true
    else:
      r.bytes.add data
    let f = r.arrived
    r.arrived = newFuture[void]("raw arrival")
    f.complete()
    if r.closed: break

proc openRaw(f: Fixture; target: string; httpMethod = "GET";
             headers: seq[(string, string)] = @[]): Future[Raw] {.async.} =
  # Unbuffered: a recv completes with whatever has arrived.
  let r = Raw(sock: newAsyncSocket(buffered = false),
              arrived: newFuture[void]("raw arrival"))
  await r.sock.connect("127.0.0.1", Port(f.port))
  var req = httpMethod & " " & target & " HTTP/1.1\r\nHost: 127.0.0.1\r\n" &
    "Connection: close\r\n"
  for (k, v) in headers:
    req.add k & ": " & v & "\r\n"
  await r.sock.send(req & "\r\n")
  asyncCheck r.reader()
  return r

proc until(r: Raw; what: proc(p: Parsed): bool): Future[bool] {.async.} =
  ## Waits until `what` holds for what has arrived, or the server closed
  ## the connection, or the deadline: whether `what` holds.
  while true:
    if what(r.parse): return true
    if r.closed: return false
    if not await r.arrived.withTimeout(deadlineMs): return false

proc whole(f: Fixture; target: string; httpMethod = "GET";
           headers: seq[(string, string)] = @[]): Parsed =
  ## A whole response (until the server closes the connection).
  let r = waitFor f.openRaw(target, httpMethod, headers)
  discard waitFor r.until(proc(p: Parsed): bool = false)
  result = r.parse
  r.sock.close()

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

proc refusalsOf(f: Fixture): seq[string] =
  let c = newHttpClient(timeout = deadlineMs)
  defer: c.close()
  for x in parseJson(c.getContent(f.baseUrl & "/neg/refusals"))["refusals"]:
    result.add x.getStr

proc nimCompile(file: string): tuple[ok: bool, output: string] =
  let (output, code) = execCmdEx("nim c --compileOnly --hints:off --path:" &
    quoteShell(repoRoot / "src") & " " & quoteShell(repoRoot / "tests/fixtures" / file))
  (code == 0, output)

proc pageHeaderNames(p: Parsed): seq[string] =
  ## The headers the dispatch and the hook shape (the transport's left out).
  for (k, _) in p.headers:
    if k notin ["date", "server", "content-length", "connection",
                "transfer-encoding", "keep-alive"]:
      result.add k

const revalidate = cacheHeaders(cpPrivateRevalidate)

suite "test_manifest_streaming_page":
  test "stream on an entry that is not a page or a get does not compile, nor a streaming get with a response type":
    let notPage = nimCompile("manifest_stream_not_page.nim")
    check not notPage.ok
    check "`stream` applies to page and get entries only" in notPage.output
    let withResp = nimCompile("manifest_stream_get_response.nim")
    check not withResp.ok
    check "a streaming get entry declares no response type" in withResp.output
    check spec(sFeed).stream and not spec(sWhole).stream and spec(sEvents).stream

  let fixture = startFixture("isonim-manifest-streaming")

  test "vacuity guard: the shell arrives before the read, with the entry's policy and the hook's CSP; the rest, the page data and the bootstrap follow":
    let gate = newAsyncSocket()
    gate.setSockOpt(OptReuseAddr, true)
    gate.bindAddr(Port(0), "127.0.0.1")
    gate.listen()
    let gatePort = int(gate.getLocalAddr()[1])
    let r = waitFor fixture.openRaw("/stream/f/1?gate=" & $gatePort)
    let gotShell = waitFor r.until(proc(p: Parsed): bool =
      "id=\"shell\"" in p.body)
    # What had arrived when the shell did: the byte the page awaits is not
    # sent yet (its connection is not even accepted).
    let atShell = r.parse
    check gotShell
    check atShell.status == 200
    check atShell.chunked
    check not atShell.ended
    check "rest:" notin atShell.body
    check atShell.header("content-type") == "text/html; charset=utf-8"
    check atShell.header("cache-control") == revalidate[0][1]
    check atShell.header("vary") == revalidate[1][1] & ", Accept"
    let csp = atShell.header("content-security-policy")
    check csp.startsWith("script-src 'nonce-")
    check atShell.header("x-page-hook") == "sFeed"
    # While the page awaits, the worker serves another request.
    let other = newHttpClient(timeout = deadlineMs)
    let otherResp = other.request(fixture.baseUrl & "/stream/w/1")
    other.close()
    check otherResp.code.int == 200
    # Now let the read complete.
    let accepting = gate.accept()
    check waitFor accepting.withTimeout(deadlineMs)
    if accepting.finished and not accepting.failed:
      let peer = accepting.read
      waitFor peer.send("Z")
      peer.close()
    let ended = waitFor r.until(proc(p: Parsed): bool = p.ended)
    gate.close()
    let done = r.parse
    # The server closes the connection (Connection: close) after the end.
    discard waitFor r.until(proc(p: Parsed): bool = false)
    r.sock.close()
    check ended
    check "<p id=\"rest\">rest:Z</p>" in done.body
    check done.body.find("id=\"shell\"") < done.body.find("rest:Z")
    check pageData(done.body) == %*{"id": 1, "items": ["a", "Z"]}
    # Order: the body, the page data, the bootstrap, the tail.
    let dataAt = done.body.find("id=\"" & pageDataScriptId & "\"")
    let bootAt = done.body.find(bootstrapMarker)
    check done.body.find("id=\"body-end\"") < dataAt
    check dataAt >= 0 and bootAt > dataAt
    check done.body.endsWith("</body></html>")
    check bootAt < done.body.len - "</body></html>".len
    # The CSP header's nonce is the bootstrap script's.
    check nonceOf(csp).len == 24
    check scriptNonce(done.body) == nonceOf(csp)

  test "a per-response policy set before the shell is the committed one":
    let p = fixture.whole("/stream/f/2")
    check p.status == 200 and p.chunked and p.ended
    check p.header("x-early-override") == "true"
    for (k, v) in cacheHeaders(cpPrivateNoStore):
      if k != "Vary":
        check p.header(k) == v
    check p.header("vary") == "Accept"

  test "after the shell: setCachePolicy is refused and reported, the headers are fixed":
    let before = fixture.refusalsOf()
    let p = fixture.whole("/stream/f/4")
    check p.status == 200 and p.ended
    check "<p id=\"late-override\">false</p>" in p.body
    check "<p id=\"late-header\">ResponseCommittedError</p>" in p.body
    check p.header("cache-control") == revalidate[0][1]
    check not p.has("x-late")
    let after = fixture.refusalsOf()
    check after.len == before.len + 1
    check after[^1] == "cpPrivateNoStore kept cpPrivateRevalidate at /stream/f/4"

  test "after the shell: RouteNotFound and errors terminate the response, logged":
    for (id, logged) in [(6, "RouteNotFound"), (7, "sFeed 7 raised after its shell")]:
      let p = fixture.whole("/stream/f/" & $id)
      check p.status == 200           # committed before the failure
      check p.chunked
      check "id=\"shell\"" in p.body
      check not p.ended               # no terminating chunk
      check "rest:" notin p.body
      let log = readFile(fixture.errorLog)
      check logged in log
      check "response terminated after the headers were sent (GET /stream/f/" &
        $id in log

  test "before the shell: RouteNotFound is the 404 and an error the 500, with none of the page":
    let nf = fixture.whole("/stream/f/3")
    check nf.status == 404
    check nf.header("content-type") == "application/json"
    check nf.header("cache-control") == errorCacheControl
    check parseJson(nf.body) == %*{"error": "not_found"}
    check not nf.has("content-security-policy")
    let err = fixture.whole("/stream/f/5")
    check err.status == 500
    check parseJson(err.body) == %*{"error": "internal"}
    check "leaked" notin nf.body & err.body

  test "before the shell: a mapped exception is its status with Retry-After and no-store, with none of the page":
    let p = fixture.whole("/stream/f/14")
    check p.status == 503
    check p.ended and not p.chunked
    check p.header("retry-after") == "1"
    check p.header("content-type") == "application/json"
    check p.header("cache-control") == errorCacheControl
    check parseJson(p.body) == %*{"error": "unavailable"}
    check not p.has("x-before-overload")
    check not p.has("content-security-policy") and not p.has("x-page-hook")
    check "leaked" notin p.body
    # Not a server fault: nothing is logged for it.
    check "sFeed 14 overloaded" notin readFile(fixture.errorLog)

  test "after the shell: a mapped exception terminates the response like any other, logged":
    let p = fixture.whole("/stream/f/15")
    check p.status == 200           # committed before the failure
    check p.chunked
    check "id=\"shell\"" in p.body
    check not p.ended               # no terminating chunk
    check not p.has("retry-after")
    check "rest:" notin p.body and "unavailable" notin p.body
    let log = readFile(fixture.errorLog)
    check "sFeed 15 overloaded after its shell" in log
    check "response terminated after the headers were sent (GET /stream/f/15" in log

  test "before the shell: RpcBadRequest is the 400, with none of the page":
    let p = fixture.whole("/stream/f/12")
    check p.status == 400
    check p.header("content-type") == "application/json"
    check p.header("cache-control") == errorCacheControl
    check parseJson(p.body) == %*{"error": "bad_request",
                                  "detail": "sFeed 12 is a bad request"}
    check not p.has("content-security-policy") and not p.has("x-page-hook")
    check "leaked" notin p.body

  test "before the shell: a redirect has the entry's policy and no body; flushing it raises ValueError":
    for id in [10, 11]:
      let p = fixture.whole("/stream/f/" & $id)
      check p.status == 302 and p.ended
      check not p.chunked
      check p.header("location") == "/stream/f/1"
      check p.header("cache-control") == revalidate[0][1]
      check p.header("vary") == revalidate[1][1]   # no Accept: not a 2xx
      check p.body.len == 0
      check p.header("content-length") in ["", "0"]
      check not p.has("content-security-policy") and not p.has("x-page-hook")
      check p.header("x-flush-refused") == (if id == 11: "ValueError" else: "")

  test "a custom page.tail is written last, instead of the default":
    let p = fixture.whole("/stream/f/13")
    check p.status == 200 and p.ended and p.chunked
    check pageData(p.body) == %*{"id": 13, "items": ["a", "-"]}
    check p.body.endsWith("<footer id=\"custom-tail\">tail</footer></body></html>")
    check p.body.count("</body></html>") == 1
    # The tail follows the page data and the bootstrap.
    check p.body.find(bootstrapMarker) < p.body.find("id=\"custom-tail\"")

  test "a page that never flushes is answered whole":
    let p = fixture.whole("/stream/f/8")
    check p.status == 200 and p.ended
    check not p.chunked
    check p.header("content-length") == $p.body.len
    check p.header("cache-control") == revalidate[0][1]
    check nonceOf(p.header("content-security-policy")) == scriptNonce(p.body)
    check pageData(p.body) == %*{"id": 8, "items": ["a", "-"]}

  test "the JSON variant is answered whole, not streamed":
    for (target, hdrs) in [("/stream/f/1.json", newSeq[(string, string)]()),
                           ("/stream/f/1", @[("Accept", "application/json")])]:
      let p = fixture.whole(target, headers = hdrs)
      check p.status == 200 and p.ended
      check not p.chunked
      check p.header("content-type") == "application/json"
      check parseJson(p.body) == %*{"id": 1, "items": ["a", "-"]}
      check p.header("cache-control") == revalidate[0][1]
      check p.header("vary") == revalidate[1][1] & ", Accept"
      check not p.has("content-security-policy") and not p.has("x-page-hook")

  test "no bootstrap where the location disables hydration":
    let p = fixture.whole("/stream/f/9")
    check p.status == 200 and p.ended and p.chunked
    check pageData(p.body) == %*{"id": 9, "items": ["a", "-"]}
    check bootstrapMarker notin p.body
    check p.body.endsWith("</script></body></html>")   # data, then the tail
    check p.has("content-security-policy")

  test "HEAD is answered with the headers only":
    let p = fixture.whole("/stream/f/1", httpMethod = "HEAD")
    check p.status == 200
    check p.header("cache-control") == revalidate[0][1]
    check p.has("content-security-policy")
    check p.body.len == 0

  test "negative control: a Page entry answers whole with Content-Length and the same headers":
    let streamed = fixture.whole("/stream/f/1")
    let p = fixture.whole("/stream/w/1")
    check p.status == 200 and p.ended
    check not p.chunked
    check p.header("content-length") == $p.body.len
    check streamed.chunked
    check p.pageHeaderNames == streamed.pageHeaderNames
    for name in ["content-type", "cache-control", "vary"]:
      check p.header(name) == streamed.header(name)
    check p.header("x-page-hook") == "sWhole"
    check nonceOf(p.header("content-security-policy")).len == 24
    check pageData(p.body) == pageData(streamed.body)
    check bootstrapMarker notin p.body      # a Page gets no bootstrap

  test "a streaming data entry: its first event arrives before the read, with its content type and the entry's policy; the rest follow":
    let gate = newAsyncSocket()
    gate.setSockOpt(OptReuseAddr, true)
    gate.bindAddr(Port(0), "127.0.0.1")
    gate.listen()
    let gatePort = int(gate.getLocalAddr()[1])
    let r = waitFor fixture.openRaw("/stream/e/1?gate=" & $gatePort)
    let gotOpen = waitFor r.until(proc(p: Parsed): bool =
      "event: open" in p.body)
    let atOpen = r.parse
    check gotOpen
    check atOpen.status == 200
    check atOpen.chunked
    check not atOpen.ended
    check "event: n" notin atOpen.body
    check atOpen.header("content-type") == "text/event-stream"
    check atOpen.header("cache-control") == revalidate[0][1]
    check atOpen.header("x-accel-buffering") == "no"
    check not atOpen.has("x-page-hook")
    let accepting = gate.accept()
    check waitFor accepting.withTimeout(deadlineMs)
    if accepting.finished and not accepting.failed:
      let peer = accepting.read
      waitFor peer.send("Z")
      peer.close()
    let ended = waitFor r.until(proc(p: Parsed): bool = p.ended)
    gate.close()
    let p = r.parse
    r.sock.close()
    check ended
    check p.body.count("event: n") == 3
    check "data: 1 gate=Z " in p.body
    check p.body.endsWith("event: end\ndata: 1\n\n")

  test "a streaming data entry: before its first flush the pipeline answers; after it an error terminates; one that never flushes is whole":
    let nf = fixture.whole("/stream/e/3")
    check nf.status == 404 and "leaked" notin nf.body
    let mapped = fixture.whole("/stream/e/8")
    check mapped.status == 503 and mapped.header("retry-after") == "1"
    check "leaked" notin mapped.body
    let late = fixture.whole("/stream/e/6")
    check late.status == 200 and late.chunked and not late.ended
    check "event: open" in late.body
    let whole = fixture.whole("/stream/e/5")
    check whole.status == 200 and not whole.chunked and whole.ended
    check whole.header("content-type") == "text/event-stream"
    check whole.body.count("event: n") == 3
    let early = fixture.whole("/stream/e/2")
    check early.header("cache-control") == cacheHeaders(cpPrivateNoStore)[0][1]
    let refusedBefore = fixture.refusalsOf()
    let committed = fixture.whole("/stream/e/4")
    check "event: late-override\ndata: false" in committed.body
    check "event: late-header\ndata: ResponseCommittedError" in committed.body
    check fixture.refusalsOf().len == refusedBefore.len + 1

  test "the generated policy tests of the streaming entries pass":
    let env = PolicyEnv(baseUrl: fixture.baseUrl,
      cookies: proc(c: Credentials): string =
        (case c
         of crUser: "sid=user"
         of crStaff: "sid=staff"
         of crAdmin: "sid=admin"
         else: ""),
      sessionCsrfToken: proc(c: Credentials): string =
        (case c
         of crUser: "csrf-user"
         of crStaff: "csrf-staff"
         of crAdmin: "csrf-admin"
         else: ""),
      cacheOverridePath: proc(t: RoutePolicyTest): string =
        (if t.route == "sFeed" and t.overridePolicy == cpPrivateNoStore: "/stream/f/2"
         else: ""))
    let tests = policyTests(StreamingRoute)
    var failures: seq[string]
    for t in tests:
      if t.route == "sWhole": continue   # a Page; checked as streamed=false
      if t.route in ["sEvents", "sPrivateEvents"]:
        check not t.streamPage           # a data entry: refusals only
      else:
        check t.streamPage
      let failure = env.runPolicyTest(t)
      if failure.len > 0: failures.add failure
    for f in failures: echo "    ", f
    check failures.len == 0
    check tests.anyIt(it.route == "sPrivate" and it.check == pcAuth)
    check tests.anyIt(it.route == "sFeed" and it.check == pcCacheOverride)
    check tests.filterIt(it.route == "sWhole").allIt(not it.streamPage)
    # A streaming data entry's served answer may never end: its tests are
    # its refusals, none of which reads a 2xx body.
    check tests.anyIt(it.route == "sPrivateEvents" and it.check == pcAuth)
    check tests.anyIt(it.route == "sEvents" and it.check == pcMethod)
    check not tests.anyIt(it.route in ["sEvents", "sPrivateEvents"] and
                          it.check in {pcCache, pcCacheOverride})
    # The runner's own guards.
    for t in tests:
      if t.route == "sFeed" and t.check == pcCache:
        var wrong = t
        wrong.path = "/stream/f/1.json"     # JSON where the page is expected
        check "did not answer its HTML" in env.runPolicyTest(wrong)
      if t.route == "sPrivate" and t.check == pcAuth:
        var wrong = t
        wrong.path = "/static/missing.html"  # nginx's own HTML 404
        wrong.expectStatus = @[404]
        check "not the pipeline's JSON error" in env.runPolicyTest(wrong)

  fixture.stop()
