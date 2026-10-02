## isonim/routing/route_dispatch.nim
##
## The server dispatch `routeManifest` generates (C target).
##
## For each request, `dispatchRoutes`:
##
## 1. matches the path against the manifest's patterns.  A path no entry
##    matches is `404`; a path that matches only entries of other methods is
##    `405` with `Allow` (a `GET` entry also serves `HEAD`);
## 2. runs the matched entry:
##    * `rpc`: the server-function dispatch (rpc.nim `dispatchRpc`);
##    * `any`: the raw handler;
##    * pages and data routes (`runRoute`): decode and validate the request
##      object from the path parameters, the query and the body (`400`;
##      unknown body fields are rejected, unknown query parameters
##      ignored), then authentication, CSRF and the client context
##      (`401`/`403`/`409`), then the canonicalization hook (which runs
##      after authorization and may answer `301` or `404`), then the
##      handler, then the cache policy's headers on its response.  A
##      progressive entry submitted by a no-JS form answers `303` to its
##      target.
##
## Responses the pipeline produces itself carry `Cache-Control: private,
## no-store`, so no cache keeps a refusal.

import std/[asyncdispatch, json, options, strutils]
import ../server/[context, rpc]
import match, route_spec

export route_spec

type
  CanonicalOutcomeKind* = enum
    coContinue   ## the URL is canonical: run the handler
    coRedirect   ## redirect to `location` with `status` (301 by default)
    coNotFound   ## the caller may not see the target: 404, nothing revealed

  CanonicalOutcome* = object
    kind*: CanonicalOutcomeKind
    location*: string
    status*: int

  Canonicalizer* = proc(ctx: RequestContext; route: string;
                        policy: CanonicalPolicy): Future[CanonicalOutcome]
    ## Stage 3 and 4 of URL-Schema.md §3.1 for entries with a `canonical`
    ## policy: authorize the target, then compare the URL with the
    ## canonical one.

  RouteRunner* = proc(ctx: RequestContext): Future[void]
    ## One entry's decode-check-handle-encode pipeline (generated).

  CompiledRoute* = object
    spec*: RouteSpec
    pattern*: RoutePattern
    run*: RouteRunner        ## nil: the application gave no handler (501)

var canonicalizer* {.threadvar.}: Canonicalizer
  ## The application's canonicalization hook.  Without one, entries with a
  ## `canonical` policy run as if their URL were canonical.

proc canonicalContinue*(): CanonicalOutcome =
  CanonicalOutcome(kind: coContinue)

proc canonicalRedirect*(location: string; status = 301): CanonicalOutcome =
  CanonicalOutcome(kind: coRedirect, location: location, status: status)

proc canonicalNotFound*(): CanonicalOutcome =
  CanonicalOutcome(kind: coNotFound)

# --------------------------------------------------------------------------
# Request decoding
# --------------------------------------------------------------------------

proc lookupAll(pairs: seq[(string, string)]; name: string): seq[string] =
  for (k, v) in pairs:
    if k == name:
      result.add v

proc decodeField[F](field: var F; name: string; pathParams,
                    query: seq[(string, string)]; body: JsonNode) =
  let fromPath = lookupAll(pathParams, name)
  let fromQuery = lookupAll(query, name)
  let inBody = body != nil and body.kind == JObject and body.hasKey(name)
  when F is Option:
    type Inner = typeof(default(F).get)
    if fromPath.len > 0:
      field = some(fromArg[Inner](newJString(fromPath[0]), name))
    elif inBody and body[name].kind != JNull:
      field = some(fromArg[Inner](body[name], name))
    elif fromQuery.len > 0:
      field = some(fromArg[Inner](newJString(fromQuery[0]), name))
    else:
      field = none(Inner)
  elif F is seq and not (F is string):
    type Item = typeof(default(F)[0])
    if inBody:
      if body[name].kind != JArray:
        raise newException(RpcBadRequest, "field '" & name & "': expected an array")
      for item in body[name]:
        field.add fromArg[Item](item, name)
    else:
      for v in fromQuery:
        field.add fromArg[Item](newJString(v), name)
  else:
    if fromPath.len > 0:
      field = fromArg[F](newJString(fromPath[0]), name)
    elif inBody:
      field = fromArg[F](body[name], name)
    elif fromQuery.len > 0:
      field = fromArg[F](newJString(fromQuery[0]), name)
    else:
      raise newException(RpcBadRequest, "field '" & name & "': missing")

proc decodeRequest*[T](pathParams, query: seq[(string, string)];
                       body: JsonNode): T =
  ## Fills the request object: each field from the path parameter of its
  ## name, else the body field, else the query parameter.  A missing
  ## field is an error unless it is an `Option` or a `seq`; a body field
  ## the type does not have is an error; query parameters it does not have
  ## are ignored.
  var known: seq[string]
  for name, field in result.fieldPairs:
    known.add name
    decodeField(field, name, pathParams, query, body)
  if body != nil and body.kind == JObject:
    for k in body.keys:
      if k notin known:
        raise newException(RpcBadRequest, "unknown field '" & k & "'")

# --------------------------------------------------------------------------
# One entry
# --------------------------------------------------------------------------

proc prepare(ctx: RequestContext; spec: RouteSpec;
             body: var JsonNode; formToken: var string): bool =
  ## Decodes the body of a state-changing request.  False (and a 400) on
  ## a malformed one.
  if spec.httpMethod in ["GET", "HEAD"]:
    return true
  try:
    (body, formToken) = decodeRpcBody(ctx.request)
  except RpcBadRequest as e:
    ctx.respondError(400, "bad_request", e.msg)
    return false
  true

