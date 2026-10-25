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
##      handler, then the headers of the response's cache policy on its
##      response.  A progressive entry submitted by a no-JS form answers
##      `303` to its target.
##
## The contract is isonim-routing-server-functions.md, "Typed Route
## Manifest".  Four parts of it live here:
##
## * **JSON variants of a page** (`json = true`): a `.json` suffix on the
##   last path parameter is removed before decoding and the hook
##   (`pvJsonSuffix`); without it, `Accept` decides after the hook
##   (`pvJsonAccept`, `prefersJson`).  A JSON answer is `Page.data` as JSON;
##   every 2xx answer of such a page has `Vary` naming `Accept`;
## * **the per-response cache policy**: the response starts with the
##   entry's `cache` (`beginCachePolicy`), the hook and the handler may make
##   it stricter (`setCachePolicy`, context.nim), and exactly that one
##   policy's headers are written, on the hook's redirect and on the
##   handler's response;
## * **not found**: the hook's `coNotFound` and a `RouteNotFound` raised by
##   the hook or the handler are one answer (`notFound`): the response is
##   put back to what it was before the hook ran, then answered 404;
## * **streaming pages** (`stream = true`, `runStreamRoute`): the handler
##   writes through a `PageStream` over the server's body writer
##   (`ctx.bodyWriter`).  Its first flush is the commit point: the content
##   type, the application's `serverHooks.pageHeaders`, the response's cache
##   policy and `Vary: Accept` are applied just before it, and nothing about
##   the status or headers changes after it (`setCachePolicy` is refused, a
##   failure propagates to the server, which terminates the response).
##   After the handler returns: the page-data script, the hydration
##   bootstrap with the response's nonce (`ctx.hydration`), and the
##   stream's tail.  A JSON variant is never streamed.
##
## Responses the pipeline produces itself carry `Cache-Control: private,
## no-store`, so no cache keeps a refusal.

import std/[asyncdispatch, json, options, strutils]
import ../server/[context, rpc]
# Only the writer: under -d:useFaststreams response_body also exports
# faststreams' outputs (whose buffers define a `Page` of their own).
from ../server/response_body import ResponseBody, write, flush
import ../ssr/markers
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
# Representations (JSON variants of a page)
# --------------------------------------------------------------------------

const jsonSuffix = ".json"

proc parseQuality(params: openArray[string]): float =
  ## The `q` weight of a media range's parameters (RFC 9110 §12.4.2): 1
  ## without one, -1 when it is not a valid qvalue (the range is ignored).
  result = 1.0
  for p in params:
    let kv = p.strip.split('=', 1)
    if kv.len == 2 and cmpIgnoreCase(kv[0].strip, "q") == 0:
      let v = kv[1].strip
      # qvalue = ( "0" [ "." 0*3DIGIT ] ) / ( "1" [ "." 0*3("0") ] )
      if v.len == 0 or v.len > 5 or v[0] notin {'0', '1'} or
          (v.len > 1 and v[1] != '.'):
        return -1.0
      for c in v[min(2, v.len) .. ^1]:
        if c notin {'0'..'9'}: return -1.0
      try:
        result = parseFloat(v)
      except ValueError:
        return -1.0
      if result > 1.0: return -1.0

proc acceptQuality(accept, mediaType: string): float =
  ## The quality `accept` gives `mediaType` (`type/subtype`): that of the
  ## most specific media range matching it (`type/subtype` over `type/*`
  ## over `*/*`, RFC 9110 §12.5.1); 0 when no range matches.  Media-range
  ## parameters other than `q` are not compared.
  let wanted = mediaType.toLowerAscii.split('/', 1)
  var best = -1     # the specificity of the range chosen so far
  result = 0.0
  for item in accept.split(','):
    let parts = item.split(';')
    let range = parts[0].strip.toLowerAscii
    let tr = range.split('/', 1)
    if tr.len != 2 or tr[0].len == 0 or tr[1].len == 0:
      continue
    let specificity =
      if tr[0] == wanted[0] and tr[1] == wanted[1]: 3
      elif tr[0] == wanted[0] and tr[1] == "*": 2
      elif tr[0] == "*" and tr[1] == "*": 1
      else: 0
    if specificity == 0 or specificity <= best:
      continue
    let q = parseQuality(parts[1 .. ^1])
    if q < 0:
      continue
    best = specificity
    result = q

