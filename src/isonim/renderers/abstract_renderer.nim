## Abstract renderer definition for IsoNim.
##
## Defines the RendererBackend interface -- a set of procs that all renderer
## implementations must provide. Uses a compile-time check proc for
## zero-overhead, static verification of conformance.
##
## Renderers provide their own backend type B and element handle type E,
## then call checkRendererBackend[B, E]() to verify they implement
## the full interface.

proc checkRendererBackend*[B, E]() {.compileTime.} =
  ## Compile-time check that a renderer type B with element type E
  ## implements all required operations.
  ## Call this in your renderer module to verify compliance.
  ##
  ## Required operations:
  ##   createElement(tag: string): E
  ##   createTextNode(text: string): E
  ##   appendChild(parent, child: E)
  ##   insertBefore(parent, child, reference: E)
  ##   removeChild(parent, child: E)
  ##   setAttribute(node: E, name, value: string)
  ##   removeAttribute(node: E, name: string)
  ##   setTextContent(node: E, text: string)
  ##   setStyle(node: E, prop, value: string)
  ##   addEventListener(node: E, event: string, handler: proc())
  ##   firstChild(node: E): E
  ##   nextSibling(node: E): E
  ##   parentNode(node: E): E

  var b: B
  var e: E
  e = b.createElement("")
  e = b.createTextNode("")
  b.appendChild(e, e)
  b.insertBefore(e, e, e)
  b.removeChild(e, e)
  b.setAttribute(e, "", "")
  b.removeAttribute(e, "")
  b.setTextContent(e, "")
  b.setStyle(e, "", "")
  b.addEventListener(e, "", proc() = discard)
  e = b.firstChild(e)
  e = b.nextSibling(e)
  e = b.parentNode(e)
