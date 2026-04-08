## Low-level Nim bindings for Facebook's Yoga layout engine.
## Compiles Yoga C++ source directly via {.compile.} — no separate build step.

const yogaRoot = currentSourcePath()[0..^(len("yoga_bindings.nim") + 1)] & "yoga"
const yogaInclude = yogaRoot
const yogaHeader = yogaInclude & "/yoga/Yoga.h"

# Include path needed for Nim-generated C files that reference the Yoga header
{.passC: "-I" & yogaInclude.}

# Compile all Yoga C++ source files
const yogaCxxFlags = "-std=c++20 -I" & yogaInclude

when defined(macosx):
  {.passL: "-lc++".}
else:
  {.passL: "-lstdc++".}

# Core
{.compile(yogaRoot & "/yoga/YGConfig.cpp", yogaCxxFlags).}
{.compile(yogaRoot & "/yoga/YGEnums.cpp", yogaCxxFlags).}
{.compile(yogaRoot & "/yoga/YGNode.cpp", yogaCxxFlags).}
{.compile(yogaRoot & "/yoga/YGNodeLayout.cpp", yogaCxxFlags).}
{.compile(yogaRoot & "/yoga/YGNodeStyle.cpp", yogaCxxFlags).}
{.compile(yogaRoot & "/yoga/YGPixelGrid.cpp", yogaCxxFlags).}
{.compile(yogaRoot & "/yoga/YGValue.cpp", yogaCxxFlags).}

# Algorithm
{.compile(yogaRoot & "/yoga/algorithm/AbsoluteLayout.cpp", yogaCxxFlags).}
{.compile(yogaRoot & "/yoga/algorithm/Baseline.cpp", yogaCxxFlags).}
{.compile(yogaRoot & "/yoga/algorithm/Cache.cpp", yogaCxxFlags).}
{.compile(yogaRoot & "/yoga/algorithm/CalculateLayout.cpp", yogaCxxFlags).}
{.compile(yogaRoot & "/yoga/algorithm/FlexLine.cpp", yogaCxxFlags).}
{.compile(yogaRoot & "/yoga/algorithm/PixelGrid.cpp", yogaCxxFlags).}

# Config
{.compile(yogaRoot & "/yoga/config/Config.cpp", yogaCxxFlags).}

# Debug
{.compile(yogaRoot & "/yoga/debug/AssertFatal.cpp", yogaCxxFlags).}
{.compile(yogaRoot & "/yoga/debug/Log.cpp", yogaCxxFlags).}

# Event
{.compile(yogaRoot & "/yoga/event/event.cpp", yogaCxxFlags).}

# Node
{.compile(yogaRoot & "/yoga/node/LayoutResults.cpp", yogaCxxFlags).}
{.compile(yogaRoot & "/yoga/node/Node.cpp", yogaCxxFlags).}

# --- Types ---

type
  YGNodeRef* = pointer
  YGNodeConstRef* = pointer
  YGConfigRef* = pointer
  YGConfigConstRef* = pointer

  YGDirection* {.size: sizeof(cint).} = enum
    Inherit = 0
    LTR = 1
    RTL = 2

  YGFlexDirection* {.size: sizeof(cint).} = enum
    Column = 0
    ColumnReverse = 1
    Row = 2
    RowReverse = 3

  YGJustify* {.size: sizeof(cint).} = enum
    Auto = 0
    FlexStart = 1
    Center = 2
    FlexEnd = 3
    SpaceBetween = 4
    SpaceAround = 5
    SpaceEvenly = 6
    Stretch = 7
    Start = 8
    End = 9

  YGAlign* {.size: sizeof(cint).} = enum
    Auto = 0
    FlexStart = 1
    Center = 2
    FlexEnd = 3
    Stretch = 4
    Baseline = 5
    SpaceBetween = 6
    SpaceAround = 7
    SpaceEvenly = 8
    Start = 9
    End = 10

  YGWrap* {.size: sizeof(cint).} = enum
    NoWrap = 0
    Wrap = 1
    WrapReverse = 2

  YGEdge* {.size: sizeof(cint).} = enum
    Left = 0
    Top = 1
    Right = 2
    Bottom = 3
    Start = 4
    End = 5
    Horizontal = 6
    Vertical = 7
    All = 8

  YGPositionType* {.size: sizeof(cint).} = enum
    Static = 0
    Relative = 1
    Absolute = 2

  YGDisplay* {.size: sizeof(cint).} = enum
    Flex = 0
    None = 1
    Contents = 2
    Grid = 3

  YGGutter* {.size: sizeof(cint).} = enum
    Column = 0
    Row = 1
    All = 2

  YGUnit* {.size: sizeof(cint).} = enum
    Undefined = 0
    Point = 1
    Percent = 2
    Auto = 3
    MaxContent = 4
    FitContent = 5
    Stretch = 6

  YGValue* {.importc, header: yogaHeader.} = object
    value*: cfloat
    unit*: YGUnit

# --- Node lifecycle ---

proc YGNodeNew*(): YGNodeRef {.importc, header: yogaHeader.}
proc YGNodeFree*(node: YGNodeRef) {.importc, header: yogaHeader.}
proc YGNodeFreeRecursive*(node: YGNodeRef) {.importc, header: yogaHeader.}
proc YGNodeReset*(node: YGNodeRef) {.importc, header: yogaHeader.}

# --- Tree ---

