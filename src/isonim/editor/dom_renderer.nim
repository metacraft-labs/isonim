## Minimal DOM renderer for the IsoNim Editor browser app.
## Wraps browser DOM API to satisfy the RendererBackend interface.

when not defined(js):
  {.error: "dom_renderer is JS-only".}

import std/dom

type
  DomRenderer* = object
  DomElement* = Element

proc createElement*(r: DomRenderer; tag: string): DomElement =
  document.createElement(tag.cstring)

proc createTextNode*(r: DomRenderer; text: string): DomElement =
  # DOM createTextNode returns a Node, but we cast to Element for interface compat
  cast[Element](document.createTextNode(text.cstring))

proc appendChild*(r: DomRenderer; parent, child: DomElement) =
  parent.appendChild(child)

proc insertBefore*(r: DomRenderer; parent, child, reference: DomElement) =
  parent.insertBefore(child, reference)

proc removeChild*(r: DomRenderer; parent, child: DomElement) =
  parent.removeChild(child)

proc setAttribute*(r: DomRenderer; node: DomElement; name, value: string) =
  node.setAttribute(name.cstring, value.cstring)

proc removeAttribute*(r: DomRenderer; node: DomElement; name: string) =
  node.removeAttribute(name.cstring)

proc setTextContent*(r: DomRenderer; node: DomElement; text: string) =
  node.textContent = text.cstring

proc textContent*(r: DomRenderer; node: DomElement): string =
  $node.textContent

proc setStyle*(r: DomRenderer; node: DomElement; prop, value: string) =
  {.emit: [node, ".style.setProperty(", prop, ",", value, ")"].}

proc addEventListener*(r: DomRenderer; node: DomElement; event: string;
                        handler: proc()) =
  node.addEventListener(event.cstring, proc(e: Event) = handler())

proc firstChild*(r: DomRenderer; node: DomElement): DomElement =
  cast[Element](node.firstChild)

proc nextSibling*(r: DomRenderer; node: DomElement): DomElement =
  cast[Element](node.nextSibling)

proc parentNode*(r: DomRenderer; node: DomElement): DomElement =
  node.parentElement
