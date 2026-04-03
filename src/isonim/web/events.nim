## isonim/web/events.nim
##
## Event delegation system.
## Attaches a single listener per event type at the document level
## and dispatches to the correct handler via DOM traversal.
##
## Port of dom-expressions event delegation.

when not defined(js):
  {.error: "isonim/web/events requires the JS backend".}

import isonim/core/js_collections
import isonim/web/dom_api

# Track which events have been delegated on the document.
# Uses JS-native Set to avoid pulling std/sets (and its hash table) into the bundle.
var delegatedEvents: JsSet[cstring]

proc ensureDelegatedEvents() =
  ## Lazily initialize the set (JS Set can't be initialized at module scope as threadvar).
  if delegatedEvents.isNil:
    delegatedEvents = newJsSet[cstring]()

proc jsConcatCstrings(a, b: cstring): cstring {.importcpp: "(# + #)".}

proc eventHandler(e: Event) {.exportc.} =
  ## The document-level handler that walks up the DOM tree looking for
  ## delegated event handlers stored as $$<eventName> properties on nodes.
  var node = e.target
  let key = jsConcatCstrings(cstring"$$", e.`type`)

  while not node.isNodeNil:
    let handler = node.getJsProp(key)
    if not handler.isNull:
      let dataKey = jsConcatCstrings(key, cstring"Data")
      let data = node.getJsProp(dataKey)
      if not data.isNull:
        # handler.call(node, data, e) -- call with data
        {.emit: [handler, ".call(", node, ",", data, ",", e, ");"].}
      else:
        # handler.call(node, e) -- call without data
        {.emit: [handler, ".call(", node, ",", e, ");"].}
      if e.cancelBubble:
        return
    # Walk up the tree
    node = node.parentNode

proc delegateEvents*(eventNames: openArray[cstring]) =
  ## Registers document-level handlers for the given event names.
  ## Each event type is only delegated once.
  ensureDelegatedEvents()
  for name in eventNames:
    if name notin delegatedEvents:
      delegatedEvents.incl(name)
      document.Node.addEventListener(name, eventHandler)

proc delegateEvents*(eventNames: openArray[string]) =
  ## String overload for backward compatibility.
  ensureDelegatedEvents()
  for name in eventNames:
    let cs = cstring(name)
    if cs notin delegatedEvents:
      delegatedEvents.incl(cs)
      document.Node.addEventListener(cs, eventHandler)

proc addEventListenerWeb*(node: Node, name: cstring, handler: EventHandler,
    delegate: bool = false) =
  ## Attach an event listener to a node.
  ## If delegate=true, stores the handler as a property for event delegation.
  ## If delegate=false, uses native addEventListener.
  if delegate:
    let propName = jsConcatCstrings(cstring"$$", name)
    node.setJsPropHandler(propName, handler)
  else:
    node.addEventListener(name, handler)

proc addEventListenerWeb*(node: Node, name: string, handler: EventHandler,
    delegate: bool = false) =
  ## String overload for backward compatibility.
  addEventListenerWeb(node, cstring(name), handler, delegate)

proc clearDelegatedEvents*() =
  ## Remove all delegated event handlers from the document.
  ensureDelegatedEvents()
  # JsSet doesn't have a Nim iterator, use JS forEach
  {.emit: [delegatedEvents, ".forEach(function(name) { ", document, ".removeEventListener(name, ", eventHandler, "); });"].}
  delegatedEvents.clear()
