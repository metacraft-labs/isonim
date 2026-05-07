## Mock DOM renderer for testing IsoNim.
##
## Provides MockRenderer that implements the RendererBackend interface
## with an in-memory tree of MockNode objects. Useful for unit testing
## renderer logic without requiring a real browser DOM.

import std/[tables, hashes]

type
  MockNodeKind* = enum
    mnkElement
    mnkText

  MockEvent* = ref object
    ## Test-time stand-in for the browser `Event` object. Carries the
    ## subset of fields handlers commonly read or write — `type`, `target`,
    ## `currentTarget`, plus `defaultPrevented` and `propagationStopped`
    ## that `preventDefault` / `stopPropagation` flip.
    `type`*: string
    target*: MockNode
    currentTarget*: MockNode
    defaultPrevented*: bool
    propagationStopped*: bool

  MockNode* = ref object
    id*: int                              ## Unique node ID (for hashing)
    kind*: MockNodeKind
    tag*: string                          ## Element tag name
    text*: string                         ## Text content (for text nodes)
    attributes*: Table[string, string]    ## Element attributes
    styles*: Table[string, string]        ## Style properties
    children*: seq[MockNode]              ## Child nodes
    parent*: MockNode                     ## Parent reference
    eventListeners*: Table[string, seq[proc()]]              ## No-arg handlers
    eventHandlers*: Table[string, seq[proc(ev: MockEvent)]]  ## Event-arg handlers

  MockRenderer* = object
    ## Mock renderer backend for unit testing.

var nextMockNodeId* {.threadvar.}: int

# Type alias for the abstract_renderer concept check
type ElementHandle* = MockNode

proc createElement*(r: MockRenderer; tag: string): MockNode =
  inc nextMockNodeId
  MockNode(
    id: nextMockNodeId,
    kind: mnkElement, tag: tag,
    attributes: initTable[string, string](),
    styles: initTable[string, string](),
    children: @[],
    eventListeners: initTable[string, seq[proc()]](),
    eventHandlers: initTable[string, seq[proc(ev: MockEvent)]]()
  )

proc createTextNode*(r: MockRenderer; text: string): MockNode =
  inc nextMockNodeId
  MockNode(
    id: nextMockNodeId,
    kind: mnkText, text: text,
    attributes: initTable[string, string](),
    styles: initTable[string, string](),
    eventListeners: initTable[string, seq[proc()]](),
    eventHandlers: initTable[string, seq[proc(ev: MockEvent)]]()
  )

proc appendChild*(r: MockRenderer; parent, child: MockNode) =
  child.parent = parent
  parent.children.add(child)

proc insertBefore*(r: MockRenderer; parent, child, reference: MockNode) =
  child.parent = parent
  var idx = -1
  for i, c in parent.children:
    if c == reference:
      idx = i
      break
  if idx >= 0:
    parent.children.insert(child, idx)
  else:
    parent.children.add(child)

proc removeChild*(r: MockRenderer; parent, child: MockNode) =
  child.parent = nil
  var idx = -1
  for i, c in parent.children:
    if c == child:
      idx = i
      break
  if idx >= 0:
    parent.children.delete(idx)

proc setAttribute*(r: MockRenderer; node: MockNode; name, value: string) =
  node.attributes[name] = value
  if name == "value":
    node.text = value

proc removeAttribute*(r: MockRenderer; node: MockNode; name: string) =
  node.attributes.del(name)

proc setTextContent*(r: MockRenderer; node: MockNode; text: string) =
  if node.kind == mnkText:
    node.text = text
  else:
    node.children.setLen(0)
    inc nextMockNodeId
    let textNode = MockNode(id: nextMockNodeId, kind: mnkText, text: text, parent: node,
                            attributes: initTable[string, string](),
                            styles: initTable[string, string](),
                            eventListeners: initTable[string, seq[proc()]](),
                            eventHandlers: initTable[string, seq[proc(ev: MockEvent)]]())
    node.children.add(textNode)

proc setStyle*(r: MockRenderer; node: MockNode; prop, value: string) =
  node.styles[prop] = value

proc addEventListener*(r: MockRenderer; node: MockNode; event: string; handler: proc()) =
  if event notin node.eventListeners:
    node.eventListeners[event] = @[]
  node.eventListeners[event].add(handler)

proc addEventListener*(r: MockRenderer; node: MockNode; event: string;
    handler: proc(ev: MockEvent)) =
  ## Overload accepting an event-receiving handler — mirrors the DOM's
  ## `(ev) => …` form. The DSL picks this overload when the user's handler
  ## takes a single `MockEvent` parameter.
  if event notin node.eventHandlers:
    node.eventHandlers[event] = @[]
  node.eventHandlers[event].add(handler)

proc firstChild*(r: MockRenderer; node: MockNode): MockNode =
  if node.children.len > 0: node.children[0] else: nil

proc nextSibling*(r: MockRenderer; node: MockNode): MockNode =
  if node.parent == nil: return nil
  let siblings = node.parent.children
  for i, c in siblings:
    if c == node and i + 1 < siblings.len:
      return siblings[i + 1]
  return nil

proc parentNode*(r: MockRenderer; node: MockNode): MockNode =
  node.parent

proc clearChildren*(r: MockRenderer; node: MockNode) =
  ## Remove all children from a mock node.
  for c in node.children:
    c.parent = nil
  node.children.setLen(0)

proc clearEventListeners*(r: MockRenderer; node: MockNode) =
  ## Remove all event listeners from a mock node.
  node.eventListeners.clear()
  node.eventHandlers.clear()

# ---- Test helpers ----

proc preventDefault*(ev: MockEvent) =
  ## Mark a MockEvent as having `preventDefault()` called on it.
  ev.defaultPrevented = true

proc stopPropagation*(ev: MockEvent) =
  ## Mark a MockEvent as having `stopPropagation()` called on it.
  ev.propagationStopped = true

proc fireEvent*(node: MockNode; event: string) =
  ## Triggers all handlers registered for the given event on a node.
  ## Calls no-arg handlers as-is, and synthesises a fresh MockEvent
  ## (with `target` and `currentTarget` set to `node`) for event-arg ones.
  if event in node.eventListeners:
    for handler in node.eventListeners[event]:
      handler()
  if event in node.eventHandlers:
    let ev = MockEvent(`type`: event, target: node, currentTarget: node)
    for handler in node.eventHandlers[event]:
      handler(ev)

proc fireEventWith*(node: MockNode; event: string; ev: MockEvent) =
  ## Like `fireEvent` but uses a caller-supplied MockEvent so tests can
  ## inspect mutations (e.g. `defaultPrevented`) after dispatch.
  if event in node.eventListeners:
    for handler in node.eventListeners[event]:
      handler()
  if event in node.eventHandlers:
    for handler in node.eventHandlers[event]:
      handler(ev)

proc textContent*(node: MockNode): string =
  ## Returns the concatenated text content of a node and its descendants.
  if node.kind == mnkText:
    return node.text
  for child in node.children:
    result.add(textContent(child))

proc inputValue*(r: MockRenderer; node: MockNode): string =
  if "value" in node.attributes:
    node.attributes["value"]
  else:
    node.text

proc setInputValue*(r: MockRenderer; node: MockNode; value: string) =
  node.attributes["value"] = value
  node.text = value

proc enableDragScroll*(r: MockRenderer; node: MockNode) =
  node.attributes["data-drag-scroll"] = "enabled"

proc hash*(node: MockNode): Hash =
  ## Hash MockNode by its unique ID (for use as Table key).
  result = hash(node.id)
