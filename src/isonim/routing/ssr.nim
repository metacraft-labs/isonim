## isonim/routing/ssr.nim
##
## SSR helpers for the router (M2).
## Wires the router's match result to renderToString so the nginx
## module (or any C-target caller) can render the correct page for
## a given request URI.
##
## SSR components return strings (via buildHtmlString), while the
## client-side router stores proc() components (side-effect based).
## This module bridges the two: it reuses the router's URL matching
## but renders string-returning components.

import ../ssr/renderer
import match, params

type
  SsrRouteEntry* = object
    pattern*: RoutePattern
    component*: proc(): string   ## SSR component returning HTML
    children*: seq[SsrRouteEntry]
    layout*: proc(childHtml: string): string  ## layout wraps child HTML

  SsrMatchEntry = object
    component: proc(): string
    layout: proc(childHtml: string): string
    params: seq[(string, string)]
    isLayout: bool

proc findSsrMatch(routes: seq[SsrRouteEntry]; path: string):
    (seq[SsrMatchEntry], seq[(string, string)]) =
  ## Find the first matching SSR route, including nested children.
  ## Returns (match chain, merged params).
  for route in routes:
    if route.children.len > 0:
      # Parent route: try prefix match, then match children against remainder
      let m = matchPrefix(route.pattern, path)
      if m.matched:
        let rest = remainingPath(route.pattern, path)
        for child in route.children:
          let cm = matchPath(child.pattern, rest)
          if cm.matched:
            var allParams = m.params & cm.params
            if route.layout != nil:
              return (@[
                SsrMatchEntry(layout: route.layout, params: m.params, isLayout: true),
                SsrMatchEntry(component: child.component, params: cm.params),
              ], allParams)
            else:
              # No layout — just render the child
              return (@[
                SsrMatchEntry(component: child.component, params: cm.params),
              ], allParams)
        # No child matched — try exact match on parent itself
        let exactM = matchPath(route.pattern, path)
        if exactM.matched and route.component != nil:
          return (@[
            SsrMatchEntry(component: route.component, params: exactM.params),
          ], exactM.params)
    else:
      # Leaf route: exact match
      let m = matchPath(route.pattern, path)
      if m.matched:
        return (@[
          SsrMatchEntry(component: route.component, params: m.params),
        ], m.params)
  return (@[], @[])

proc renderRoute*(routes: seq[SsrRouteEntry]; path: string;
                  routeParams: RouteParams = nil): string =
  ## Render the matched route for the given path to an HTML string.
  ## Used by SSR (nginx module) to render the correct page.
  ##
  ## Matches `path` against the route table, populates `routeParams`
  ## (if provided) with extracted URL parameters, then renders the
  ## matched component via renderToString.
  ##
  ## For nested routes with layouts, the layout receives the child
  ## component's HTML as its argument.
  ##
  ## Returns a "404 Not Found" div when no route matches.

  let (chain, allParams) = findSsrMatch(routes, path)

  if routeParams != nil:
    routeParams.updateFrom(allParams)

  if chain.len == 0:
    return "<div>404 Not Found</div>"

  renderToString proc(): string =
    if chain.len == 1:
      if chain[0].isLayout:
        chain[0].layout("")
      else:
        chain[0].component()
    elif chain.len == 2 and chain[0].isLayout:
      # Layout wrapping a child
      let childHtml = chain[1].component()
      chain[0].layout(childHtml)
    else:
      # Fallback: render first component
      chain[0].component()
