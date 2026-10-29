## isonim/routing/history.nim
##
## The browser history for a client router that renders its own pages
## (JS target): push a path and hear back/forward, with the navigation
## generation of URL-Schema.md §5.4 advanced on both, as `Router.navigate`
## and its popstate listener advance it (router.nim).
##
## `Router` also matches a route table and keeps reactive parameters; an
## application that matches the manifest's patterns itself (match.nim) and
## renders through an `Outlet` (outlet.nim) needs only this part, and a
## bundle with a size budget does not pay for the rest.

when not defined(js):
  {.error: "isonim/routing/history is the browser's (JS target only)".}

import std/jsffi
import ../core/nondet as nondet
import ../web/dom_api as eventDom
import client_context

proc pushPath*(path: string; replace = false) =
  ## A client navigation to `path`: the navigation generation advances
  ## (navigation-scoped requests in flight are aborted, their responses
  ## dropped), then the URL is pushed (or replaced).
  bumpNavigationGeneration()
  if replace: nondet.replaceState(path)
  else: nondet.pushState(path)

proc currentPath*(): string =
  ## The page's path (`location.pathname`).
  nondet.location()

proc onHistoryChange*(cb: proc (path: string)) =
  ## Calls `cb` with the new path on every back or forward, after the
  ## navigation generation advanced.
  var window {.importc, nodecl.}: JsObject
  let handler = proc (e: eventDom.Event) =
    bumpNavigationGeneration()
    cb(nondet.location())
  discard nondet.listen(window, "popstate", handler)
