## Native GUI renderer prototype for IsoNim.
##
## Implements RendererBackend with an in-memory tree of NativeWidget objects.
## Maps HTML-like tags to native widget kinds (Window, Panel, Button, etc.).
## Demonstrates that IsoNim's reactive core and DSL can drive a native GUI.
##
## This prototype uses a mock widget system. The same interface could be
## backed by real native toolkits: GPUI (Zed), GTK, Cocoa, or Dioxus.

import std/[tables, strutils]
import isonim/renderers/abstract_renderer

type
  NativeWidgetKind* = enum
    nwkWindow       ## Top-level window container
    nwkPanel        ## Generic container with layout
    nwkLabel        ## Static text display
    nwkButton       ## Clickable button
    nwkInput        ## Text input field
    nwkCheckbox     ## Toggle checkbox
    nwkList         ## Scrollable list container
    nwkListItem     ## Item within a list
    nwkImage        ## Image display
    nwkText         ## Raw text node (no widget)

  LayoutDirection* = enum
    ldVertical      ## Children stacked vertically
    ldHorizontal    ## Children arranged horizontally

  NativeWidget* = ref object
    kind*: NativeWidgetKind
    tag*: string              ## Original HTML tag (for mapping/debugging)
    text*: string             ## Text content
    attributes*: Table[string, string]
    styles*: Table[string, string]
    children*: seq[NativeWidget]
    parent*: NativeWidget
    eventListeners*: Table[string, seq[proc()]]
    id*: int                  ## Unique widget id
    layout*: LayoutDirection  ## Layout direction for containers
    visible*: bool            ## Visibility state
    enabled*: bool            ## Enabled/disabled state

  NativeRenderer* = object
    ## Native GUI renderer backend.

var nextNativeWidgetId*: int

proc tagToWidgetKind(tag: string): NativeWidgetKind =
  ## Maps HTML-like tags to native widget kinds.
  case tag
  of "div", "section", "article", "main", "aside", "nav":
    nwkPanel
  of "header", "footer":
    nwkPanel
  of "span", "p", "h1", "h2", "h3", "h4", "h5", "h6", "label", "strong", "em":
    nwkLabel
  of "button":
    nwkButton
  of "input":
    nwkInput
  of "ul", "ol":
    nwkList
  of "li":
    nwkListItem
  of "img":
    nwkImage
  of "form":
    nwkPanel
  of "details", "summary":
    nwkPanel
  else:
    nwkPanel

proc tagToLayout(tag: string): LayoutDirection =
  ## Default layout direction based on tag semantics.
  case tag
  of "div", "section", "article", "main", "ul", "ol", "form", "details":
    ldVertical
  of "header", "footer", "nav", "span":
    ldHorizontal
  else:
    ldVertical

proc createElement*(r: NativeRenderer; tag: string): NativeWidget =
  inc nextNativeWidgetId
  NativeWidget(
    id: nextNativeWidgetId,
    kind: tagToWidgetKind(tag),
    tag: tag,
    layout: tagToLayout(tag),
    visible: true,
    enabled: true,
    attributes: initTable[string, string](),
    styles: initTable[string, string](),
    children: @[],
    eventListeners: initTable[string, seq[proc()]]()
  )

proc createTextNode*(r: NativeRenderer; text: string): NativeWidget =
  inc nextNativeWidgetId
  NativeWidget(
    id: nextNativeWidgetId,
    kind: nwkText,
    text: text,
    visible: true,
    enabled: true,
    attributes: initTable[string, string](),
    styles: initTable[string, string](),
    eventListeners: initTable[string, seq[proc()]]()
  )

proc appendChild*(r: NativeRenderer; parent, child: NativeWidget) =
  child.parent = parent
  parent.children.add(child)

proc insertBefore*(r: NativeRenderer; parent, child, reference: NativeWidget) =
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

proc removeChild*(r: NativeRenderer; parent, child: NativeWidget) =
  child.parent = nil
  var idx = -1
  for i, c in parent.children:
    if c == child:
      idx = i
      break
  if idx >= 0:
    parent.children.delete(idx)

proc setAttribute*(r: NativeRenderer; node: NativeWidget; name, value: string) =
  node.attributes[name] = value
  # Apply semantic attribute mappings
  case name
  of "disabled":
    node.enabled = false
  of "hidden":
    node.visible = false
  of "value":
    if node.kind == nwkInput:
      node.text = value
  else:
    discard

proc removeAttribute*(r: NativeRenderer; node: NativeWidget; name: string) =
  node.attributes.del(name)
  case name
  of "disabled":
    node.enabled = true
  of "hidden":
    node.visible = true
  else:
    discard

