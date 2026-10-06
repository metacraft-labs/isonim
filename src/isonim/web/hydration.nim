## isonim/web/hydration.nim
##
## Client-side hydration: picks up SSR-rendered DOM nodes instead of creating
## new ones.  Events fired before hydration completes are queued and replayed.
##
## Port of dom-expressions client.js hydration functions, plus the adoption
## the `ui(r):` DSL needs (IsoNim.md § Hydration): while `hydrate` runs, the
## web renderer's `createElement` returns the server-rendered element whose
## `data-hk` key matches its own count (`claimElement`), and its
## `appendChild` leaves an adopted child where the server put it
## (`hydrationAppend`). Text nodes are not adopted: the client's text node
## goes in front of the server's, which is then removed as unclaimed, so
## the visible content does not change.

when not defined(js):
  {.error: "isonim/web/hydration requires the JS backend".}

import std/jsffi
import isonim/web/dom_api
import isonim/web/client
import isonim/rxcore

# ---------------------------------------------------------------------------
# gatherHydratable — scan DOM for [data-hk] elements and populate registry
# ---------------------------------------------------------------------------

proc gatherHydratable*(element: Node, root: cstring = cstring"") =
  ## Scans element for descendants with `data-hk` attributes and populates
  ## `sharedConfig.registry`.  If `root` is non-empty only keys that start
  ## with `root` are collected.
  if sharedConfig.registry == nil:
    sharedConfig.registry = newHydrationRegistry()

  # querySelectorAll("[data-hk]") on the element
  var templates: JsObject
  {.emit: [templates, " = ", element, ".querySelectorAll('*[data-hk]');"].}

  var length: int
  {.emit: [length, " = ", templates, ".length;"].}

  for i in 0 ..< length:
    var node: JsObject
    {.emit: [node, " = ", templates, "[", i, "];"].}
    var key: cstring
    {.emit: [key, " = ", node, ".getAttribute('data-hk');"].}
    if key != nil:
      var matches = true
      if root != cstring"" and root != nil:
        {.emit: [matches, " = ", key, ".startsWith(", root, ");"].}
      if matches and not sharedConfig.registry.has(key):
        sharedConfig.registry.set(key, node)

# ---------------------------------------------------------------------------
# getNextElement — reuse existing DOM node or create via template
# ---------------------------------------------------------------------------

proc getNextElement*(tmplFn: proc(): Node): Node =
  ## During hydration returns the existing DOM node from the registry
  ## (keyed by the current hydration key).  Outside hydration, or if
  ## no matching node is found, falls back to calling `tmplFn()`.
  if not isHydrating():
    return tmplFn()

  let key = getHydrationKey()
  if sharedConfig.registry == nil:
    return tmplFn()

  let existing = sharedConfig.registry.get(key)
  var isNil: bool
  {.emit: [isNil, " = (", existing, " == null || ", existing, " === undefined);"].}
  if isNil:
    return tmplFn()

  sharedConfig.registry.delete(key)
  return cast[Node](existing)

# ---------------------------------------------------------------------------
# getNextMatch — find next sibling matching a given node name
# ---------------------------------------------------------------------------

proc getNextMatch*(el: Node, nodeName: cstring): Node =
  ## Walks nextSibling from `el` looking for a node whose nodeName matches.
  ## Returns the matching node or nil.
  var current = el.nextSibling
  while not current.isNodeNil:
    var curName: cstring
    {.emit: [curName, " = ", current, ".nodeName;"].}
    if curName == nodeName:
      return current
    current = current.nextSibling
  return nil

# ---------------------------------------------------------------------------
# getNextMarker — find the next comment node (Suspense boundary marker)
# ---------------------------------------------------------------------------

proc getNextMarker*(start: Node): (Node, seq[Node]) =
  ## Walks from `start` collecting nodes until a comment node (nodeType 8)
  ## is found. Returns the comment node and the list of in-between nodes.
  var nodes: seq[Node] = @[]
  var current = start
  while not current.isNodeNil:
    if current.nodeType == 8:  # Comment node
      return (current, nodes)
    nodes.add(current)
    current = current.nextSibling
  return (nil, nodes)


