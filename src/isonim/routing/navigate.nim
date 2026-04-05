## isonim/routing/navigate.nim
##
## Navigation helpers: global navigate() and Link component.

import router
import match

export router.navigate

proc navigate*(path: string; replace = false) =
  ## Global navigation function. Uses the active router.
  if activeRouter != nil:
    activeRouter.navigate(path, replace)

when defined(js):
  import ../web/dom_api

  proc Link*(parent: Node; href: string; text: string) =
    ## Link component. Renders an <a> that navigates via the router
    ## (no page reload) on click.
    let a = document.createElement(cstring"a")
    a.setAttribute(cstring"href", cstring(href))
    let textNode = document.createTextNode(cstring(text))
    discard a.appendChild(textNode)

    let capturedHref = href
    a.addEventListener(cstring"click", proc(e: Event) =
      # Prevent default browser navigation
      {.emit: [e, ".preventDefault();"].}
      navigate(capturedHref)
    )

    discard parent.appendChild(a)
