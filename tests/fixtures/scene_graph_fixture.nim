## Fixture for tests/test_scene_graph_hooks.nim. Real DSL, real renderer.
import isonim/ssr/escape
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

# SSR arm: the same markup through the string-mode DSL, so the test can assert
# on what `data-isonim-src` does and does not reach a production bundle.
proc ssrPage*(): string =
  ui:
    tdiv(class = "root"):
      span: text "title"

when isMainModule:
  # Call the SSR arm so its code is EMITTED. A proc nobody calls is dead-code
  # eliminated, and an assertion about a bundle that never contained the code
  # cannot fail -- which is exactly the vacuous test this file already
  # removed once.
  echo "ssr-len=", ssrPage().len
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