proc canonicalStage(ctx: RequestContext;
                    spec: RouteSpec): Future[bool] {.async.} =
  ## False when the canonicalization answered instead of the handler.
  if spec.canonical == ccNone or canonicalizer.isNil:
    return true
  let outcome = await canonicalizer(ctx, spec.name, spec.canonical)
  case outcome.kind
  of coContinue:
    return true
  of coNotFound:
    ctx.respondError(404, "not_found")
    return false
  of coRedirect:
    ctx.responseBody.setLen(0)
    for (k, v) in cacheHeaders(spec.cache):
      ctx.response.setHeader(k, v)
    ctx.response.redirect(outcome.location,
                          if outcome.status == 0: 301 else: outcome.status)
    return false

proc runRoute*[Req, Resp](ctx: RequestContext; spec: RouteSpec;
    handler: proc(ctx: RequestContext; req: Req): Future[Resp]): Future[void] {.async.} =
  ## The pipeline of a page or data entry around its handler.
  var body: JsonNode = nil
  var formToken = ""
  if not ctx.prepare(spec, body, formToken):
    return
  var req: Req
  try:
    req = decodeRequest[Req](ctx.pathParams, ctx.request.queryParams, body)
  except RpcBadRequest as e:
    ctx.respondError(400, "bad_request", e.msg)
    return
  if not await ctx.enforcePolicies(spec.name, spec.auth, spec.csrf, formToken):
    return
  if not await ctx.canonicalStage(spec):
    return
  var resp: Resp
  try:
    resp = await handler(ctx, req)
  except RpcBadRequest as e:
    ctx.respondError(400, "bad_request", e.msg)
    return
  except CatchableError as e:
    ctx.failure = e
    ctx.responseBody.setLen(0)
    ctx.respondError(500, "internal")
    return
  ctx.applyCachePolicy(spec.cache)
  if ctx.response.isRedirect:
    return
  if spec.progressive and ctx.isNoJsFormSubmission():
    ctx.redirectAfterPost(spec.target)
    return
  when Resp is Page:
    ctx.response.contentType = "text/html; charset=utf-8"
    # The page's data goes in before </body> (at the end without one).
    let script = pageDataScript($(%resp.data))
    let at = resp.html.rfind("</body>")
    ctx.responseBody =
      if at >= 0: resp.html[0 ..< at] & script & resp.html[at .. ^1]
      else: resp.html & script
  else:
    ctx.response.contentType = "application/json"
    ctx.responseBody = $(%resp)

proc runAny*(ctx: RequestContext; spec: RouteSpec;
             handler: proc(ctx: RequestContext): Future[void]): Future[void] {.async.} =
  ## An `any` entry: authentication, CSRF (state-changing methods) and the
  ## client context, then the raw handler, which owns the response.
  var body: JsonNode = nil
  var formToken = ""
  if isStateChanging(ctx.request.httpMethod) and
      ctx.request.mediaType == "application/x-www-form-urlencoded":
    try:
      (body, formToken) = decodeRpcBody(ctx.request)
    except RpcBadRequest as e:
      ctx.respondError(400, "bad_request", e.msg)
      return
  if not await ctx.enforcePolicies(spec.name, spec.auth, spec.csrf, formToken):
    return
  try:
    await handler(ctx)
  except CatchableError as e:
    ctx.failure = e
    ctx.responseBody.setLen(0)
    ctx.respondError(500, "internal")
    return
  ctx.applyCachePolicy(spec.cache)

# --------------------------------------------------------------------------
# The manifest
# --------------------------------------------------------------------------

proc compileRoute*(spec: RouteSpec; run: RouteRunner): CompiledRoute =
  CompiledRoute(spec: spec, pattern: parsePattern(spec.path), run: run)

proc matchRoute(r: CompiledRoute; path: string): MatchResult =
  if r.spec.kind == rkRpc:
    if path == r.spec.path or path.startsWith(r.spec.path & "/"):
      return MatchResult(matched: true)
    return MatchResult(matched: false)
  if r.spec.prefix: matchPrefix(r.pattern, path)
  else: matchPath(r.pattern, path)

proc methodMatches(spec: RouteSpec; httpMethod: string): bool =
  spec.httpMethod == "*" or spec.httpMethod == httpMethod or
    (spec.httpMethod == "GET" and httpMethod == "HEAD")

proc dispatchRoutes*(routes: seq[CompiledRoute];
                     ctx: RequestContext): Future[void] {.async.} =
  ## Serves one request from the manifest.  The response is left in `ctx`.
  let path = ctx.request.path
  let httpMethod = ctx.request.httpMethod
  var allowed: seq[string]
  for r in routes:
    let m = r.matchRoute(path)
    if not m.matched:
      continue
    if not r.spec.methodMatches(httpMethod):
      if r.spec.httpMethod notin allowed:
        allowed.add r.spec.httpMethod
        if r.spec.httpMethod == "GET":
          allowed.add "HEAD"
      continue
    ctx.pathParams = m.params
    if r.spec.kind == rkRpc:
      await dispatchRpc(ctx, r.spec.path)
      return
    ctx.echoContextHeader()
    if r.run.isNil:
      ctx.respondError(501, "not_implemented", r.spec.name)
      return
    await r.run(ctx)
    return
  if allowed.len > 0:
    ctx.response.setHeader("Allow", allowed.join(", "))
    ctx.respondError(405, "method_not_allowed")
  else:
    ctx.respondError(404, "not_found")
