## Minimal DOM renderer for the IsoNim Editor browser app.
## Wraps browser DOM API to satisfy the RendererBackend interface.

when not defined(js):
  {.error: "dom_renderer is JS-only".}

import std/dom

type
  DomRenderer* = object
    doc*: Document
      ## Which document new nodes are created in. `nil` means the editor's own.
      ##
      ## The preview is an iframe, and an element created by the editor's
      ## `document` cannot be appended into the frame's: same-origin or not,
      ## a node belongs to the document that made it. So mounting a project's
      ## UI into the preview needs a renderer pointed at
      ## `frame.contentDocument`, which is what this field is for.
      ##
      ## Defaulted rather than required so every existing `DomRenderer()` keeps
      ## working and keeps meaning "the editor's own document".
  DomElement* = Element

proc ownerDoc(r: DomRenderer): Document {.inline.} =
  if r.doc.isNil: document else: r.doc

proc createElement*(r: DomRenderer; tag: string): DomElement =
  r.ownerDoc.createElement(tag.cstring)

proc createTextNode*(r: DomRenderer; text: string): DomElement =
  # DOM createTextNode returns a Node, but we cast to Element for interface compat
  cast[Element](r.ownerDoc.createTextNode(text.cstring))

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

proc clearChildren*(r: DomRenderer; node: DomElement) =
  node.innerHTML = cstring""

proc textContent*(r: DomRenderer; node: DomElement): string =
  $node.textContent

proc setStyle*(r: DomRenderer; node: DomElement; prop, value: string) =
  let p = prop.cstring
  let v = value.cstring
  {.emit: [node, ".style.setProperty(", p, ",", v, ")"].}

proc setInnerHtml*(r: DomRenderer; node: DomElement; html: string) =
  ## Replace the element's inner DOM with the supplied HTML string.
  ## The brief tab uses this for the rendered markdown body.
  let h = html.cstring
  {.emit: [node, ".innerHTML = ", h].}

proc appendRawHtml*(r: DomRenderer; parent: DomElement; html: string) =
  ## Parse `html` and append the resulting nodes to `parent`, with NO wrapper.
  ##
  ## The DSL's `raw` node drops an HTML string in at the position it appears.
  ## SSR does that by concatenation, so there is no extra element; client mode
  ## has to match, or the same block renders two different trees and every
  ## selector written against one is wrong against the other. A `<template>`
  ## parses the fragment without adopting it into the layout, and appending
  ## `.content` moves the parsed children in as siblings.
  let h = html.cstring
  {.emit: [
    "(function (parent, html) {",
    "  const tpl = parent.ownerDocument.createElement('template');",
    "  tpl.innerHTML = html;",
    "  parent.appendChild(tpl.content);",
    "})(", parent, ", ", h, ");"].}

proc addPointerListener*(r: DomRenderer; node: DomElement; event: string;
    handler: proc(x, y: float; shift, alt: bool)) =
  ## A pointer event reduced to what a drag needs: where it is and which
  ## modifiers are down.
  ##
  ## Exists so a generic view can handle a drag without naming the browser's
  ## `Event` type -- the mock renderer offers the same proc over its own
  ## event, and the view is written once against both. Without it a view
  ## could only take a no-argument handler, which is how the property row's
  ## scrub ended up adding a fixed step per `mousemove` with no idea which
  ## way the pointer had gone.
  node.addEventListener(event.cstring, proc(e: Event) =
    let me = cast[MouseEvent](e)
    handler(me.clientX.float, me.clientY.float, me.shiftKey, me.altKey))

proc getAttribute*(r: DomRenderer; node: DomElement; name: string): string =
  ## Read an attribute. Returns the empty string when absent so the
  ## brief tab's copy-button locator behaves the same as the mock.
  var s: cstring
  let n = name.cstring
  {.emit: [s, " = ", node, ".getAttribute(", n, ") || ''"].}
  $s

proc addEventListener*(r: DomRenderer; node: DomElement; event: string;
                        handler: proc()) =
  node.addEventListener(event.cstring, proc(e: Event) = handler())

proc addEventListener*(r: DomRenderer; node: DomElement; event: string;
                        handler: proc(ev: Event)) =
  ## Overload for handlers that consume the browser `Event`. Passes the
  ## handler through unwrapped so it can call `ev.preventDefault`,
  ## `ev.stopPropagation`, inspect `ev.target`, etc.
  node.addEventListener(event.cstring, handler)

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

proc focus*(r: DomRenderer; node: DomElement) =
  ## Move keyboard focus to `node`. Used by the M58 choice-column rebuild
  ## to transfer focus to the active chip when a focused chip is removed
  ## by a backend-driven re-pin of the chip set.
  {.emit: [node, ".focus({preventScroll: true})"].}

proc activeElement*(r: DomRenderer): DomElement =
  ## Returns the currently-focused DOM element (or nil).
  ##
  ## Focus is per-document, so this follows `doc` for the same reason node
  ## creation does: a renderer pointed at the preview frame asking the editor's
  ## document what is focused would answer about the wrong window.
  cast[Element](r.ownerDoc.activeElement)
