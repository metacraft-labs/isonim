## fixture_app.nim
##
## The server side of the nginx fixture (tests/nginx/README.md): compiled
## into the ngx-isonim module with `-d:ngxIsonimAppModule=<this file>`
## (ngx-isonim src/apps.nim calls `registerApps` once per worker) and
## `-d:isonimRpcPrefix=/api/v1/rpc`.
##
## It serves the route manifest of fixture_manifest.nim as the async app
## `fixture` (`isonim_rpc on; isonim_rpc_app fixture;`), and with it the
## server functions of fixture_rpc.nim under `/api/v1/rpc`.
##
## It also serves the SSR -> hydrate round trip of hydration_app.nim (the
## string and streaming renderers `hydration` and `hydration-stream`).
##
## Sessions: the cookie `sid=user|staff|admin` is a session with that role,
## whose CSRF token is `csrf-<sid>`.  Signatures: `X-Signature:
## valid-<route>`.  The instance's incarnation is `inc-1`.
##
## Canonicalization (`rTopic`, `ccTopicSlug`): topic `<id>`'s canonical
## path is `/t/topic-<id>/<id>`; topic 13 is one the caller may not see
## (404, nothing revealed); any other slug is a 301 to the canonical path.

import std/[asyncdispatch, strutils]
import isonim/routing/route_dispatch
from app_registry import registerAsyncApp  # ngx-isonim (src/app_registry.nim)
import isonim/server/[context, rpc]
import isonim/routing/client_context
import fixture_manifest
import hydration_app

const
  instanceId* = "fixture-instance"
  incarnationId* = "inc-1"

proc homePage(ctx: RequestContext; req: HomeRequest): Future[Page[HomeResponse]] {.async.} =
  let token = ctx.csrfTokenFor()
  let html = "<!doctype html><html><head><meta charset=\"utf-8\">" &
    "<title>IsoNim nginx fixture</title>" &
    clientContextMeta(instanceId, incarnationId, token) &
    "</head><body><h1 id=\"title\">IsoNim nginx fixture</h1>" &
    "<p>Value: <span id=\"value\"></span></p>" &
    rSubscribeForm(ctx, SubscribeRequest(),
      "<input name=\"email\" value=\"reader@example.test\">" &
      "<button id=\"subscribe\" type=\"submit\">Subscribe</button>") &
    "<script src=\"/static/client.js\"></script></body></html>"
  return Page[HomeResponse](html: html, data: HomeResponse(title: "home"))

proc otherPage(ctx: RequestContext; req: OtherRequest): Future[Page[OtherResponse]] {.async.} =
  return Page[OtherResponse](html: "<!doctype html><title>other</title>",
                             data: OtherResponse(title: "other"))

proc handlers(): FixtureRouteHandlers =
  FixtureRouteHandlers(
    rHome: homePage,
    rOther: otherPage,
    rTopic: proc(ctx: RequestContext; req: TopicRequest): Future[Page[TopicResponse]] {.async.} =
      return Page[TopicResponse](html: "<!doctype html><title>topic</title>",
                                 data: TopicResponse(id: req.id)),
    rItem: proc(ctx: RequestContext; req: ItemRequest): Future[ItemResponse] {.async.} =
      return ItemResponse(id: req.id, name: "item-" & $req.id),
    rDelayed: proc(ctx: RequestContext; req: DelayedRequest): Future[DelayedResponse] {.async.} =
      await sleepAsync(req.ms)
      return DelayedResponse(value: req.value),
    rDelayedNav: proc(ctx: RequestContext; req: DelayedRequest): Future[DelayedResponse] {.async.} =
      await sleepAsync(req.ms)
      return DelayedResponse(value: req.value),
    rAsset: proc(ctx: RequestContext; req: AssetRequest): Future[AssetResponse] {.async.} =
      return AssetResponse(name: req.name, bytes: req.name.len),
    rHealth: proc(ctx: RequestContext; req: HealthRequest): Future[HealthResponse] {.async.} =
      return HealthResponse(ok: true),
    rWho: proc(ctx: RequestContext; req: WhoRequest): Future[WhoResponse] {.async.} =
      return WhoResponse(subject: ctx.session.subject, csrf: $ctx.csrf),
    rCreateItem: proc(ctx: RequestContext; req: CreateItemRequest): Future[ItemResponse] {.async.} =
      return ItemResponse(id: 7, name: req.name),
    rRenameItem: proc(ctx: RequestContext; req: RenameItemRequest): Future[ItemResponse] {.async.} =
      return ItemResponse(id: req.id, name: req.name),
    rDeleteItem: proc(ctx: RequestContext; req: DeleteItemRequest): Future[Deleted] {.async.} =
      return Deleted(deleted: req.id),
    rSubscribe: proc(ctx: RequestContext; req: SubscribeRequest): Future[SubscribeResponse] {.async.} =
      return SubscribeResponse(subscribed: req.email.len > 0),
    rWebhook: proc(ctx: RequestContext; req: WebhookRequest): Future[WebhookResponse] {.async.} =
      return WebhookResponse(accepted: true))

proc canonicalizeTopic(ctx: RequestContext; route: string;
                       policy: CanonicalPolicy): Future[CanonicalOutcome] {.async.} =
  ## Stage 3 then Stage 4 of URL-Schema.md §3.1 for the fixture's topics.
  var slug, id: string
  for (k, v) in ctx.pathParams:
    if k == "slug": slug = v
    elif k == "id": id = v
  if id == "13":
    return canonicalNotFound()      # authorization of the target first
  if slug != "topic-" & id:
    return canonicalRedirect("/t/topic-" & id & "/" & id)
  return canonicalContinue()

proc installHooks*() =
  ## The fixture's sessions, signatures, incarnation and canonicalization
  ## (also used by tests/test_route_manifest.nim in-process).
  serverHooks = ServerHooks(
    resolveSession: proc(req: SsrRequest): Future[Session] {.async.} =
      let sid = req.cookie("sid")
      case sid
      of "user", "staff", "admin":
        return Session(subject: sid, staff: sid == "staff", admin: sid == "admin",
                       csrfToken: "csrf-" & sid)
      else:
        return nil,
    verifySignature: proc(ctx: RequestContext; route: string): Future[bool] {.async.} =
      return ctx.request.header("X-Signature") == "valid-" & route,
    currentIncarnation: proc(): string = incarnationId)
  canonicalizer = canonicalizeTopic

proc fixtureApp*(): RequestHandler =
  manifestApp(handlers())

proc registerApps*() =
  installHooks()
  registerAsyncApp("fixture", fixtureApp())
  registerHydrationApps()
