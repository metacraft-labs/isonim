## isonim/dsl/iso_view.nim
##
## `{.isoView.}`: one view proc, written once, that renders on the server
## and hydrates in the browser.
##
## ```nim
## import isonim/dsl/iso_view
##
## proc topicRow*(r: IsoRenderer; t: TopicSummary): IsoNode {.isoView.} =
##   li(class = "topic"):
##     a(href = "/t/" & t.slug & "/" & $t.id): text t.title
## ```
##
## The body is a `ui` DSL block. It is compiled twice, as `uiIsomorphic`
## (isomorphic.nim) does for a block without parameters:
##
## * **C target (the server):** `ui:` string mode; the proc returns the
##   markup (`IsoNode` is `string`). Inside a hydratable render
##   (`renderToString`, `withHydrationKeys`, ssr/markers.nim) every element
##   carries its `data-hk` key. Event handlers (`onclick = proc ...`) are
##   dropped, as string mode drops them, so they may name client-only
##   procs.
## * **JS target (the browser):** `ui(r):` with the `WebRenderer`; the proc
##   returns the element (`IsoNode` is `Element`). Called inside `hydrate`,
##   it adopts the server's elements key by key (web/hydration.nim).
##
## A view calls another as `otherView(r, ...)` on both targets: the call's
## value (markup or an element) is appended where it appears, which keeps
## the server's key order equal to the client's creation order (markers.nim:
## markup is produced where it appears). Signals read in the body render
## their current value on the server and stay reactive in the browser.
##
## Why a pragma and not `uiIsomorphic`: views take data (a page's typed
## data, a list item), and `uiIsomorphic` defines parameterless blocks. The
## two arms are the same body, so they cannot drift (the property
## `uiIsomorphic` exists for); the first parameter must be the renderer,
## named `r`, because the client arm is `ui(r):`.

import std/macros
import ./ui
export ui
import ../ssr/escape
export escape
import ../core/[signals, computation]
export signals, computation

when defined(js):
  import ../web/[dom_api, web_renderer]
  export dom_api, web_renderer
  type
    IsoRenderer* = WebRenderer
      ## The renderer a view builds with: the browser DOM on the client.
    IsoNode* = Element
      ## What a view returns: an element on the client.
else:
  import ../ssr/markers
  export markers
  type
    IsoRenderer* = object
      ## Stands in for the renderer on the server, where `ui:` builds a
      ## string and needs none; it carries no state.
    IsoNode* = string
      ## What a view returns: markup on the server.

  const isoServer* = IsoRenderer()
    ## The value server code passes as a view's renderer.

macro isoView*(procDef: untyped): untyped =
  ## Compiles a view proc's `ui` body for both targets (module doc).
  procDef.expectKind({nnkProcDef, nnkFuncDef})
  let params = procDef.params
  if params.len < 2 or params[1][0].kind != nnkIdent or not params[1][0].eqIdent("r"):
    error("an {.isoView.} proc's first parameter is the renderer, `r: IsoRenderer`", procDef)
  let body = procDef.body
  if body.kind == nnkEmpty:
    error("an {.isoView.} proc needs a ui body", procDef)
  var docs = newStmtList()
  var dsl = newStmtList()
  for child in (if body.kind == nnkStmtList: body else: newStmtList(body)):
    if child.kind == nnkCommentStmt and dsl.len == 0: docs.add child
    else: dsl.add child
  let client = newCall(ident"ui", ident"r")
  client.add dsl.copyNimTree
  let server = newCall(ident"ui")
  server.add dsl.copyNimTree
  var newBody = docs
  newBody.add nnkWhenStmt.newTree(
    nnkElifBranch.newTree(newCall(ident"defined", ident"js"), newStmtList(client)),
    nnkElse.newTree(newStmtList(server)))
  result = procDef.copyNimTree
  result.body = newBody
