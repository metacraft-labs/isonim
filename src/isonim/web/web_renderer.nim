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

template createElementBody(tag, projectNative: untyped): untyped =
  # One hydration/native algorithm; each caller fixes its result projection at
  # compile time. The ordinary projection retains the original tail expression.
  noteOp(boCreateElement, 1, tag)
  if isHydrating():
    let adopted = claimElement(cstring(tag))
    if not adopted.isNodeNil:
      return Element(adopted)
  projectNative(dom_api.document.createElement(cstring(tag)))

template ordinaryElement(native: untyped): untyped = native

proc createElement*(r: WebRenderer; tag: string): Element =
  ## Create a real DOM element, or adopt its server-rendered hydration match.
  createElementBody(tag, ordinaryElement)

# Private compiler declarations live after all ordinary operations below.
# Keeping this former declaration span empty preserves ordinary debug locations
# as well as generated symbol identities during that relocation. A private
# feature that is merely compiled in must not perturb an ordinary bundle.





























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

proc appendRawHtml*(r: WebRenderer; parent: Element; html: string) =
  ## `raw <html>` in a `ui(r):` block: appends the nodes `html` parses to
  ## (trusted markup only: sanitized content an application stored, never
  ## a member's raw text). While `hydrate` runs and `parent` is an adopted
  ## server element, the server's nodes for the same markup are kept in
  ## place instead (`hydrationAppendRaw`), so the fragment's elements keep
  ## their identity; markup that differs is a counted mismatch, and the
  ## client's nodes replace the server's.
  noteOp(boSetInnerHtml, 1, html)
  if isHydrating() and hydrationAppendRaw(Node(parent), cstring(html)):
    return
  {.emit: ["""var t = document.createElement('template'); t.innerHTML = """, cstring(html),
           """; """, parent, """.appendChild(t.content);"""].}

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

proc webNodeIsElement(n: Node): bool {.importjs: "(#.nodeType === 1)".}
proc webInputValue(e: Element): cstring {.importjs: "(#.value || '')".}
proc webSetInputValue(e: Element; v: cstring) {.importjs: "#.value = #".}
proc webSetChecked(e: Element; v: bool) {.importjs: "#.checked = #".}

proc isNilNode*(r: WebRenderer; node: Element): bool =
  ## Whether `node` is absent (`null`): the navigation procs below answer it
  ## for "no such element".
  isNodeNil(Node(node))

proc firstElementChild*(r: WebRenderer; node: Element): Element =
  ## The first ELEMENT child of `node` (text and comment nodes skipped), or
  ## nil. Typed as the renderer's element, unlike `firstChild`, so a view
  ## generic over the renderer can walk an element's children.
  noteOp(boFirstChild, 2)
  var child = Node(node).firstChild
  while not isNodeNil(child) and not webNodeIsElement(child):
    child = child.nextSibling
  cast[Element](child)

proc nextElementSibling*(r: WebRenderer; node: Element): Element =
  ## The next ELEMENT sibling of `node`, or nil.
  noteOp(boNextSibling, 2)
  var sibling = Node(node).nextSibling
  while not isNodeNil(sibling) and not webNodeIsElement(sibling):
    sibling = sibling.nextSibling
  cast[Element](sibling)

proc getAttribute*(r: WebRenderer; node: Element; name: string): string =
  ## An attribute's value, or the empty string when it is absent (as
  ## `MockRenderer.getAttribute`).
  let raw = dom_api.getAttribute(node, cstring(name))
  result = if raw.isNil: "" else: $raw
  noteOp(boGetAttribute, 1, name, result)

proc inputValue*(r: WebRenderer; node: Element): string =
  ## The current `value` of a form control.
  result = $webInputValue(node)
  noteOp(boInputValue, 1, result)

proc setInputValue*(r: WebRenderer; node: Element; value: string) =
  noteOp(boSetInputValue, 1, value)
  webSetInputValue(node, cstring(value))

proc setChecked*(r: WebRenderer; node: Element; checked: bool) =
  ## Set a checkbox's or radio button's `checked` state (the property, which
  ## is what the control shows — not the `checked` attribute, which is only
  ## its initial value).
  noteOp(boSetAttribute, 1, "checked", if checked: "true" else: "false")
  webSetChecked(node, checked)