proc prefersJson*(accept: string): bool =
  ## Whether a request with this `Accept` gets a page's JSON variant:
  ## `application/json` has a higher quality than `text/html`.  A tie
  ## (`*/*`, or no `Accept`) is HTML.
  let a = if accept.strip.len == 0: "*/*" else: accept
  acceptQuality(a, "application/json") > acceptQuality(a, "text/html")

proc takeJsonSuffix(ctx: RequestContext; spec: RouteSpec) =
  ## For a page with a JSON variant: removes `.json` from the last path
  ## parameter and records `pvJsonSuffix`.
  ctx.pageVariant = pvHtml
  if spec.kind != rkPage or not spec.json:
    return
  let names = patternParams(spec.path)
  if names.len == 0:
    return
  let last = names[^1]
  for i in countdown(ctx.pathParams.high, 0):
    if ctx.pathParams[i][0] == last:
      let v = ctx.pathParams[i][1]
      if v.len > jsonSuffix.len and v.endsWith(jsonSuffix):
        ctx.pathParams[i][1] = v[0 ..< v.len - jsonSuffix.len]
        ctx.pageVariant = pvJsonSuffix
      return

proc addVaryAccept(ctx: RequestContext) =
  ## `Vary` names `Accept` (appended to the policy's fields).
  let vary = ctx.response.header("Vary")
  for f in vary.split(','):
    if cmpIgnoreCase(f.strip, "Accept") == 0 or f.strip == "*":
      return
  ctx.response.setHeader("Vary", if vary.strip.len > 0: vary & ", Accept"
                                 else: "Accept")

# --------------------------------------------------------------------------
# One entry
# --------------------------------------------------------------------------

proc notFound(ctx: RequestContext; before: ResponseSnapshot) =
  ## The one not-found answer of a route (the hook's `coNotFound`, or
  ## `RouteNotFound` from the hook or the handler): nothing set since
  ## `before` is kept, then 404 with the pipeline's error body and
  ## `Cache-Control: private, no-store`.
  ctx.response.restore(before)
  ctx.responseBody.setLen(0)
  ctx.respondError(404, "not_found")

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

proc canonicalStage(ctx: RequestContext; spec: RouteSpec;
                    before: ResponseSnapshot): Future[bool] {.async.} =
  ## False when the canonicalization answered instead of the handler.
  if spec.canonical == ccNone or canonicalizer.isNil:
    return true
  var outcome: CanonicalOutcome
  try:
    outcome = await canonicalizer(ctx, spec.name, spec.canonical)
  except RouteNotFound:
    outcome = canonicalNotFound()
  case outcome.kind
  of coContinue:
    return true
  of coNotFound:
    ctx.notFound(before)
    return false
  of coRedirect:
    ctx.responseBody.setLen(0)
    # The response's policy: the entry's, or what the hook set for it.
    ctx.applyCachePolicy(ctx.responseCachePolicy)
    ctx.response.redirect(outcome.location,
                          if outcome.status == 0: 301 else: outcome.status)
    return false

type
  Prelude[Req] = object
    ## What the stages before a page's or data entry's handler leave it.
    ok: bool                 ## false: the pipeline already answered
    req: Req
    before: ResponseSnapshot ## the response before the hook ran

proc routePrelude[Req](ctx: RequestContext;
                       spec: RouteSpec): Future[Prelude[Req]] {.async.} =
  ## The stages before the handler: the cache policy, the `.json` suffix,
  ## request decoding (`400`), authentication, CSRF and the client context,
  ## the canonicalization hook, and the `Accept` negotiation.
  var body: JsonNode = nil
  var formToken = ""
  ctx.beginCachePolicy(spec.cache, spec.cacheOverrides)
  ctx.takeJsonSuffix(spec)
  if not ctx.prepare(spec, body, formToken):
    return
  try:
    result.req = decodeRequest[Req](ctx.pathParams, ctx.request.queryParams, body)
  except RpcBadRequest as e:
    ctx.respondError(400, "bad_request", e.msg)
    return
  if not await ctx.enforcePolicies(spec.name, spec.auth, spec.csrf, formToken):
    return
  # What the response was before the hook and the handler ran: a not-found
  # answer goes back to it.
  let before = ctx.response.snapshot()
  if not await ctx.canonicalStage(spec, before):
    return
  result.before = before
  # `Accept` is read only now, so the hook's answer cannot depend on it.
  if spec.kind == rkPage and spec.json and ctx.pageVariant == pvHtml and
      prefersJson(ctx.request.header("Accept")):
    ctx.pageVariant = pvJsonAccept
  result.ok = true

