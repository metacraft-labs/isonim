## isonim/routing/manifest.nim
##
## The typed route manifest: one declaration per route, from which the
## server dispatch, the typed browser clients, the progressive-enhancement
## forms and the per-route policy tests are generated
## (pilot-projects/isonim-forum/URL-Schema.md §5).
##
## ```nim
## import isonim/routing/manifest
##
## routeManifest ForumRoute:
##   page   rHome,       "/"
##   page   rTopic,      "/t/:slug/:id", canonical = ccTopicSlug
##   get    rTopicPosts, "/t/:id/posts", TopicPostsQuery, PostRangeResponse
##   post   rTimings,    "/topics/timings", TimingsBatch, TimingsAck,
##          auth = aSession, csrf = csrfSession, cache = cpPrivateNoStore,
##          contextScope = csAccount
##   action rSubscribe,  "/subscribe", SubscribeForm, SubscribeResult,
##          csrf = csrfAnon, target = "/thanks"
##   rpc    rRpc,        "/api/v1/rpc"
##   any    rExtension,  "/api/v1/ext/:key", prefix = true, csrf = csrfSession
## ```
##
## **Entries.**  `page` (an SSR page, `GET`), `get`, `post`, `put`, `patch`,
## `delete`, `action` (a `post` with `progressive = true`), `rpc` (the mount
## of the `{.server.}` functions: one `POST` entry per server function,
## each with its own policies) and `any` (a raw handler for every method).
## Each entry is `kind name, "pattern"`, then optionally the request and
## the response type, then options:
##
## | Option | Default | |
## | :--- | :--- | :--- |
## | `auth` | `aOptional` | `AuthPolicy` |
## | `csrf` | `csrfNone` | `CsrfPolicy`; a state-changing entry must declare one other than `csrfNone` (a compile-time error otherwise) |
## | `cache` | `cpPrivateRevalidate` | `CachePolicy` |
## | `canonical` | `ccNone` | `CanonicalPolicy`: the canonicalization hook runs after authorization |
## | `contextScope` | `csNavigation` for `GET`, `csAccount` otherwise | URL-Schema.md §5.4 |
## | `prefix` | `false` | the pattern also matches every path below it |
## | `progressive` | `false` (`true` for `action`) | a `POST` a no-JS form may submit |
## | `target` | `""` | where a progressive entry's no-JS form is redirected (303); "" = the same-origin `Referer`, else `/` |
##
## Omitted types are named after the entry: `rTopic` uses `TopicRequest`
## and `TopicResponse` (a page's handler returns `Page[TopicResponse]`).
## A request type is a plain object: its fields are filled from the path
## parameters of the same name, then the body, then the query.
##
## **Generated, both targets.**  The enum `ForumRoute`;
## `routeSpecs(ForumRoute)` and `spec(r)` (the declared entries as
## `RouteSpec`); `<name>Path(req)` for every page and data entry.
##
## **Generated, C target.**  `ForumRouteHandlers`, an object with one
## handler field per page, data and `any` entry, and
## `manifestApp(handlers)`, the server dispatch (route_dispatch.nim) as a
## `RequestHandler`; `<name>Form(ctx, req, inner)` for each progressive
## entry (a `<form>` with its `action`, `method` and `_csrf` field);
## `policyTests(ForumRoute)`, the per-route policy tests
## (route_policy.nim, run with route_tests.nim).
##
## **Generated, JS target.**  `<name>Call(req): Future[Resp]` for each data
## and mutation entry (fetch, CSRF and context headers, stale responses
## dropped: route_client.nim); `<name>Navigate(req)` and
## `<name>Link(parent, req, text)` for each page.

import std/[macros, strutils, sets]
import route_spec, navigate, client_context
import ../server/[policy, context, rpc]

export route_spec, navigate, client_context, policy, context, rpc

when defined(js):
  import route_client
  export route_client