proc YGNodeInsertChild*(node: YGNodeRef; child: YGNodeRef; index: csize_t) {.importc, header: yogaHeader.}
proc YGNodeRemoveChild*(node: YGNodeRef; child: YGNodeRef) {.importc, header: yogaHeader.}
proc YGNodeRemoveAllChildren*(node: YGNodeRef) {.importc, header: yogaHeader.}
proc YGNodeGetChildCount*(node: YGNodeConstRef): csize_t {.importc, header: yogaHeader.}
proc YGNodeGetChild*(node: YGNodeRef; index: csize_t): YGNodeRef {.importc, header: yogaHeader.}
proc YGNodeGetParent*(node: YGNodeRef): YGNodeRef {.importc, header: yogaHeader.}
proc YGNodeGetOwner*(node: YGNodeRef): YGNodeRef {.importc, header: yogaHeader.}

# --- Style setters ---

proc YGNodeStyleSetDirection*(node: YGNodeRef; direction: YGDirection) {.importc, header: yogaHeader.}
proc YGNodeStyleSetFlexDirection*(node: YGNodeRef; flexDirection: YGFlexDirection) {.importc, header: yogaHeader.}
proc YGNodeStyleSetJustifyContent*(node: YGNodeRef; justifyContent: YGJustify) {.importc, header: yogaHeader.}
proc YGNodeStyleSetAlignContent*(node: YGNodeRef; alignContent: YGAlign) {.importc, header: yogaHeader.}
proc YGNodeStyleSetAlignItems*(node: YGNodeRef; alignItems: YGAlign) {.importc, header: yogaHeader.}
proc YGNodeStyleSetAlignSelf*(node: YGNodeRef; alignSelf: YGAlign) {.importc, header: yogaHeader.}
proc YGNodeStyleSetFlexWrap*(node: YGNodeRef; flexWrap: YGWrap) {.importc, header: yogaHeader.}
proc YGNodeStyleSetPositionType*(node: YGNodeRef; positionType: YGPositionType) {.importc, header: yogaHeader.}
proc YGNodeStyleSetDisplay*(node: YGNodeRef; display: YGDisplay) {.importc, header: yogaHeader.}

proc YGNodeStyleSetFlex*(node: YGNodeRef; flex: cfloat) {.importc, header: yogaHeader.}
proc YGNodeStyleSetFlexGrow*(node: YGNodeRef; flexGrow: cfloat) {.importc, header: yogaHeader.}
proc YGNodeStyleSetFlexShrink*(node: YGNodeRef; flexShrink: cfloat) {.importc, header: yogaHeader.}

proc YGNodeStyleSetWidth*(node: YGNodeRef; width: cfloat) {.importc, header: yogaHeader.}
proc YGNodeStyleSetHeight*(node: YGNodeRef; height: cfloat) {.importc, header: yogaHeader.}
proc YGNodeStyleSetWidthPercent*(node: YGNodeRef; width: cfloat) {.importc, header: yogaHeader.}
proc YGNodeStyleSetHeightPercent*(node: YGNodeRef; height: cfloat) {.importc, header: yogaHeader.}
proc YGNodeStyleSetMinWidth*(node: YGNodeRef; minWidth: cfloat) {.importc, header: yogaHeader.}
proc YGNodeStyleSetMinHeight*(node: YGNodeRef; minHeight: cfloat) {.importc, header: yogaHeader.}
proc YGNodeStyleSetMaxWidth*(node: YGNodeRef; maxWidth: cfloat) {.importc, header: yogaHeader.}
proc YGNodeStyleSetMaxHeight*(node: YGNodeRef; maxHeight: cfloat) {.importc, header: yogaHeader.}

proc YGNodeStyleSetPadding*(node: YGNodeRef; edge: YGEdge; padding: cfloat) {.importc, header: yogaHeader.}
proc YGNodeStyleSetMargin*(node: YGNodeRef; edge: YGEdge; margin: cfloat) {.importc, header: yogaHeader.}
proc YGNodeStyleSetBorder*(node: YGNodeRef; edge: YGEdge; border: cfloat) {.importc, header: yogaHeader.}
proc YGNodeStyleSetGap*(node: YGNodeRef; gutter: YGGutter; gapLength: cfloat) {.importc, header: yogaHeader.}

# --- Layout calculation ---

proc YGNodeCalculateLayout*(node: YGNodeRef; availableWidth: cfloat;
                             availableHeight: cfloat;
                             ownerDirection: YGDirection) {.importc, header: yogaHeader.}

# --- Layout results ---

proc YGNodeLayoutGetLeft*(node: YGNodeConstRef): cfloat {.importc, header: yogaHeader.}
proc YGNodeLayoutGetTop*(node: YGNodeConstRef): cfloat {.importc, header: yogaHeader.}
proc YGNodeLayoutGetRight*(node: YGNodeConstRef): cfloat {.importc, header: yogaHeader.}
proc YGNodeLayoutGetBottom*(node: YGNodeConstRef): cfloat {.importc, header: yogaHeader.}
proc YGNodeLayoutGetWidth*(node: YGNodeConstRef): cfloat {.importc, header: yogaHeader.}
proc YGNodeLayoutGetHeight*(node: YGNodeConstRef): cfloat {.importc, header: yogaHeader.}
proc YGNodeLayoutGetMargin*(node: YGNodeConstRef; edge: YGEdge): cfloat {.importc, header: yogaHeader.}
proc YGNodeLayoutGetBorder*(node: YGNodeConstRef; edge: YGEdge): cfloat {.importc, header: yogaHeader.}
proc YGNodeLayoutGetPadding*(node: YGNodeConstRef; edge: YGEdge): cfloat {.importc, header: yogaHeader.}