proc failBeforeCommit(ctx: RequestContext; e: ref CatchableError;
                      before: ResponseSnapshot) =
  ## A handler's exception while nothing is sent: the pipeline's answer.
  if e of RouteNotFound:
    ctx.notFound(before)
  elif e of RpcBadRequest:
    ctx.respondError(400, "bad_request", e.msg)
  else:
    ctx.failure = e
    ctx.responseBody.setLen(0)
    ctx.respondError(500, "internal")

proc answerJsonVariant[T](ctx: RequestContext; spec: RouteSpec; data: T) =
  ## A page's JSON answer (after the handler, its cache policy applied).
  if spec.json and ctx.response.status in 200 .. 299:
    # The same URL answers HTML and JSON (by Accept).
    ctx.addVaryAccept()
  ctx.response.contentType = "application/json"
  ctx.responseBody = $(%data)

proc runRoute*[Req, Resp](ctx: RequestContext; spec: RouteSpec;
    handler: proc(ctx: RequestContext; req: Req): Future[Resp]): Future[void] {.async.} =
  ## The pipeline of a page or data entry around its handler.
  let pre = await routePrelude[Req](ctx, spec)
  if not pre.ok:
    return
  var resp: Resp
  try:
    resp = await handler(ctx, pre.req)
  except CatchableError as e:
    ctx.failBeforeCommit(e, pre.before)
    return
  when Resp is Page:
    if not ctx.response.isRedirect and ctx.pageVariant == pvHtml:
      # The application's page headers, before the policy's, so that the
      # policy's are the dispatch's whatever the hook set.
      let hook = serverHooks.pageHeaders
      if hook != nil:
        hook(ctx, spec.name)
  # Exactly one policy: the entry's, or the stricter one the hook or the
  # handler set for this response.
  ctx.applyCachePolicy(ctx.responseCachePolicy)
  if ctx.response.isRedirect:
    return
  if spec.progressive and ctx.isNoJsFormSubmission():
    ctx.redirectAfterPost(spec.target)
    return
  when Resp is Page:
    if ctx.pageVariant != pvHtml:
      ctx.answerJsonVariant(spec, resp.data)
    else:
      if spec.json and ctx.response.status in 200 .. 299:
        ctx.addVaryAccept()
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

# --------------------------------------------------------------------------
# Streaming pages (isonim-routing-server-functions.md, "Streaming Pages")
# --------------------------------------------------------------------------

const defaultPageTail* = "</body></html>"
  ## What a streaming page's dispatch writes last, unless the handler sets
  ## `page.tail`.

type
  PageStream* = ref object
    ## A streaming page's HTML on its way to the client.  `write` queues,
    ## `flush` sends; the first flush commits the response's status and
    ## headers.  Nothing queued reaches the server before a flush, so a
    ## handler that fails before its first flush is answered by the
    ## pipeline (404, 400, 500) with none of its HTML.
    ctx: RequestContext
    spec: RouteSpec
    pending: string
    committed: bool
    discarding: bool   ## a JSON variant: the HTML is not sent
    tail*: string
      ## The closing markup the dispatch writes after the page-data and
      ## bootstrap scripts (default `defaultPageTail`).

proc committed*(page: PageStream): bool =
  ## Whether the first flush has happened (the headers are committed).
  page.committed

proc write*(page: PageStream; html: string) =
  ## Queues `html`; it is sent at the next `flush` (or when the handler
  ## returns).  A JSON variant's stream discards it.
  if not page.discarding:
    page.pending.add html

proc emit(page: PageStream; flush: bool) =
  ## Hands what is queued to the server: its body writer (flushed when
  ## `flush`), or, on a server that does not stream, the context's body.
  let ctx = page.ctx
  if page.pending.len > 0 or flush:
    let w = ctx.bodyWriter
    let data = move page.pending
    page.pending = ""
    if w.isNil:
      ctx.responseBody.add data
    else:
      if data.len > 0:
        w.write(data)
      if flush:
        w.flush()