proc setInnerHtml*(r: WebRenderer; node: Element; html: string) =
  ## Replace `node`'s children with parsed `html` (trusted markup only: a
  ## view's own static SVG, never data).
  noteOp(boSetInnerHtml, 1, html)
  node.innerHTML = cstring(html)

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
  import isonim/core/private/iid_lookup
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
  proc noteElement*(el: Element; iid: string) =
    ## The two-argument typed element hook indexes stable ids. Weak refs
    ## prevent detached trees from being retained; finalization removes keys
    ## only if no newer claim has replaced the collected node.
    rememberIid(cstring(iid), el)
  proc resolveIid*(iid: string): Element =
    ## Resolve the latest node claimed for an identity, or nil after GC.
    cast[Element](resolveIidLookup(cstring(iid)))


when defined(js) and defined(isonimInternalClientOrdinals):
  import nim_everywhere/raw_nondet
  type InternalClientCreationOrdinals* = distinct JsObject
    ## Private forward metadata for one caller-owned creation namespace.
    ## Construct and use in the same realm at session start. Reachability is
    ## the only lifetime; there is no reset, inverse lookup or session admission.

  proc newInternalClientCreationOrdinals*(): InternalClientCreationOrdinals
      {.importjs: "({ordinals: new WeakMap(), next: 1n})", tags: [RawNondet].}
    ## Allocate one weak forward map and an exact integer counter, explicitly.

  proc assignInternalClientCreationOrdinal(context: InternalClientCreationOrdinals;
      element: Element): Element {.importjs: """(function(c,e){
var n=c.next; var successor=n+1n; c.ordinals.set(e,n); c.next=successor; return e;
})(#,#)""", tags: [RawNondet].}

  proc internalClientCreationOrdinal*(context: InternalClientCreationOrdinals;
      element: Element): cstring {.importjs: """(function(c,e){
var n=c.ordinals.get(e); return n===undefined ? null : n.toString(10);
})(#,#)""", tags: [RawNondet].}
    ## Exact positive decimal metadata, or JS null for a node this context
    ## never created. Detachment/removal/adoption do not erase existing metadata.

  proc createInternalClientElement*(context: InternalClientCreationOrdinals;
      r: WebRenderer; tag: string): Element =
    ## Number only a successful new native element, before returning it. Real
    ## hydration adoption returns without assigning or consuming a new number.
    ## Native failures precede all metadata work; later allocation failures
    ## propagate with no rollback or automatic retry promise.
    template numberedElement(native: untyped): untyped =
      assignInternalClientCreationOrdinal(context, native)
    createElementBody(tag, numberedElement)

