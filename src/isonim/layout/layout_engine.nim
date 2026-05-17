## Layout engine that wraps a RendererBackend and builds a parallel Yoga tree.
## After building the component tree, call `calculateLayout` to compute Yoga
## positions, then `allLayouts` to retrieve computed frames for each platform view.
##
## Usage:
##   let engine = newLayoutEngine()
##   let elem = styledElement[R, E](r, "div", engine, {"padding": "16", "width": "390"})
##   engine.calculateLayout(390, 844)
##   for (handle, layout) in engine.allLayouts(): ...

import std/[tables, strutils]
import isonim/layout/flexbox
import isonim/layout/yoga_bindings

type
  LayoutNode* = object
    yogaNode*: YGNodeRef
    viewHandle*: int64  # opaque handle to the platform view (pointer cast to int64)
    children*: seq[int]  # indices into nodes seq

  LayoutEngine* = ref object
    nodes*: seq[LayoutNode]
    handleToIndex*: Table[int64, int]

  LayoutResult* = object
    x*, y*, width*, height*: float

proc newLayoutEngine*(): LayoutEngine =
  LayoutEngine(nodes: @[], handleToIndex: initTable[int64, int]())

proc registerNode*(engine: LayoutEngine; viewHandle: int64): int =
  ## Register a view and create a corresponding Yoga node.
  ## Returns the index into the nodes seq.
  let yogaNode = YGNodeNew()
  let idx = engine.nodes.len
  engine.nodes.add(LayoutNode(yogaNode: yogaNode, viewHandle: viewHandle))
  engine.handleToIndex[viewHandle] = idx
  idx

proc addChild*(engine: LayoutEngine; parentHandle, childHandle: int64) =
  ## Register a parent-child relationship in the Yoga tree.
  if parentHandle in engine.handleToIndex and childHandle in engine.handleToIndex:
    let parentIdx = engine.handleToIndex[parentHandle]
    let childIdx = engine.handleToIndex[childHandle]
    engine.nodes[parentIdx].children.add(childIdx)
    let childCount = YGNodeGetChildCount(engine.nodes[parentIdx].yogaNode)
    YGNodeInsertChild(engine.nodes[parentIdx].yogaNode,
                       engine.nodes[childIdx].yogaNode, childCount)

proc removeChild*(engine: LayoutEngine; parentHandle, childHandle: int64) =
  ## Remove a child from its parent in the Yoga tree.
  if parentHandle in engine.handleToIndex and childHandle in engine.handleToIndex:
    let parentIdx = engine.handleToIndex[parentHandle]
    let childIdx = engine.handleToIndex[childHandle]
    # Remove from parent's children seq
    for i, c in engine.nodes[parentIdx].children:
      if c == childIdx:
        engine.nodes[parentIdx].children.delete(i)
        break
    # Remove from Yoga tree
    YGNodeRemoveChild(engine.nodes[parentIdx].yogaNode,
                       engine.nodes[childIdx].yogaNode)

proc insertChildBefore*(engine: LayoutEngine;
                         parentHandle, childHandle, refHandle: int64) =
  ## Insert a child before a reference child in the Yoga tree.
  if parentHandle in engine.handleToIndex and childHandle in engine.handleToIndex:
    let parentIdx = engine.handleToIndex[parentHandle]
    let childIdx = engine.handleToIndex[childHandle]
    if refHandle in engine.handleToIndex:
      let refIdx = engine.handleToIndex[refHandle]
      # Find the position of refIdx in parent's children
      var pos = engine.nodes[parentIdx].children.len
      for i, c in engine.nodes[parentIdx].children:
        if c == refIdx:
          pos = i
          break
      engine.nodes[parentIdx].children.insert(childIdx, pos)
      YGNodeInsertChild(engine.nodes[parentIdx].yogaNode,
                         engine.nodes[childIdx].yogaNode, cuint(pos))
    else:
      # Fallback: append at end
      engine.addChild(parentHandle, childHandle)

