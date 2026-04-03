## Tests for buildHtmlString (SSR mode DSL) and isomorphicHtml.
## Verifies that the same DSL syntax generates correct HTML strings
## for server-side rendering.

import unittest
import std/[strutils, tables]
import isonim/core/[signals, owner]
import isonim/dsl/html
import isonim/ssr/escape
import isonim/ssr/markers
import isonim/testing/mock_dom
import isonim/ssr/renderer

suite "buildHtmlString":
  test "static_elements":
    ## Basic static HTML generation
    let html = buildHtmlString:
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
    let html = buildHtmlString:
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
    let html = buildHtmlString:
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
      let html = buildHtmlString:
        span: text $count.val

      check "<span>42</span>" in html
      dispose()

  test "dynamic_attribute":
    ## Dynamic attributes evaluated inline
    createRoot proc(dispose: proc()) =
      let cls = createSignal("active")
      let html = buildHtmlString:
        tdiv(class = cls.val)

      check "class=\"active\"" in html
      dispose()

  test "event_handlers_ignored":
    ## Event handlers are silently ignored in SSR mode
    var clicked = 0
    let html = buildHtmlString:
      button(onclick = proc() = inc clicked):
        text "Click"

    check "<button>Click</button>" in html
    # Handler was not invoked
    check clicked == 0

  test "html_escaping":
    ## Special characters are escaped in text and attributes
    let html = buildHtmlString:
      tdiv(title = "a\"b&c"):
        text "<script>alert('xss')</script>"

    check "&lt;script&gt;" in html
    check "a&quot;b&amp;c" in html
    check "<script>" notin html  # raw script tag not present

  test "multiple_attributes":
    ## Multiple attributes rendered correctly
    let html = buildHtmlString:
      a(href = "/page", class = "link", target = "_blank"):
        text "Link"

    check "href=\"/page\"" in html
    check "class=\"link\"" in html
    check "target=\"_blank\"" in html
    check "<a" in html
    check "</a>" in html

  test "empty_element":
    ## Element with no children
    let html = buildHtmlString:
      tdiv(class = "empty")

    check "<div class=\"empty\"></div>" == html

  test "hydration_key":
    ## Elements with hydrate=true get data-hk attributes
    resetHydrationCounter()
    let html = buildHtmlString:
      tdiv(hydrate = true):
        text "hydrated"

    check "data-hk=" in html

  test "mixed_static_and_dynamic":
    ## Mix of static and dynamic content in one tree
    createRoot proc(dispose: proc()) =
      let name = createSignal("World")
      let html = buildHtmlString:
        tdiv:
          h1: text "Hello"
          p: text $("Welcome, " & name.val)
          footer: text "Static footer"

      check "<h1>Hello</h1>" in html
      check "Welcome, World" in html
      check "<footer>Static footer</footer>" in html
      dispose()

suite "isomorphicHtml":
  test "client_mode":
    ## isomorphicHtml produces element tree in client mode (no -d:isServer)
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let root = isomorphicHtml(renderer):
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
  test "buildHtmlString_in_renderToString":
    ## buildHtmlString works inside renderToString
    let html = renderToString(proc(): string =
      buildHtmlString:
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

  test "buildHtmlString_with_signals_in_renderToString":
    ## Signals work correctly in SSR context
    let html = renderToString(proc(): string =
      let count = createSignal(5)
      let label = createSignal("tasks")
      buildHtmlString:
        tdiv:
          span: text $count.val & " " & label.val
    )

    check "5 tasks" in html

  test "buildHtmlString_with_loop":
    ## Use ssrFor with buildHtmlString for list items
    let items = @["Apple", "Banana", "Cherry"]
    let html = buildHtmlString:
      ul:
        raw ssrFor(items, proc(item: string, index: int): string =
          buildHtmlString:
            li: text item
        )

    check "<ul>" in html
    check "<li>Apple</li>" in html
    check "<li>Banana</li>" in html
    check "<li>Cherry</li>" in html

  test "buildHtmlString_with_conditional":
    ## Use ssrShow with buildHtmlString
    let loggedIn = true
    let bodyFn = proc(): string =
      buildHtmlString:
        span: text "Welcome!"
    let fallbackFn = proc(): string =
      buildHtmlString:
        span: text "Please log in"
    let html = buildHtmlString:
      tdiv:
        raw ssrShow(loggedIn, bodyFn, fallbackFn)

    check "Welcome!" in html
    check "Please log in" notin html

  test "buildHtmlString_showIf_ssr":
    ## showIf in SSR mode renders body when condition is true
    let loggedIn = true
    let html = buildHtmlString:
      tdiv:
        showIf(loggedIn):
          p: text "Welcome"

    check "<p>Welcome</p>" in html
    check "<div>" in html

  test "buildHtmlString_showIf_ssr_false":
    ## showIf in SSR mode renders nothing when condition is false (no fallback)
    let loggedIn = false
    let html = buildHtmlString:
      tdiv:
        showIf(loggedIn):
          p: text "Welcome"

    check "<p>Welcome</p>" notin html
    check "<div></div>" == html

  test "buildHtmlString_showIf_ssr_fallback":
    ## showIf + showElse in SSR mode
    let loggedIn = false
    let html = buildHtmlString:
      tdiv:
        showIf(loggedIn):
          p: text "Welcome"
        showElse:
          p: text "Please log in"

    check "Welcome" notin html
    check "<p>Please log in</p>" in html

  test "buildHtmlString_showIf_ssr_fallback_true":
    ## showIf + showElse in SSR mode when condition is true
    let loggedIn = true
    let html = buildHtmlString:
      tdiv:
        showIf(loggedIn):
          p: text "Welcome"
        showElse:
          p: text "Please log in"

    check "<p>Welcome</p>" in html
    check "Please log in" notin html

  test "buildHtmlString_forIn_ssr":
    ## forIn in SSR mode renders list items
    let items = @["Apple", "Banana", "Cherry"]
    let html = buildHtmlString:
      ul:
        forIn(items):
          li: text item

    check "<ul>" in html
    check "<li>Apple</li>" in html
    check "<li>Banana</li>" in html
    check "<li>Cherry</li>" in html

  test "buildHtmlString_forIn_ssr_with_index":
    ## forIn in SSR mode provides index variable
    let items = @["a", "b"]
    let html = buildHtmlString:
      ul:
        forIn(items):
          li: text $index & ": " & item

    check "<li>0: a</li>" in html
    check "<li>1: b</li>" in html
