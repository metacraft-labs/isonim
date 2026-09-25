## Fixture for tests/test_scene_graph_hooks.nim. Real DSL, real renderer.
import isonim/dsl/ui
import isonim/testing/mock_dom
import std/tables
import isonim/dsl/scene_graph

proc build(r: MockRenderer): auto =
  ui(r):
    tdiv(class = "root"):
      span: text "title"
      tdiv(class = "row"):
        tdiv(class = "cell")

when isMainModule:
  let r = MockRenderer()
  when defined(isonimEditor):
    resetSceneGraph()
  discard build(r)
  when defined(isonimEditor):
    let g = sceneGraph()
    echo "nodes=", g.nodes.len
    var roots = 0
    var orphans = 0
    for n in g.nodes:
      if n.parentId.len == 0: inc roots
      elif not g.byId.hasKey(n.parentId): inc orphans
    echo "root=", roots
    echo "orphans=", orphans
