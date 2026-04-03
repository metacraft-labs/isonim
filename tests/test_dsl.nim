import unittest
import std/tables
import isonim/core/[signals, computation, owner, batch, graph]
import isonim/testing/mock_dom
import isonim/dsl/html
import isonim/dsl/components

suite "DSL":
  test "test_dsl_static_html":
    ## buildHtml with static content produces correct MockNode tree
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let root = buildHtml(renderer):
        tdiv(class = "container"):
          h1: text "Hello"
          p: text "World"

      check root.kind == mnkElement
      check root.tag == "div"
      check root.attributes["class"] == "container"
      check root.children.len == 2

      let h1 = root.children[0]
      check h1.tag == "h1"
      check h1.children.len == 1
      check h1.children[0].kind == mnkText
      check h1.children[0].text == "Hello"

      let p = root.children[1]
      check p.tag == "p"
      check p.children.len == 1
      check p.children[0].kind == mnkText
      check p.children[0].text == "World"

  test "test_dsl_dynamic_text_update":
    ## Signal-dependent text updates MockNode when signal changes
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let count = createSignal(0)

      let root = buildHtml(renderer):
        tdiv:
          span: text $count.val

      let span = root.children[0]
      check span.children.len == 1
      check span.children[0].text == "0"

      count.val = 42
      check span.children[0].text == "42"

  test "test_dsl_dynamic_attribute":
    ## Signal-dependent attribute updates via createRenderEffect
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let cls = createSignal("red")

      let root = buildHtml(renderer):
        tdiv(class = cls.val)

      check root.attributes["class"] == "red"

      cls.val = "blue"
      check root.attributes["class"] == "blue"

  test "test_dsl_event_handler":
    ## onclick registers handler; mock event triggers callback
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      var clicked = 0

      let root = buildHtml(renderer):
        button(onclick = proc() = inc clicked):
          text "Click me"

      check clicked == 0
      root.fireEvent("click")
      check clicked == 1
      root.fireEvent("click")
      check clicked == 2

  test "test_for_keyed_reconciliation":
    ## For adds/removes/reorders MockNodes matching array changes
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let items = createSignal(@["a", "b", "c"])
      let parent = renderer.createElement("div")

      forEachKeyed(renderer, parent,
        proc(): seq[string] = items.val,
        proc(item: proc(): string, index: proc(): int): MockNode =
          let node = renderer.createElement("span")
          createRenderEffect proc() =
            renderer.setTextContent(node, item())
          node
      )

      check parent.children.len == 3
      check parent.children[0].textContent == "a"
      check parent.children[1].textContent == "b"
      check parent.children[2].textContent == "c"

      # Save references to track identity
      let nodeA = parent.children[0]
      let nodeB = parent.children[1]
      let nodeC = parent.children[2]

      # Remove "b"
      items.val = @["a", "c"]
      check parent.children.len == 2
      check parent.children[0] == nodeA
      check parent.children[1] == nodeC

      # Add "d" and reorder
      items.val = @["c", "a", "d"]
      check parent.children.len == 3
      check parent.children[0] == nodeC
      check parent.children[1] == nodeA
      check parent.children[2].textContent == "d"

  test "test_index_stable_references":
    ## Index keeps stable node refs; updates signal value in-place
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let items = createSignal(@[10, 20, 30])
      let parent = renderer.createElement("div")

      indexEach(renderer, parent,
        proc(): seq[int] = items.val,
        proc(item: proc(): int, index: int): MockNode =
          let node = renderer.createElement("span")
          createRenderEffect proc() =
            renderer.setTextContent(node, $item())
          node
      )

      check parent.children.len == 3
      check parent.children[0].textContent == "10"
      check parent.children[1].textContent == "20"
      check parent.children[2].textContent == "30"

      # Save references
      let node0 = parent.children[0]
      let node1 = parent.children[1]
      let node2 = parent.children[2]

      # Update values - nodes should stay the same, content updates
      items.val = @[100, 200, 300]
      check parent.children.len == 3
      check parent.children[0] == node0  # Same reference
      check parent.children[1] == node1  # Same reference
      check parent.children[2] == node2  # Same reference
      check parent.children[0].textContent == "100"
      check parent.children[1].textContent == "200"
      check parent.children[2].textContent == "300"

  test "test_show_conditional":
    ## Show renders content when true, fallback when false
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let visible = createSignal(true)
      let parent = renderer.createElement("div")

      show(renderer, parent,
        proc(): bool = visible.val,
        proc(): MockNode =
          let node = renderer.createElement("span")
          let txt = renderer.createTextNode("visible")
          renderer.appendChild(node, txt)
          node
        ,
        proc(): MockNode =
          let node = renderer.createElement("span")
          let txt = renderer.createTextNode("hidden")
          renderer.appendChild(node, txt)
          node
      )

      check parent.children.len == 1
      check parent.children[0].textContent == "visible"

      visible.val = false
      check parent.children.len == 1
      check parent.children[0].textContent == "hidden"

      visible.val = true
      check parent.children.len == 1
      check parent.children[0].textContent == "visible"

  test "test_error_boundary_catches":
    ## ErrorBoundary renders fallback when child throws
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let parent = renderer.createElement("div")

      errorBoundary(renderer, parent,
        proc(): MockNode =
          raise newException(CatchableError, "boom")
        ,
        proc(err: ref CatchableError): MockNode =
          let node = renderer.createElement("span")
          let txt = renderer.createTextNode("Error: " & err.msg)
          renderer.appendChild(node, txt)
          node
      )

      check parent.children.len == 1
      check parent.children[0].textContent == "Error: boom"

  test "test_dsl_nested_components":
    ## Nested components create proper owner hierarchy
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      var outerOwner: OwnerBase
      var innerOwner: OwnerBase

      # Simulate nested component pattern
      let root = buildHtml(renderer):
        tdiv:
          tdiv:
            text "inner"

      # Verify nested structure
      check root.tag == "div"
      check root.children.len == 1
      check root.children[0].tag == "div"
      check root.children[0].children.len == 1
      check root.children[0].children[0].text == "inner"

      # Verify owner hierarchy by creating effects in nested roots
      var outerDispose: proc()
      var innerDispose: proc()
      var outerVal = 0
      var innerVal = 0
      let s = createSignal(0)

      createRoot proc(d1: proc()) =
        outerDispose = d1
        outerOwner = getOwner()
        createEffect proc() =
          outerVal = s.val
        createRoot proc(d2: proc()) =
          innerDispose = d2
          innerOwner = getOwner()
          createEffect proc() =
            innerVal = s.val

      s.val = 5
      check outerVal == 5
      check innerVal == 5

      # Disposing inner shouldn't affect outer
      innerDispose()
      s.val = 10
      check outerVal == 10
      check innerVal == 5  # Disposed, not updated

      # Verify owner hierarchy
      check innerOwner.owner == outerOwner

  test "test_showIf_basic":
    ## showIf renders body when condition is true
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let visible = createSignal(true)

      let root = buildHtml(renderer):
        tdiv:
          showIf(visible.val):
            p: text "shown"

      # showIf creates a container; check that the text is visible
      check root.tag == "div"
      check root.textContent == "shown"

  test "test_showIf_with_fallback":
    ## showIf + showElse toggles between body and fallback
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let visible = createSignal(true)

      let root = buildHtml(renderer):
        tdiv:
          showIf(visible.val):
            p: text "visible"
          showElse:
            p: text "hidden"

      check root.textContent == "visible"

      visible.val = false
      check root.textContent == "hidden"

      visible.val = true
      check root.textContent == "visible"

  test "test_showIf_reactive":
    ## showIf responds to signal changes without fallback
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let visible = createSignal(false)

      let root = buildHtml(renderer):
        tdiv:
          showIf(visible.val):
            p: text "now you see me"

      # Initially false, no content rendered
      check root.children.len == 0

      visible.val = true
      check root.textContent == "now you see me"

      visible.val = false
      check root.children.len == 0

  test "test_forIn_basic":
    ## forIn renders list items
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let items = createSignal(@["a", "b", "c"])

      let root = buildHtml(renderer):
        ul:
          forIn(items.val):
            li: text $item

      check root.tag == "ul"
      check root.children.len == 3
      check root.children[0].textContent == "a"
      check root.children[1].textContent == "b"
      check root.children[2].textContent == "c"

  test "test_forIn_reactive":
    ## forIn updates when signal changes
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let items = createSignal(@["x", "y"])

      let root = buildHtml(renderer):
        ul:
          forIn(items.val):
            li: text $item

      check root.children.len == 2
      check root.children[0].textContent == "x"
      check root.children[1].textContent == "y"

      items.val = @["x", "y", "z"]
      check root.children.len == 3
      check root.children[2].textContent == "z"

      items.val = @["y"]
      check root.children.len == 1
      check root.children[0].textContent == "y"

  test "test_forIn_with_index":
    ## forIn provides index variable
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let items = createSignal(@["a", "b", "c"])

      let root = buildHtml(renderer):
        ul:
          forIn(items.val):
            li: text $index & ": " & $item

      check root.children.len == 3
      check root.children[0].textContent == "0: a"
      check root.children[1].textContent == "1: b"
      check root.children[2].textContent == "2: c"
