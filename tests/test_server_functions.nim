## Server functions: the `{.server.}` / `{.action.}` macros on both targets.
##
## C target: the procs are async procs callable in-process, registered as
## `<rpcPrefix>/<module>/<proc>` with their policies; the registry handler
## decodes arguments, runs the proc and encodes the result; the macros
## reject what they must at compile time (checked by compiling fixtures).
##
## JS target: the stubs `POST` through `fetch` to a real HTTP server
## started in this Node.js process (no mock: the request crosses a real
## socket), carry the CSRF and context headers, decode typed results and
## reject non-2xx answers with `RpcError`.  The compiled test itself must
## contain no `XMLHttpRequest`.

import std/[json, strutils]
import isonim/server/[rpc, pragma, context]

type
  Point = object
    x: int
    y: int

proc add(a: int, b: int): Future[int] {.server.} =
  return a + b

proc greet(name: string): Future[string] {.server(auth = aPublic, csrf = csrfAnon).} =
  return "Hello, " & name & "!"

proc multiply(x: float, y: float): Future[float] {.server.} =
  return x * y

proc negate(flag: bool): Future[bool] {.server.} =
  return not flag

proc noArgs(): Future[int] {.server.} =
  return 42

proc makePoint(x: int, y: int): Future[Point] {.server.} =
  return Point(x: x, y: y)

proc whoAmI(ctx: RequestContext; suffix: string): Future[string]
    {.server(auth = aSession, contextScope = csNavigation).} =
  return ctx.session.subject & suffix

proc boom(): Future[int] {.server.} =
  raise newException(ValueError, "boom")

proc retried(tag: string): Future[int] {.server.} =
  ## The JS suite's resend cases: its Node server answers by `tag`
  ## (a 503 with or without `Retry-After`, then 200), never this body.
  return tag.len

proc subscribe(email: string): Future[bool] {.action(target = "/thanks").} =
  return email.contains('@')

when not defined(js):
  import std/[unittest, tables, osproc, os]

  proc call(name: string; args: JsonNode; ctx: RequestContext = nil): JsonNode =
    waitFor lookupRpc("test_server_functions/" & name).handler(ctx, args)

  suite "Server functions — C target":
    test "server functions are async procs callable in-process":
      check waitFor(add(3, 4)) == 7
      check waitFor(greet("World")) == "Hello, World!"
      check waitFor(multiply(2.5, 4.0)) == 10.0
      check waitFor(negate(true)) == false
      check waitFor(noArgs()) == 42
      check waitFor(makePoint(10, 20)) == Point(x: 10, y: 20)

    test "endpoints are module-qualified under rpcPrefix":
      check rpcPrefix == "/api"
      check addUrl == "/api/test_server_functions/add"
      check subscribeUrl == "/api/test_server_functions/subscribe"
      for name in ["add", "greet", "multiply", "negate", "noArgs", "makePoint",
                   "whoAmI", "boom", "subscribe"]:
        check rpcRegistry.hasKey("test_server_functions/" & name)
      check lookupRpc("add").isNil   # the unqualified name is not an endpoint

    test "the registry keeps each function's policies":
      let a = lookupRpc("test_server_functions/add")
      check a.auth == aOptional and a.csrf == csrfSession and
            a.contextScope == csAccount and not a.isAction
      check a.params == @["a", "b"]
      let g = lookupRpc("test_server_functions/greet")
      check g.auth == aPublic and g.csrf == csrfAnon
      let w = lookupRpc("test_server_functions/whoAmI")
      check w.auth == aSession and w.contextScope == csNavigation
      check w.params == @["suffix"]   # the context is not an argument
      let s = lookupRpc("test_server_functions/subscribe")
      check s.isAction and s.target == "/thanks"

    test "the handler decodes arguments and encodes the result":
      check call("add", %*{"a": 10, "b": 20}).getInt == 30
      check call("greet", %*{"name": "Nim"}).getStr == "Hello, Nim!"
      check call("makePoint", %*{"x": 5, "y": 15}) == %*{"x": 5, "y": 15}
      check call("noArgs", newJObject()).getInt == 42

    test "form fields (strings) decode to the parameter types":
      check call("add", %*{"a": "2", "b": "40"}).getInt == 42
      check call("negate", %*{"flag": "on"}).getBool == false
      check call("multiply", %*{"x": "1.5", "y": "2"}).getFloat == 3.0

    test "missing and mistyped arguments are RpcBadRequest":
      expect RpcBadRequest:
        discard call("add", %*{"a": 1})
      expect RpcBadRequest:
        discard call("add", %*{"a": "one", "b": 2})
      expect RpcBadRequest:
        discard call("greet", %*{"name": 3})

    test "the request context reaches the server function":
      let ctx = newRequestContext(newSsrRequest("POST", "/x", "/x", "", @[], "127.0.0.1"))
      ctx.session = Session(subject: "alice")
      check call("whoAmI", %*{"suffix": "!"}, ctx).getStr == "alice!"
      check waitFor(whoAmI(ctx, "?")) == "alice?"

    test "a raising server function fails its future":
      let f = lookupRpc("test_server_functions/boom").handler(nil, newJObject())
      expect ValueError:
        discard waitFor f

    test "sample arguments have the parameter types":
      check lookupRpc("test_server_functions/add").sample() == %*{"a": 0, "b": 0}
      check lookupRpc("test_server_functions/noArgs").sample() == newJObject()

  # The macros' compile-time errors.  Each fixture is compiled (C code
  # generation, no link); the negative control compiles clean.
  const fixtures = currentSourcePath().parentDir / "fixtures"

  proc nimCheck(file: string): tuple[ok: bool, output: string] =
    let src = currentSourcePath().parentDir.parentDir / "src"
    let (output, code) = execCmdEx("nim c --compileOnly --hints:off --path:" &
      quoteShell(src) & " " & quoteShell(fixtures / file))
    (code == 0, output)

  suite "Server functions — compile-time checks":
    test "a server function must return Future[T]":
      let r = nimCheck("server_fn_sync_return.nim")
      check not r.ok
      check "must return Future[T]" in r.output

    test "a server function cannot declare csrfNone":
      let r = nimCheck("server_fn_csrf_none.nim")
      check not r.ok
      check "csrfNone is only valid for safe methods" in r.output

    proc nimJs(file, flags: string): tuple[ok: bool, output: string] =
      let src = currentSourcePath().parentDir.parentDir / "src"
      let (output, code) = execCmdEx("nim js --compileOnly --hints:off -d:nimStringHash2 " & flags & " --path:" &
        quoteShell(src) & " --out:" & quoteShell(getTempDir() / "isonim_json_decode_int64.js") & " " &
        quoteShell(fixtures / file))
      (code == 0, output)

    test "a --jsbigint64:off client refuses an int64 field (a string is exact)":
      let r = nimJs("json_decode_int64.nim", "--jsbigint64:off")
      check not r.ok
      check "is not exact in a --jsbigint64:off build" in r.output
      let s = nimJs("json_decode_int64.nim", "--jsbigint64:off -d:asString")
      check s.ok
      if not s.ok: echo s.output
      let b = nimJs("json_decode_int64.nim", "--jsbigint64:on")
      check b.ok
      if not b.ok: echo b.output

    test "negative control: a well-formed server function compiles":
      let r = nimCheck("server_fn_ok.nim")
      check r.ok
      if not r.ok: echo r.output