else:
  import std/asyncdispatch
  import route_dispatch, route_policy
  import ../server/form_action
  export asyncdispatch, route_dispatch, route_policy, form_action

type
  EntryDef = object
    node: NimNode
    kindWord: string
    name: NimNode
    path: string
    kind: RouteKind
    httpMethod: string
    reqType, respType: NimNode
    auth, csrf, cache, canonical, contextScope: NimNode
    prefix, progressive: bool
    target: string

proc derivedTypeName(name, suffix: string): NimNode =
  var base = name
  if base.len > 1 and base[0] == 'r' and base[1] in {'A'..'Z'}:
    base = base[1 .. ^1]
  else:
    base[0] = base[0].toUpperAscii
  ident(base & suffix)

proc boolOption(n: NimNode): bool =
  if n.kind in {nnkIdent, nnkSym} and n.eqIdent("true"): return true
  if n.kind in {nnkIdent, nnkSym} and n.eqIdent("false"): return false
  error("expected true or false", n)

proc parseEntry(stmt: NimNode): EntryDef =
  if stmt.kind notin {nnkCommand, nnkCall} or stmt.len < 3:
    error("a manifest entry is `kind name, \"pattern\", ...`", stmt)
  result.node = stmt
  result.kindWord = $stmt[0]
  result.name = stmt[1]
  if result.name.kind != nnkIdent:
    error("the entry name must be an identifier", result.name)
  if stmt[2].kind notin {nnkStrLit, nnkTripleStrLit, nnkRStrLit}:
    error("the pattern must be a string literal", stmt[2])
  result.path = stmt[2].strVal
  if not result.path.startsWith("/"):
    error("the pattern must start with /", stmt[2])
  case result.kindWord
  of "page": (result.kind, result.httpMethod) = (rkPage, "GET")
  of "get": (result.kind, result.httpMethod) = (rkApi, "GET")
  of "post": (result.kind, result.httpMethod) = (rkApi, "POST")
  of "put": (result.kind, result.httpMethod) = (rkApi, "PUT")
  of "patch": (result.kind, result.httpMethod) = (rkApi, "PATCH")
  of "delete": (result.kind, result.httpMethod) = (rkApi, "DELETE")
  of "action":
    (result.kind, result.httpMethod) = (rkApi, "POST")
    result.progressive = true
  of "rpc": (result.kind, result.httpMethod) = (rkRpc, "POST")
  of "any": (result.kind, result.httpMethod) = (rkAny, "*")
  else:
    error("unknown entry kind `" & result.kindWord & "` (expected page, " &
      "get, post, put, patch, delete, action, rpc or any)", stmt[0])

  var positional: seq[NimNode]
  for i in 3 ..< stmt.len:
    let a = stmt[i]
    if a.kind == nnkExprEqExpr:
      let key = $a[0]
      case key
      of "auth": result.auth = a[1]
      of "csrf": result.csrf = a[1]
      of "cache": result.cache = a[1]
      of "canonical": result.canonical = a[1]
      of "contextScope": result.contextScope = a[1]
      of "prefix": result.prefix = boolOption(a[1])
      of "progressive": result.progressive = boolOption(a[1])
      of "target":
        if a[1].kind notin {nnkStrLit, nnkTripleStrLit, nnkRStrLit}:
          error("`target` must be a string literal", a[1])
        result.target = a[1].strVal
      else:
        error("unknown option `" & key & "`", a)
    else:
      if positional.len == 2:
        error("an entry takes at most a request and a response type", a)
      positional.add a
  let nameStr = $result.name
  if result.kind in {rkRpc, rkAny}:
    if positional.len > 0:
      error("`" & result.kindWord & "` entries declare no types", positional[0])
  else:
    result.reqType = if positional.len > 0: positional[0]
                     else: derivedTypeName(nameStr, "Request")
    result.respType = if positional.len > 1: positional[1]
                      else: derivedTypeName(nameStr, "Response")

  # Policy checks.
  let stateChanging = result.httpMethod notin ["GET", "HEAD"]
  if stateChanging and result.kind != rkRpc:
    if result.csrf.isNil:
      error(nameStr & ": a state-changing entry (" & result.httpMethod &
        ") must declare its CSRF policy (csrfSession, csrfAnon or " &
        "csrfExempt(reason))", stmt)
    if result.csrf.kind in {nnkIdent, nnkSym} and result.csrf.eqIdent("csrfNone"):
      error(nameStr & ": csrfNone is only valid for safe methods; a " &
        result.httpMethod & " entry needs csrfSession, csrfAnon or " &
        "csrfExempt(reason)", result.csrf)
  if result.kind == rkRpc and result.csrf != nil:
    error("the `rpc` entry takes no CSRF policy: each server function " &
      "declares its own", result.csrf)
  if result.progressive and result.httpMethod != "POST":
    error(nameStr & ": only POST entries can be progressive", stmt)
  if result.target.len > 0 and not result.progressive:
    error(nameStr & ": `target` applies to progressive entries only", stmt)

  if result.auth.isNil: result.auth = ident"aOptional"
  if result.csrf.isNil: result.csrf = ident"csrfNone"
  if result.cache.isNil:
    result.cache = (if result.kind == rkRpc: ident"cpPrivateNoStore"
                    else: ident"cpPrivateRevalidate")
  if result.canonical.isNil: result.canonical = ident"ccNone"
  if result.contextScope.isNil:
    result.contextScope = (if stateChanging and result.kind != rkAny:
                             ident"csAccount"
                           else: ident"csNavigation")