proc parseLayoutFloat(value: string): float =
  ## Parse a CSS-like dimension value (strips `px` / `dp` units and
  ## whitespace) into a float, returning `-1.0` for any value that
  ## isn't purely numeric. Pulled out of `setLayoutStyle` so the
  ## try-except sits in a small, leaf-shaped proc rather than at the
  ## top of a large case-statement-bearing proc — the latter shape
  ## tripped iOS ARM64 release builds where `parseFloat`'s ValueError
  ## was raised through the entire case scope and the try-except in
  ## the surrounding proc body didn't catch it cleanly (the exception
  ## propagated through to the caller and silently aborted the
  ## `setStyle` → composition-root chain, producing the M-EVP-14 iOS
  ## "empty render" symptom on the device while every other backend
  ## rendered fine). Isolating parseFloat in its own proc lets the
  ## compiler emit a tight ValueError handler around exactly the
  ## raising call, which Nim/iOS handle correctly.
  let stripped = value.replace("px", "").replace("dp", "").strip()
  if stripped.len == 0:
    return -1.0
  # Fast path: only call parseFloat when the string looks numeric.
  # Avoids paying the try-except cost on every colour / class / font
  # name pushed through `setStyle`.
  let first = stripped[0]
  if not (first in {'0'..'9', '-', '+', '.'}):
    return -1.0
  try: parseFloat(stripped) except ValueError: -1.0

