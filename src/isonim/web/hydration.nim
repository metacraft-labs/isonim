## isonim/web/hydration.nim
##
## Client-side hydration: picks up SSR-rendered DOM nodes instead of creating
## new ones.  Events fired before hydration completes are queued and replayed.
##
## Port of dom-expressions client.js hydration functions.

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
# runHydrationEvents — replay queued events after hydration completes
# ---------------------------------------------------------------------------

proc runHydrationEvents*() =
  ## Replays events that were captured by the hydration script (_$HY)
  ## before the framework was ready. Each event is re-dispatched on its
  ## original target element.
  if sharedConfig.events.isNil:
    return

  var length: int
  {.emit: [length, " = ", sharedConfig.events, ".length;"].}

  for i in 0 ..< length:
    var el, ev: JsObject
    {.emit: [el, " = ", sharedConfig.events, "[", i, "][0];"].}
    {.emit: [ev, " = ", sharedConfig.events, "[", i, "][1];"].}
    # Re-dispatch the captured event on its original target
    {.emit: [el, ".dispatchEvent(", ev, ");"].}

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
  ## 4. Runs the component code (which calls getNextElement instead of
  ##    creating new nodes).
  ## 5. Replays queued events.

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

  try:
    gatherHydratable(element.Node, renderId)
    discard render(code, element)
  finally:
    sharedConfig.context = nil

  # Replay queued events
  runHydrationEvents()

  # Mark hydration as done
  sharedConfig.done = true
  {.emit: ["if (globalThis._$HY) globalThis._$HY.done = true;"].}
