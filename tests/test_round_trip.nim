## SSR → Client round-trip integration tests.
##
## Verifies that:
## 1. buildHtmlString and buildHtml produce structurally equivalent output
## 2. SSR HTML contains correct hydration markers
## 3. The same component renders consistently across modes
## 4. Full-page SSR with the demo task store produces valid HTML

import unittest
import std/[strutils, tables]
import isonim/core/[signals, computation, owner]
import isonim/dsl/[html, components]
import isonim/ssr/[renderer, escape, markers]
import isonim/testing/mock_dom

# Import demo components (paths configured in tests/config.nims)
import task_store
import shared_components
import components

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc extractTagStructure(html: string): seq[string] =
  ## Extracts the tag structure from HTML for comparison.
  ## Returns a sequence like ["div", "h1", "/h1", "p", "/p", "/div"].
  var i = 0
  while i < html.len:
    if html[i] == '<':
      let start = i + 1
      var j = start
      # Skip to end of tag name (space, >, or /)
      while j < html.len and html[j] notin {' ', '>', '/', '\t', '\n'}:
        inc j
      if start < j:
        let isClosing = html[start] == '/'
        let nameStart = if isClosing: start + 1 else: start
        var nameEnd = nameStart
        while nameEnd < html.len and html[nameEnd] notin {' ', '>', '/', '\t', '\n'}:
          inc nameEnd
        let tagName = html[nameStart ..< nameEnd]
        if tagName.len > 0 and tagName[0] != '!':  # Skip comments
          if isClosing:
            result.add("/" & tagName)
          else:
            result.add(tagName)
      # Skip to end of tag
      while i < html.len and html[i] != '>':
        inc i
    inc i

proc countOccurrences(haystack, needle: string): int =
  var i = 0
  while true:
    let pos = haystack.find(needle, i)
    if pos < 0: break
    inc result
    i = pos + needle.len

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "SSR ↔ Client structural equivalence":
  test "same_static_structure":
    ## buildHtml and buildHtmlString produce the same tag structure
    ## for static content.
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()

      # Client mode
      let clientRoot = buildHtml(renderer):
        tdiv(class = "container"):
          h1: text "Title"
          p: text "Body"
          footer:
            span: text "Footer text"

      # SSR mode
      let ssrHtml = buildHtmlString:
        tdiv(class = "container"):
          h1: text "Title"
          p: text "Body"
          footer:
            span: text "Footer text"

      # Verify tag structure matches
      let ssrTags = extractTagStructure(ssrHtml)
      check "div" in ssrTags
      check "h1" in ssrTags
      check "p" in ssrTags
      check "footer" in ssrTags
      check "span" in ssrTags

      # Verify client structure matches
      check clientRoot.tag == "div"
      check clientRoot.attributes["class"] == "container"
      check clientRoot.children.len == 3
      check clientRoot.children[0].tag == "h1"
      check clientRoot.children[1].tag == "p"
      check clientRoot.children[2].tag == "footer"

      # Verify content
      check "Title" in ssrHtml
      check "Body" in ssrHtml
      check "Footer text" in ssrHtml
      check clientRoot.children[0].textContent == "Title"
      check clientRoot.children[1].textContent == "Body"
      check clientRoot.children[2].children[0].textContent == "Footer text"
      dispose()

  test "same_dynamic_values":
    ## Both modes evaluate reactive values the same way.
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let count = createSignal(7)
      let label = createSignal("items")

      # Client mode
      let clientRoot = buildHtml(renderer):
        span: text $count.val & " " & label.val

      # SSR mode
      let ssrHtml = buildHtmlString:
        span: text $count.val & " " & label.val

      check clientRoot.textContent == "7 items"
      check "7 items" in ssrHtml
      dispose()

  test "same_attributes":
    ## Attributes render identically in both modes.
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let cls = createSignal("active")

      # Client
      let clientRoot = buildHtml(renderer):
        tdiv(class = cls.val, id = "main")

      # SSR
      let ssrHtml = buildHtmlString:
        tdiv(class = cls.val, id = "main")

      check clientRoot.attributes["class"] == "active"
      check clientRoot.attributes["id"] == "main"
      check "class=\"active\"" in ssrHtml
      check "id=\"main\"" in ssrHtml
      dispose()

  test "event_handlers_client_only":
    ## Events work in client mode, are silently skipped in SSR.
    var clicked = 0
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()

      let clientRoot = buildHtml(renderer):
        button(onclick = proc() = inc clicked):
          text "Click"

      let ssrHtml = buildHtmlString:
        button(onclick = proc() = inc clicked):
          text "Click"

      # Client: handler is registered
      clientRoot.fireEvent("click")
      check clicked == 1

      # SSR: no onclick in output, handler was not invoked during render
      check "onclick" notin ssrHtml
      check "<button>Click</button>" == ssrHtml
      dispose()