proc setTextContent*(r: NativeRenderer; node: NativeWidget; text: string) =
  if node.kind == nwkText:
    node.text = text
  else:
    node.children.setLen(0)
    inc nextNativeWidgetId
    let textNode = NativeWidget(
      id: nextNativeWidgetId,
      kind: nwkText,
      text: text,
      parent: node,
      visible: true,
      enabled: true,
      attributes: initTable[string, string](),
      styles: initTable[string, string](),
      eventListeners: initTable[string, seq[proc()]]()
    )
    node.children.add(textNode)

proc setStyle*(r: NativeRenderer; node: NativeWidget; prop, value: string) =
  node.styles[prop] = value
  # Map CSS-like properties to native concepts
  case prop
  of "flex-direction":
    if value == "row":
      node.layout = ldHorizontal
    else:
      node.layout = ldVertical
  of "display":
    if value == "none":
      node.visible = false
    else:
      node.visible = true
  else:
    discard

proc addEventListener*(r: NativeRenderer; node: NativeWidget; event: string; handler: proc()) =
  if event notin node.eventListeners:
    node.eventListeners[event] = @[]
  node.eventListeners[event].add(handler)

proc firstChild*(r: NativeRenderer; node: NativeWidget): NativeWidget =
  if node.children.len > 0: node.children[0] else: nil

proc nextSibling*(r: NativeRenderer; node: NativeWidget): NativeWidget =
  if node.parent == nil: return nil
  let siblings = node.parent.children
  for i, c in siblings:
    if c == node and i + 1 < siblings.len:
      return siblings[i + 1]
  return nil

proc parentNode*(r: NativeRenderer; node: NativeWidget): NativeWidget =
  node.parent

# ---- Test helpers ----

proc fireEvent*(node: NativeWidget; event: string) =
  ## Triggers all handlers registered for the given event.
  if event in node.eventListeners:
    for handler in node.eventListeners[event]:
      handler()

proc textContent*(node: NativeWidget): string =
  ## Returns concatenated text content of a node and descendants.
  if node.kind == nwkText:
    return node.text
  for child in node.children:
    result.add(textContent(child))

# ---- Native GUI text rendering ----

proc widgetKindLabel(kind: NativeWidgetKind): string =
  case kind
  of nwkWindow: "Window"
  of nwkPanel: "Panel"
  of nwkLabel: "Label"
  of nwkButton: "Button"
  of nwkInput: "Input"
  of nwkCheckbox: "Checkbox"
  of nwkList: "List"
  of nwkListItem: "ListItem"
  of nwkImage: "Image"
  of nwkText: "Text"

proc renderWidgetTree*(node: NativeWidget; indent: int = 0): string =
  ## Renders the widget tree as an ASCII representation.
  ## Useful for debugging and visual verification.
  let prefix = "  ".repeat(indent)
  let enabledStr = if node.enabled: "" else: " [disabled]"
  let visibleStr = if node.visible: "" else: " [hidden]"

  case node.kind
  of nwkText:
    result = prefix & "\"" & node.text & "\"\n"
  of nwkButton:
    let label = if node.children.len > 0: textContent(node) else: node.text
    result = prefix & "Button(" & label & ")" & enabledStr & "\n"
  of nwkInput:
    let value = node.attributes.getOrDefault("value", node.text)
    let placeholder = node.attributes.getOrDefault("placeholder", "")
    let display = if value.len > 0: value else: placeholder
    result = prefix & "Input[" & display & "]" & enabledStr & "\n"
  of nwkLabel:
    let content = textContent(node)
    let tag = if node.tag in ["h1", "h2", "h3"]: node.tag.toUpperAscii() & ": " else: ""
    result = prefix & "Label(" & tag & content & ")\n"
  of nwkCheckbox:
    let checked = "checked" in node.attributes
    let mark = if checked: "[x]" else: "[ ]"
    result = prefix & "Checkbox " & mark & "\n"
  of nwkImage:
    let src = node.attributes.getOrDefault("src", "?")
    result = prefix & "Image(" & src & ")\n"
  else:
    let layoutStr = if node.layout == ldHorizontal: " ->" else: " v"
    let title = node.attributes.getOrDefault("class", node.tag)
    result = prefix & widgetKindLabel(node.kind) & "(" & title & ")" & layoutStr & enabledStr & visibleStr & "\n"
    for child in node.children:
      result.add renderWidgetTree(child, indent + 1)

# ---- Compile-time concept check ----

when not compiles(checkRendererBackend[NativeRenderer, NativeWidget]()):
  {.error: "NativeRenderer does not implement RendererBackend".}
