## Tests for the native GUI renderer prototype (M29).
##
## Validates that NativeRenderer implements RendererBackend,
## renders correctly, and produces identical behavior as other renderers
## when given the same component logic.

import unittest
import std/[tables, strutils]
import isonim/renderers/native
import isonim/renderers/terminal
import isonim/testing/mock_dom
import isonim/core/[signals, computation, owner]

# ---- Generic test component (works with any renderer) ----

proc createCounter*[R, N](renderer: R): N =
  ## A counter component that works with any RendererBackend.
  let count = createSignal(0)
  let container = renderer.createElement("div")
  let label = renderer.createTextNode("")
  let incBtn = renderer.createElement("button")
  let decBtn = renderer.createElement("button")

  renderer.appendChild(incBtn, renderer.createTextNode("+"))
  renderer.appendChild(decBtn, renderer.createTextNode("-"))
  renderer.appendChild(container, label)
  renderer.appendChild(container, incBtn)
  renderer.appendChild(container, decBtn)

  renderer.addEventListener(incBtn, "click", proc() =
    count.val = count.val + 1
  )
  renderer.addEventListener(decBtn, "click", proc() =
    count.val = count.val - 1
  )

  createRenderEffect do:
    renderer.setTextContent(label, "Count: " & $count.val)

  return container

proc createTaskList*[R, N](renderer: R; items: seq[string]): N =
  ## A list component that works with any RendererBackend.
  let ul = renderer.createElement("ul")
  for item in items:
    let li = renderer.createElement("li")
    let span = renderer.createElement("span")
    renderer.setTextContent(span, item)
    renderer.appendChild(li, span)
    renderer.appendChild(ul, li)
  return ul

suite "Native Renderer - Basic Operations":
  test "createElement produces correct widget kinds":
    let r = NativeRenderer()
    check r.createElement("div").kind == nwkPanel
    check r.createElement("button").kind == nwkButton
    check r.createElement("input").kind == nwkInput
    check r.createElement("span").kind == nwkLabel
    check r.createElement("h1").kind == nwkLabel
    check r.createElement("ul").kind == nwkList
    check r.createElement("li").kind == nwkListItem
    check r.createElement("img").kind == nwkImage

  test "createTextNode produces text widget":
    let r = NativeRenderer()
    let t = r.createTextNode("hello")
    check t.kind == nwkText
    check t.text == "hello"

  test "appendChild builds tree":
    let r = NativeRenderer()
    let parent = r.createElement("div")
    let child = r.createElement("span")
    r.appendChild(parent, child)
    check parent.children.len == 1
    check parent.children[0] == child
    check child.parent == parent

  test "removeChild removes from tree":
    let r = NativeRenderer()
    let parent = r.createElement("div")
    let child = r.createElement("span")
    r.appendChild(parent, child)
    r.removeChild(parent, child)
    check parent.children.len == 0
    check child.parent == nil

  test "insertBefore inserts at correct position":
    let r = NativeRenderer()
    let parent = r.createElement("div")
    let a = r.createElement("span")
    let b = r.createElement("span")
    let c = r.createElement("span")
    r.appendChild(parent, a)
    r.appendChild(parent, c)
    r.insertBefore(parent, b, c)
    check parent.children.len == 3
    check parent.children[0] == a
    check parent.children[1] == b
    check parent.children[2] == c

  test "setAttribute maps to native properties":
    let r = NativeRenderer()
    let node = r.createElement("input")
    r.setAttribute(node, "disabled", "")
    check node.enabled == false
    r.removeAttribute(node, "disabled")
    check node.enabled == true

  test "setStyle maps CSS to native layout":
    let r = NativeRenderer()
    let node = r.createElement("div")
    check node.layout == ldVertical
    r.setStyle(node, "flex-direction", "row")
    check node.layout == ldHorizontal
    r.setStyle(node, "display", "none")
    check node.visible == false

  test "tree navigation works":
    let r = NativeRenderer()
    let parent = r.createElement("div")
    let a = r.createElement("span")
    let b = r.createElement("span")
    r.appendChild(parent, a)
    r.appendChild(parent, b)
    check r.firstChild(parent) == a
    check r.nextSibling(a) == b
    check r.nextSibling(b) == nil
    check r.parentNode(a) == parent

