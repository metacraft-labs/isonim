## Both imports and the actually USED ordinary Link/renderer must retain exact
## emitted bytes with private features unused. No normalization is permitted.
when defined(js):
  import isonim/routing/navigate
  import isonim/web/[web_renderer,dom_api]
  let r=WebRenderer()
  let parent=document.getElementById("root")
  discard r.createElement("div")
  Link(Node(parent),"/next","Next")
else:
  import isonim/core/nondet
  static:
    doAssert not declared(InternalClientRenderer)
    doAssert not declared(newInternalClientRenderer)
    doAssert not declared(internalClientLink)
