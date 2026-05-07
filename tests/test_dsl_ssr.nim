## Tests for the bare `ui:` form (SSR mode DSL) and isomorphicUi.
## Verifies that the same DSL syntax generates correct HTML strings
## for server-side rendering.

import unittest
import std/[strutils, tables]
import isonim/core/[signals, owner]
import isonim/dsl/ui
import isonim/ssr/escape
import isonim/ssr/markers
import isonim/testing/mock_dom
import isonim/ssr/renderer

suite "ui (SSR string mode)":
  test "static_elements":
    ## Basic static HTML generation
    let html = ui:
      tdiv(class = "container"):
        h1: text "Hello"
        p: text "World"

    check "<div" in html
    check "class=\"container\"" in html
    check "<h1>Hello</h1>" in html
    check "<p>World</p>" in html
    check "</div>" in html

  test "nested_elements":
    ## Deeply nested element generation
    let html = ui:
      tdiv:
        section:
          article:
            p: text "Deep"

    check "<div>" in html
    check "<section>" in html
    check "<article>" in html
    check "<p>Deep</p>" in html

  test "void_elements":
    ## Self-closing void elements (br, input, img, etc.)
    let html = ui:
      tdiv:
        input(ttype = "text", placeholder = "Enter text")
        br()
        img(src = "photo.jpg", alt = "Photo")

    check "<input" in html
    check "/>" in html
    check "<br />" in html
    check "<img" in html
    check "src=\"photo.jpg\"" in html

  test "dynamic_text":
    ## Dynamic expressions evaluated inline, no effects
    createRoot proc(dispose: proc()) =
      let count = createSignal(42)
      let html = ui:
        span: text $count.val

      check "<span>42</span>" in html
      dispose()

  test "dynamic_attribute":
    ## Dynamic attributes evaluated inline
    createRoot proc(dispose: proc()) =
      let cls = createSignal("active")
      let html = ui:
        tdiv(class = cls.val)

      check "class=\"active\"" in html
      dispose()

  test "event_handlers_ignored":
    ## Event handlers are silently ignored in SSR mode
    var clicked = 0
    let html = ui:
      button(onclick = proc() = inc clicked):
        text "Click"

    check "<button>Click</button>" in html
    # Handler was not invoked
    check clicked == 0

  test "html_escaping":
    ## Special characters are escaped in text and attributes
    let html = ui:
      tdiv(title = "a\"b&c"):
        text "<script>alert('xss')</script>"

    check "&lt;script&gt;" in html
    check "a&quot;b&amp;c" in html
    check "<script>" notin html  # raw script tag not present

  test "multiple_attributes":
    ## Multiple attributes rendered correctly
    let html = ui:
      a(href = "/page", class = "link", target = "_blank"):
        text "Link"

    check "href=\"/page\"" in html
    check "class=\"link\"" in html
    check "target=\"_blank\"" in html
    check "<a" in html
    check "</a>" in html

  test "empty_element":
    ## Element with no children
    let html = ui:
      tdiv(class = "empty")

    check "<div class=\"empty\"></div>" == html

  test "hydration_key":
    ## Elements with hydrate=true get data-hk attributes
    resetHydrationCounter()
    let html = ui:
      tdiv(hydrate = true):
        text "hydrated"

    check "data-hk=" in html

  test "mixed_static_and_dynamic":
    ## Mix of static and dynamic content in one tree
    createRoot proc(dispose: proc()) =
      let name = createSignal("World")
      let html = ui:
        tdiv:
          h1: text "Hello"
          p: text $("Welcome, " & name.val)
          footer: text "Static footer"

      check "<h1>Hello</h1>" in html
      check "Welcome, World" in html
      check "<footer>Static footer</footer>" in html
      dispose()

