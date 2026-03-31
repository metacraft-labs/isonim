import unittest
import std/[json, strutils]
import isonim/ssr/escape
import isonim/ssr/markers
import isonim/ssr/renderer
import isonim/ssr/serializer
import isonim/rxcore

suite "SSR - Escape":
  test "test_escape_html_owasp":
    check escapeHtml("<script>alert('xss')</script>") ==
      "&lt;script&gt;alert('xss')&lt;/script&gt;"
    check escapeHtml("a & b") == "a &amp; b"
    check escapeHtml("no special chars") == "no special chars"
    check escapeAttr("say \"hello\"") == "say &quot;hello&quot;"
    check escapeAttr("a & b") == "a &amp; b"
    check escapeAttr("no special chars") == "no special chars"

suite "SSR - Render":
  test "test_render_to_string_basic":
    let html = renderToString(proc(): string =
      ssrElement("div", {"class": "container"},
        ssrElement("h1", children = escapeHtml("Hello World")))
    )
    check "<div" in html
    check "class=\"container\"" in html
    check "<h1>Hello World</h1>" in html
    check "</div>" in html

  test "test_hydration_markers_present":
    let html = renderToString(proc(): string =
      ssrElement("div", needsId = true, children =
        ssrElement("span", needsId = true, children = "dynamic"))
    )
    check "data-hk=\"1\"" in html
    check "data-hk=\"2\"" in html

  test "test_hydration_script_generation":
    let script = generateHydrationScript()
    check "<script>" in script
    check "window._$HY" in script
    check "data-hk" in script
    check "click" in script
    check "input" in script
    check "<!--xs-->" in script
    # With nonce
    let scriptNonce = generateHydrationScript(nonce = "abc123")
    check "nonce=\"abc123\"" in scriptNonce

  test "test_ssr_for_component":
    let items = @["apple", "banana", "cherry"]
    let html = renderToString(proc(): string =
      ssrElement("ul", children =
        ssrFor(items, proc(item: string, index: int): string =
          ssrElement("li", children = escapeHtml(item))))
    )
    check "<ul>" in html
    check "<li>apple</li>" in html
    check "<li>banana</li>" in html
    check "<li>cherry</li>" in html
    check "</ul>" in html

  test "test_ssr_show_component":
    # Condition true: renders body
    let htmlTrue = renderToString(proc(): string =
      ssrShow(true,
        body = proc(): string = ssrElement("p", children = "visible"),
        fallback = proc(): string = ssrElement("p", children = "hidden"))
    )
    check "<p>visible</p>" in htmlTrue
    check "hidden" notin htmlTrue

    # Condition false: renders fallback
    let htmlFalse = renderToString(proc(): string =
      ssrShow(false,
        body = proc(): string = ssrElement("p", children = "visible"),
        fallback = proc(): string = ssrElement("p", children = "hidden"))
    )
    check "<p>hidden</p>" in htmlFalse
    check "visible" notin htmlFalse

    # Condition false, no fallback: empty
    let htmlNoFallback = renderToString(proc(): string =
      ssrShow(false,
        body = proc(): string = ssrElement("p", children = "visible"))
    )
    check htmlNoFallback == ""

  test "test_ssr_resource_serialization":
    let data = %*{"name": "Alice", "age": 30}
    let script = serializeResourceData("user-1", data)
    check "<script>" in script
    check "_$HY.r[\"user-1\"]=" in script
    check "</script>" in script

    # Multiple resources
    let multi = serializeResources(@[
      ("res-a", %*{"x": 1}),
      ("res-b", %*{"y": 2})
    ])
    check "_$HY.r[\"res-a\"]=" in multi
    check "_$HY.r[\"res-b\"]=" in multi
    # Single script block
    var scriptCount = 0
    for i in 0 ..< multi.len - 7:
      if multi[i ..< i + 8] == "<script>":
        inc scriptCount
    check scriptCount == 1

    # Empty resources
    check serializeResources(@[]) == ""
