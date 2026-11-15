## An event-argument handler that prevents the default action, or reads the
## key, is portable across the framework's renderers: the same handler body
## compiles, and works, on `MockRenderer`, `NativeRenderer`,
## `TerminalRenderer` and `WebRenderer`.
##
## The repository says so itself. `TerminalEvent`
## (`isonim/renderers/terminal_demo`) is documented with "Mirrors the
## browser's `Event` shape so user code stays portable across renderers", and
## that renderer's event-argument `addEventListener` overload lets terminal
## UIs "call `ev.preventDefault` from the same `(ev) =>` shorthand the web
## renderer accepts". `isonim/web/web_renderer` is there so that views
## written over the renderer type work on `MockRenderer` and on `WebRenderer`
## "without code changes". The editor's own `DomRenderer`
## (`isonim/editor/dom_renderer`), whose event is `std/dom`'s, is not covered
## here.
##
## Two handler bodies are held to that: `ev.preventDefault()` in an
## `onclick`, and `if ev.key == "Enter": ...` in an `onkeydown`. Each is
## written once below (`preventingView`, `keyReadingView`), generic over the
## renderer and its event type, and instantiated for every renderer, so what
## is compared from one renderer to the next is one piece of source text.
##
## * `MockRenderer`, `NativeRenderer` and `TerminalRenderer` build an
##   in-memory tree, so their views are built and their handlers are fired:
##   the default is prevented, and Enter is acted on and Tab is not.
## * `WebRenderer` needs a DOM to dispatch an event, which Node does not
##   have, so its half is decided at compile time:
##   `compiles(view(WebRenderer, WebEvent))` is computed into a constant and
##   asserted at run time. A handler that does not compile on the web is
##   therefore a failed assertion and not a build error, and the same run
##   reports the other renderers beside it.
##
## What makes a failure of the web half mean what it says is checked first
## (the "setup" tests). On `WebRenderer` the same view compiles when its
## handler body is empty, and when it reads a member the web event declares
## (`ev.target`): the view, the `ui` macro and the event-argument
## `addEventListener` overload are in order. And the two handler bodies under
## test compile on `MockRenderer` in the same build: the bodies are in order.
## What is left is whether the web event itself gives `preventDefault` and
## `key` something to bind to, and a failing test prints that too, from the
## bare expression with no view around it.
##
## Run it on both targets. The web renderer exists only on the JS backend, so
## the C run covers the in-memory renderers alone:
##
##   nim c -r --out:build/tests/test_event_handler_portability tests/test_event_handler_portability.nim
##   nim js -r --out:build/tests/test_event_handler_portability.js tests/test_event_handler_portability.nim
##
## MOCK POLICY (workspace rule: every mock justified in the header).
## No stand-in is introduced here. `MockRenderer` (`isonim/testing/mock_dom`),
## `NativeRenderer` (`isonim/renderers/native`) and `TerminalRenderer`
## (`isonim/renderers/terminal_demo`) are renderers the framework ships, and
## here they are subjects of the property, not substitutes for the web one.
## The web half uses the real `WebRenderer` and the real `dom_api.Event`. It
## stops at compilation because dispatching a browser event needs a DOM; the
## web tests that bring a DOM shim live in `tests/test_web.nim`.
import std/unittest
import isonim/core/owner
import isonim/dsl/ui
import isonim/testing/mock_dom
import isonim/renderers/[native, terminal_demo]

when defined(js):
  import isonim/web/[dom_api, web_renderer]

  type WebEvent = dom_api.Event
    ## The event `WebRenderer`'s event-argument `addEventListener` overload
    ## hands to a handler.

# ---------------------------------------------------------------------------
# The views. One source text per handler body, for every renderer.
# ---------------------------------------------------------------------------

template preventingView(R, E: typedesc): untyped =
  ## A button whose handler prevents the default action of the click.
  block:
    let r = R()
    ui(r):
      button(onclick = proc(ev: E) = ev.preventDefault()):
        text "Submit"

template keyReadingView(R, E: typedesc; onEnter: proc()): untyped =
  ## A text input whose handler acts on the Enter key and on no other.
  block:
    let r = R()
    ui(r):
      input(`type` = "text",
            onkeydown = proc(ev: E) =
              if ev.key == "Enter": onEnter())

# The view of `preventingView` again, with two handler bodies the web renderer
# is known to accept. They are the setup of the web half (module
# documentation), and differ from `preventingView` in the handler body alone.

when defined(js):
  template emptyHandlerView(R, E: typedesc): untyped =
    ## The handler does nothing.
    block:
      let r = R()
      ui(r):
        button(onclick = proc(ev: E) = discard):
          text "Submit"

  template targetReadingView(R, E: typedesc): untyped =
    ## The handler reads `ev.target`.
    block:
      let r = R()
      ui(r):
        button(onclick = proc(ev: E) = discard ev.target):
          text "Submit"