suite "SSR hydration markers":
  test "hydration_keys_in_dynamic_elements":
    ## Elements with hydrate=true get data-hk attributes in SSR mode.
    resetHydrationCounter()
    let html = buildHtmlString:
      tdiv(hydrate = true):
        span(hydrate = true):
          text "Dynamic"

    check "data-hk=\"1\"" in html
    check "data-hk=\"2\"" in html

  test "hydration_keys_sequential":
    ## Hydration keys are sequential within a render.
    resetHydrationCounter()
    let html = renderToString(proc(): string =
      buildHtmlString:
        tdiv(hydrate = true):
          span(hydrate = true): text "A"
          span(hydrate = true): text "B"
          span(hydrate = true): text "C"
    )

    check "data-hk=\"1\"" in html
    check "data-hk=\"2\"" in html
    check "data-hk=\"3\"" in html
    check "data-hk=\"4\"" in html

suite "Demo app SSR integration":
  setup:
    resetIdCounter()

  test "page_header_isomorphic":
    ## pageHeader works in both client and SSR modes.
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let clientNode = pageHeader(renderer)

      # Client mode: returns element
      when not defined(isServer):
        check clientNode.tag == "header"
        check clientNode.attributes["class"] == "page-header"
        check clientNode.children.len == 2
        check clientNode.children[0].tag == "h1"
        check clientNode.children[0].textContent == "IsoNim Task Manager"
      dispose()

  test "empty_state_isomorphic":
    ## emptyState works in both modes.
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let clientNode = emptyState(renderer)

      when not defined(isServer):
        check clientNode.tag == "div"
        check clientNode.attributes["class"] == "empty-state"
        check clientNode.children.len == 2
      dispose()

  test "task_list_ssr_empty":
    ## SSR renders empty state for empty task list.
    createRoot proc(dispose: proc()) =
      let store = createTaskStore()
      let html = renderTaskListSsr(store)
      check "No tasks" in html
      check "<p" in html
      dispose()

  test "task_list_ssr_with_items":
    ## SSR renders task items correctly.
    createRoot proc(dispose: proc()) =
      let store = createTaskStore()
      store.addTask("Buy groceries")
      store.addTask("Walk the dog")
      store.toggleTask(2)  # Mark "Walk the dog" as done

      let html = renderTaskListSsr(store)
      check "<ul" in html
      check "Buy groceries" in html
      check "Walk the dog" in html
      check "class=\"completed\"" in html
      check "class=\"\"" in html  # Active task has empty class
      check countOccurrences(html, "<li") == 2
      dispose()

  test "task_footer_ssr":
    ## SSR renders footer with correct count.
    createRoot proc(dispose: proc()) =
      let store = createTaskStore()
      store.addTask("Task 1")
      store.addTask("Task 2")
      store.addTask("Task 3")
      store.toggleTask(1)

      let html = renderTaskFooterSsr(store)
      check "2 items left" in html
      check "all" in html
      check "active" in html
      check "completed" in html
      dispose()

  test "task_footer_ssr_empty":
    ## SSR renders nothing when no tasks.
    createRoot proc(dispose: proc()) =
      let store = createTaskStore()
      let html = renderTaskFooterSsr(store)
      check html == ""
      dispose()

  test "full_page_ssr":
    ## Full-page SSR produces valid complete HTML.
    createRoot proc(dispose: proc()) =
      let store = createTaskStore()
      store.addTask("Review PR")
      store.addTask("Deploy to staging")

      let html = renderFullPageSsr(store)

      # Structure
      check "<div class=\"app\">" in html
      check "IsoNim Task Manager" in html
      check "What needs to be done?" in html

      # Content
      check "Review PR" in html
      check "Deploy to staging" in html

      # Tags are properly closed
      let openDivs = countOccurrences(html, "<div")
      let closeDivs = countOccurrences(html, "</div>")
      check openDivs == closeDivs
      dispose()

  test "ssr_then_client_same_data":
    ## SSR and client rendering of the same store produce equivalent content.
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let store = createTaskStore()
      store.addTask("Shared task")

      # SSR render
      let ssrHtml = renderTaskListSsr(store)

      # Client render
      let clientParent = renderer.createElement("div")
      renderTaskList(renderer, clientParent, store)

      # Both should contain the task text
      check "Shared task" in ssrHtml

      # Client should have rendered the task in the DOM tree
      # (section > ul > li > span with "Shared task")
      let section = clientParent.children[0]
      check section.tag == "section"
      # The show component rendered the ul
      check section.children.len > 0
      let ul = section.children[0]
      check ul.tag == "ul"
      check ul.children.len == 1
      let li = ul.children[0]
      # li should contain checkbox, span, button
      check li.children.len == 3
      # span has the task text
      check li.children[1].textContent == "Shared task"
      dispose()
