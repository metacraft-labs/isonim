## streaming_manifest.nim
##
## The route manifest of tests/routing/t_manifest_streaming.nim (IFP-M30):
## streaming pages (isonim-routing-server-functions.md, "Streaming Pages").
## Served by the nginx fixture (tests/nginx/README.md) as the async app
## `streaming` under `/stream/` (streaming_app.nim), and shared with the
## test, which runs its generated policy tests.
##
## * `sFeed`: a streaming page with a JSON variant and a declared
##   per-response policy (`cpPrivateNoStore`); what each id does is in
##   streaming_app.nim;
## * `sWhole`: the same page in the `Page`-returning form (the negative
##   control: answered whole);
## * `sPrivate`: a streaming page that needs a session, whose generated
##   refusals must come before any shell.

import std/options
import isonim/routing/manifest

export manifest, options

type
  FeedRequest* = object
    id*: int
    gate*: Option[int]
      ## A port on 127.0.0.1 the handler connects to after its shell, and
      ## reads one byte from (the test holds the socket).

  FeedResponse* = object
    id*: int
    items*: seq[string]

  WholeRequest* = object
    id*: int

  PrivateRequest* = object
    id*: int

routeManifest StreamingRoute:
  page sFeed,    "/stream/f/:id", FeedRequest, FeedResponse,
       stream = true, json = true, cacheOverrides = [cpPrivateNoStore]
  page sWhole,   "/stream/w/:id", WholeRequest, FeedResponse,
       json = true, cacheOverrides = [cpPrivateNoStore]
  page sPrivate, "/stream/private/:id", PrivateRequest, FeedResponse,
       stream = true, auth = aSession, cache = cpPrivateNoStore
