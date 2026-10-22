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
import isonim/web/hydration
import isonim/rxcore
import isonim/core/boundary_meter
import isonim/core/nondet
import std/jsffi
export boundary_meter

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
  ##
  ## While `hydrate` runs, returns the server-rendered element whose
  ## `data-hk` key is this element's count instead (`claimElement`), so a
  ## `ui(r):` tree adopts the page it was rendered into.
  noteOp(boCreateElement, 1, tag)
  if isHydrating():
    let adopted = claimElement(cstring(tag))
    if not adopted.isNodeNil:
      return Element(adopted)
  dom_api.document.createElement(cstring(tag))

proc createTextNode*(r: WebRenderer; text: string): Node =
  ## Create a real DOM text node via `document.createTextNode`.
  noteOp(boCreateTextNode, 1, text)
  dom_api.document.createTextNode(cstring(text))

# ---------------------------------------------------------------------------
# Tree manipulation
# ---------------------------------------------------------------------------

proc appendChild*(r: WebRenderer; parent: Element, child: Element) =
  ## Append a child element to a parent element.
  noteOp(boAppendChild, 2)
  if isHydrating() and hydrationAppend(Node(parent), Node(child)):
    return
  dom_api.appendChild(Node(parent), Node(child))

proc appendChild*(r: WebRenderer; parent: Element, child: Node) =
  ## Append a child node to a parent element.
  noteOp(boAppendChild, 2)
  if isHydrating() and hydrationAppend(Node(parent), child):
    return
  dom_api.appendChild(Node(parent), child)

proc appendChild*(r: WebRenderer; parent: Node, child: Node) =
  ## Append a child node to a parent node.
  noteOp(boAppendChild, 2)
  if isHydrating() and hydrationAppend(parent, child):
    return
  dom_api.appendChild(parent, child)

# ---------------------------------------------------------------------------
# Attributes
# ---------------------------------------------------------------------------

proc setAttribute*(r: WebRenderer; node: Element; name, value: string) =
  ## Set an attribute on a real DOM element.
  noteOp(boSetAttribute, 1, name, value)
  dom_api.setAttribute(node, cstring(name), cstring(value))

proc removeAttribute*(r: WebRenderer; node: Element; name: string) =
  ## Remove an attribute from a real DOM element.
  noteOp(boRemoveAttribute, 1, name)
  dom_api.removeAttribute(node, cstring(name))

# ---------------------------------------------------------------------------
# Text content
# ---------------------------------------------------------------------------

proc setTextContent*(r: WebRenderer; node: Element; text: string) =
  ## Set the text content of a real DOM element.
  noteOp(boSetTextContent, 1, text)
  Node(node).textContent = cstring(text)

proc setTextContent*(r: WebRenderer; node: Node; text: string) =
  ## Set the text content of a real DOM node.
  noteOp(boSetTextContent, 1, text)
  node.textContent = cstring(text)

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

proc addEventListener*(r: WebRenderer; node: Element; event: string;
                        handler: proc()) =
  ## Attach a click (or other) event listener to a real DOM element.
  ## Wraps the no-arg handler into the EventHandler signature expected
  ## by the listener boundary.
  noteOp(boAddEventListener, 2, event)
  let wrappedHandler: EventHandler = proc(ev: Event) =
    handler()
  discard nondet.listen(cast[JsObject](node), event, wrappedHandler)

proc addEventListener*(r: WebRenderer; node: Element; event: string;
                        handler: proc(ev: Event)) =
  ## Event-consuming overload. Preserve the original callback identity at
  ## the boundary, so repeated native registrations remain deduplicated.
  noteOp(boAddEventListener, 2, event)
  discard nondet.listen(cast[JsObject](node), event, EventHandler(handler))

# ---------------------------------------------------------------------------
# Navigation helpers (match MockRenderer interface)
# ---------------------------------------------------------------------------

proc firstChild*(r: WebRenderer; node: Element): Node =
  noteOp(boFirstChild, 2)
  Node(node).firstChild

proc nextSibling*(r: WebRenderer; node: Element): Node =
  noteOp(boNextSibling, 2)
  Node(node).nextSibling

proc parentNode*(r: WebRenderer; node: Element): Node =
  noteOp(boParentNode, 2)
  Node(node).parentNode

# ---------------------------------------------------------------------------
# Style manipulation
# ---------------------------------------------------------------------------

proc setStyle*(r: WebRenderer; node: Element; prop: string; value: string) =
  ## Set a CSS style property on a real DOM element.
  noteOp(boSetStyle, 1, prop, value)
  dom_api.setStyleProperty(node, cstring(prop), cstring(value))

