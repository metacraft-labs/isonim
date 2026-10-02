## isonim/server/pragma.nim
##
## `{.server.}` and `{.action.}`: a proc that runs on the server and is
## called from the browser.
##
## ```nim
## import isonim/server
##
## proc likePost(ctx: RequestContext; postId: int): Future[int]
##     {.server(auth = aSession, csrf = csrfSession).} =
##   result = await db.like(ctx.session.subject, postId)
##
## proc subscribe(email: string): Future[bool] {.action(target = "/thanks").} =
##   ...
## ```
##
## A server function is asynchronous on both targets: it returns
## `Future[T]` (a compile-time error otherwise), and callers `await` it.
##
## * **C target (the server):** the proc compiles as an `{.async.}` proc
##   (std/asyncdispatch) and module initialization registers it as the
##   endpoint `<rpcPrefix>/<module>/<proc>` (rpc.nim), where `<module>` is
##   the declaring module's file name.  SSR code calls it directly.
## * **JS target (the browser):** the body is replaced by `rpcCall`, a
##   `fetch` returning `Future[T]`; the original body never reaches the JS
##   output.
##
## A first parameter of type `RequestContext` receives the request context
## on the server (request, response, session, CSRF verdict, see
## context.nim); it is not an argument on the wire, and the browser stub
## ignores it (pass `nil`).  Every other parameter is a JSON argument of the
## same name; unknown arguments are rejected.
##
## Options (all optional):
##
## | Option | Default | Meaning |
## | :--- | :--- | :--- |
## | `auth` | `aOptional` | `AuthPolicy` checked before the handler |
## | `csrf` | `csrfSession` | `CsrfPolicy`; `csrfNone` is a compile-time error (server functions are `POST`) |
## | `contextScope` | `csAccount` | when the browser drops the response (URL-Schema.md §5.4) |
## | `target` | `""` | `{.action.}` only: where a no-JS form submission is redirected (303); "" = the same-origin `Referer`, else `/` |
##
## `{.action.}` (or `{.server, action.}`) is a server function that also
## accepts a form-encoded body, so a plain HTML `<form method="post">`
## reaches it without JavaScript and is answered with redirect-after-POST.
##
## Both generate a `<procName>Url` constant holding the endpoint URL.

import std/[macros, strutils]

proc moduleNameOf(n: NimNode): string =
  ## The declaring module: the file name of `n` without directory and
  ## extension.
  var f = n.lineInfoObj.filename
  let slash = max(f.rfind('/'), f.rfind('\\'))
  if slash >= 0:
    f = f[slash + 1 .. ^1]
  if f.endsWith(".nim"):
    f.setLen(f.len - 4)
  f

proc baseName(n: NimNode): NimNode =
  case n.kind
  of nnkPostfix: n[1]
  of nnkAccQuoted: n[0]
  else: n

proc isPragmaNamed(p: NimNode; name: string): bool =
  case p.kind
  of nnkIdent, nnkSym: p.eqIdent(name)
  of nnkCall, nnkCommand, nnkExprColonExpr:
    p[0].kind in {nnkIdent, nnkSym} and p[0].eqIdent(name)
  else: false

type ServerOptions = object
  auth, csrf, contextScope, target: NimNode
  isAction: bool

proc parseOptions(args: seq[NimNode]; opts: var ServerOptions) =
  for a in args:
    if a.kind notin {nnkExprEqExpr, nnkExprColonExpr}:
      error("server function options are written `name = value`", a)
    let key = $a[0]
    case key
    of "auth": opts.auth = a[1]
    of "csrf": opts.csrf = a[1]
    of "contextScope": opts.contextScope = a[1]
    of "target":
      if a[1].kind notin {nnkStrLit, nnkTripleStrLit, nnkRStrLit}:
        error("`target` must be a string literal", a[1])
      opts.target = a[1]
    else:
      error("unknown server function option `" & key &
        "` (expected auth, csrf, contextScope or target)", a)