when defined(isonimInternalClientTargets):
  when not defined(isonimInternalClientRouting) or not defined(isonimInternalClientOrdinals):
    {.error: "private client targets require client routing and ordinals".}

  type InternalClientTargetContext* = distinct JsObject
    ## Explicit same-realm linkage. The inverse retains scalar keys and weak
    ## wrappers only; its reachability is its lifetime, with no reset policy.

  proc makeInternalClientTargetContext(forward: InternalClientCreationOrdinals):
      InternalClientTargetContext {.importjs: "({forward: #, targets: new Map()})",
      tags: [RawNondet].}

  proc newInternalClientTargetContext*(): InternalClientTargetContext =
    ## Allocate one unchanged forward namespace and its separate weak inverse.
    makeInternalClientTargetContext(newInternalClientCreationOrdinals())

  proc targetForwardContext(context: InternalClientTargetContext):
      InternalClientCreationOrdinals {.importjs: "#.forward", tags: [RawNondet].}

  proc requireInternalClientTargetContext(context: InternalClientTargetContext)
      {.importjs: """(function(c){
if(!c || !c.forward || !(c.forward.ordinals instanceof WeakMap) ||
 typeof c.forward.next !== 'bigint' || !(c.targets instanceof Map))
 throw new TypeError('invalid private client target context');
})(#)""", tags: [RawNondet].}

  proc requireInternalClientTargetLink(context: InternalClientTargetContext;
      forward: InternalClientCreationOrdinals) {.importjs: """(function(c,f){
if(c.forward !== f) throw new TypeError('mismatched private client target context');
})(#,#)""", tags: [RawNondet].}

  proc hasInternalClientTargets(context: InternalClientTargetContext): bool
      {.importjs: "(# != null)", tags: [RawNondet].}

  proc indexInternalClientTarget(context: InternalClientTargetContext;
      element: Element): Element {.importjs: """(function(c,e){
var n=c.forward.ordinals.get(e); var ref=new WeakRef(e); c.targets.set(n,ref); return e;
})(#,#)""", tags: [RawNondet].}

  proc createInternalClientTargetElement(context: InternalClientTargetContext;
      forward: InternalClientCreationOrdinals; r: WebRenderer; tag: string): Element =
    # Linkage is checked before the shared meter/HY/native operation. The fixed
    # projection commits forward metadata first, then indexes that ACTUAL value.
    # A later allocation failure propagates; this context must then be abandoned.
    requireInternalClientTargetContext(context)
    requireInternalClientTargetLink(context, forward)
    template indexedElement(native: untyped): untyped =
      indexInternalClientTarget(context,
        assignInternalClientCreationOrdinal(forward, native))
    createElementBody(tag, indexedElement)

  proc internalClientTargetOrdinal*(context: InternalClientTargetContext;
      element: Element): cstring =
    ## Observe the same production forward metadata; never populate the inverse.
    requireInternalClientTargetContext(context)
    internalClientCreationOrdinal(targetForwardContext(context), element)

  proc internalClientTargetIid(target: cstring): cstring
      {.importjs: """(function(t){
return typeof t==='string' && t.startsWith('iid:') && t.length>4 ? t.slice(4) : null;
})(#)""", tags: [RawNondet].}

  proc lookupInternalClientTarget(context: InternalClientTargetContext;
      target: cstring): JsObject {.importjs: """(function(c,t){
if(typeof t!=='string') return null;
if(t==='doc') return document;
if(t==='win') return window;
// Unlike the usual end anchor, the final negative lookahead also excludes a trailing newline.
if(!/^ord:[1-9][0-9]*(?![\s\S])/.test(t)) return null;
var n=BigInt(t.slice(4)); var ref=c.targets.get(n);
return ref===undefined ? null : ref.deref() || null;
})(#,#)""", tags: [RawNondet].}

  proc resolveInternalClientTarget*(context: InternalClientTargetContext;
      target: cstring): JsObject =
    ## Resolve a live weak ordinal in this namespace, or the existing build-wide
    ## IID registry. Detached caller-held elements remain valid live results.
    ## Dynamic dereference remains visible to installed recorder instrumentation.
    requireInternalClientTargetContext(context)
    when defined(isonimStableIds):
      let iid = internalClientTargetIid(target)
      if not iid.isNil:
        return resolveIidLookup(iid)
    lookupInternalClientTarget(context, target)