proc setLayoutStyle*(engine: LayoutEngine; viewHandle: int64; prop, value: string) =
  ## Apply a CSS-like style property to the Yoga node for this view.
  ## Non-layout properties (colors, fonts, etc.) are silently ignored.
  if viewHandle notin engine.handleToIndex: return
  let idx = engine.handleToIndex[viewHandle]
  let node = engine.nodes[idx].yogaNode

  # NOTE: do NOT call `parseFloat` here at the top of the proc — see
  # `parseLayoutFloat` for the iOS ARM64 release-build rationale. The
  # branches that need a numeric value call `parseLayoutFloat(value)`
  # lazily; non-numeric branches (`flex-direction`, `align-items`,
  # the `discard` arm for colours, etc.) never trigger the try-except
  # path at all.

  case prop
  of "width":
    let numVal = parseLayoutFloat(value)
    if numVal > 0: YGNodeStyleSetWidth(node, cfloat(numVal))
  of "height":
    let numVal = parseLayoutFloat(value)
    if numVal > 0: YGNodeStyleSetHeight(node, cfloat(numVal))
  of "min-width":
    let numVal = parseLayoutFloat(value)
    if numVal > 0: YGNodeStyleSetMinWidth(node, cfloat(numVal))
  of "min-height":
    let numVal = parseLayoutFloat(value)
    if numVal > 0: YGNodeStyleSetMinHeight(node, cfloat(numVal))
  of "max-width":
    let numVal = parseLayoutFloat(value)
    if numVal > 0: YGNodeStyleSetMaxWidth(node, cfloat(numVal))
  of "max-height":
    let numVal = parseLayoutFloat(value)
    if numVal > 0: YGNodeStyleSetMaxHeight(node, cfloat(numVal))
  of "padding":
    let numVal = parseLayoutFloat(value)
    if numVal >= 0: YGNodeStyleSetPadding(node, YGEdge.All, cfloat(numVal))
  of "padding-left":
    let numVal = parseLayoutFloat(value)
    if numVal >= 0: YGNodeStyleSetPadding(node, YGEdge.Left, cfloat(numVal))
  of "padding-right":
    let numVal = parseLayoutFloat(value)
    if numVal >= 0: YGNodeStyleSetPadding(node, YGEdge.Right, cfloat(numVal))
  of "padding-top":
    let numVal = parseLayoutFloat(value)
    if numVal >= 0: YGNodeStyleSetPadding(node, YGEdge.Top, cfloat(numVal))
  of "padding-bottom":
    let numVal = parseLayoutFloat(value)
    if numVal >= 0: YGNodeStyleSetPadding(node, YGEdge.Bottom, cfloat(numVal))
  of "margin":
    let numVal = parseLayoutFloat(value)
    if numVal >= 0: YGNodeStyleSetMargin(node, YGEdge.All, cfloat(numVal))
  of "margin-left":
    let numVal = parseLayoutFloat(value)
    if numVal >= 0: YGNodeStyleSetMargin(node, YGEdge.Left, cfloat(numVal))
  of "margin-right":
    let numVal = parseLayoutFloat(value)
    if numVal >= 0: YGNodeStyleSetMargin(node, YGEdge.Right, cfloat(numVal))
  of "margin-top":
    let numVal = parseLayoutFloat(value)
    if numVal >= 0: YGNodeStyleSetMargin(node, YGEdge.Top, cfloat(numVal))
  of "margin-bottom":
    let numVal = parseLayoutFloat(value)
    if numVal >= 0: YGNodeStyleSetMargin(node, YGEdge.Bottom, cfloat(numVal))
  of "gap":
    let numVal = parseLayoutFloat(value)
    if numVal >= 0: YGNodeStyleSetGap(node, YGGutter.All, cfloat(numVal))
  of "flex-direction":
    case value
    of "row": YGNodeStyleSetFlexDirection(node, YGFlexDirection.Row)
    of "row-reverse": YGNodeStyleSetFlexDirection(node, YGFlexDirection.RowReverse)
    of "column-reverse": YGNodeStyleSetFlexDirection(node, YGFlexDirection.ColumnReverse)
    else: YGNodeStyleSetFlexDirection(node, YGFlexDirection.Column)
  of "flex":
    let numVal = parseLayoutFloat(value)
    if numVal > 0: YGNodeStyleSetFlex(node, cfloat(numVal))
  of "flex-grow":
    let numVal = parseLayoutFloat(value)
    if numVal >= 0: YGNodeStyleSetFlexGrow(node, cfloat(numVal))
  of "flex-shrink":
    let numVal = parseLayoutFloat(value)
    if numVal >= 0: YGNodeStyleSetFlexShrink(node, cfloat(numVal))
  of "align-items":
    case value
    of "center": YGNodeStyleSetAlignItems(node, YGAlign.Center)
    of "flex-start", "start": YGNodeStyleSetAlignItems(node, YGAlign.FlexStart)
    of "flex-end", "end": YGNodeStyleSetAlignItems(node, YGAlign.FlexEnd)
    of "stretch": YGNodeStyleSetAlignItems(node, YGAlign.Stretch)
    of "baseline": YGNodeStyleSetAlignItems(node, YGAlign.Baseline)
    else: discard
  of "align-self":
    case value
    of "center": YGNodeStyleSetAlignSelf(node, YGAlign.Center)
    of "flex-start", "start": YGNodeStyleSetAlignSelf(node, YGAlign.FlexStart)
    of "flex-end", "end": YGNodeStyleSetAlignSelf(node, YGAlign.FlexEnd)
    of "stretch": YGNodeStyleSetAlignSelf(node, YGAlign.Stretch)
    of "auto": YGNodeStyleSetAlignSelf(node, YGAlign.Auto)
    else: discard
  of "justify-content":
    case value
    of "center": YGNodeStyleSetJustifyContent(node, YGJustify.Center)
    of "flex-start", "start": YGNodeStyleSetJustifyContent(node, YGJustify.FlexStart)
    of "flex-end", "end": YGNodeStyleSetJustifyContent(node, YGJustify.FlexEnd)
    of "space-between": YGNodeStyleSetJustifyContent(node, YGJustify.SpaceBetween)
    of "space-around": YGNodeStyleSetJustifyContent(node, YGJustify.SpaceAround)
    of "space-evenly": YGNodeStyleSetJustifyContent(node, YGJustify.SpaceEvenly)
    else: discard
  of "flex-wrap":
    case value
    of "wrap": YGNodeStyleSetFlexWrap(node, YGWrap.Wrap)
    of "wrap-reverse": YGNodeStyleSetFlexWrap(node, YGWrap.WrapReverse)
    of "nowrap": YGNodeStyleSetFlexWrap(node, YGWrap.NoWrap)
    else: discard
  of "display":
    if value == "none":
      YGNodeStyleSetDisplay(node, YGDisplay.None)
    else:
      YGNodeStyleSetDisplay(node, YGDisplay.Flex)
  of "position":
    case value
    of "absolute": YGNodeStyleSetPositionType(node, YGPositionType.Absolute)
    of "relative": YGNodeStyleSetPositionType(node, YGPositionType.Relative)
    else: discard
  of "border-radius", "background-color", "color", "font-size",
     "border-color", "font-weight", "text-decoration", "opacity":
    discard  # Visual-only, not layout-affecting
  else:
    discard

proc calculateLayout*(engine: LayoutEngine; width, height: float) =
  ## Compute layout for the entire tree. The root node gets the specified
  ## available width/height.
  if engine.nodes.len > 0:
    YGNodeCalculateLayout(engine.nodes[0].yogaNode,
                           cfloat(width), cfloat(height), YGDirection.LTR)

