## Fixture for tests/test_style_provenance.nim. Real DSL, real renderers.
##
## Four authored constructs, chosen so that each one produces a DIFFERENT
## provenance record and so that the four together are indistinguishable once
## the browser has resolved them:
##
##   class = "p-4"                  -> a class the compile-time index knows
##   class = "zc-not-a-class"       -> a class nothing can resolve: the record
##                                     that must NOT be silent
##   padding = "var(--zc-space-token)" -> a token reference
##   color   = "#123456"            -> a literal, and the control for the
##                                     whole feature: it must come back as a
##                                     literal, not as a binding
##
## The SSR arm is a separate proc, and `isMainModule` CALLS it, for the reason
## the scene-graph fixture already documents: a proc nobody calls is
## dead-code eliminated, and an assertion about a bundle that never contained
## the code cannot fail.

import isonim/ssr/escape
import isonim/dsl/ui
import isonim/testing/mock_dom
import isonim/dsl/scene_graph

proc build(r: MockRenderer): auto =
  ui(r):
    tdiv(class = "p-4 zc-not-a-class"):
      tdiv(padding = "var(--zc-space-token)", color = "#123456"):
        text "provenance"

proc ssrPage*(): string =
  ui:
    tdiv(class = "p-4 zc-not-a-class"):
      tdiv(padding = "var(--zc-space-token)", color = "#123456"):
        text "provenance"

when isMainModule:
  echo "ssr-len=", ssrPage().len
  let r = MockRenderer()
  when defined(isonimEditor):
    resetSceneGraph()
  discard build(r)
  when defined(isonimEditor):
    let g = sceneGraph()
    echo "nodes=", g.nodes.len
    # What the recorder holds, decoded. This is the claim the zero-cost arm
    # cannot make: that the payload in the bundle is a payload that MEANS
    # something, rather than a string that happens to be present.
    var records = 0
    var unresolved = 0
    for n in g.nodes:
      for b in sceneBindings(n.id):
        inc records
        echo "binding kind=", b.kind, " property=", b.property,
             " detail=", b.detail, " token=", b.token
        if b.kind == sbkUnresolved:
          inc unresolved
    echo "records=", records
    echo "unresolved=", unresolved
    echo "page-unresolved=", sceneUnresolvedBindings().len
    # The SSR arm's HTML, so the ViewModel test can feed the REAL wire format
    # to `previewDomElementRef` rather than a payload the test hand-rolled.
    # A test that encodes its own input proves the decoder agrees with the
    # test, not that it agrees with the DSL.
    echo "ssr-html=", ssrPage()