suite "isomorphicUi":
  test "client_mode":
    ## isomorphicUi produces element tree in client mode (no -d:isServer)
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let root = isomorphicUi(renderer):
        tdiv(class = "app"):
          h1: text "IsoNim"

      # In client mode (default), returns a MockNode
      when not defined(isServer):
        check root.kind == mnkElement
        check root.tag == "div"
        check root.attributes["class"] == "app"
        check root.children[0].tag == "h1"
        check root.children[0].children[0].text == "IsoNim"
      dispose()

suite "SSR + renderToString integration":
  test "ui_in_renderToString":
    ## uiString works inside renderToString
    let html = renderToString(proc(): string =
      ui:
        tdiv(class = "page"):
          header:
            h1: text "My App"
          main:
            p: text "Content here"
          footer:
            p: text "Footer"
    )

    check "<div class=\"page\">" in html
    check "<header><h1>My App</h1></header>" in html
    check "<main><p>Content here</p></main>" in html
    check "<footer><p>Footer</p></footer>" in html

  test "ui_with_signals_in_renderToString":
    ## Signals work correctly in SSR context
    let html = renderToString(proc(): string =
      let count = createSignal(5)
      let label = createSignal("tasks")
      ui:
        tdiv:
          span: text $count.val & " " & label.val
    )

    check "5 tasks" in html

  test "ui_with_loop":
    ## Use ssrFor with uiString for list items
    let items = @["Apple", "Banana", "Cherry"]
    let html = ui:
      ul:
        raw ssrFor(items, proc(item: string, index: int): string =
          ui:
            li: text item
        )

    check "<ul>" in html
    check "<li>Apple</li>" in html
    check "<li>Banana</li>" in html
    check "<li>Cherry</li>" in html

  test "ui_with_conditional":
    ## Use ssrShow with uiString
    let loggedIn = true
    let bodyFn = proc(): string =
      ui:
        span: text "Welcome!"
    let fallbackFn = proc(): string =
      ui:
        span: text "Please log in"
    let html = ui:
      tdiv:
        raw ssrShow(loggedIn, bodyFn, fallbackFn)

    check "Welcome!" in html
    check "Please log in" notin html

suite "SSR natural control flow":
  test "ui_if_true":
    ## Natural if/else in SSR mode renders correct branch
    let loggedIn = true
    let html = ui:
      tdiv:
        if loggedIn:
          p: text "Welcome"
        else:
          p: text "Please log in"

    check "<p>Welcome</p>" in html
    check "Please log in" notin html

  test "ui_if_false":
    ## Natural if/else in SSR mode renders else branch
    let loggedIn = false
    let html = ui:
      tdiv:
        if loggedIn:
          p: text "Welcome"
        else:
          p: text "Please log in"

    check "Welcome" notin html
    check "<p>Please log in</p>" in html

  test "ui_if_no_else":
    ## Natural if without else renders nothing when false
    let show = false
    let html = ui:
      tdiv:
        if show:
          p: text "shown"

    check "<div></div>" == html

  test "ui_for_loop":
    ## Natural for loop in SSR mode renders list items
    let items = @["Apple", "Banana", "Cherry"]
    let html = ui:
      ul:
        for item in items:
          li: text item

    check "<ul>" in html
    check "<li>Apple</li>" in html
    check "<li>Banana</li>" in html
    check "<li>Cherry</li>" in html

  test "ui_case_statement":
    ## Natural case statement in SSR mode selects correct branch
    type Color = enum red, green, blue
    let c = green
    let html = ui:
      tdiv:
        case c
        of red:
          span: text "RED"
        of green:
          span: text "GREEN"
        of blue:
          span: text "BLUE"

    check "<span>GREEN</span>" in html
    check "RED" notin html
    check "BLUE" notin html

  test "ui_nested_if_for":
    ## Nested if and for in SSR mode
    let showList = true
    let items = @["x", "y"]
    let html = ui:
      tdiv:
        if showList:
          for item in items:
            span: text item

    check "<span>x</span>" in html
    check "<span>y</span>" in html
