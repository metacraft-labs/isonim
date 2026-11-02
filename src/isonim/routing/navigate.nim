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

  when defined(isonimInternalClientRouting):
    import std/macros

    macro projectClientLink(renderer: typed): untyped =
      # Parse the actual public implementation before semantic binding fixes its
      # renderer overloads. Leaving that source body in place also preserves its
      # debug locations and ordinary generated symbols byte for byte. Fail closed
      # if its defining shape changes; never maintain a second anchor algorithm.
      let source = parseStmt(staticRead(currentSourcePath()), currentSourcePath())
      var implementation: NimNode
      proc find(node: NimNode) =
        if node.kind == nnkProcDef and node[0].kind == nnkPostfix and
            node[0][1].eqIdent("Link"):
          if implementation != nil: error("multiple public Link implementations")
          implementation = node
        else:
          for child in node: find(child)
      find(source)
      if implementation == nil: error("public Link implementation not found")
      let params = implementation[3]
      if implementation[2].kind != nnkEmpty or params.len != 4 or
          params[0].kind != nnkEmpty:
        error("public Link signature changed")
      for i, expected in ["parent", "href", "text"]:
        let parameter = params[i + 1]
        let expectedType = if i == 0: "Node" else: "string"
        if parameter.kind != nnkIdentDefs or parameter.len != 3 or
            not parameter[0].eqIdent(expected) or
            not parameter[1].eqIdent(expectedType) or
            parameter[2].kind != nnkEmpty:
          error("public Link signature changed")
      let body = implementation[6].copyNimTree
      var first = 0
      while first < body.len and body[first].kind == nnkCommentStmt: inc first
      if first == body.len or body[first].kind != nnkLetSection or
          body[first].len != 1 or body[first][0].len != 3 or
          not body[first][0][0].eqIdent("r") or
          body[first][0][2].kind != nnkCall or body[first][0][2].len != 1 or
          not body[first][0][2][0].eqIdent("WebRenderer"):
        error("public Link renderer binding changed")
      body[first][0][2] = renderer
      result = newBlockStmt(body)

    proc internalClientLink*(r: InternalClientRenderer; parent: Node;
        href, text: string) =
      ## Fixed compile-time projection of Link's actual source. Its tail remains
      ## direct DOM append, preserving native identity, metering and key scopes.
      projectClientLink(r)