when defined(isonimInternalClientRouting):
  when not defined(isonimInternalClientOrdinals):
    {.error: "private client routing requires isonimInternalClientOrdinals".}

  type InternalClientRenderer* = object
    ## Explicit trusted linkage for one caller-owned creation namespace. Copies
    ## retain the same context; construction never allocates a new namespace.
    context: InternalClientCreationOrdinals
    ordinary: WebRenderer
    when defined(isonimInternalClientTargets):
      targets: InternalClientTargetContext

  proc requireClientContext(context: InternalClientCreationOrdinals)
      {.importjs: """(function(c){if(!c || !(c.ordinals instanceof WeakMap) ||
typeof c.next !== 'bigint') throw new TypeError('invalid private client creation context');})(#)""",
       tags: [RawNondet].}

  proc newInternalClientRenderer*(context: InternalClientCreationOrdinals): InternalClientRenderer =
    requireClientContext(context)
    InternalClientRenderer(context: context)

  when defined(isonimInternalClientTargets):
    proc newInternalClientTargetRenderer*(context: InternalClientTargetContext): InternalClientRenderer =
      requireInternalClientTargetContext(context)
      InternalClientRenderer(context: targetForwardContext(context), targets: context)

  proc createElement*(r: InternalClientRenderer; tag: string): Element =
    when defined(isonimInternalClientTargets):
      if hasInternalClientTargets(r.targets):
        return createInternalClientTargetElement(r.targets, r.context, r.ordinary, tag)
    requireClientContext(r.context)
    createInternalClientElement(r.context, r.ordinary, tag)

  proc appendRawHtml*(r: InternalClientRenderer; parent: Element; html: string)
      {.error: "private client routing does not admit parsed raw HTML".}
  proc setInnerHtml*(r: InternalClientRenderer; node: Element; html: string)
      {.error: "private client routing does not admit parsed inner HTML".}

  proc createTextNode*(r: InternalClientRenderer; text: string): Node =
    r.ordinary.createTextNode(text)

  proc appendChild*(r: InternalClientRenderer; parent, child: Element) =
    r.ordinary.appendChild(parent, child)

  proc appendChild*(r: InternalClientRenderer; parent: Element; child: Node) =
    r.ordinary.appendChild(parent, child)

  proc appendChild*(r: InternalClientRenderer; parent, child: Node) =
    r.ordinary.appendChild(parent, child)

  proc setAttribute*(r: InternalClientRenderer; node: Element; name, value: string) =
    r.ordinary.setAttribute(node, name, value)

  proc removeAttribute*(r: InternalClientRenderer; node: Element; name: string) =
    r.ordinary.removeAttribute(node, name)

  proc setTextContent*(r: InternalClientRenderer; node: Element; text: string) =
    r.ordinary.setTextContent(node, text)

  proc setTextContent*(r: InternalClientRenderer; node: Node; text: string) =
    r.ordinary.setTextContent(node, text)

  proc addEventListener*(r: InternalClientRenderer; node: Element; event: string; handler: proc()) =
    r.ordinary.addEventListener(node, event, handler)

  proc addEventListener*(r: InternalClientRenderer; node: Element; event: string; handler: proc(ev: Event)) =
    r.ordinary.addEventListener(node, event, handler)

  proc firstChild*(r: InternalClientRenderer; node: Element): Node =
    r.ordinary.firstChild(node)

  proc nextSibling*(r: InternalClientRenderer; node: Element): Node =
    r.ordinary.nextSibling(node)

  proc parentNode*(r: InternalClientRenderer; node: Element): Node =
    r.ordinary.parentNode(node)

  proc isNilNode*(r: InternalClientRenderer; node: Element): bool =
    r.ordinary.isNilNode(node)

  proc firstElementChild*(r: InternalClientRenderer; node: Element): Element =
    r.ordinary.firstElementChild(node)

  proc nextElementSibling*(r: InternalClientRenderer; node: Element): Element =
    r.ordinary.nextElementSibling(node)

  proc getAttribute*(r: InternalClientRenderer; node: Element; name: string): string =
    r.ordinary.getAttribute(node, name)

  proc inputValue*(r: InternalClientRenderer; node: Element): string =
    r.ordinary.inputValue(node)

  proc setInputValue*(r: InternalClientRenderer; node: Element; value: string) =
    r.ordinary.setInputValue(node, value)

  proc setChecked*(r: InternalClientRenderer; node: Element; checked: bool) =
    r.ordinary.setChecked(node, checked)

  proc setStyle*(r: InternalClientRenderer; node: Element; prop, value: string) =
    r.ordinary.setStyle(node, prop, value)

  proc removeChild*(r: InternalClientRenderer; parent, child: Element) =
    r.ordinary.removeChild(parent, child)

  proc insertBefore*(r: InternalClientRenderer; parent, child, reference: Element) =
    r.ordinary.insertBefore(parent, child, reference)

  proc clearChildren*(r: InternalClientRenderer; node: Element) =
    r.ordinary.clearChildren(node)

  proc clearEventListeners*(r: InternalClientRenderer; node: Element) =
    r.ordinary.clearEventListeners(node)

# A private routing preparation build excludes the WHOLE effective HMR mode,
# even if its creator happens to be removed by dead-code elimination. Ordinary
# HMR builds do not select this private facade and retain their existing meaning.
when defined(isonimInternalClientRouting) and defined(isonimHmr):
  {.error: "private client routing does not admit HMR mode".}