proc removeChild*(r: WebRenderer; parent: Element; child: Element) =
  ## Remove a child element from its parent in the real DOM.
  noteOp(boRemoveChild, 2)
  discard dom_api.removeChild(Node(parent), Node(child))

proc insertBefore*(r: WebRenderer; parent: Element; child: Element;
                    reference: Element) =
  ## Insert a child element before a reference element in the real DOM.
  noteOp(boInsertBefore, 3)
  discard dom_api.insertBefore(Node(parent), Node(child), Node(reference))

proc clearChildren*(r: WebRenderer; node: Element) =
  ## Remove all children from a real DOM element.
  ## Uses innerHTML = "" for efficiency.
  noteOp(boClearChildren, 1)
  node.innerHTML = cstring""

proc clearEventListeners*(r: WebRenderer; node: Element) =
  ## Placeholder for clearing event listeners on a real DOM element.
  ## In practice, the generic view code re-creates event listeners
  ## after clearChildren, so this is a no-op for the web renderer
  ## (the old element's listeners are replaced by new ones).
  ##
  ## For a full implementation, we would need to clone+replace the
  ## node, but the current generic view pattern does not require it.
  discard


when defined(isonimStableIds):
  {.emit: """
  (() => {
  if (globalThis.__isonimRememberIid) return;
  globalThis.__isonimIids = new Map();
  const iidCandidates = new Map();
  globalThis.__isonimValidateIids = (only) => {
    const entries = only === undefined ? iidCandidates : [[only, iidCandidates.get(only) || []]];
    for (const [iid, refs] of entries) {
      const alive = refs.filter(ref => ref.deref());
      const mounted = alive.filter(ref => ref.deref().isConnected);
      if (mounted.length > 1) throw new Error('duplicate live stable iid: ' + iid);
      const chosen = mounted[0] || alive[alive.length - 1];
      if (chosen) globalThis.__isonimIids.set(iid, chosen);
      else { globalThis.__isonimIids.delete(iid); iidCandidates.delete(iid); }
    }
  };
  let iidValidationPending = false;
  const scheduleIidValidation = () => {
    if (iidValidationPending) return;
    iidValidationPending = true;
    queueMicrotask(() => { iidValidationPending = false; globalThis.__isonimValidateIids(); });
  };
  globalThis.__isonimIidFinalizer = new FinalizationRegistry(({iid, ref}) => {
    const refs = (iidCandidates.get(iid) || []).filter(candidate => candidate !== ref && candidate.deref());
    if (refs.length) iidCandidates.set(iid, refs);
    else iidCandidates.delete(iid);
    // A collected predecessor never removes a newer claim for the same id.
    if (globalThis.__isonimIids.get(iid) === ref) {
      if (refs.length) globalThis.__isonimIids.set(iid, refs[refs.length - 1]);
      else globalThis.__isonimIids.delete(iid);
    }
  });
  globalThis.__isonimRememberIid = (iid, el) => {
    const refs = (iidCandidates.get(iid) || []).filter(ref => ref.deref());
    if (!refs.some(ref => ref.deref() === el)) {
      const ref = new WeakRef(el);
      refs.push(ref);
      iidCandidates.set(iid, refs);
      globalThis.__isonimIidFinalizer.register(el, {iid, ref});
      const previous = globalThis.__isonimIids.get(iid)?.deref();
      if (!previous || !previous.isConnected) globalThis.__isonimIids.set(iid, ref);
    }
    // Reconciliation may insert a successor before detaching its predecessor.
    // Validate the completed DOM batch, never overwrite a mounted predecessor.
    scheduleIidValidation();
  };
  new MutationObserver(scheduleIidValidation).observe(document, {childList: true, subtree: true});
  })();
  """.}
  proc rememberIid(iid: cstring; el: Element) {.importjs: "globalThis.__isonimRememberIid(#, #)".}
  proc resolveIidRaw(iid: cstring): Element {.importjs: "((iid) => { globalThis.__isonimValidateIids(iid); return globalThis.__isonimIids.get(iid)?.deref() || null; })(#)".}
  proc noteElement*(el: Element; iid: string) =
    ## The two-argument typed element hook indexes stable ids. Weak refs
    ## prevent detached trees from being retained; finalization removes keys
    ## only if no newer claim has replaced the collected node.
    rememberIid(cstring(iid), el)
  proc resolveIid*(iid: string): Element =
    ## Resolve the latest node claimed for an identity, or nil after GC.
    resolveIidRaw(cstring(iid))