proc commitHeaders(page: PageStream) =
  ## The response's headers, just before they are sent: the content type,
  ## the application's page headers, exactly one cache policy's headers and
  ## (for a page with a JSON variant) `Vary` naming `Accept`.  From now on
  ## the cache policy cannot change.
  let ctx = page.ctx
  ctx.response.contentType = "text/html; charset=utf-8"
  let hook = serverHooks.pageHeaders
  if hook != nil:
    hook(ctx, page.spec.name)
  ctx.applyCachePolicy(ctx.responseCachePolicy)
  if page.spec.json and ctx.response.status in 200 .. 299:
    ctx.addVaryAccept()
  ctx.fixCachePolicy()
  page.committed = true

proc flush*(page: PageStream) =
  ## Sends what is queued.  The first flush commits the response: its
  ## headers are applied, then the server sends them with the queued HTML.
  ## Raises `ValueError` on a redirected response (a redirect has no body),
  ## and what the server's writer raises (`ClientConnectionError`,
  ## `ResponseTooLargeError`).  A JSON variant's stream does nothing.
  if page.discarding:
    return
  let ctx = page.ctx
  if not page.committed:
    if ctx.response.isRedirect:
      raise newException(ValueError, "the page redirected to " &
        ctx.response.location & "; a redirect carries no body")
    page.commitHeaders()
    if ctx.bodyWriter.isNil:
      # No server writer: the bytes stay in the context, but the response
      # is fixed exactly as a streaming server would have fixed it.
      ctx.response.markCommitted()
  page.emit(flush = true)

proc shell*(page: PageStream; html: string) =
  ## Writes the document shell and flushes it: the commit point.  Call it
  ## before the first read, so the client gets the shell while the data
  ## is read.
  page.write(html)
  page.flush()

proc newPageStream(ctx: RequestContext; spec: RouteSpec): PageStream =
  PageStream(ctx: ctx, spec: spec, tail: defaultPageTail,
             discarding: ctx.pageVariant != pvHtml)

proc finishStream[T](page: PageStream; data: T) =
  ## After the handler returned: the page-data script, the hydration
  ## bootstrap (with the response's CSP nonce) when the server enables it,
  ## and the tail.  The server ends the response.
  let ctx = page.ctx
  if not page.committed:
    page.commitHeaders()
  page.pending.add pageDataScript($(%data))
  if ctx.hydration:
    page.pending.add generateHydrationScript(nonce = ctx.response.cspNonce)
  page.pending.add page.tail
  page.emit(flush = false)

proc runStreamRoute*[Req, Resp](ctx: RequestContext; spec: RouteSpec;
    handler: proc(ctx: RequestContext; req: Req;
                  page: PageStream): Future[Resp]): Future[void] {.async.} =
  ## The pipeline of a streaming page around its handler (see
  ## "Streaming pages" in the module documentation).
  let pre = await routePrelude[Req](ctx, spec)
  if not pre.ok:
    return
  let page = newPageStream(ctx, spec)
  var data: Resp
  try:
    data = await handler(ctx, pre.req, page)
  except CatchableError as e:
    if page.committed:
      # The headers are sent: no 404, 400 or 500 can be answered any more.
      # The server terminates the response and logs the error.
      raise e
    ctx.failBeforeCommit(e, pre.before)
    return
  if page.discarding:
    # A JSON variant: answered whole, as for a Page.
    ctx.applyCachePolicy(ctx.responseCachePolicy)
    if ctx.response.isRedirect:
      return
    ctx.answerJsonVariant(spec, data)
    return
  if ctx.response.isRedirect and not page.committed:
    page.pending.setLen(0)
    ctx.applyCachePolicy(ctx.responseCachePolicy)
    return
  page.finishStream(data)

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
  ctx.beginCachePolicy(spec.cache, spec.cacheOverrides)
  if not await ctx.enforcePolicies(spec.name, spec.auth, spec.csrf, formToken):
    return
  let before = ctx.response.snapshot()
  try:
    await handler(ctx)
  except RouteNotFound:
    ctx.notFound(before)
    return
  except CatchableError as e:
    ctx.failure = e
    ctx.responseBody.setLen(0)
    ctx.respondError(500, "internal")
    return
  ctx.applyCachePolicy(ctx.responseCachePolicy)

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
