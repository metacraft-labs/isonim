## Terminal renderer for IsoNim.
##
## Implements RendererBackend with an in-memory tree of TerminalNode objects.
## Proves the reactive core and DSL are truly decoupled from the DOM by
## providing a terminal-friendly text output renderer.

import std/[tables, strutils]
import isonim/renderers/abstract_renderer

type
  TerminalNodeKind* = enum
    tnkBox       ## Container (like div) — renders as bordered box or indented block
    tnkText      ## Text content
    tnkButton    ## Interactive button — renders as [label]
    tnkInput     ## Text input field

  TerminalEvent* = ref object
    ## Event passed to event-arg handlers in the terminal renderer.
    ## Mirrors the browser's `Event` shape so user code stays portable
    ## across renderers — `type`, `target`, plus the cancellation flags.
    `type`*: string
    target*: TerminalNode
    currentTarget*: TerminalNode
    defaultPrevented*: bool
    propagationStopped*: bool

  TerminalNode* = ref object
    kind*: TerminalNodeKind
    tag*: string              ## Original tag name (for debugging)
    text*: string             ## Text content
    attributes*: Table[string, string]
    styles*: Table[string, string]
    children*: seq[TerminalNode]
    parent*: TerminalNode
    eventListeners*: Table[string, seq[proc()]]
    eventHandlers*: Table[string, seq[proc(ev: TerminalEvent)]]
    id*: int                  ## Unique node id

  TerminalRenderer* = object
    ## Terminal renderer backend.

var nextTerminalNodeId* {.threadvar.}: int
  ## Per-thread monotonic id counter. Was a plain `var` global until M0
  ## of `isonim-tui` exposed the parallel-test race; the production
  ## replacement renderer in `isonim_tui` mirrors `mock_dom.nim:40` and
  ## this demo renderer follows suit so the two stay in lockstep.

proc tagToKind(tag: string): TerminalNodeKind =
  case tag
  of "button": tnkButton
  of "input": tnkInput
  else: tnkBox

proc createElement*(r: TerminalRenderer; tag: string): TerminalNode =
  inc nextTerminalNodeId
  TerminalNode(
    id: nextTerminalNodeId,
    kind: tagToKind(tag),
    tag: tag,
    attributes: initTable[string, string](),
    styles: initTable[string, string](),
    children: @[],
    eventListeners: initTable[string, seq[proc()]](),
    eventHandlers: initTable[string, seq[proc(ev: TerminalEvent)]]()
  )

proc createTextNode*(r: TerminalRenderer; text: string): TerminalNode =
  inc nextTerminalNodeId
  TerminalNode(
    id: nextTerminalNodeId,
    kind: tnkText,
    text: text,
    attributes: initTable[string, string](),
    styles: initTable[string, string](),
    eventListeners: initTable[string, seq[proc()]](),
    eventHandlers: initTable[string, seq[proc(ev: TerminalEvent)]]()
  )

proc appendChild*(r: TerminalRenderer; parent, child: TerminalNode) =
  child.parent = parent
  parent.children.add(child)

proc insertBefore*(r: TerminalRenderer; parent, child, reference: TerminalNode) =
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

proc removeChild*(r: TerminalRenderer; parent, child: TerminalNode) =
  child.parent = nil
  var idx = -1
  for i, c in parent.children:
    if c == child:
      idx = i
      break
  if idx >= 0:
    parent.children.delete(idx)

proc setAttribute*(r: TerminalRenderer; node: TerminalNode; name, value: string) =
  node.attributes[name] = value

proc removeAttribute*(r: TerminalRenderer; node: TerminalNode; name: string) =
  node.attributes.del(name)

proc setTextContent*(r: TerminalRenderer; node: TerminalNode; text: string) =
  if node.kind == tnkText:
    node.text = text
  else:
    node.children.setLen(0)
    inc nextTerminalNodeId
    let textNode = TerminalNode(
      id: nextTerminalNodeId,
      kind: tnkText,
      text: text,
      parent: node,
      attributes: initTable[string, string](),
      styles: initTable[string, string](),
      eventListeners: initTable[string, seq[proc()]](),
      eventHandlers: initTable[string, seq[proc(ev: TerminalEvent)]]()
    )
    node.children.add(textNode)

