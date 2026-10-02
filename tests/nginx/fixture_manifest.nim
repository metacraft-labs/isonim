## fixture_manifest.nim
##
## The route manifest of the nginx fixture (tests/nginx/README.md), shared
## by the server (compiled into the ngx-isonim module by fixture_app.nim),
## the browser client (fixture_client.nim) and tests/test_route_manifest.nim.
##
## It has a page, data routes, mutations, a progressive `action` with a
## no-JS form, the `rpc` mount of fixture_rpc.nim, and between them every
## CSRF policy (csrfNone on GETs, csrfSession, csrfAnon, csrfExempt), every
## cache policy and every authentication policy, and a staff-only page with
## a `canonical` policy (`rTopic`, canonicalized by fixture_app.nim's hook).

import isonim/routing/manifest
import fixture_rpc

export manifest, fixture_rpc

type
  HomeRequest* = object
  HomeResponse* = object
    title*: string

  OtherRequest* = object
  OtherResponse* = object
    title*: string

  TopicRequest* = object
    slug*: string
    id*: int

  TopicResponse* = object
    id*: int

  ItemRequest* = object
    id*: int

  ItemResponse* = object
    id*: int
    name*: string

  CreateItemRequest* = object
    name*: string

  RenameItemRequest* = object
    id*: int
    name*: string

  DeleteItemRequest* = object
    id*: int

  Deleted* = object
    deleted*: int

  DelayedRequest* = object
    ms*: int
    value*: string

  DelayedResponse* = object
    value*: string

  AssetRequest* = object
    name*: string

  AssetResponse* = object
    name*: string
    bytes*: int

  HealthRequest* = object
  HealthResponse* = object
    ok*: bool

  SubscribeRequest* = object
    email*: string

  SubscribeResponse* = object
    subscribed*: bool

  WebhookRequest* = object
    event*: string

  WebhookResponse* = object
    accepted*: bool

  WhoRequest* = object
  WhoResponse* = object
    subject*: string
    csrf*: string

routeManifest FixtureRoute:
  page   rHome,       "/"
  page   rOther,      "/other"
  page   rTopic,      "/t/:slug/:id", auth = aStaff, canonical = ccTopicSlug
  get    rItem,       "/api/v1/items/:id", auth = aPublic, cache = cpMediaRevalidate
  get    rDelayed,    "/api/v1/delayed", auth = aPublic, cache = cpPrivateNoStore,
         contextScope = csAccount
  get    rDelayedNav, "/api/v1/delayed-nav", DelayedRequest, DelayedResponse,
         auth = aPublic, cache = cpPrivateNoStore
  get    rAsset,      "/api/v1/assets/:name", auth = aPublic, cache = cpImmutable
  get    rHealth,     "/api/v1/health", auth = aPublic, cache = cpNone
  get    rWho,        "/api/v1/who", auth = aSession, cache = cpPrivateNoStore
  post   rCreateItem, "/api/v1/items", CreateItemRequest, ItemResponse,
         auth = aSession, csrf = csrfSession, cache = cpPrivateNoStore
  put    rRenameItem, "/api/v1/items/:id", RenameItemRequest, ItemResponse,
         auth = aStaff, csrf = csrfSession, cache = cpPrivateNoStore
  delete rDeleteItem, "/api/v1/items/:id", DeleteItemRequest, Deleted,
         auth = aAdmin, csrf = csrfSession, cache = cpPrivateNoStore
  action rSubscribe,  "/subscribe", auth = aPublic, csrf = csrfAnon,
         cache = cpPrivateNoStore, target = "/thanks"
  post   rWebhook,    "/api/v1/webhook", auth = aSignature,
         csrf = csrfExempt("billing-webhook"), cache = cpPrivateNoStore,
         contextScope = csNone
  rpc    rRpc,        "/api/v1/rpc"
