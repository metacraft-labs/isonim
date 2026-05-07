import unittest
import std/[tables, sugar]
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
    createRoot do (dispose: proc()):
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
    createRoot do (dispose: proc()):
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
    createRoot do (dispose: proc()):
      let renderer = MockRenderer()
      let cls = createSignal("red")

      let root = ui(renderer):
        tdiv(class = cls.val)

      check root.attributes["class"] == "red"

      cls.val = "blue"
      check root.attributes["class"] == "blue"

  test "test_dsl_event_handler":
    ## onclick registers handler; mock event triggers callback
    createRoot do (dispose: proc()):
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
    createRoot do (dispose: proc()):
      let renderer = MockRenderer()
      let items = createSignal(@["a", "b", "c"])
      let parent = renderer.createElement("div")

      forEachKeyed(renderer, parent,
        proc(): seq[string] = items.val,
        proc(item: proc(): string, index: proc(): int): MockNode =
          let node = renderer.createElement("span")
          createRenderEffect do:
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
    createRoot do (dispose: proc()):
      let renderer = MockRenderer()
      let items = createSignal(@[10, 20, 30])
      let parent = renderer.createElement("div")

      indexEach(renderer, parent,
        proc(): seq[int] = items.val,
        proc(item: proc(): int, index: int): MockNode =
          let node = renderer.createElement("span")
          createRenderEffect do:
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
    createRoot do (dispose: proc()):
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
    createRoot do (dispose: proc()):
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
    createRoot do (dispose: proc()):
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

      createRoot do (d1: proc()):
        outerDispose = d1
        outerOwner = getOwner()
        createEffect do:
          outerVal = s.val
        createRoot do (d2: proc()):
          innerDispose = d2
          innerOwner = getOwner()
          createEffect do:
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
    createRoot do (dispose: proc()):
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
    createRoot do (dispose: proc()):
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
    createRoot do (dispose: proc()):
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
    createRoot do (dispose: proc()):
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
    createRoot do (dispose: proc()):
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
    createRoot do (dispose: proc()):
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
    createRoot do (dispose: proc()):
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

# ---------------------------------------------------------------------------
# `std/sugar` interop
#
# These tests pin down which `std/sugar` idioms compose cleanly with the `ui`
# DSL — the answers aren't obvious because the DSL macro inspects AST shapes
# at compile time, and sugar expansions can produce shapes the macro doesn't
# match. The intent is that examples and user code can use sugar's `=>` and
# `capture` wherever they'd reach for a `proc(...) = ...` block.
# ---------------------------------------------------------------------------
suite "DSL — std/sugar interop":
  test "onclick accepts () => stmt closure":
    ## sugar's `=>` produces `proc() = stmt`, which is exactly what `onclick`
    ## consumes (handler: proc() in MockRenderer.addEventListener). The
    ## one-line form should work without a `proc()` wrapper.
    createRoot do (dispose: proc()):
      let renderer = MockRenderer()
      var clicked = 0
      let root = ui(renderer):
        button(onclick = () => (inc clicked)):
          text "Click"
      check clicked == 0
      root.fireEvent("click")
      check clicked == 1
      root.fireEvent("click")
      check clicked == 2
      dispose()

  test "onclick accepts () => (stmt; stmt) multi-statement closure":
    ## Multiple statements packed into a tuple-style group. The trailing
    ## value is whatever the last statement returns; for void side
    ## effects this stays a `proc()`.
    createRoot do (dispose: proc()):
      let renderer = MockRenderer()
      var trail: seq[int] = @[]
      let root = ui(renderer):
        button(onclick = () => (trail.add 1; trail.add 2; trail.add 3)):
          text "Click"
      root.fireEvent("click")
      check trail == @[1, 2, 3]
      dispose()

  test "onclick closure can write to an enclosing signal":
    ## A common shape — the click handler bumps a signal that the rest of
    ## the tree reacts to. Verifies the `=>` body sees the surrounding
    ## scope and that signal writes through it run through the normal
    ## reactive cascade.
    createRoot do (dispose: proc()):
      let renderer = MockRenderer()
      let count = createSignal(0)
      var rendered = -1
      let root = ui(renderer):
        tdiv:
          button(onclick = () => (count.val = count.val + 1)):
            text "+"
          span: text $count.val
      createEffect do:
        rendered = count.val
      check rendered == 0
      root.children[0].fireEvent("click")
      check count.val == 1
      check rendered == 1
      root.children[0].fireEvent("click")
      check count.val == 2
      check rendered == 2
      dispose()

  test "capture creates per-iteration closures for buttons":
    ## The classic loop-closure trap: without `capture`, every handler
    ## sees the final loop value. With `capture i`, each handler keeps
    ## its own `i`. This is one of the headline reasons sugar exists, and
    ## it should compose with the DSL.
    createRoot do (dispose: proc()):
      let renderer = MockRenderer()
      let parent = renderer.createElement("div")
      var lastClicked = -1
      for i in 0 ..< 4:
        capture i:
          let btn = ui(renderer):
            button(onclick = () => (lastClicked = i)):
              text $i
          renderer.appendChild(parent, btn)
      check parent.children.len == 4
      parent.children[0].fireEvent("click")
      check lastClicked == 0
      parent.children[2].fireEvent("click")
      check lastClicked == 2
      parent.children[3].fireEvent("click")
      check lastClicked == 3
      dispose()

  test "=> closure works as a builder passed to a helper":
    ## Helpers that accept a `() -> MockNode` builder argument should
    ## also accept the sugar shorthand. Lets users pull DSL fragments
    ## into reusable layout helpers without a `proc():` wrapper at every
    ## call site. Note: a `:` DSL block can't appear inside `=>`'s parens
    ## directly (Nim parser limitation), so the typical pattern is to
    ## name the inner builder and reference it from the `=>` body.
    proc panel(r: MockRenderer; build: () -> MockNode): MockNode =
      let p = r.createElement("div")
      r.setAttribute(p, "class", "panel")
      r.appendChild(p, build())
      p

    proc buildSaveButton(r: MockRenderer): MockNode =
      ui(r):
        button(class = "primary"): text "Save"

    createRoot do (dispose: proc()):
      let renderer = MockRenderer()
      let p = renderer.panel(() => buildSaveButton(renderer))
      check p.attributes["class"] == "panel"
      check p.children.len == 1
      check p.children[0].tag == "button"
      check p.children[0].attributes["class"] == "primary"
      dispose()

  test "text directive does NOT accept () => closure (documented gap)":
    ## The DSL's `text` directive consumes an *expression* and wraps the
    ## evaluation itself in a render effect — it does not consume a
    ## builder closure. The right shape is `text $signal.val`, not
    ## `text () => $signal.val`. This test pins that in: the working
    ## form must compile and behave reactively.
    createRoot do (dispose: proc()):
      let renderer = MockRenderer()
      let count = createSignal(0)
      let root = ui(renderer):
        span: text $count.val
      check root.children[0].text == "0"
      count.val = 42
      check root.children[0].text == "42"
      dispose()
