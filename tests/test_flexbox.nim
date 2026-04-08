import unittest
import isonim/layout/flexbox

suite "Yoga Flexbox - Basic Layout":
  test "root node with fixed dimensions":
    var root = newFlexNode()
    root.setWidth(300)
    root.setHeight(200)
    root.calculateLayout(300, 200)
    let layout = root.getLayout()
    check layout.width == 300
    check layout.height == 200
    root.free()

  test "child positioned at origin":
    var root = newFlexNode()
    root.setWidth(300)
    root.setHeight(200)
    var child = newFlexNode()
    child.setWidth(100)
    child.setHeight(50)
    root.addChild(child)
    root.calculateLayout(300, 200)
    let cl = child.getLayout()
    check cl.width == 100
    check cl.height == 50
    check cl.x == 0
    check cl.y == 0
    root.free()

  test "column layout (default)":
    var root = newFlexNode()
    root.setWidth(300)
    root.setHeight(200)
    var c1 = newFlexNode()
    c1.setHeight(50)
    var c2 = newFlexNode()
    c2.setHeight(50)
    root.addChild(c1)
    root.addChild(c2)
    root.calculateLayout(300, 200)
    check c1.getLayout().y == 0
    check c2.getLayout().y == 50  # stacked below c1

  test "row layout":
    var root = newFlexNode()
    root.setWidth(300)
    root.setHeight(100)
    root.setFlexDirection(YGFlexDirection.Row)
    var c1 = newFlexNode()
    c1.setWidth(100)
    var c2 = newFlexNode()
    c2.setWidth(100)
    root.addChild(c1)
    root.addChild(c2)
    root.calculateLayout(300, 100)
    check c1.getLayout().x == 0
    check c2.getLayout().x == 100  # beside c1

  test "flex grow distributes space":
    var root = newFlexNode()
    root.setWidth(300)
    root.setHeight(100)
    root.setFlexDirection(YGFlexDirection.Row)
    var c1 = newFlexNode()
    c1.setFlexGrow(1)
    var c2 = newFlexNode()
    c2.setFlexGrow(2)
    root.addChild(c1)
    root.addChild(c2)
    root.calculateLayout(300, 100)
    check c1.getLayout().width == 100  # 1/3 of 300
    check c2.getLayout().width == 200  # 2/3 of 300

  test "padding offsets children":
    var root = newFlexNode()
    root.setWidth(300)
    root.setHeight(200)
    root.setPaddingAll(20)
    var child = newFlexNode()
    child.setWidth(100)
    child.setHeight(50)
    root.addChild(child)
    root.calculateLayout(300, 200)
    check child.getLayout().x == 20
    check child.getLayout().y == 20

  test "justify content center":
    var root = newFlexNode()
    root.setWidth(300)
    root.setHeight(200)
    root.setJustifyContent(YGJustify.Center)
    var child = newFlexNode()
    child.setWidth(100)
    child.setHeight(50)
    root.addChild(child)
    root.calculateLayout(300, 200)
    check child.getLayout().y == 75  # centered: (200-50)/2

  test "align items center":
    var root = newFlexNode()
    root.setWidth(300)
    root.setHeight(200)
    root.setAlignItems(YGAlign.Center)
    var child = newFlexNode()
    child.setWidth(100)
    child.setHeight(50)
    root.addChild(child)
    root.calculateLayout(300, 200)
    check child.getLayout().x == 100  # centered: (300-100)/2

  test "gap between children":
    var root = newFlexNode()
    root.setWidth(300)
    root.setHeight(200)
    root.setGap(10)
    var c1 = newFlexNode()
    c1.setHeight(50)
    var c2 = newFlexNode()
    c2.setHeight(50)
    root.addChild(c1)
    root.addChild(c2)
    root.calculateLayout(300, 200)
    check c1.getLayout().y == 0
    check c2.getLayout().y == 60  # 50 + 10 gap

  test "display none hides element":
    var root = newFlexNode()
    root.setWidth(300)
    root.setHeight(200)
    var c1 = newFlexNode()
    c1.setHeight(50)
    var c2 = newFlexNode()
    c2.setHeight(50)
    c2.setDisplay(YGDisplay.None)
    var c3 = newFlexNode()
    c3.setHeight(50)
    root.addChild(c1)
    root.addChild(c2)
    root.addChild(c3)
    root.calculateLayout(300, 200)
    check c3.getLayout().y == 50  # c2 hidden, c3 at y=50 not 100
