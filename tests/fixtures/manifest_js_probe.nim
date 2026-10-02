## Compiled for the JS target by tests/test_route_manifest.nim: every
## browser-side artifact the fixture manifest must generate exists with the
## right type.
import isonim/routing/manifest
import ../nginx/fixture_manifest

static:
  # Typed async clients of data and mutation entries.
  doAssert compiles((let f: Future[ItemResponse] = rItemCall(ItemRequest(id: 1))))
  doAssert compiles((let f: Future[DelayedResponse] = rDelayedCall(DelayedRequest())))
  doAssert compiles((let f: Future[DelayedResponse] = rDelayedNavCall(DelayedRequest())))
  doAssert compiles((let f: Future[AssetResponse] = rAssetCall(AssetRequest())))
  doAssert compiles((let f: Future[HealthResponse] = rHealthCall(HealthRequest())))
  doAssert compiles((let f: Future[WhoResponse] = rWhoCall(WhoRequest())))
  doAssert compiles((let f: Future[ItemResponse] = rCreateItemCall(CreateItemRequest())))
  doAssert compiles((let f: Future[ItemResponse] = rRenameItemCall(RenameItemRequest())))
  doAssert compiles((let f: Future[Deleted] = rDeleteItemCall(DeleteItemRequest())))
  doAssert compiles((let f: Future[SubscribeResponse] = rSubscribeCall(SubscribeRequest())))
  doAssert compiles((let f: Future[WebhookResponse] = rWebhookCall(WebhookRequest())))
  # Navigation helpers of pages.
  doAssert compiles(rHomeNavigate(HomeRequest()))
  doAssert compiles(rOtherNavigate(OtherRequest()))
  doAssert compiles((let p: string = rHomePath(HomeRequest())))
  # Server-function stubs of the rpc entry.
  doAssert compiles((let f: Future[int] = sum(1, 2)))
  # Pages have no call; server-side forms are not in the browser.
  doAssert not compiles(rHomeCall(HomeRequest()))
  doAssert not compiles(rSubscribeForm(nil, SubscribeRequest(), ""))