suite "Native Renderer - Reactive":
  test "reactive counter works with NativeRenderer":
    createRoot do (dispose: proc()):
      let r = NativeRenderer()
      let counter = createCounter[NativeRenderer, NativeWidget](r)

      check native.textContent(counter) == "Count: 0+-"

      # Click increment
      let incBtn = counter.children[1]
      incBtn.fireEvent("click")
      check native.textContent(counter) == "Count: 1+-"

      incBtn.fireEvent("click")
      incBtn.fireEvent("click")
      check native.textContent(counter) == "Count: 3+-"

      # Click decrement
      let decBtn = counter.children[2]
      decBtn.fireEvent("click")
      check native.textContent(counter) == "Count: 2+-"

      dispose()

  test "task list renders with NativeRenderer":
    let r = NativeRenderer()
    let list = createTaskList[NativeRenderer, NativeWidget](r,
      @["Buy groceries", "Write code", "Test app"])

    check list.kind == nwkList
    check list.children.len == 3
    check list.children[0].kind == nwkListItem
    check native.textContent(list.children[0]) == "Buy groceries"
    check native.textContent(list.children[1]) == "Write code"
    check native.textContent(list.children[2]) == "Test app"

  test "reactive signal updates native widget":
    createRoot do (dispose: proc()):
      let r = NativeRenderer()
      let name = createSignal("World")
      let label = r.createElement("span")

      createRenderEffect do:
        r.setTextContent(label, "Hello, " & name.val & "!")

      check native.textContent(label) == "Hello, World!"
      name.val = "IsoNim"
      check native.textContent(label) == "Hello, IsoNim!"

      dispose()

suite "Native Renderer - Widget Tree Rendering":
  test "renderWidgetTree produces ASCII output":
    let r = NativeRenderer()
    let root = r.createElement("div")
    r.setAttribute(root, "class", "app")
    let h1 = r.createElement("h1")
    r.setTextContent(h1, "Task Manager")
    let ul = r.createElement("ul")
    let li1 = r.createElement("li")
    r.setTextContent(li1, "Task 1")
    let li2 = r.createElement("li")
    r.setTextContent(li2, "Task 2")
    r.appendChild(ul, li1)
    r.appendChild(ul, li2)
    r.appendChild(root, h1)
    r.appendChild(root, ul)

    let output = renderWidgetTree(root)
    check "Panel(app)" in output
    check "Label(H1: Task Manager)" in output
    check "Task 1" in output
    check "Task 2" in output

suite "Cross-Renderer Compatibility":
  test "same counter component works across all three renderers":
    ## Proves the reactive core is truly decoupled from rendering.
    createRoot do (dispose: proc()):
      let nr = NativeRenderer()
      let tr = TerminalRenderer()
      let mr = MockRenderer()

      let nativeCounter = createCounter[NativeRenderer, NativeWidget](nr)
      let terminalCounter = createCounter[TerminalRenderer, TerminalNode](tr)
      let mockCounter = createCounter[MockRenderer, MockNode](mr)

      # All start at 0
      check native.textContent(nativeCounter) == "Count: 0+-"
      check terminal.textContent(terminalCounter) == "Count: 0+-"
      check mock_dom.textContent(mockCounter) == "Count: 0+-"

      # Increment native
      nativeCounter.children[1].fireEvent("click")
      check native.textContent(nativeCounter) == "Count: 1+-"

      # Increment terminal
      terminalCounter.children[1].fireEvent("click")
      check terminal.textContent(terminalCounter) == "Count: 1+-"

      # Increment mock
      mockCounter.children[1].fireEvent("click")
      check mock_dom.textContent(mockCounter) == "Count: 1+-"

      # All three produce same structure
      check nativeCounter.children.len == terminalCounter.children.len
      check nativeCounter.children.len == mockCounter.children.len

      dispose()

  test "same task list works across all three renderers":
    let nr = NativeRenderer()
    let tr = TerminalRenderer()
    let mr = MockRenderer()
    let items = @["Alpha", "Beta", "Gamma"]

    let nList = createTaskList[NativeRenderer, NativeWidget](nr, items)
    let tList = createTaskList[TerminalRenderer, TerminalNode](tr, items)
    let mList = createTaskList[MockRenderer, MockNode](mr, items)

    # Same child count
    check nList.children.len == 3
    check tList.children.len == 3
    check mList.children.len == 3

    # Same text content
    for i in 0..2:
      check native.textContent(nList.children[i]) == items[i]
      check terminal.textContent(tList.children[i]) == items[i]
      check mock_dom.textContent(mList.children[i]) == items[i]