proc getLayout*(engine: LayoutEngine; viewHandle: int64): LayoutResult =
  ## Get the computed layout for a single view.
  if viewHandle in engine.handleToIndex:
    let idx = engine.handleToIndex[viewHandle]
    let node = engine.nodes[idx].yogaNode
    LayoutResult(
      x: YGNodeLayoutGetLeft(node),
      y: YGNodeLayoutGetTop(node),
      width: YGNodeLayoutGetWidth(node),
      height: YGNodeLayoutGetHeight(node))
  else:
    LayoutResult()

proc allLayouts*(engine: LayoutEngine): seq[tuple[handle: int64, layout: LayoutResult]] =
  ## Get computed layouts for all registered views.
  for node in engine.nodes:
    let l = LayoutResult(
      x: YGNodeLayoutGetLeft(node.yogaNode),
      y: YGNodeLayoutGetTop(node.yogaNode),
      width: YGNodeLayoutGetWidth(node.yogaNode),
      height: YGNodeLayoutGetHeight(node.yogaNode))
    result.add((node.viewHandle, l))

proc parentIndex*(engine: LayoutEngine; nodeIdx: int): int =
  ## Find the parent index for a given node. Returns -1 if root or not found.
  for i, node in engine.nodes:
    for childIdx in node.children:
      if childIdx == nodeIdx:
        return i
  return -1

proc allLayoutsFlipped*(engine: LayoutEngine; rootHeight: float):
    seq[tuple[handle: int64, layout: LayoutResult]] =
  ## Get computed layouts with Y-axis flipped for bottom-left origin systems
  ## (e.g., AppKit). For each node, Y is computed as:
  ##   parentHeight - yogaTop - nodeHeight
  for i, node in engine.nodes:
    let yogaX = YGNodeLayoutGetLeft(node.yogaNode)
    let yogaY = YGNodeLayoutGetTop(node.yogaNode)
    let w = YGNodeLayoutGetWidth(node.yogaNode)
    let h = YGNodeLayoutGetHeight(node.yogaNode)
    # Get parent height for Y flip
    var parentH = rootHeight
    let pIdx = engine.parentIndex(i)
    if pIdx >= 0:
      parentH = float(YGNodeLayoutGetHeight(engine.nodes[pIdx].yogaNode))
    let flippedY = parentH - float(yogaY) - float(h)
    result.add((node.viewHandle, LayoutResult(
      x: float(yogaX), y: flippedY,
      width: float(w), height: float(h))))

proc freeAll*(engine: LayoutEngine) =
  ## Free all Yoga nodes. Call when done with layout.
  for i in countdown(engine.nodes.len - 1, 0):
    YGNodeFree(engine.nodes[i].yogaNode)
  engine.nodes.setLen(0)
  engine.handleToIndex.clear()

# ---------------------------------------------------------------------------
# Layout-aware element helpers
# ---------------------------------------------------------------------------
# These helpers create elements via the renderer AND register them in the
# layout engine simultaneously, avoiding duplicated setStyle calls.

proc styledElement*[R, E](r: R; tag: string; engine: LayoutEngine;
                           styles: openArray[(string, string)]): E =
  ## Create an element, register it in the layout engine, and apply styles
  ## to both the renderer and Yoga tree.
  let elem = r.createElement(tag)
  let handle = cast[int64](cast[pointer](elem))
  discard engine.registerNode(handle)
  for (prop, value) in styles:
    r.setStyle(elem, prop, value)
    engine.setLayoutStyle(handle, prop, value)
  elem

proc styledTextNode*[R, E](r: R; text: string; engine: LayoutEngine;
                             styles: openArray[(string, string)]): E =
  ## Create a text node, register it in the layout engine, and apply styles.
  let elem = r.createTextNode(text)
  let handle = cast[int64](cast[pointer](elem))
  discard engine.registerNode(handle)
  for (prop, value) in styles:
    r.setStyle(elem, prop, value)
    engine.setLayoutStyle(handle, prop, value)
  elem

proc styledAppend*[R, E](r: R; parent, child: E; engine: LayoutEngine) =
  ## Append child to parent in both the renderer and layout engine.
  r.appendChild(parent, child)
  engine.addChild(cast[int64](cast[pointer](parent)), cast[int64](cast[pointer](child)))
