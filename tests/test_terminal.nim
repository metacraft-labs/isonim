## Terminal renderer tests for IsoNim.
##
## Validates that TerminalRenderer implements the RendererBackend concept,
## that it renders and updates correctly, and that the same component
## logic works with both MockRenderer and TerminalRenderer.

import unittest
import std/[tables, strutils]
import isonim/renderers/terminal_demo as terminal
import isonim/testing/mock_dom
import isonim/core/[signals, computation, owner]

# ---- Renderer-agnostic counter component ----

proc createCounter*[R, N](renderer: R): N =
  ## Creates a counter component using any renderer backend.
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

  renderer.addEventListener(incBtn, "click", proc() = count.val = count.val + 1)
  renderer.addEventListener(decBtn, "click", proc() = count.val = count.val - 1)

  createRenderEffect do:
    renderer.setTextContent(label, "Count: " & $count.val)

  return container

suite "Terminal Renderer":
  test "test_terminal_renderer_concept":
    ## TerminalRenderer compiles against RendererBackend concept check.
    ## The `when not compiles()` check in terminal.nim already verifies this
    ## at compile time. This test verifies it also works at runtime.
    # Compile-time verification: if this module compiles, the check passed.
    # The terminal.nim module contains:
    #   when not compiles(checkRendererBackend[TerminalRenderer, TerminalNode]()):
    #     {.error: ...}
    check true  # If we got here, the compile-time check passed

    let r = TerminalRenderer()
    let elem = r.createElement("div")
    check elem.kind == tnkBox
    check elem.tag == "div"

    let txt = r.createTextNode("hello")
    check txt.kind == tnkText
    check txt.text == "hello"

    r.appendChild(elem, txt)
    check elem.children.len == 1
    check r.firstChild(elem) == txt
    check r.parentNode(txt) == elem

    let btn = r.createElement("button")
    check btn.kind == tnkButton
    r.appendChild(elem, btn)
    check elem.children.len == 2
    check r.nextSibling(txt) == btn

    r.setAttribute(elem, "class", "main")
    check elem.attributes["class"] == "main"
    r.removeAttribute(elem, "class")
    check "class" notin elem.attributes

    r.setStyle(elem, "color", "red")
    check elem.styles["color"] == "red"

    r.setTextContent(txt, "world")
    check txt.text == "world"

    var clicked = false
    r.addEventListener(btn, "click", proc() = clicked = true)
    btn.fireEvent("click")
    check clicked

    r.removeChild(elem, txt)
    check elem.children.len == 1
    check r.firstChild(elem) == btn

    # insertBefore
    let newTxt = r.createTextNode("before")
    r.insertBefore(elem, newTxt, btn)
    check elem.children.len == 2
    check r.firstChild(elem) == newTxt
    check r.nextSibling(newTxt) == btn

  test "test_terminal_counter":
    ## Counter component renders and updates in terminal.
    createRoot do (dispose: proc()):
      let r = TerminalRenderer()
      let app = createCounter[TerminalRenderer, TerminalNode](r)

      # Initial state: label should show "Count: 0"
      let label = app.children[0]
      check textContent(label) == "Count: 0"

      # Verify renderToText output
      let output = renderToText(app)
      check "Count: 0" in output
      check "[+]" in output
      check "[-]" in output

      # Simulate increment
      let incBtn = app.children[1]
      incBtn.fireEvent("click")
      check textContent(label) == "Count: 1"

      let output2 = renderToText(app)
      check "Count: 1" in output2

      # Simulate decrement
      let decBtn = app.children[2]
      decBtn.fireEvent("click")
      check textContent(label) == "Count: 0"

      # Multiple increments
      incBtn.fireEvent("click")
      incBtn.fireEvent("click")
      incBtn.fireEvent("click")
      check textContent(label) == "Count: 3"

      dispose()

  test "test_same_component_dual_target":
    ## Same component logic works with both MockRenderer and TerminalRenderer.
    ## This is the key proof of GUI-agnostic architecture.
    createRoot do (dispose: proc()):
      # Create counter with MockRenderer
      let mockR = MockRenderer()
      let mockApp = createCounter[MockRenderer, MockNode](mockR)

      # Create counter with TerminalRenderer
      let termR = TerminalRenderer()
      let termApp = createCounter[TerminalRenderer, TerminalNode](termR)

      # Both should have same initial structure
      check mockApp.children.len == 3  # label, incBtn, decBtn
      check termApp.children.len == 3

      # Both should show Count: 0
      let mockLabel = mockApp.children[0]
      let termLabel = termApp.children[0]
      check mock_dom.textContent(mockLabel) == "Count: 0"
      check terminal.textContent(termLabel) == "Count: 0"

      # Increment mock counter
      let mockInc = mockApp.children[1]
      mockInc.fireEvent("click")
      check mock_dom.textContent(mockLabel) == "Count: 1"
      # Terminal counter should still be at 0
      check terminal.textContent(termLabel) == "Count: 0"

      # Increment terminal counter twice
      let termInc = termApp.children[1]
      termInc.fireEvent("click")
      termInc.fireEvent("click")
      check terminal.textContent(termLabel) == "Count: 2"
      # Mock counter should still be at 1
      check mock_dom.textContent(mockLabel) == "Count: 1"

      # Decrement both
      let mockDec = mockApp.children[2]
      let termDec = termApp.children[2]
      mockDec.fireEvent("click")
      termDec.fireEvent("click")
      check mock_dom.textContent(mockLabel) == "Count: 0"
      check terminal.textContent(termLabel) == "Count: 1"

      dispose()

  test "test_terminal_renderToText_boxes":
    ## renderToText produces correct text output for nested structures.
    let r = TerminalRenderer()
    let container = r.createElement("div")
    r.setAttribute(container, "title", "App")

    let heading = r.createTextNode("Hello Terminal")
    r.appendChild(container, heading)

    let btn = r.createElement("button")
    r.appendChild(btn, r.createTextNode("Click"))
    r.appendChild(container, btn)

    let input = r.createElement("input")
    r.setAttribute(input, "value", "typed text")
    r.appendChild(container, input)

    let output = renderToText(container)
    check "┌─ App ─┐" in output
    check "Hello Terminal" in output
    check "[Click]" in output
    check "[typed text]" in output
    check "└─────────┘" in output

  test "test_terminal_node_kinds":
    ## Different tags map to correct TerminalNodeKind.
    let r = TerminalRenderer()

    check r.createElement("div").kind == tnkBox
    check r.createElement("span").kind == tnkBox
    check r.createElement("h1").kind == tnkBox
    check r.createElement("button").kind == tnkButton
    check r.createElement("input").kind == tnkInput
    check r.createTextNode("hi").kind == tnkText

  test "test_terminal_setTextContent_element":
    ## setTextContent on a non-text node replaces children with a text node.
    let r = TerminalRenderer()
    let div1 = r.createElement("div")
    let child1 = r.createElement("span")
    let child2 = r.createElement("span")
    r.appendChild(div1, child1)
    r.appendChild(div1, child2)
    check div1.children.len == 2

    r.setTextContent(div1, "replaced")
    check div1.children.len == 1
    check div1.children[0].kind == tnkText
    check div1.children[0].text == "replaced"
    check div1.children[0].parent == div1
