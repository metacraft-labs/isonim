## streaming_app.nim
##
## The server side of streaming_manifest.nim, compiled into the nginx
## fixture's module by tests/nginx/fixture_app.nim (the async app
## `streaming`, served at `/stream/`).
##
## The application's `serverHooks.pageHeaders` (`streamingPageHeaders`,
## installed by fixture_app.nim for every manifest, acting on this one's
## entries only) sets `Content-Security-Policy: script-src
## 'nonce-<the response's nonce>'; object-src 'none'` and
## `X-Page-Hook: <route>`.
##
## `sFeed` (`/stream/f/:id`), a streaming page, by id:
##
## * 2: before its shell the handler makes the response `cpPrivateNoStore`
##   (`setCachePolicy`, accepted) and reports the answer in
##   `X-Early-Override`;
## * 3: writes HTML without flushing, then raises `RouteNotFound`: the 404,
##   none of the HTML;
## * 4: after its shell asks for `cpPrivateNoStore` (refused: committed)
##   and sets a header (`ResponseCommittedError`), and writes both answers
##   into the body (`#late-override`, `#late-header`);
## * 5: writes HTML without flushing, then raises: `500`, none of the HTML;
## * 6: after its shell raises `RouteNotFound`: the response is terminated;
## * 7: after its shell raises `ValueError`: the response is terminated;
## * 8: never flushes: answered whole;
## * 10: writes HTML without flushing, then redirects (`302` to
##   `/stream/f/1`) and returns: the redirect, with the entry's policy and no
##   body;
## * 11: redirects, then calls `page.flush()`, which raises `ValueError`;
##   the handler reports the exception's type in `X-Flush-Refused` and
##   returns;
## * 12: writes HTML without flushing, then raises `RpcBadRequest`: `400`,
##   none of the HTML;
## * 13: sets its own `page.tail` (`#custom-tail` before `</body></html>`);
## * 14: sets a header and writes HTML without flushing, then raises
##   `StreamOverloaded`, which the fixture maps (`mappedStreamingExceptions`):
##   `503` with `Retry-After: 1`, none of the HTML or the header;
## * 15: after its shell raises `StreamOverloaded`: the response is
##   terminated, as for 7 (the mapping applies only before the commit);
## * any id: the shell (`#shell`), then, with `gate`, one byte read from
##   `127.0.0.1:<gate>` (`#rest`), then the body; the data is
##   `{id, items: ["a", <byte>]}`.  Its JSON variant flushes nothing.
##
## The fixture's `streamingRedirectTarget` is where 10 and 11 redirect.
##
## `sWhole` (`/stream/w/:id`): the same document as a `Page`.
## `sPrivate` (`/stream/private/:id`): a shell and a body.

import std/[asyncdispatch, asyncnet, options]
import isonim/routing/route_dispatch
import isonim/server/context
import streaming_manifest

export streaming_manifest

const
  streamingRedirectTarget* = "/stream/f/1"
    ## Where sFeed 10 and 11 redirect.
  customTail* = "<footer id=\"custom-tail\">tail</footer></body></html>"
    ## sFeed 13's `page.tail`.
  shellHtml* = "<!doctype html><html><head><meta charset=\"utf-8\">" &
    "<title>stream</title></head><body><h1 id=\"shell\">shell</h1>"
    ## What a streaming page flushes first; the test waits for it.

type
  StreamOverloaded* = object of CatchableError
    ## Raised by sFeed 14 and 15; the fixture maps it to 503 with
    ## `Retry-After: 1` (`mappedStreamingExceptions`).

proc mappedStreamingExceptions*(): seq[ExceptionMapping] =
  ## The fixture's `serverHooks.mappedExceptions` (isonim-routing-server-
  ## functions.md, "Mapped Exceptions").
  @[mapException[StreamOverloaded](503, "unavailable", retryAfter = 1)]

proc isStreamingRoute*(route: string): bool =
  for s in routeSpecs(StreamingRoute):
    if s.name == route: return true
  false

