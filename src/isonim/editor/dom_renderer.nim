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
  let p = prop.cstring
  let v = value.cstring
  {.emit: [node, ".style.setProperty(", p, ",", v, ")"].}

proc addEventListener*(r: DomRenderer; node: DomElement; event: string;
                        handler: proc()) =
  node.addEventListener(event.cstring, proc(e: Event) = handler())

proc inputValue*(r: DomRenderer; node: DomElement): string =
  var value: cstring
  {.emit: [value, " = ", node, ".value || ''"].}
  $value

proc setInputValue*(r: DomRenderer; node: DomElement; value: string) =
  let v = value.cstring
  {.emit: [node, ".value = ", v].}

proc enableDragScroll*(r: DomRenderer; node: DomElement) =
  {.emit: [node, """
    .style.cursor = 'grab';
    (() => {
      const el = """, node, """;
      let dragging = false;
      let startX = 0;
      let startY = 0;
      let startLeft = 0;
      let startTop = 0;
      el.addEventListener('mousedown', (event) => {
        if (event.button !== 0) return;
        dragging = true;
        startX = event.clientX;
        startY = event.clientY;
        startLeft = el.scrollLeft;
        startTop = el.scrollTop;
        el.style.cursor = 'grabbing';
        event.preventDefault();
      });
      window.addEventListener('mousemove', (event) => {
        if (!dragging) return;
        el.scrollLeft = startLeft - (event.clientX - startX);
        el.scrollTop = startTop - (event.clientY - startY);
      });
      window.addEventListener('mouseup', () => {
        if (!dragging) return;
        dragging = false;
        el.style.cursor = 'grab';
      });
    })()
  """].}

proc firstChild*(r: DomRenderer; node: DomElement): DomElement =
  cast[Element](node.firstChild)

proc nextSibling*(r: DomRenderer; node: DomElement): DomElement =
  cast[Element](node.nextSibling)

proc parentNode*(r: DomRenderer; node: DomElement): DomElement =
  node.parentElement