# ---------------------------------------------------------------------------
# In-memory renderers: the views are built and their handlers are fired.
# ---------------------------------------------------------------------------

template checkPreventsDefault(R, E: typedesc) =
  ## Builds `preventingView` on `R` and fires a click carrying a fresh event.
  createRoot do (dispose: proc()):
    let root = preventingView(R, E)
    let ev = E()
    require not ev.defaultPrevented
    root.fireEventWith("click", ev)
    check ev.defaultPrevented
    dispose()

template checkReadsKey(R, E: typedesc) =
  ## Builds `keyReadingView` on `R` and fires a keydown for Tab, then Enter.
  createRoot do (dispose: proc()):
    var entered = 0
    let root = keyReadingView(R, E, proc() = inc entered)
    root.fireEventWith("keydown", E(key: "Tab"))
    check entered == 0
    root.fireEventWith("keydown", E(key: "Enter"))
    check entered == 1
    dispose()

suite "event handler portability: in-memory renderers":
  test "MockRenderer: a handler that calls ev.preventDefault() prevents the default":
    checkPreventsDefault(MockRenderer, MockEvent)

  test "MockRenderer: a handler that reads ev.key acts on Enter alone":
    checkReadsKey(MockRenderer, MockEvent)

  test "NativeRenderer: a handler that calls ev.preventDefault() prevents the default":
    checkPreventsDefault(NativeRenderer, NativeEvent)

  test "NativeRenderer: a handler that reads ev.key acts on Enter alone":
    checkReadsKey(NativeRenderer, NativeEvent)

  test "TerminalRenderer: a handler that calls ev.preventDefault() prevents the default":
    checkPreventsDefault(TerminalRenderer, TerminalEvent)

  test "TerminalRenderer: a handler that reads ev.key acts on Enter alone":
    checkReadsKey(TerminalRenderer, TerminalEvent)

# ---------------------------------------------------------------------------
# Web renderer: the same views, decided at compile time.
# ---------------------------------------------------------------------------

when defined(js):
  const
    # Setup: `compiles` can answer "yes" for a view on WebRenderer.
    webEmptyHandlerCompiles = compiles(emptyHandlerView(WebRenderer, WebEvent))
    webTargetReadingHandlerCompiles = compiles(targetReadingView(WebRenderer, WebEvent))
    # Setup: the handler bodies under test are not themselves at fault.
    mockPreventingHandlerCompiles = compiles(preventingView(MockRenderer, MockEvent))
    mockKeyReadingHandlerCompiles = compiles(
      keyReadingView(MockRenderer, MockEvent, proc() = discard))
    # The property.
    webPreventingHandlerCompiles = compiles(preventingView(WebRenderer, WebEvent))
    webKeyReadingHandlerCompiles = compiles(
      keyReadingView(WebRenderer, WebEvent, proc() = discard))
    # Not asserted, printed when the property fails: the two expressions on a
    # bare web event, with no view, no `ui` macro and no renderer around them.
    webEventBindsPreventDefault = compiles(preventDefault(default(WebEvent)))
    webEventBindsKey = compiles(default(WebEvent).key == "Enter")

  suite "event handler portability: web renderer":
    test "setup: an event-argument handler with an empty body compiles on WebRenderer":
      check webEmptyHandlerCompiles

    test "setup: a handler that reads ev.target compiles on WebRenderer":
      check webTargetReadingHandlerCompiles

    test "setup: the handler bodies under test compile on MockRenderer in this build":
      check mockPreventingHandlerCompiles
      check mockKeyReadingHandlerCompiles

    test "WebRenderer: a handler that calls ev.preventDefault() compiles":
      require webEmptyHandlerCompiles
      require webTargetReadingHandlerCompiles
      require mockPreventingHandlerCompiles
      checkpoint "on a bare dom_api.Event, with no view around it, " &
        "`ev.preventDefault()` compiles: " & $webEventBindsPreventDefault
      check webPreventingHandlerCompiles

    test "WebRenderer: a handler that reads ev.key compiles":
      require webEmptyHandlerCompiles
      require webTargetReadingHandlerCompiles
      require mockKeyReadingHandlerCompiles
      checkpoint "on a bare dom_api.Event, with no view around it, " &
        "`ev.key == \"Enter\"` compiles: " & $webEventBindsKey
      check webKeyReadingHandlerCompiles
else:
  # A green run on this backend says nothing about the web renderer.
  echo "note: WebRenderer exists only on the JS backend; this run covered ",
    "the in-memory renderers alone. Run this file with `nim js -r` as well."