proc specConstr(e: EntryDef): NimNode =
  nnkObjConstr.newTree(ident"RouteSpec",
    newColonExpr(ident"name", newLit($e.name)),
    newColonExpr(ident"kind", ident($e.kind)),
    newColonExpr(ident"httpMethod", newLit(e.httpMethod)),
    newColonExpr(ident"path", newLit(e.path)),
    newColonExpr(ident"prefix", newLit(e.prefix)),
    newColonExpr(ident"requestType",
      newLit(if e.reqType.isNil: "" else: e.reqType.repr)),
    newColonExpr(ident"responseType",
      newLit(if e.respType.isNil: "" else: e.respType.repr)),
    newColonExpr(ident"auth", e.auth),
    newColonExpr(ident"csrf", e.csrf),
    newColonExpr(ident"cache", e.cache),
    newColonExpr(ident"canonical", e.canonical),
    newColonExpr(ident"contextScope", e.contextScope),
    newColonExpr(ident"progressive", newLit(e.progressive)),
    newColonExpr(ident"target", newLit(e.target)))

proc handlerType(e: EntryDef): NimNode =
  let ctxDef = newIdentDefs(ident"ctx", ident"RequestContext")
  case e.kind
  of rkAny:
    nnkProcTy.newTree(nnkFormalParams.newTree(
      nnkBracketExpr.newTree(ident"Future", ident"void"), ctxDef), newEmptyNode())
  of rkPage:
    nnkProcTy.newTree(nnkFormalParams.newTree(
      nnkBracketExpr.newTree(ident"Future",
        nnkBracketExpr.newTree(ident"Page", e.respType)),
      ctxDef, newIdentDefs(ident"req", e.reqType)), newEmptyNode())
  else:
    nnkProcTy.newTree(nnkFormalParams.newTree(
      nnkBracketExpr.newTree(ident"Future", e.respType),
      ctxDef, newIdentDefs(ident"req", e.reqType)), newEmptyNode())

