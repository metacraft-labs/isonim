## isonim/routing/navigate.nim
##
## Navigation helpers: global navigate() and Link component.

import router

export router.navigate

proc navigate*(path: string; replace = false) =
  ## Global navigation function. Uses the active router.
  if activeRouter != nil:
    activeRouter.navigate(path, replace)

when defined(js):
  import ../web/dom_api
  import ../web/web_renderer
  import ../dsl/ui
  import ../rxcore

  proc Link*(parent: Node; href: string; text: string) =
    ## Link component. Renders an <a> that navigates via the router
    ## (no page reload) on click. Stable builds use ordinary component scopes;
    ## repeated programmatic calls need withStableKey/withStableInstance.
    let r = WebRenderer()
    let capturedHref = href
    let a = ui(r):
      a(href = href, onclick = proc(e: Event) =
        {.emit: [e, ".preventDefault();"].}
        navigate(capturedHref)):
        text(text)
    discard parent.appendChild(a)
