## Editor scene-graph hooks: record the element hierarchy as it is built.
##
## The counterpart to `isonim/dsl/scene_graph_hooks_off.nim`. Selected by
## `-d:isonimEditor`; never reached in a production build.
##
## Deliberately tiny and close to dependency-free. It is imported by the DSL,
## which every IsoNim project compiles, so anything it pulls in becomes a
## dependency of the whole framework in editor builds.

import std/[tables, strutils]

type
  SceneNode* = object
    ## One element in the rendered hierarchy.
    id*: string        ## Stable across recompiles; derived by the macro.
    tag*: string       ## Resolved HTML tag, e.g. "div".
    parentId*: string  ## Empty for a root.
    file*: string
    line*: int
    column*: int

  SceneGraph* = object
    nodes*: seq[SceneNode]
    byId*: Table[string, int]  ## id -> index into `nodes`

var current = SceneGraph(nodes: @[], byId: initTable[string, int]())
  ## A plain global rather than a `threadvar`: rendering is single-threaded on
  ## every backend the editor previews, and `threadvar` does not survive the
  ## JS backend, which is the one the Web preview uses.

proc resetSceneGraph*() =
  ## Start a fresh recording. Call before re-rendering a story.
  current = SceneGraph(nodes: @[], byId: initTable[string, int]())

proc sceneGraph*(): SceneGraph =
  ## The hierarchy recorded by the most recent render.
  current

proc parseLoc*(loc: string): tuple[file: string, line, column: int] =
  ## `loc` is "file:line:column" as emitted by the macro. A malformed value
  ## yields zeros rather than raising: the scene graph is an observability
  ## feature, and it must not be able to take down the page it observes.
  result = ("", 0, 0)
  let lastColon = loc.rfind(':')
  if lastColon <= 0: return
  let midColon = loc.rfind(':', last = lastColon - 1)
  if midColon <= 0: return
  result.file = loc[0 ..< midColon]
  try:
    result.line = parseInt(loc[midColon + 1 ..< lastColon])
    result.column = parseInt(loc[lastColon + 1 .. ^1])
  except ValueError:
    discard

proc recordElement*(id, tag, loc, parentId: string) =
  ## The hook's body, as a proc so the template stays a thin forwarding shim
  ## and the DSL's expansion does not carry this logic per element.
  let parsed = parseLoc(loc)
  current.byId[id] = current.nodes.len
  current.nodes.add SceneNode(
    id: id, tag: tag, parentId: parentId,
    file: parsed.file, line: parsed.line, column: parsed.column)

template noteElement*(el: untyped; id: static string; tag: static string;
                      loc: static string; parentId: static string) =
  ## Record one element. `el` — the renderer's element handle — is
  ## deliberately unused: its lifetime belongs to the renderer, and the graph
  ## must not keep it alive.
  recordElement(id, tag, loc, parentId)