# ---------------------------------------------------------------------------
# Adoption: the web renderer's createElement / appendChild during hydration
# ---------------------------------------------------------------------------

{.emit: """
var isonimHy = {
  adopted: [],
  mismatches: 0,
  // Place `child` in the adopted `parent`: a server node stays where it is
  // (the unclaimed nodes between the cursor and it are removed); a new node
  // goes in at the cursor.
  append: function(parent, child) {
    var cur = parent.__isonimHyCursor;
    if (cur && cur.parentNode !== parent) cur = null;
    if (child.parentNode === parent) {
      var n = cur;
      while (n && n !== child) n = n.nextSibling;
      if (n === child) {
        while (cur !== child) { var nx = cur.nextSibling; parent.removeChild(cur); cur = nx; }
        parent.__isonimHyCursor = child.nextSibling;
        return;
      }
    }
    parent.insertBefore(child, cur);
  },
  // Hydration is over: remove what no client node claimed, forget cursors.
  finish: function() {
    for (var i = 0; i < isonimHy.adopted.length; i++) {
      var el = isonimHy.adopted[i];
      var cur = el.__isonimHyCursor;
      if (cur && cur.parentNode === el) {
        while (cur) { var nx = cur.nextSibling; el.removeChild(cur); cur = nx; }
      }
      delete el.__isonimHyCursor;
      delete el.__isonimHy;
    }
    isonimHy.adopted = [];
  }
};
""".}

proc claimElement*(tag: cstring): Node =
  ## During hydration: the server-rendered element for the next hydration
  ## key, when it is a `tag`; nil otherwise (the caller creates a new one,
  ## and the miss is counted in `hydrationMismatches`). Consumes the key
  ## either way, as `getNextElement` does.
  let key = getHydrationKey()
  if sharedConfig.registry == nil:
    {.emit: "isonimHy.mismatches++;".}
    return nil
  let existing = sharedConfig.registry.get(key)
  var ok: bool
  {.emit: [ok, " = (", existing, " != null && String(", existing,
           ".localName).toLowerCase() === String(", tag, ").toLowerCase());"].}
  if not ok:
    {.emit: "isonimHy.mismatches++;".}
    return nil
  sharedConfig.registry.delete(key)
  {.emit: [existing, ".__isonimHy = true; ", existing, ".__isonimHyCursor = ",
           existing, ".firstChild; isonimHy.adopted.push(", existing, ");"].}
  return cast[Node](existing)

proc hydrationAppend*(parent, child: Node): bool =
  ## During hydration, places `child` in `parent` when `parent` is an
  ## adopted server element (see the module doc). Returns false when it is
  ## not, and the caller appends as usual.
  var adopted: bool
  {.emit: [adopted, " = (", parent, " != null && ", parent, ".__isonimHy === true);"].}
  if adopted:
    {.emit: ["isonimHy.append(", parent, ", ", child, ");"].}
  adopted

proc hydrationMismatches*(): int =
  ## Elements the last `hydrate` could not adopt (no server element with
  ## their key, or one with another tag).
  {.emit: [result, " = isonimHy.mismatches;"].}

# ---------------------------------------------------------------------------
# runHydrationEvents — replay queued events after hydration completes
# ---------------------------------------------------------------------------

proc runHydrationEvents*() =
  ## Replays events that the hydration script (_$HY) recorded before the
  ## framework was ready, once each, in order, now that the listeners are
  ## attached to the very nodes the events reached.
  ##
  ## Each is replayed as a new, plain `Event` of the same type and bubbling
  ## (not as a re-dispatch of the original): a re-dispatched `MouseEvent`
  ## "click" would run the element's activation behaviour a second time,
  ## e.g. un-toggle the checkbox the user just toggled. The original is
  ## available to handlers as `event.isonimReplayOf`. Default actions the
  ## browser already took (a navigation, a form submission) are not undone.
  if sharedConfig.events.isNil:
    return

  var length: int
  {.emit: [length, " = ", sharedConfig.events, ".length;"].}

  for i in 0 ..< length:
    var el, ev: JsObject
    {.emit: [el, " = ", sharedConfig.events, "[", i, "][0];"].}
    {.emit: [ev, " = ", sharedConfig.events, "[", i, "][1];"].}
    {.emit: ["""
      var target = (""", ev, """.target && """, ev, """.target.nodeType === 1) ? """, ev, """.target : """, el, """;
      var replay = """, ev, """;
      if (typeof Event === 'function' && """, ev, """ instanceof Event) {
        replay = new Event(""", ev, """.type, {bubbles: """, ev, """.bubbles,
          cancelable: """, ev, """.cancelable, composed: """, ev, """.composed});
        Object.defineProperty(replay, 'isonimReplayOf', {value: """, ev, """});
      }
      target.dispatchEvent(replay);
    """].}

