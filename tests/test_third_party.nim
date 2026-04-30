## Tests for ref, onMount, and third-party library hosting patterns.
##
## Demonstrates the SolidJS pattern for hosting third-party JS libraries:
## create a container element with a ref, then use onMount to initialize
## the library on that element, and onCleanup to tear down.

import unittest
import std/tables
import isonim/core/[signals, computation, owner, batch, graph]
import isonim/testing/mock_dom
import isonim/dsl/ui

# ---------------------------------------------------------------------------
# Mock third-party library (simulates Monaco, xterm.js, etc.)
# ---------------------------------------------------------------------------

type
  MockLibraryWidget = ref object
    ## Simulates a third-party JS library widget that mounts on a DOM element.
    container*: MockNode
    value*: string
    destroyed*: bool

var widgetCount* = 0
  ## Tracks how many widgets have been created (for leak detection).

proc createMockWidget(container: MockNode; initialValue: string): MockLibraryWidget =
  ## Simulates: new ExternalLibrary(element, { value: initialValue })
  inc widgetCount
  result = MockLibraryWidget(
    container: container,
    value: initialValue,
    destroyed: false,
  )
  # The library typically modifies the DOM element
  container.attributes["data-widget"] = "mock-library"
  container.attributes["data-value"] = initialValue

proc updateValue*(w: MockLibraryWidget; newVal: string) =
  ## Simulates: widget.setValue(newVal)
  if not w.destroyed:
    w.value = newVal
    w.container.attributes["data-value"] = newVal

proc destroy*(w: MockLibraryWidget) =
  ## Simulates: widget.destroy()
  w.destroyed = true
  dec widgetCount
  w.container.attributes.del("data-widget")
  w.container.attributes.del("data-value")

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "ref and onMount":
  test "ref captures created element":
    ## The ref=variable pattern assigns the DOM element to the variable
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      var containerEl: MockNode

      let root = ui(renderer):
        tdiv(class="wrapper"):
          tdiv(ref=containerEl, class="target"):
            text "content"

      # ref should have been set during element creation
      check containerEl != nil
      check containerEl.tag == "div"
      check containerEl.attributes["class"] == "target"
      check containerEl.textContent == "content"

      # containerEl should be the same object as the child in the tree
      check root.children[0] == containerEl

  test "onMount fires after element exists":
    ## onMount runs its callback once, after the reactive root is set up
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      var mounted = false
      var mountedEl: MockNode

      var containerEl: MockNode
      let root = ui(renderer):
        tdiv(ref=containerEl, class="host"):
          discard

      onMount proc() =
        mounted = true
        mountedEl = containerEl

      check mounted == true
      check mountedEl != nil
      check mountedEl.tag == "div"
      check mountedEl.attributes["class"] == "host"

  test "onMount does not track signals":
    ## onMount should not re-run when signals change
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let count = createSignal(0)
      var mountCount = 0

      let root = ui(renderer):
        tdiv:
          discard

      onMount proc() =
        inc mountCount
        # Read a signal inside onMount — should NOT create a subscription
        discard count.val

      check mountCount == 1

      # Changing the signal should NOT re-trigger onMount
      count.val = 1
      check mountCount == 1

      count.val = 2
      check mountCount == 1

  test "onCleanup fires on dispose":
    ## onCleanup registered inside onMount fires when the root is disposed
    var cleanedUp = false
    var myDispose: proc()

    createRoot proc(dispose: proc()) =
      myDispose = dispose
      let renderer = MockRenderer()

      let root = ui(renderer):
        tdiv:
          discard

      onMount proc() =
        onCleanup proc() =
          cleanedUp = true

    check cleanedUp == false
    myDispose()
    check cleanedUp == true

  test "third-party widget lifecycle":
    ## Full pattern: ref + onMount + onCleanup for third-party library hosting
    var myDispose: proc()
    var widget: MockLibraryWidget
    let initialCount = widgetCount

    createRoot proc(dispose: proc()) =
      myDispose = dispose
      let renderer = MockRenderer()

      var containerEl: MockNode
      let root = ui(renderer):
        tdiv(class="app"):
          tdiv(ref=containerEl, class="widget-host"):
            discard

      onMount proc() =
        widget = createMockWidget(containerEl, "hello")
        onCleanup proc() =
          widget.destroy()

    # Widget should be created
    check widget != nil
    check widget.destroyed == false
    check widget.value == "hello"
    check widgetCount == initialCount + 1
    check widget.container.attributes["data-widget"] == "mock-library"

    # Disposing the root should clean up the widget
    myDispose()
    check widget.destroyed == true
    check widgetCount == initialCount

  test "reactive props flow to third-party widget":
    ## Signals can drive updates to a third-party widget via createEffect
    var myDispose: proc()
    var widget: MockLibraryWidget

    createRoot proc(dispose: proc()) =
      myDispose = dispose
      let renderer = MockRenderer()
      let value = createSignal("initial")

      var containerEl: MockNode
      let root = ui(renderer):
        tdiv:
          tdiv(ref=containerEl, class="widget-host"):
            discard

      onMount proc() =
        widget = createMockWidget(containerEl, value.val)
        onCleanup proc() =
          widget.destroy()

      # Reactive bridge: when `value` changes, update the widget
      createEffect proc() =
        if widget != nil:
          widget.updateValue(value.val)

      check widget.value == "initial"

      # Update signal — effect should push new value to widget
      value.val = "updated"
      check widget.value == "updated"

      value.val = "final"
      check widget.value == "final"

    myDispose()
    check widget.destroyed == true

  test "multiple refs in same tree":
    ## Multiple ref bindings in the same ui block all work
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      var header: MockNode
      var content: MockNode
      var footer: MockNode

      let root = ui(renderer):
        tdiv:
          tdiv(ref=header, class="header"):
            text "Header"
          tdiv(ref=content, class="content"):
            text "Content"
          tdiv(ref=footer, class="footer"):
            text "Footer"

      check header != nil
      check content != nil
      check footer != nil
      check header.attributes["class"] == "header"
      check content.attributes["class"] == "content"
      check footer.attributes["class"] == "footer"
      check header != content
      check content != footer
