## Actual USED ordinary operations under the private ordinal define. Compiler
## byte identity is compared without source/output normalization. Native static
## checks cannot leave feature names in runtime assertion diagnostics.
when defined(js):
  import isonim/routing/navigate
  import isonim/web/[web_renderer,dom_api]
  let r=WebRenderer()
  let parent=document.getElementById("root")
  let child=r.createElement("div")
  r.appendChild(parent,child)
  r.setAttribute(child,"data-control","ordinary")
  r.setTextContent(child,"Ordinary")
  Link(Node(parent),"/next","Next")
else:
  import isonim/core/nondet
  static:
    doAssert not declared(InternalClientCreationOrdinals)
    doAssert not declared(newInternalClientCreationOrdinals)
    doAssert not declared(createInternalClientElement)
    doAssert not declared(internalClientCreationOrdinal)
