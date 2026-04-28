## isonim/web/web_renderer.nim
##
## WebRenderer — a thin adapter that exposes the same proc interface as
## `MockRenderer` (createElement, setAttribute, appendChild, etc.) but
## delegates to real browser DOM operations via `dom_api`.
##
## This allows IsoNim views written generically over the renderer type
## to work with both `MockRenderer` (headless tests) and `WebRenderer`
## (live browser DOM) without code changes.
##
## Usage:
##   import isonim/web/web_renderer
##   let r = WebRenderer()
##   let div = r.createElement("div")
##   r.setAttribute(div, "class", "my-class")

when not defined(js):
  {.error: "isonim/web/web_renderer requires the JS backend".}

import isonim/web/dom_api

type
  WebRenderer* = object
    ## Stateless renderer adapter for the real browser DOM.
    ## All operations delegate to `dom_api` which emits `{.importcpp.}`
    ## calls against the browser's `document` object.

# ---------------------------------------------------------------------------
# Element creation
# ---------------------------------------------------------------------------

proc createElement*(r: WebRenderer; tag: string): Element =
  ## Create a real DOM element via `document.createElement`.
  dom_api.document.createElement(cstring(tag))

proc createTextNode*(r: WebRenderer; text: string): Node =
  ## Create a real DOM text node via `document.createTextNode`.
  dom_api.document.createTextNode(cstring(text))

# ---------------------------------------------------------------------------
# Tree manipulation
# ---------------------------------------------------------------------------

proc appendChild*(r: WebRenderer; parent: Element, child: Element) =
  ## Append a child element to a parent element.
  dom_api.appendChild(Node(parent), Node(child))

proc appendChild*(r: WebRenderer; parent: Element, child: Node) =
  ## Append a child node to a parent element.
  dom_api.appendChild(Node(parent), child)

proc appendChild*(r: WebRenderer; parent: Node, child: Node) =
  ## Append a child node to a parent node.
  dom_api.appendChild(parent, child)

# ---------------------------------------------------------------------------
# Attributes
# ---------------------------------------------------------------------------

proc setAttribute*(r: WebRenderer; node: Element; name, value: string) =
  ## Set an attribute on a real DOM element.
  dom_api.setAttribute(node, cstring(name), cstring(value))

proc removeAttribute*(r: WebRenderer; node: Element; name: string) =
  ## Remove an attribute from a real DOM element.
  dom_api.removeAttribute(node, cstring(name))

# ---------------------------------------------------------------------------
# Text content
# ---------------------------------------------------------------------------

proc setTextContent*(r: WebRenderer; node: Element; text: string) =
  ## Set the text content of a real DOM element.
  Node(node).textContent = cstring(text)

proc setTextContent*(r: WebRenderer; node: Node; text: string) =
  ## Set the text content of a real DOM node.
  node.textContent = cstring(text)

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

proc addEventListener*(r: WebRenderer; node: Element; event: string;
                        handler: proc()) =
  ## Attach a click (or other) event listener to a real DOM element.
  ## Wraps the no-arg handler into the EventHandler signature expected
  ## by `dom_api.addEventListener`.
  let wrappedHandler: EventHandler = proc(ev: Event) =
    handler()
  dom_api.addEventListener(Node(node), cstring(event), wrappedHandler)

# ---------------------------------------------------------------------------
# Navigation helpers (match MockRenderer interface)
# ---------------------------------------------------------------------------

proc firstChild*(r: WebRenderer; node: Element): Node =
  Node(node).firstChild

proc nextSibling*(r: WebRenderer; node: Element): Node =
  Node(node).nextSibling

proc parentNode*(r: WebRenderer; node: Element): Node =
  Node(node).parentNode