proc streamingPageHeaders*(ctx: RequestContext; route: string) =
  ## The fixture's `serverHooks.pageHeaders`, for this manifest's pages.
  if not isStreamingRoute(route):
    return
  ctx.response.setHeader("Content-Security-Policy",
    "script-src " & ctx.response.cspNonceSource & "; object-src 'none'")
  ctx.response.setHeader("X-Page-Hook", route)

proc readGate(port: int): Future[string] {.async.} =
  ## The read the page awaits: one byte from a socket the test holds.
  let sock = newAsyncSocket()
  try:
    await sock.connect("127.0.0.1", Port(port))
    result = await sock.recv(1)
  finally:
    sock.close()

proc feedPage(ctx: RequestContext; req: FeedRequest;
              page: PageStream): Future[FeedResponse] {.async.} =
  case req.id
  of 2:
    ctx.response.setHeader("X-Early-Override",
                           $ctx.setCachePolicy(cpPrivateNoStore))
  of 3:
    page.write("<p>leaked before not-found</p>")
    routeNotFound()
  of 5:
    page.write("<p>leaked before the error</p>")
    raise newException(ValueError, "sFeed 5 raised before its shell")
  of 10:
    page.write("<p>leaked before the redirect</p>")
    ctx.response.redirect(streamingRedirectTarget)
    return FeedResponse(id: req.id, items: @["redirected"])
  of 11:
    ctx.response.redirect(streamingRedirectTarget)
    page.write("<p>leaked by the refused flush</p>")
    var refused = "none"
    try:
      page.flush()
    except ValueError:
      refused = "ValueError"
    ctx.response.setHeader("X-Flush-Refused", refused)
    return FeedResponse(id: req.id, items: @["redirected"])
  of 12:
    page.write("<p>leaked before the bad request</p>")
    raise newException(RpcBadRequest, "sFeed 12 is a bad request")
  of 13:
    page.tail = customTail
  of 14:
    ctx.response.setHeader("X-Before-Overload", "1")
    page.write("<p>leaked before the overload</p>")
    raise newException(StreamOverloaded, "sFeed 14 overloaded before its shell")
  else:
    discard
  if req.id == 8:
    page.write(shellHtml)
  else:
    page.shell(shellHtml)
  var got = "-"
  if req.gate.isSome:
    got = await readGate(req.gate.get)
  case req.id
  of 4:
    let accepted = ctx.setCachePolicy(cpPrivateNoStore)
    var headerAnswer = "accepted"
    try:
      ctx.response.setHeader("X-Late", "1")
    except ResponseCommittedError:
      headerAnswer = "ResponseCommittedError"
    page.write("<p id=\"late-override\">" & $accepted & "</p>" &
               "<p id=\"late-header\">" & headerAnswer & "</p>")
  of 6:
    await sleepAsync(0)
    routeNotFound()
  of 7:
    await sleepAsync(0)
    raise newException(ValueError, "sFeed 7 raised after its shell")
  of 15:
    await sleepAsync(0)
    raise newException(StreamOverloaded, "sFeed 15 overloaded after its shell")
  else:
    discard
  page.write("<p id=\"rest\">rest:" & got & "</p>")
  if req.id != 8:
    page.flush()
  page.write("<p id=\"body-end\">end</p>")
  return FeedResponse(id: req.id, items: @["a", got])

proc wholePage(ctx: RequestContext;
               req: WholeRequest): Future[Page[FeedResponse]] {.async.} =
  return Page[FeedResponse](
    html: shellHtml & "<p id=\"rest\">rest:-</p></body></html>",
    data: FeedResponse(id: req.id, items: @["a", "-"]))

proc privatePage(ctx: RequestContext; req: PrivateRequest;
                 page: PageStream): Future[FeedResponse] {.async.} =
  page.shell(shellHtml)
  page.write("<p id=\"rest\">private</p>")
  return FeedResponse(id: req.id, items: @["private"])

proc streamingApp*(): RequestHandler =
  manifestApp(StreamingRouteHandlers(sFeed: feedPage, sWhole: wholePage,
                                     sPrivate: privatePage))
