## High-level Nim API for Facebook's Yoga flexbox layout engine.

import isonim/layout/yoga_bindings
export yoga_bindings

type
  FlexNode* = object
    ygNode*: YGNodeRef
    children*: seq[FlexNode]

  FlexLayout* = object
    x*, y*, width*, height*: float

proc newFlexNode*(): FlexNode =
  FlexNode(ygNode: YGNodeNew())

proc free*(node: var FlexNode) =
  YGNodeFree(node.ygNode)

proc addChild*(parent: var FlexNode; child: FlexNode) =
  let idx = YGNodeGetChildCount(parent.ygNode)
  YGNodeInsertChild(parent.ygNode, child.ygNode, idx)
  parent.children.add(child)

proc setWidth*(node: FlexNode; width: float) =
  YGNodeStyleSetWidth(node.ygNode, cfloat(width))

proc setHeight*(node: FlexNode; height: float) =
  YGNodeStyleSetHeight(node.ygNode, cfloat(height))

proc setMinWidth*(node: FlexNode; width: float) =
  YGNodeStyleSetMinWidth(node.ygNode, cfloat(width))

proc setMinHeight*(node: FlexNode; height: float) =
  YGNodeStyleSetMinHeight(node.ygNode, cfloat(height))

proc setMaxWidth*(node: FlexNode; width: float) =
  YGNodeStyleSetMaxWidth(node.ygNode, cfloat(width))

proc setMaxHeight*(node: FlexNode; height: float) =
  YGNodeStyleSetMaxHeight(node.ygNode, cfloat(height))

proc setWidthPercent*(node: FlexNode; pct: float) =
  YGNodeStyleSetWidthPercent(node.ygNode, cfloat(pct))

proc setHeightPercent*(node: FlexNode; pct: float) =
  YGNodeStyleSetHeightPercent(node.ygNode, cfloat(pct))

proc setFlexDirection*(node: FlexNode; dir: YGFlexDirection) =
  YGNodeStyleSetFlexDirection(node.ygNode, dir)

proc setJustifyContent*(node: FlexNode; justify: YGJustify) =
  YGNodeStyleSetJustifyContent(node.ygNode, justify)

proc setAlignItems*(node: FlexNode; align: YGAlign) =
  YGNodeStyleSetAlignItems(node.ygNode, align)

proc setAlignSelf*(node: FlexNode; align: YGAlign) =
  YGNodeStyleSetAlignSelf(node.ygNode, align)

proc setAlignContent*(node: FlexNode; align: YGAlign) =
  YGNodeStyleSetAlignContent(node.ygNode, align)

proc setFlexWrap*(node: FlexNode; wrap: YGWrap) =
  YGNodeStyleSetFlexWrap(node.ygNode, wrap)

proc setPositionType*(node: FlexNode; posType: YGPositionType) =
  YGNodeStyleSetPositionType(node.ygNode, posType)

proc setPadding*(node: FlexNode; edge: YGEdge; value: float) =
  YGNodeStyleSetPadding(node.ygNode, edge, cfloat(value))

proc setPaddingAll*(node: FlexNode; value: float) =
  setPadding(node, YGEdge.All, value)

proc setMargin*(node: FlexNode; edge: YGEdge; value: float) =
  YGNodeStyleSetMargin(node.ygNode, edge, cfloat(value))

proc setMarginAll*(node: FlexNode; value: float) =
  setMargin(node, YGEdge.All, value)

proc setGap*(node: FlexNode; gutter: YGGutter; value: float) =
  YGNodeStyleSetGap(node.ygNode, gutter, cfloat(value))

proc setGap*(node: FlexNode; value: float) =
  ## Set gap for all gutters (column and row).
  setGap(node, YGGutter.All, value)

proc setFlexGrow*(node: FlexNode; grow: float) =
  YGNodeStyleSetFlexGrow(node.ygNode, cfloat(grow))

proc setFlexShrink*(node: FlexNode; shrink: float) =
  YGNodeStyleSetFlexShrink(node.ygNode, cfloat(shrink))

proc setFlex*(node: FlexNode; flex: float) =
  YGNodeStyleSetFlex(node.ygNode, cfloat(flex))

proc setDisplay*(node: FlexNode; display: YGDisplay) =
  YGNodeStyleSetDisplay(node.ygNode, display)

proc setBorderWidth*(node: FlexNode; edge: YGEdge; width: float) =
  YGNodeStyleSetBorder(node.ygNode, edge, cfloat(width))

proc setDirection*(node: FlexNode; direction: YGDirection) =
  YGNodeStyleSetDirection(node.ygNode, direction)

proc calculateLayout*(node: FlexNode; availWidth, availHeight: float;
                       direction: YGDirection = YGDirection.LTR) =
  YGNodeCalculateLayout(node.ygNode, cfloat(availWidth), cfloat(availHeight), direction)

proc getLayout*(node: FlexNode): FlexLayout =
  FlexLayout(
    x: YGNodeLayoutGetLeft(node.ygNode),
    y: YGNodeLayoutGetTop(node.ygNode),
    width: YGNodeLayoutGetWidth(node.ygNode),
    height: YGNodeLayoutGetHeight(node.ygNode),
  )

proc childCount*(node: FlexNode): int =
  int(YGNodeGetChildCount(node.ygNode))
