## fixture_client.nim
##
## The browser side of the nginx fixture (tests/nginx/README.md), compiled
## to build/nginx-fixture/www/client.js with `-d:isonimRpcPrefix=/api/v1/rpc`
## and loaded by the fixture's home page.  It calls the server through the
## generated clients only (the `{.server.}` stubs of fixture_rpc.nim and the
## route clients of fixture_manifest.nim), and exposes `window.fx` for the
## Playwright specs:
##
## * `sum`, `describe`, `bodySize`, `slow`, `slowPending`, `fast`: server
##   functions
##   (tests/browser/specs/rpc-over-nginx.spec.ts);
## * `load(ms, value, scope)`: a delayed route call whose result, when
##   applied, sets a signal (shown in #value, counted by an effect), a
##   cache entry and a localStorage key; `switchAccount`,
##   `changeIncarnation`, `navigate`: the context changes; `state()`: all
##   of it, plus the dropped-response count
##   (tests/browser/specs/request-context-generation.spec.ts);
## * `loadSlowBody(value)`: the same navigation-scoped call through
##   `callRoute` (what every generated client calls) to
##   `/api/v1/slow-body`, which the fixture's nginx proxies to an upstream
##   the spec runs: it sends the response headers and holds the body back,
##   so a navigation can land while the body is being read.

when not defined(js):
  {.error: "fixture_client.nim is the browser client (JS target)".}

import std/[asyncjs, jsffi, strutils]
import isonim/core/[signals, computation, owner]
import isonim/routing/[router, match, route_client]
import fixture_manifest

var
  value: Signal[string]
  effectRuns = 0
  cache: JsObject           ## a Map: what the "app" cached from responses
  appRouter: Router
  lastDrop: DroppedResponse

createRoot proc(dispose: proc()) =
  value = createSignal("")
  createEffect proc() =
    let v = cstring(value.val)
    inc effectRuns
    {.emit: """
    var el = document.getElementById("value");
    if (el) el.textContent = `v`;
    """.}
  appRouter = createRouter(@[
    RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
    RouteEntry(pattern: parsePattern("/other"), component: proc() = discard)])
{.emit: "`cache` = new Map();".}
onDroppedResponse(proc(d: DroppedResponse) = lastDrop = d)

proc apply(v: string) =
  ## What the application does with a response: a signal, a cache entry and
  ## browser storage.
  value.val = v
  let s = cstring(v)
  {.emit: """
  `cache`.set(`s`, Date.now());
  window.localStorage.setItem("fx.value", `s`);
  """.}

proc js(s: string): cstring = cstring(s)

# --- server functions -------------------------------------------------------

proc fxSum(a, b: int): Future[int] {.exportc.} =
  sum(a, b)

proc fxDescribe(a, b: int; label: cstring): Future[JsObject] {.async, exportc.} =
  let p = await describe(a, b, $label)
  var o = newJsObject()
  o.a = p.a
  o.b = p.b
  o.sum = p.sum
  o.label = js(p.label)
  return o

proc fxBodySize(n: int): Future[JsObject] {.async, exportc.} =
  ## Sends an `n`-byte argument; resolves with {ok, value} or {ok, status}.
  var o = newJsObject()
  try:
    let size = await bodySize(repeat('x', n))
    o.ok = true
    o.value = size
  except RpcError as e:
    o.ok = false
    o.status = e.status
  return o

proc fxSlow(ms: int): Future[cstring] {.async, exportc.} =
  return js(await slowOp(ms))

proc fxFast(): Future[cstring] {.async, exportc.} =
  return js(await fastOp())

proc fxSlowPending(): Future[int] {.exportc.} =
  slowPending()

# --- request-context generation -------------------------------------------

proc fxLoad(ms: int; v: cstring; scope: cstring) {.async, exportc.} =
  ## A route call whose response, if it is applied, changes the state.
  let req = DelayedRequest(ms: ms, value: $v)
  let resp =
    if $scope == "navigation": await rDelayedNavCall(req)
    else: await rDelayedCall(req)
  apply(resp.value)

proc fxLoadSlowBody(v: cstring) {.async, exportc.} =
  ## A navigation-scoped call whose body arrives only when the spec's
  ## upstream releases it.  Not a manifest entry: the path is nginx's
  ## proxy to that upstream, which the generated policy tests cannot reach.
  let resp = await callRoute[DelayedRequest, DelayedResponse]("GET",
    "/api/v1/slow-body", DelayedRequest(ms: 0, value: $v), csNavigation)
  apply(resp.value)

proc fxSwitchAccount() {.exportc.} = bumpAccountGeneration()
proc fxChangeIncarnation(id: cstring) {.exportc.} = setIncarnation($id)
proc fxNavigate(path: cstring) {.exportc.} = appRouter.navigate($path)

proc fxState(): JsObject {.exportc.} =
  var o = newJsObject()
  o.value = js(value.value)
  o.effectRuns = effectRuns
  o.cacheSize = cache.size
  o.dropped = droppedResponseCount()
  o.dropReason = js(lastDrop.reason)
  o.dropStatus = lastDrop.status
  o.navigationGeneration = clientContext().navigationGeneration
  o.accountGeneration = clientContext().accountGeneration
  o.contextHeader = js(contextHeaderValue())
  return o

{.emit: """
window.fx = {
  sum: `fxSum`, describe: `fxDescribe`, bodySize: `fxBodySize`,
  slow: `fxSlow`, fast: `fxFast`, slowPending: `fxSlowPending`,
  load: `fxLoad`, loadSlowBody: `fxLoadSlowBody`, switchAccount: `fxSwitchAccount`,
  changeIncarnation: `fxChangeIncarnation`, navigate: `fxNavigate`,
  state: `fxState`,
};
window.fxReady = true;
""".}
