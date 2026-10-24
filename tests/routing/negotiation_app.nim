## negotiation_app.nim
##
## The server side of negotiation_manifest.nim, compiled into the nginx
## fixture's module by tests/nginx/fixture_app.nim (the async app
## `negotiation`, served at `/neg/`).  What each target does:
##
## `nArticle` (`/neg/a/:slug/:id`, canonical slug `article-<id>`):
##
## * id 13: the caller may not see it; the hook sets a probe header, then
##   answers `coNotFound` (the probe must not survive);
## * id 5: a private target; the hook makes the response
##   `cpPrivateNoStore`, then redirects a wrong slug (keeping `.json`) or
##   continues; the handler then asks for the entry's `cpPrivateRevalidate`
##   (refused: weaker than the response's policy) and reports the answer in
##   `X-Handler-Override`;
## * id 3: the hook continues; the handler finds the target gone: it sets a
##   probe header and a cookie, then raises `RouteNotFound`;
## * any other id: a public target, the entry's policy; a wrong slug is a
##   301 to the canonical path (keeping `.json`).
##
## `nPlain` (`/neg/p/:id`): no hook; for id 7 the handler asks for the
## undeclared `cpPrivateNoStore` (refused) and reports it in
## `X-Handler-Override`.
##
## `nLocked` (`/neg/locked/:id`, a `cpPrivateNoStore` entry): the hook asks
## for `cpPrivateRevalidate`, which is refused, and reports the answer in
## `X-Override`.
##
## `nRaw` (`/neg/raw/:id`): id 3 raises `RouteNotFound` after setting a
## probe header; any other id answers `raw <id>`.
##
## `nRawCached` (`/neg/rc/:id`, a `cpMediaRevalidate` entry declaring
## `cpPrivateRevalidate` and `cpPrivateNoStore`): the handler asks for
##
## * id 2: `cpPrivateRevalidate` (accepted: stricter, declared);
## * id 4: `cpPrivateNoStore` (accepted), then `cpPrivateRevalidate`
##   (refused: weaker than the response's policy);
## * id 6: `cpNone` (refused: weaker than the entry's, and undeclared);
## * any other id: nothing (the entry's policy);
##
## and reports each answer in `X-Handler-Override` (comma-separated, in
## order), then answers `rc <id>`.
##
## `nRefusals`: every refusal `serverHooks.onCachePolicyRefused` was told
## of (`recordCacheRefusal`), in order; the fixture runs one worker, so the
## list is the server's.

import std/[asyncdispatch, strutils]
import isonim/routing/route_dispatch
import isonim/server/context
import negotiation_manifest

export negotiation_manifest

var refusals {.threadvar.}: seq[string]

proc recordCacheRefusal*(ctx: RequestContext; requested, kept: CachePolicy) =
  ## The fixture's `serverHooks.onCachePolicyRefused`.
  refusals.add $requested & " kept " & $kept & " at " & ctx.request.path

proc isNegotiationRoute*(route: string): bool =
  ## Whether the canonicalization hook is asked about one of this
  ## manifest's entries (the fixture has one hook for both manifests).
  for s in routeSpecs(NegotiationRoute):
    if s.name == route: return true
  false

proc articleLocation(id: string): string = "/neg/a/article-" & id & "/" & id

proc negotiationCanonicalizer*(ctx: RequestContext; route: string;
                               policy: CanonicalPolicy): Future[CanonicalOutcome] {.async.} =
  let id = ctx.pathParam("id")
  case route
  of "nArticle":
    if id == "13":
      ctx.response.setHeader("X-Hook-Probe", "set-before-not-found")
      return canonicalNotFound()      # authorization of the target first
    if id == "5":
      discard ctx.setCachePolicy(cpPrivateNoStore)
    if ctx.pathParam("slug") != "article-" & id:
      return canonicalRedirect(ctx.keepPageVariant(articleLocation(id)))
    return canonicalContinue()
  of "nLocked":
    let accepted = ctx.setCachePolicy(cpPrivateRevalidate)
    ctx.response.setHeader("X-Override", if accepted: "accepted" else: "refused")
    return canonicalContinue()
  else:
    return canonicalContinue()

proc articlePage(ctx: RequestContext; req: ArticleRequest): Future[Page[ArticleResponse]] {.async.} =
  if req.id == 3:
    ctx.response.setHeader("X-Handler-Probe", "set-before-not-found")
    ctx.response.setCookie("probe", "1")
    routeNotFound()
  if req.id == 5:
    let accepted = ctx.setCachePolicy(cpPrivateRevalidate)
    ctx.response.setHeader("X-Handler-Override",
                           if accepted: "accepted" else: "refused")
  return Page[ArticleResponse](
    html: "<!doctype html><html><body><h1>article " & $req.id &
          "</h1></body></html>",
    data: ArticleResponse(id: req.id, title: "article " & $req.id))

proc plainPage(ctx: RequestContext; req: PlainRequest): Future[Page[PlainResponse]] {.async.} =
  if req.id == 7:
    let accepted = ctx.setCachePolicy(cpPrivateNoStore)
    ctx.response.setHeader("X-Handler-Override",
                           if accepted: "accepted" else: "refused")
  return Page[PlainResponse](html: "<!doctype html><title>plain</title>",
                             data: PlainResponse(id: req.id))

proc lockedPage(ctx: RequestContext; req: LockedRequest): Future[Page[LockedResponse]] {.async.} =
  return Page[LockedResponse](html: "<!doctype html><title>locked</title>",
                              data: LockedResponse(id: req.id))

proc rawHandler(ctx: RequestContext): Future[void] {.async.} =
  let id = ctx.pathParam("id")
  if id == "3":
    ctx.response.setHeader("X-Handler-Probe", "set-before-not-found")
    routeNotFound()
  ctx.response.contentType = "text/plain"
  ctx.write "raw " & id

proc rawCachedHandler(ctx: RequestContext): Future[void] {.async.} =
  let id = ctx.pathParam("id")
  let asks =
    case id
    of "2": @[cpPrivateRevalidate]
    of "4": @[cpPrivateNoStore, cpPrivateRevalidate]
    of "6": @[cpNone]
    else: @[]
  var answers: seq[string]
  for p in asks:
    answers.add(if ctx.setCachePolicy(p): "accepted" else: "refused")
  if answers.len > 0:
    ctx.response.setHeader("X-Handler-Override", answers.join(","))
  ctx.response.contentType = "text/plain"
  ctx.write "rc " & id

proc negotiationApp*(): RequestHandler =
  manifestApp(NegotiationRouteHandlers(
    nArticle: articlePage,
    nPlain: plainPage,
    nLocked: lockedPage,
    nRaw: rawHandler,
    nRawCached: rawCachedHandler,
    nRefusals: proc(ctx: RequestContext; req: RefusalsRequest): Future[RefusalsResponse] {.async.} =
      return RefusalsResponse(refusals: refusals)))