else:
  import std/[asyncjs, jsffi]

  # A real HTTP server in this Node.js process.  It answers like
  # `dispatchRpc` for the functions above and records what it received.
  # Node has no document base URL, so relative URLs ("/api/...") are
  # resolved against the server (the browser does this by itself).
  var port: int
  {.emit: """
  const http = require("http");
  globalThis.__received = [];
  globalThis.__server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => body += c);
    req.on("end", () => {
      globalThis.__received.push({method: req.method, url: req.url,
        headers: req.headers, body: body});
      const args = body ? JSON.parse(body) : {};
      const name = req.url.split("/").pop();
      let out, status = 200;
      // `retried`: the resend cases, per `args.tag` (rpc_client.nim: one
      // resend, with the same key, after a 503 whose Retry-After is
      // delta-seconds within 0..60).
      const tries = globalThis.__tries ??= {};
      if (name === "retried") {
        const n = tries[args.tag] = (tries[args.tag] ?? 0) + 1;
        globalThis.__received[globalThis.__received.length - 1].at = Date.now();
        const retryAfter = {after1: "1", after0: "0", always: "0", toolong: "61",
                            date: "Wed, 21 Oct 2026 07:28:00 GMT"}[args.tag];
        if (args.tag === "always" || n === 1) {
          const h = {"Content-Type": "application/json"};
          if (retryAfter !== undefined) h["Retry-After"] = retryAfter;
          res.writeHead(503, h);
          res.end(JSON.stringify({error: "unavailable"}));
          return;
        }
        res.writeHead(200, {"Content-Type": "application/json"});
        res.end(JSON.stringify(n));
        return;
      }
      if (name === "add") out = args.a + args.b;
      else if (name === "makePoint") out = {x: args.x, y: args.y};
      else if (name === "greet") out = "Hello, " + args.name + "!";
      else { status = 500; out = {error: "internal"}; }
      const hdrs = {"Content-Type": "application/json"};
      // Commit positions (read-your-writes): `add` commits at 0/16B3748,
      // `greet` reports an older one, which the client must not adopt.
      if (name === "add") hdrs["Isonim-Commit"] = "cell-1:0/16B3748";
      if (name === "greet") hdrs["Isonim-Commit"] = "cell-1:0/16B0000";
      res.writeHead(status, hdrs);
      res.end(JSON.stringify(out));
    });
  });
  const realFetch = globalThis.fetch;
  globalThis.fetch = (url, init) => realFetch(
    url.startsWith("/") ? "http://127.0.0.1:" + globalThis.__port + url : url, init);
  """.}

  proc listen(): Future[int] =
    {.emit: """
    `result` = new Promise((resolve) => globalThis.__server.listen(0, "127.0.0.1",
      () => { globalThis.__port = globalThis.__server.address().port;
              resolve(globalThis.__port); }));
    """.}

  proc received(i: int): JsObject =
    {.emit: "`result` = globalThis.__received[`i`];".}

  proc ownSource(): cstring =
    {.emit: "`result` = require('fs').readFileSync(process.argv[1], 'utf8');".}

  proc main() {.async.} =
    port = await listen()
    setCsrfToken("tok-123")
    initClientContext("inst-1", "inc-1")

    doAssert addUrl == "/api/test_server_functions/add"
    doAssert (await add(2, 3)) == 5
    let r0 = received(0)
    doAssert $r0.method.to(cstring) == "POST"
    doAssert $r0.url.to(cstring) == "/api/test_server_functions/add"
    doAssert $r0.headers["x-csrf-token"].to(cstring) == "tok-123"
    doAssert $r0.headers["isonim-context"].to(cstring) == "inc-1:0"
    doAssert $r0.headers["content-type"].to(cstring) == "application/json"
    doAssert parseJson($r0.body.to(cstring)) == %*{"a": 2, "b": 3}

    doAssert r0.headers["isonim-after"].isUndefined   # no write answered yet

    doAssert (await makePoint(7, 8)) == Point(x: 7, y: 8)
    # The write's `Isonim-Commit` comes back as `Isonim-After`.
    doAssert $received(1).headers["isonim-after"].to(cstring) == "cell-1:0/16B3748"
    doAssert (await greet("JS")) == "Hello, JS!"
    discard await add(1, 1)
    # `greet` answered an older position of the same cell: still the newest.
    doAssert $received(3).headers["isonim-after"].to(cstring) == "cell-1:0/16B3748"
    # A new account generation forgets the position.
    bumpAccountGeneration()
    doAssert (await makePoint(1, 2)) == Point(x: 1, y: 2)
    doAssert received(4).headers["isonim-after"].isUndefined
    # The window is 60 s on the page's clock; a malformed position is ignored.
    noteCommit("cell-2:A/1", 1000.0)
    doAssert afterHeaderValue(1000.0 + 59_999.0) == "cell-2:A/1"
    doAssert afterHeaderValue(1000.0 + 60_000.0) == ""
    noteCommit("cell-2:A/1", 2000.0)
    noteCommit("cell-2:not-an-lsn", 2000.0)
    doAssert afterHeaderValue(2000.0) == "cell-2:A/1"
    noteCommit("cell-2:9/FFFFFFFF", 2000.0)      # older than A/1
    doAssert afterHeaderValue(2000.0) == "cell-2:A/1"
    noteCommit("cell-2:A/2", 2000.0)
    doAssert afterHeaderValue(2000.0) == "cell-2:A/2"

    # A non-2xx answer rejects with RpcError.
    var failed = false
    try:
      discard await boom()
    except RpcError as e:
      failed = true
      doAssert e.status == 500
      doAssert "internal" in e.body
    doAssert failed

    # A write answered 503 with `Retry-After` is resent once, with its key,
    # no earlier than the delay; anything else is not resent.
    proc attempts(tag: string): seq[JsObject] =
      var all: seq[JsObject]
      {.emit: [all, " = globalThis.__received.filter(r => r.url.endsWith('/retried') && JSON.parse(r.body).tag === ", cstring(tag), ");"].}
      all
    doAssert (await retried("after1")) == 2
    let a1 = attempts("after1")
    doAssert a1.len == 2
    let key1 = $a1[0].headers["idempotency-key"].to(cstring)
    doAssert key1.len == 36                       # a UUID
    doAssert $a1[1].headers["idempotency-key"].to(cstring) == key1
    # Date.now() is whole milliseconds: a wait of >= 1000 ms reads >= 999.
    let gap = a1[1].at.to(float) - a1[0].at.to(float)
    doAssert gap >= 999.0, "the resend did not wait for Retry-After: " & $gap & " ms"
    doAssert (await retried("after0")) == 2
    doAssert attempts("after0").len == 2
    for tag in ["noheader", "toolong", "date", "always"]:
      var status = 0
      try:
        discard await retried(tag)
      except RpcError as e:
        status = e.status
      doAssert status == 503, tag
      doAssert attempts(tag).len == (if tag == "always": 2 else: 1), tag
    doAssert $attempts("always")[1].headers["idempotency-key"].to(cstring) ==
      $attempts("always")[0].headers["idempotency-key"].to(cstring)
    # Another write draws another key.
    doAssert $attempts("after0")[0].headers["idempotency-key"].to(cstring) != key1

    # The context argument is not sent.
    doAssert whoAmIUrl == "/api/test_server_functions/whoAmI"

    # No synchronous XHR anywhere in the compiled client.
    # (The needle is built at run time so that this check is not itself an
    # occurrence.)
    doAssert ("XMLHttp" & "Request") notin $ownSource()
    echo "[OK] server functions over fetch (JS): 6 checks, the commit position sent back, and the 503 resend"
    {.emit: "globalThis.__server.close();".}

  discard main()
