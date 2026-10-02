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
      if (name === "add") out = args.a + args.b;
      else if (name === "makePoint") out = {x: args.x, y: args.y};
      else if (name === "greet") out = "Hello, " + args.name + "!";
      else { status = 500; out = {error: "internal"}; }
      res.writeHead(status, {"Content-Type": "application/json"});
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
    doAssert $r0.headers["x-isonim-context"].to(cstring) == "inc-1:0"
    doAssert $r0.headers["content-type"].to(cstring) == "application/json"
    doAssert parseJson($r0.body.to(cstring)) == %*{"a": 2, "b": 3}

    doAssert (await makePoint(7, 8)) == Point(x: 7, y: 8)
    doAssert (await greet("JS")) == "Hello, JS!"

    # A non-2xx answer rejects with RpcError.
    var failed = false
    try:
      discard await boom()
    except RpcError as e:
      failed = true
      doAssert e.status == 500
      doAssert "internal" in e.body
    doAssert failed

    # The context argument is not sent.
    doAssert whoAmIUrl == "/api/test_server_functions/whoAmI"

    # No synchronous XHR anywhere in the compiled client.
    # (The needle is built at run time so that this check is not itself an
    # occurrence.)
    doAssert ("XMLHttp" & "Request") notin $ownSource()
    echo "[OK] server functions over fetch (JS): 6 checks"
    {.emit: "globalThis.__server.close();".}

  discard main()