# ---------------------------------------------------------------------------
# hydrate — main entry point
# ---------------------------------------------------------------------------

proc hydrate*(code: proc(): Node, element: Element,
              renderId: cstring = cstring"") =
  ## Hydrates server-rendered HTML inside `element`.
  ##
  ## 1. Checks globalThis._$HY for the hydration context from SSR.
  ## 2. Populates sharedConfig with registry, events, completed set.
  ## 3. Gathers hydratable elements from the existing DOM.
  ## 4. Runs the component code under a reactive root. Its elements are the
  ##    server's (the web renderer's `createElement` claims them by key,
  ##    `getNextElement` likewise); the root is appended to `element` only
  ##    if it is not already there.
  ## 5. Removes server nodes no client node claimed inside adopted elements.
  ## 6. Stops the bootstrap's recording, replays what it recorded, and sets
  ##    `_$HY.done` (and `_$HY.mismatches`).
  ##
  ## Without a `_$HY` (no server-rendered page), or when it is already
  ## done, this is `render`.

  # Check if _$HY exists and whether hydration was already completed
  var hyExists, hyDone: bool
  {.emit: [hyExists, " = (typeof globalThis._$HY !== 'undefined' && globalThis._$HY != null);"].}

  if hyExists:
    {.emit: [hyDone, " = !!(globalThis._$HY.done);"].}
  else:
    hyDone = true  # No hydration context — just do a normal render

  if hyDone:
    # Hydration already done or no SSR context — fall back to normal render
    discard render(code, element)
    return

  # Wire up sharedConfig from globalThis._$HY
  {.emit: [sharedConfig.completed, " = globalThis._$HY.completed;"].}
  {.emit: [sharedConfig.events, " = globalThis._$HY.events;"].}

  sharedConfig.load = proc(id: cstring): JsObject =
    var res: JsObject
    {.emit: [res, " = globalThis._$HY.r[", id, "];"].}
    return res

  sharedConfig.has = proc(id: cstring): bool =
    {.emit: [result, " = (", id, " in globalThis._$HY.r);"].}

  sharedConfig.gather = proc(root: cstring) =
    gatherHydratable(element.Node, root)

  sharedConfig.registry = newHydrationRegistry()

  sharedConfig.context = HydrationContext(
    id: $renderId,
    count: 0,
  )
  {.emit: "isonimHy.mismatches = 0; isonimHy.adopted = [];".}

  try:
    gatherHydratable(element.Node, renderId)
    createRoot proc(dispose: proc()) =
      let node = untrack(proc(): Node = code())
      if not node.isNodeNil and node.parentNode != element.Node:
        element.Node.appendChild(node)
  finally:
    {.emit: "isonimHy.finish();".}
    sharedConfig.context = nil

  # Take the queue (the bootstrap stops recording), then replay it.
  {.emit: "globalThis._$HY.events = null;".}
  runHydrationEvents()
  sharedConfig.events = nil

  # Mark hydration as done
  sharedConfig.done = true
  {.emit: ["if (globalThis._$HY) { globalThis._$HY.mismatches = isonimHy.mismatches; globalThis._$HY.done = true; }"].}
  if hydrationMismatches() > 0:
    {.emit: "console.warn('isonim hydrate: ' + isonimHy.mismatches + ' element(s) had no server-rendered match and were created anew');".}