proc setStyle*(r: TerminalRenderer; node: TerminalNode; prop, value: string) =
  node.styles[prop] = value

proc addEventListener*(r: TerminalRenderer; node: TerminalNode; event: string; handler: proc()) =
  if event notin node.eventListeners:
    node.eventListeners[event] = @[]
  node.eventListeners[event].add(handler)

proc addEventListener*(r: TerminalRenderer; node: TerminalNode; event: string;
    handler: proc(ev: TerminalEvent)) =
  ## Overload for handlers that receive a `TerminalEvent`. Lets terminal
  ## UIs read `ev.target` or call `ev.preventDefault` from the same
  ## `(ev) =>` shorthand the web renderer accepts.
  if event notin node.eventHandlers:
    node.eventHandlers[event] = @[]
  node.eventHandlers[event].add(handler)

proc firstChild*(r: TerminalRenderer; node: TerminalNode): TerminalNode =
  if node.children.len > 0: node.children[0] else: nil

proc nextSibling*(r: TerminalRenderer; node: TerminalNode): TerminalNode =
  if node.parent == nil: return nil
  let siblings = node.parent.children
  for i, c in siblings:
    if c == node and i + 1 < siblings.len:
      return siblings[i + 1]
  return nil

proc parentNode*(r: TerminalRenderer; node: TerminalNode): TerminalNode =
  node.parent

# ---- Test helpers ----

proc preventDefault*(ev: TerminalEvent) =
  ev.defaultPrevented = true

proc stopPropagation*(ev: TerminalEvent) =
  ev.propagationStopped = true

proc fireEvent*(node: TerminalNode; event: string) =
  ## Triggers all handlers registered for the given event on a node.
  ## Calls no-arg handlers as-is, then synthesises a TerminalEvent for
  ## any event-arg handlers registered on the same event name.
  if event in node.eventListeners:
    for handler in node.eventListeners[event]:
      handler()
  if event in node.eventHandlers:
    let ev = TerminalEvent(`type`: event, target: node, currentTarget: node)
    for handler in node.eventHandlers[event]:
      handler(ev)

proc fireEventWith*(node: TerminalNode; event: string; ev: TerminalEvent) =
  ## Like `fireEvent` but uses a caller-supplied event so tests can
  ## inspect mutations after dispatch.
  if event in node.eventListeners:
    for handler in node.eventListeners[event]:
      handler()
  if event in node.eventHandlers:
    for handler in node.eventHandlers[event]:
      handler(ev)

proc textContent*(node: TerminalNode): string =
  ## Returns the concatenated text content of a node and its descendants.
  if node.kind == tnkText:
    return node.text
  for child in node.children:
    result.add(textContent(child))

# ---- Terminal text rendering ----

proc renderToText*(node: TerminalNode; indent: int = 0): string =
  ## Converts the terminal node tree to plain text.
  ## Boxes become indented blocks, text becomes lines,
  ## buttons become [label], etc.
  let prefix = "  ".repeat(indent)
  case node.kind
  of tnkText:
    result = prefix & node.text & "\n"
  of tnkButton:
    let label = if node.children.len > 0: textContent(node) else: node.text
    result = prefix & "[" & label & "]\n"
  of tnkBox:
    let title = node.attributes.getOrDefault("title", "")
    if title.len > 0:
      result = prefix & "┌─ " & title & " ─┐\n"
    for child in node.children:
      result.add renderToText(child, indent + 1)
    if title.len > 0:
      result.add prefix & "└─────────┘\n"
  of tnkInput:
    let value = node.attributes.getOrDefault("value", "")
    result = prefix & "[" & value & "]\n"

# ---- Compile-time concept check ----
# Verify at compile time that TerminalRenderer implements all 13
# RendererBackend operations. We use `when compiles()` because the
# checkRendererBackend body calls createElement which mutates a global
# id counter — not permitted inside `static` blocks by the Nim VM.

when not compiles(checkRendererBackend[TerminalRenderer, TerminalNode]()):
  {.error: "TerminalRenderer does not implement RendererBackend".}
