## isonim/routing/router.nim
##
## Signal-based router. Integrates with the History API on JS
## and accepts manual path setting on C (for SSR).
##
## The router is renderer-agnostic — no DOM operations here.

import ../core/[signals, computation]
when defined(js):
  import ../core/owner
import match

type
  RouteEntry* = object
    pattern*: RoutePattern
    component*: proc()          ## the component to render
    children*: seq[RouteEntry]  ## nested routes (reserved for M1)
    layout*: proc()             ## optional layout wrapper (reserved for M1)

  Router* = ref object
    routes*: seq[RouteEntry]
    currentPath*: Signal[string]
    params*: Signal[seq[(string, string)]]
    matchedIndex*: Signal[int]  ## index into routes, -1 if no match

var activeRouter*: Router
  ## The currently active router instance. Used by global navigate().

proc findMatch(router: Router; path: string): (int, seq[(string, string)]) =
  ## Find the first matching route. Returns (index, params) or (-1, @[]).
  for i in 0 ..< router.routes.len:
    let m = matchPath(router.routes[i].pattern, path)
    if m.matched:
      return (i, m.params)
  return (-1, @[])

proc updateMatch(router: Router) =
  ## Update matchedIndex and params signals from currentPath.
  let (idx, pars) = router.findMatch(router.currentPath.val)
  router.matchedIndex.val = idx
  router.params.val = pars

when defined(js):
  type
    Location {.importc.} = ref object
      pathname: cstring
      search: cstring
      hash: cstring

    History {.importc.} = ref object

    WindowObj {.importc.} = ref object
      location: Location
      history: History

  var window {.importc, nodecl.}: WindowObj

  proc pushState(h: History; state: JsRoot; title: cstring; url: cstring)
    {.importcpp: "#.pushState(#, #, #)".}

  proc replaceState(h: History; state: JsRoot; title: cstring; url: cstring)
    {.importcpp: "#.replaceState(#, #, #)".}

  proc addEventListener(w: WindowObj; event: cstring; handler: proc(e: JsRoot))
    {.importcpp: "#.addEventListener(#, #)".}

  proc removeEventListener(w: WindowObj; event: cstring; handler: proc(e: JsRoot))
    {.importcpp: "#.removeEventListener(#, #)".}

when defined(js):
  proc hasWindow(): bool =
    ## Check if window object is available (false in Node.js).
    {.emit: [result, " = (typeof window !== 'undefined');"].}

  proc getWindowPathname(): string =
    ## Read window.location.pathname.
    var cs: cstring
    {.emit: [cs, " = window.location.pathname;"].}
    result = $cs

proc createRouter*(routes: seq[RouteEntry]; initialPath: string): Router =
  ## Create a router from route definitions with an explicit initial path.
  ## Does not read window.location or listen to popstate.
  ## Use this overload for SSR (C backend) or testing.
  let router = Router(
    routes: routes,
    currentPath: createSignal(initialPath),
    params: createSignal(newSeq[(string, string)]()),
    matchedIndex: createSignal(-1),
  )

  # Perform initial match
  let (idx, pars) = router.findMatch(initialPath)
  router.matchedIndex.value = idx
  router.params.value = pars

  # Set up reactive effect: when currentPath changes, re-match
  createEffect proc() =
    router.updateMatch()

  activeRouter = router
  result = router

proc createRouter*(routes: seq[RouteEntry]): Router =
  ## Create a router from route definitions.
  ## On JS (in browser): reads window.location.pathname and listens to popstate.
  ## On JS (in Node.js) or C: starts with "/".
  let initialPath =
    when defined(js):
      if hasWindow(): getWindowPathname()
      else: "/"
    else:
      "/"

  let router = createRouter(routes, initialPath)

  when defined(js):
    if hasWindow():
      # Listen for browser back/forward
      let popstateHandler = proc(e: JsRoot) =
        router.currentPath.val = getWindowPathname()

      window.addEventListener(cstring"popstate", popstateHandler)

      onCleanup proc() =
        window.removeEventListener(cstring"popstate", popstateHandler)

  result = router

proc navigate*(router: Router; path: string; replace = false) =
  ## Navigate to a new path. Updates currentPath signal.
  ## On JS (in browser): pushState/replaceState. On C or Node.js: just updates the signal.
  when defined(js):
    if hasWindow():
      if replace:
        window.history.replaceState(nil, cstring"", cstring(path))
      else:
        window.history.pushState(nil, cstring"", cstring(path))

  router.currentPath.val = path

proc currentParams*(router: Router): seq[(string, string)] =
  ## Get current route params (reactive read).
  router.params.val

proc matchedRoute*(router: Router): RouteEntry =
  ## Get the currently matched route entry (reactive read).
  ## Returns a default RouteEntry if no route matches.
  let idx = router.matchedIndex.val
  if idx >= 0 and idx < router.routes.len:
    router.routes[idx]
  else:
    RouteEntry()

proc hasMatch*(router: Router): bool =
  ## Returns true if a route is currently matched (reactive read).
  router.matchedIndex.val >= 0
