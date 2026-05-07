import unittest
import std/tables
import isonim/core/[signals, computation, owner, batch, graph]
import isonim/testing/mock_dom
import isonim/dsl/ui
import isonim/dsl/components

proc renderAddButton(r: MockRenderer): MockNode =
  ui(r):
    button(class = "add"):
      text "Add"

suite "DSL":
  test "test_dsl_static_html":
    ## ui with static content produces correct MockNode tree
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let root = ui(renderer):
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

      let root = ui(renderer):
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

      let root = ui(renderer):
        tdiv(class = cls.val)

      check root.attributes["class"] == "red"

      cls.val = "blue"
      check root.attributes["class"] == "blue"

  test "test_dsl_event_handler":
    ## onclick registers handler; mock event triggers callback
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      var clicked = 0

      let root = ui(renderer):
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
      let root = ui(renderer):
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

  test "test_dsl_appends_helper_proc_result":
    ## Component/helper procs returning nodes compose naturally inside ui blocks.
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()

      let root = ui(renderer):
        tdiv:
          renderAddButton(renderer)

      check root.tag == "div"
      check root.children.len == 1
      check root.children[0].tag == "button"
      check root.children[0].attributes["class"] == "add"
      check root.children[0].textContent == "Add"

  test "test_dsl_appends_helper_proc_result_in_if_else_branch":
    ## Helper procs returning nodes also append from natural if/else branches.
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let showFallback = true

      let root = ui(renderer):
        tdiv:
          if not showFallback:
            span: text "primary"
          else:
            renderAddButton(renderer)

      check root.tag == "div"
      check root.children.len == 1
      check root.children[0].tag == "button"
      check root.children[0].attributes["class"] == "add"
      check root.children[0].textContent == "Add"

  test "test_dsl_if_true_branch":
    ## if statement inside ui body renders the true branch
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let cond = true
      let root = ui(renderer):
        tdiv:
          if cond:
            span: text "yes"
          else:
            span: text "no"

      check root.children.len == 1
      check root.children[0].tag == "span"
      check root.children[0].textContent == "yes"

  test "test_dsl_if_false_branch":
    ## if statement inside ui body renders the else branch
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let cond = false
      let root = ui(renderer):
        tdiv:
          if cond:
            span: text "yes"
          else:
            span: text "no"

      check root.children.len == 1
      check root.children[0].tag == "span"
      check root.children[0].textContent == "no"

  test "test_dsl_for_loop":
    ## for loop inside ui body creates children for each iteration
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let items = @["alpha", "beta", "gamma"]
      let root = ui(renderer):
        ul:
          for item in items:
            let s = item  # copy to avoid lent capture
            li: text s

      check root.tag == "ul"
      check root.children.len == 3
      check root.children[0].textContent == "alpha"
      check root.children[1].textContent == "beta"
      check root.children[2].textContent == "gamma"

  test "test_dsl_case_statement":
    ## case statement inside ui body selects the correct branch
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      type Color = enum red, green, blue
      let c = green
      let root = ui(renderer):
        tdiv:
          case c
          of red:
            span: text "RED"
          of green:
            span: text "GREEN"
          of blue:
            span: text "BLUE"

      check root.children.len == 1
      check root.children[0].textContent == "GREEN"

  test "test_dsl_nested_if_for":
    ## if and for can be nested inside each other in the DSL
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let showList = true
      let items = @["x", "y"]
      let root = ui(renderer):
        tdiv:
          if showList:
            for item in items:
              let s = item
              span: text s

      check root.children.len == 2
      check root.children[0].textContent == "x"
      check root.children[1].textContent == "y"
