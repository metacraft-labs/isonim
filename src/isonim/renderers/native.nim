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
import isonim/rxcore

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

# ---- NH-M1: reactive root scaffold for native renderers ----
#
# The native sibling of the web seam at `isonim/web/client.nim::render`.
#
# Web `render()` does three things: open a reactive root with `createRoot`,
# wrap the root build in an accessor, and route that accessor through an
# insertion site that lives inside a `createRenderEffect`. The third step is
# the load-bearing one: because the insertion site is an effect, a later
# hot-component proxy (NH-M2) can swap the root component by writing a signal
# the accessor reads, instead of disposing and re-creating the reactive root
# (which would drop every signal, resource and cleanup the running app owns).
#
# `renderNative` is that same seam, expressed against any renderer that
# satisfies `abstract_renderer.checkRendererBackend`. It deliberately does NOT
# know what "the surface" is: the TUI mounts into a `TerminalTestHarness`, GPUI
# and Freya mount into a shim-owned element tree, so the surface-specific step
# is a `mount` callback (or, for renderers whose surface really is a parent
# element, the `renderer`/`host` overload below, which performs the insert
# through the RendererBackend proc surface itself).
#
# TRACKING CONTRACT. `accessor` is invoked *inside* the render effect with
# tracking ON, so every signal it reads becomes a dependency of the mount seam.
# Callers that want today's build-once behaviour — the root tree is constructed
# exactly once and all later updates flow through the leaves' own fine-grained
# effects — pass their build proc through `staticNativeRoot`, which is the
# direct analogue of web `render()`'s `untrack(proc(): Node = code())`.

type
  NativeRootAccessor*[E] = proc(): E {.closure.}
    ## Produces the current root node. Called inside the mount seam's render
    ## effect, so signal reads performed here re-run the seam.

  NativeRootMount*[E] = proc(node: E) {.closure.}
    ## Attaches `node` to the renderer's surface. Called once per render
    ## effect run, including the first, and must be idempotent for a repeated
    ## identical `node` (the TUI's repaint-on-flush is exactly that case).

  NativeRootHandle*[E] = ref object
    ## Live handle on a mounted reactive root.
    current*: E          ## The node the surface currently holds.
    renders*: int        ## Times the render effect body has run.
    rootSwaps*: int      ## Times `current` changed identity (1 after mount).
    disposeRoot: proc()  ## `createRoot`'s disposer; nil once disposed.

proc staticNativeRoot*[E](build: proc(): E): NativeRootAccessor[E] =
  ## Wrap a plain build proc so the mount seam runs it exactly once.
  ##
  ## Mirrors `isonim/web/client.nim::render`, which passes
  ## `untrack(proc(): Node = code())` for the same reason: a composition root
  ## that reads a signal while *constructing* the tree must not thereby make
  ## the whole tree a dependency of the insertion site. Non-HMR callers use
  ## this and observe byte-identical behaviour to a direct build call.
  if build == nil:
    raise newException(ValueError,
      "staticNativeRoot: build proc is nil — there is no root to construct")
  result = proc(): E = untrack(proc(): E = build())

proc renderNative*[E](accessor: NativeRootAccessor[E];
                      mount: NativeRootMount[E]): NativeRootHandle[E] =
  ## Open a reactive root and mount `accessor`'s result through a render
  ## effect. Returns a handle whose `dispose` tears the root down.
  ##
  ## This is the shared scaffold every `renderNative*` per-renderer entry
  ## point delegates to (`isonim-tui::renderTui`, `isonim-gpui::renderGpui`,
  ## `isonim-freya::renderFreya`).
  if accessor == nil:
    raise newException(ValueError,
      "renderNative: accessor is nil — the reactive root has nothing to build")
  if mount == nil:
    raise newException(ValueError,
      "renderNative: mount is nil — a built root would never reach a surface")
  let handle = NativeRootHandle[E](renders: 0, rootSwaps: 0)
  createRoot proc(dispose: proc()) =
    handle.disposeRoot = dispose
    createRenderEffect proc() =
      let node = accessor()
      let swapped = handle.renders == 0 or handle.current != node
      inc handle.renders
      if swapped:
        handle.current = node
        inc handle.rootSwaps
      mount(node)
  handle

proc renderNative*[R, E](renderer: R; host: E;
                         accessor: NativeRootAccessor[E]): NativeRootHandle[E] =
  ## `renderNative` for renderers whose surface is an element: the reactive
  ## insert is performed with the RendererBackend's own `appendChild` /
  ## `removeChild`, so the renderer's tree-mutation API stays the single
  ## reconciliation primitive (Native HMR design principle #4).
  ##
  ## `mixin` is load-bearing: without it Nim binds `appendChild` /
  ## `removeChild` at the definition site, where the only candidates are this
  ## module's own `NativeRenderer` overloads, and every other renderer fails to
  ## instantiate with "type mismatch … Expected: proc appendChild(r:
  ## NativeRenderer …)".
  mixin appendChild, removeChild
  var mounted: E
  var haveMounted = false
  renderNative(accessor, proc(node: E) =
    if haveMounted:
      if mounted == node: return
      renderer.removeChild(host, mounted)
    renderer.appendChild(host, node)
    mounted = node
    haveMounted = true)

proc dispose*[E](handle: NativeRootHandle[E]) =
  ## Dispose the reactive root. Idempotent.
  if handle == nil: return
  let d = handle.disposeRoot
  if d != nil:
    handle.disposeRoot = nil
    d()

proc isDisposed*[E](handle: NativeRootHandle[E]): bool =
  handle == nil or handle.disposeRoot == nil

# ---- Compile-time concept check ----

when not compiles(checkRendererBackend[NativeRenderer, NativeWidget]()):
  {.error: "NativeRenderer does not implement RendererBackend".}