proc genServerFn(prc: NimNode; options: seq[NimNode]; isAction: bool): NimNode =
  prc.expectKind({nnkProcDef, nnkFuncDef})
  var opts = ServerOptions(isAction: isAction)
  parseOptions(options, opts)

  # Pragmas other than server/action stay on the proc.  `{.server, action.}`
  # arrives here as `server` with `action` still in the list.
  var keptPragmas = newNimNode(nnkPragma)
  if prc.pragma.kind == nnkPragma:
    for p in prc.pragma:
      if p.isPragmaNamed("action"):
        opts.isAction = true
        if p.kind in {nnkCall, nnkCommand}:
          parseOptions(p[1 .. ^1], opts)
      elif p.isPragmaNamed("server"):
        if p.kind in {nnkCall, nnkCommand}:
          parseOptions(p[1 .. ^1], opts)
      else:
        keptPragmas.add p

  if opts.target != nil and not opts.isAction:
    error("`target` applies to {.action.} server functions only", opts.target)
  if opts.csrf != nil and opts.csrf.kind in {nnkIdent, nnkSym} and
      opts.csrf.eqIdent("csrfNone"):
    error("a server function is a state-changing POST endpoint; " &
      "csrfNone is only valid for safe methods (GET/HEAD)", opts.csrf)
  if opts.auth.isNil: opts.auth = ident"aOptional"
  if opts.csrf.isNil: opts.csrf = ident"csrfSession"
  if opts.contextScope.isNil: opts.contextScope = ident"csAccount"
  if opts.target.isNil: opts.target = newLit("")

  let nameNode = prc[0]
  let procName = $baseName(nameNode)
  let params = prc.params
  let retType = params[0]
  if not (retType.kind == nnkBracketExpr and retType[0].eqIdent("Future") and
          retType.len == 2):
    error("server function `" & procName & "` must return Future[T]: " &
      "server functions are asynchronous on both targets", prc)
  let valueType = retType[1]
  if valueType.kind in {nnkIdent, nnkSym} and valueType.eqIdent("void"):
    error("server function `" & procName & "` must return a value " &
      "(Future[void] is not supported; return Future[bool] instead)", prc)

  # The parameters: an optional leading RequestContext, then the
  # arguments that travel as JSON.
  var ctxParam: NimNode = nil
  var argNames: seq[NimNode]
  var argTypes: seq[NimNode]
  for i in 1 ..< params.len:
    let defs = params[i]
    let pType = defs[^2]
    for j in 0 ..< defs.len - 2:
      if i == 1 and j == 0 and pType.kind in {nnkIdent, nnkSym} and
          pType.eqIdent("RequestContext"):
        ctxParam = defs[j]
      else:
        if pType.kind in {nnkIdent, nnkSym} and pType.eqIdent("RequestContext"):
          error("the RequestContext parameter must be the first one", defs[j])
        argNames.add defs[j]
        argTypes.add pType

  let endpointName = moduleNameOf(prc) & "/" & procName
  let endpointLit = newLit(endpointName)
  let urlConst = ident(procName & "Url")
  let exported = nameNode.kind == nnkPostfix

  result = newStmtList()
  # <procName>Url, on both targets.
  result.add newNimNode(nnkConstSection).add(newNimNode(nnkConstDef).add(
    (if exported: postfix(urlConst, "*") else: urlConst),
    newEmptyNode(),
    newCall(ident"rpcUrl", endpointLit)))

  var publicProc = prc.copyNimTree()
  if defined(js):
    # The browser stub: POST the arguments, await the typed result.
    var argsExpr: NimNode
    if argNames.len == 0:
      argsExpr = newCall(ident"newJObject")
    else:
      var table = newNimNode(nnkTableConstr)
      for n in argNames:
        table.add newColonExpr(newLit($n), n)
      argsExpr = newCall(ident"%*", table)
    var body = newStmtList()
    if ctxParam != nil:
      body.add newNimNode(nnkDiscardStmt).add(ctxParam)
    body.add newCall(newNimNode(nnkBracketExpr).add(ident"rpcCall", valueType),
      urlConst, argsExpr, opts.contextScope)
    publicProc.body = body
    publicProc.pragma = (if keptPragmas.len > 0: keptPragmas else: newEmptyNode())
    result.add publicProc
  else:
    keptPragmas.add ident"async"
    publicProc.pragma = keptPragmas
    result.add publicProc

    # The registry entry: decode the arguments, call, encode the result.
    let ctxSym = genSym(nskParam, "ctx")
    let argsSym = genSym(nskParam, "args")
    var call = newCall(baseName(nameNode))
    if ctxParam != nil:
      call.add ctxSym
    var decode = newStmtList()
    for i, n in argNames:
      let local = genSym(nskLet, $n)
      decode.add newLetStmt(local, newCall(
        newNimNode(nnkBracketExpr).add(ident"rpcArg", argTypes[i]),
        argsSym, newLit($n)))
      call.add local
    decode.add newCall(ident"rpcResultJson", call)
    let handler = newProc(
      params = [newNimNode(nnkBracketExpr).add(ident"Future", ident"JsonNode"),
                newIdentDefs(ctxSym, ident"RequestContext"),
                newIdentDefs(argsSym, ident"JsonNode")],
      body = decode, procType = nnkLambda)
    var paramList = newNimNode(nnkBracket)
    for n in argNames:
      paramList.add newLit($n)
    var sampleBody = newCall(ident"newJObject")
    if argNames.len > 0:
      var table = newNimNode(nnkTableConstr)
      for i, n in argNames:
        table.add newColonExpr(newLit($n),
          newCall(ident"%", newCall(ident"default", argTypes[i])))
      sampleBody = newCall(ident"%*", table)
    let sampleProc = newProc(
      params = [ident"JsonNode"], body = newStmtList(sampleBody),
      procType = nnkLambda)
    result.add newCall(ident"registerRpc", newNimNode(nnkObjConstr).add(
      ident"RpcEndpoint",
      newColonExpr(ident"name", endpointLit),
      newColonExpr(ident"handler", handler),
      newColonExpr(ident"params", prefix(paramList, "@")),
      newColonExpr(ident"isAction", newLit(opts.isAction)),
      newColonExpr(ident"target", opts.target),
      newColonExpr(ident"auth", opts.auth),
      newColonExpr(ident"csrf", opts.csrf),
      newColonExpr(ident"contextScope", opts.contextScope),
      newColonExpr(ident"sample", sampleProc)))

macro server*(args: varargs[untyped]): untyped =
  ## Makes a proc a server function (see the module documentation).
  ## `{.server.}`, `{.server(auth = aSession).}`, `{.server, action.}`.
  if args.len == 0:
    error("{.server.} must be applied to a proc")
  var opts: seq[NimNode]
  for i in 0 ..< args.len - 1:
    opts.add args[i]
  genServerFn(args[^1], opts, isAction = false)

macro action*(args: varargs[untyped]): untyped =
  ## A server function that also takes no-JS form submissions (see the
  ## module documentation).  `{.action.}`, `{.action(target = "/done").}`.
  if args.len == 0:
    error("{.action.} must be applied to a proc")
  var opts: seq[NimNode]
  for i in 0 ..< args.len - 1:
    opts.add args[i]
  genServerFn(args[^1], opts, isAction = true)