macro routeManifest*(enumName: untyped; body: untyped): untyped =
  ## Declares a route manifest (see the module documentation).
  enumName.expectKind(nnkIdent)
  var entries: seq[EntryDef]
  var seen = initHashSet[string]()
  var rpcCount = 0
  for stmt in body:
    if stmt.kind == nnkCommentStmt:
      continue
    let e = parseEntry(stmt)
    if $e.name in seen:
      error("duplicate entry `" & $e.name & "`", e.name)
    seen.incl $e.name
    if e.kind == rkRpc:
      inc rpcCount
      if rpcCount > 1:
        error("a manifest has at most one `rpc` entry", stmt)
    entries.add e
  if entries.len == 0:
    error("an empty route manifest", body)

  let enumStr = $enumName
  result = newStmtList()

  # The enum.
  var enumTy = nnkEnumTy.newTree(newEmptyNode())
  for e in entries:
    enumTy.add e.name
  result.add nnkTypeSection.newTree(nnkTypeDef.newTree(
    postfix(enumName, "*"), newEmptyNode(), enumTy))

  # The specs.
  var specList = nnkBracket.newTree()
  for e in entries:
    specList.add specConstr(e)
  let specsProc = ident"routeSpecs"
  result.add quote do:
    proc `specsProc`*(_: typedesc[`enumName`]): seq[RouteSpec] =
      ## The manifest's entries, in declaration order.
      @`specList`
    proc spec*(r: `enumName`): RouteSpec =
      routeSpecs(`enumName`)[ord(r)]

  # The rpc mount must be where the server-function stubs post to.
  for e in entries:
    if e.kind == rkRpc:
      let p = newLit(e.path)
      let msg = newLit("the rpc entry " & $e.name & " mounts server functions at " &
        e.path & " but they are compiled for rpcPrefix; build with " &
        "-d:isonimRpcPrefix=" & e.path)
      result.add quote do:
        when rpcPrefix != `p`:
          {.error: `msg`.}

  # <name>Path, both targets.
  for e in entries:
    if e.kind in {rkPage, rkApi}:
      let pathProc = ident($e.name & "Path")
      let reqT = e.reqType
      let pat = newLit(e.path)
      result.add quote do:
        proc `pathProc`*(req: `reqT`): string =
          buildPath(`pat`, req)

  var cSide = newStmtList()
  var jsSide = newStmtList()

  # ---- C: handlers, dispatch, forms, policy tests ----
  let handlersName = ident(enumStr & "Handlers")
  var recList = nnkRecList.newTree()
  for e in entries:
    if e.kind in {rkPage, rkApi, rkAny}:
      recList.add newIdentDefs(postfix(e.name, "*"), handlerType(e))
  if recList.len == 0:
    recList.add newIdentDefs(ident"unused", ident"bool")
  cSide.add nnkTypeSection.newTree(nnkTypeDef.newTree(
    postfix(handlersName, "*"), newEmptyNode(),
    nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), recList)))

  let hSym = ident"handlers"
  let routesSym = genSym(nskVar, "routes")
  let specsSym = genSym(nskLet, "specs")
  var build = newStmtList()
  build.add newLetStmt(specsSym, newCall(ident"routeSpecs", enumName))
  build.add nnkVarSection.newTree(newIdentDefs(routesSym,
    nnkBracketExpr.newTree(ident"seq", ident"CompiledRoute")))
  for i, e in entries:
    let s = genSym(nskLet, "spec")
    let h = genSym(nskLet, "handler")
    var blk = newStmtList(newLetStmt(s, nnkBracketExpr.newTree(specsSym, newLit(i))))
    var runner: NimNode
    case e.kind
    of rkRpc:
      runner = newNilLit()
    of rkAny:
      blk.add newLetStmt(h, newDotExpr(hSym, e.name))
      let ctxP = genSym(nskParam, "ctx")
      runner = newProc(params = [nnkBracketExpr.newTree(ident"Future", ident"void"),
                                 newIdentDefs(ctxP, ident"RequestContext")],
                       body = newCall(ident"runAny", ctxP, s, h),
                       procType = nnkLambda)
      runner = nnkIfExpr.newTree(
        nnkElifExpr.newTree(newCall(ident"isNil", h), newNilLit()),
        nnkElseExpr.newTree(runner))
    of rkPage, rkApi:
      blk.add newLetStmt(h, newDotExpr(hSym, e.name))
      let ctxP = genSym(nskParam, "ctx")
      let respT = if e.kind == rkPage: nnkBracketExpr.newTree(ident"Page", e.respType)
                  else: e.respType
      let call = newCall(nnkBracketExpr.newTree(ident"runRoute", e.reqType, respT),
                         ctxP, s, h)
      runner = newProc(params = [nnkBracketExpr.newTree(ident"Future", ident"void"),
                                 newIdentDefs(ctxP, ident"RequestContext")],
                       body = call, procType = nnkLambda)
      runner = nnkIfExpr.newTree(
        nnkElifExpr.newTree(newCall(ident"isNil", h), newNilLit()),
        nnkElseExpr.newTree(runner))
    blk.add newCall(newDotExpr(routesSym, ident"add"),
                    newCall(ident"compileRoute", s, runner))
    build.add nnkBlockStmt.newTree(newEmptyNode(), blk)
  let ctxQ = genSym(nskParam, "ctx")
  build.add newAssignment(ident"result", newProc(
    params = [nnkBracketExpr.newTree(ident"Future", ident"void"),
              newIdentDefs(ctxQ, ident"RequestContext")],
    body = newCall(ident"dispatchRoutes", routesSym, ctxQ),
    procType = nnkLambda))
  cSide.add newProc(name = postfix(ident"manifestApp", "*"),
    params = [ident"RequestHandler", newIdentDefs(hSym, handlersName)],
    body = build)

  # Forms of progressive entries.
  for e in entries:
    if e.progressive:
      let formProc = ident($e.name & "Form")
      let pathProc = ident($e.name & "Path")
      let reqT = e.reqType
      cSide.add quote do:
        proc `formProc`*(ctx: RequestContext; req: `reqT`; inner: string;
                         attrs = ""): string =
          ## The progressive form of this entry: `action`, `method` and the
          ## `_csrf` field of this request's token.
          formHtml(ctx, `pathProc`(req), inner, attrs)

  # Policy tests.
  var samples = nnkBracket.newTree()
  for e in entries:
    if e.kind in {rkPage, rkApi}:
      let pat = newLit(e.path)
      let reqT = e.reqType
      samples.add quote do:
        RouteSample(path: samplePath[`reqT`](`pat`),
                    query: sampleQuery[`reqT`](`pat`),
                    body: sampleBody[`reqT`](`pat`))
    else:
      samples.add quote do: RouteSample()
  cSide.add quote do:
    proc policyTests*(_: typedesc[`enumName`]): seq[RoutePolicyTest] =
      ## The per-route policy tests of this manifest (route_policy.nim).
      buildPolicyTests(routeSpecs(`enumName`), @`samples`)

  # ---- JS: typed clients and navigation ----
  for e in entries:
    let pathProc = ident($e.name & "Path")
    let reqT = e.reqType
    case e.kind
    of rkApi:
      let callProc = ident($e.name & "Call")
      let respT = e.respType
      let m = newLit(e.httpMethod)
      let pat = newLit(e.path)
      let scope = e.contextScope
      jsSide.add quote do:
        proc `callProc`*(req: `reqT`): Future[`respT`] =
          callRoute[`reqT`, `respT`](`m`, `pat`, req, `scope`)
    of rkPage:
      let navProc = ident($e.name & "Navigate")
      let linkProc = ident($e.name & "Link")
      jsSide.add quote do:
        proc `navProc`*(req: `reqT`) =
          navigate(`pathProc`(req))
        proc `linkProc`*[P](parent: P; req: `reqT`; text: string) =
          Link(parent, `pathProc`(req), text)
    else:
      discard

  if jsSide.len == 0:
    jsSide.add nnkDiscardStmt.newTree(newEmptyNode())
  result.add nnkWhenStmt.newTree(
    nnkElifBranch.newTree(newCall(ident"defined", ident"js"), jsSide),
    nnkElse.newTree(cSide))
