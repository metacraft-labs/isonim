## Real D2 and Graphviz integration against the filesystem cache. No doubles
## replace renderer positives and missing configuration is a failing condition.
import std/[unittest, os, strutils, tempfiles, xmltree, sha1]
import isonim/content/[markdown, directives, prose]
import isonim/content/ext/[diagrams, math, tool_runner]
import isonim/static/[head, scripts, exporter]
import ./helpers/content_tool_fixture

let d2 = getEnv("ISONIM_D2")
let dot = getEnv("ISONIM_DOT")
doAssert d2.len > 0 and dot.len > 0, "D2/Graphviz not configured; enter nix develop .#content-tools"
let work = createTempDir("isonim-diagrams-", "")
let config = DiagramConfig(d2Path: d2, dotPath: dot, cacheDir: work / "cache")
proc html(body: string): string =
  renderProseHtml(parseMarkdownDocWithHooks(@[diagramHooks(config)], body, "diagrams.md"))

suite "build time diagrams":
  test "real D2 and dot fences produce themeable inline SVG":
    let result = html("```d2\na -> b: hello\n```\n\n```dot\ndigraph { a -> b; a [style=filled,fillcolor=red]; }\n```")
    check result.count("class=\"isonim-diagram\"") == 2
    check "<svg" in result
    check "<path" in result
    check "<text" in result
    check "var(--diagram-" in result
    check "fill=\"#" notin result
    check "fill=\"red\"" notin result
    check "fill:#" notin result
    check "<script" notin result
    check "<mask" in result
    check "--diagram-mask-visible" in result
  test "warm and independent cold caches are byte identical":
    for language in ["dot", "d2"]:
      let source = if language == "dot": "digraph { a -> b }" else: "a -> b: hello"
      let location = SourceLocation(path: "diagrams.md", line: 2)
      let a = renderDiagram(language, source, config, location)
      let b = renderDiagram(language, source, config, location)
      let cold = DiagramConfig(d2Path: d2, dotPath: dot, cacheDir: work / "cold")
      let c = renderDiagram(language, source, cold, location)
      check fragmentHtml(a) == fragmentHtml(b)
      check fragmentHtml(a) == fragmentHtml(c)
  test "CLI nonzero is not swallowed or cached":
    for language in ["dot", "d2"]:
      var failure = ""
      try: discard renderDiagram(language, "{", config, SourceLocation(path: "bad.md", line: 9))
      except ValueError as e: failure = e.msg
      check "bad.md:9:" in failure
      check "exited with status" in failure
  test "missing configuration refuses explicitly even with a populated cache":
    var absent = config
    absent.dotPath = ""
    var failure = ""
    try: discard renderDiagram("dot", "digraph { a -> b }", absent, SourceLocation(path: "missing.md", line: 7))
    except ValueError as e: failure = e.msg
    check failure == "missing.md:7: Graphviz not configured"
    absent = config
    absent.d2Path = ""
    failure = ""
    try: discard renderDiagram("d2", "a -> b", absent, SourceLocation(path: "missing.md", line: 8))
    except ValueError as e: failure = e.msg
    check failure == "missing.md:8: D2 not configured"
  test "duplicate diagrams namespace every id and preserve instance local references":
    proc identifiers(output: string): tuple[ids, refs: seq[string]] =
      var ids, refs: seq[string]
      proc visit(n: XmlNode) =
        if n.kind != xnElement: return
        if n.attr("id").len > 0: ids.add n.attr("id")
        if n.attr("aria-labelledby").len > 0: refs.add n.attr("aria-labelledby").splitWhitespace()
        for key in ["href", "xlink:href"]:
          if n.attr(key).startsWith("#"): refs.add n.attr(key)[1 .. ^1]
        for key in ["fill", "stroke", "mask", "clip-path", "marker-start", "marker-mid", "marker-end", "style"]:
          for url in cssUrls(n.attr(key)):
            if url.startsWith("#"): refs.add url[1 .. ^1]
        if n.tag == "style":
          for url in cssUrls(n.innerText):
            if url.startsWith("#"): refs.add url[1 .. ^1]
        for child in n: visit(child)
      visit(strictXml(output))
      (ids, refs)
    for language in ["dot", "d2"]:
      let source = if language == "dot": "digraph { a -> b }" else: "a -> b: hello"
      let a = identifiers(fragmentHtml(renderDiagram(language, source, config, SourceLocation(path: "a.md", line: 1))))
      let b = identifiers(fragmentHtml(renderDiagram(language, source, config, SourceLocation(path: "a.md", line: 6))))
      check a.ids.len > 1
      check b.ids.len == a.ids.len
      for id in a.ids: check id notin b.ids
      for reference in a.refs: check reference in a.ids
      for reference in b.refs: check reference in b.ids
      if language == "d2":
        check a.refs.len >= 2
        check b.refs.len == a.refs.len
  test "same source location accepts distinct stable occurrence keys":
    let location = SourceLocation(path: "same.md", line: 1)
    let a = renderDiagram("dot", "digraph { a -> b }", config, location, "first")
    let b = renderDiagram("dot", "digraph { a -> b }", config, location, "second")
    check fragmentHtml(a) != fragmentHtml(b)
    check a == renderDiagram("dot", "digraph { a -> b }", config, location, "first")
  test "D2 structural masks stay fixed while palette colors remain inherited":
    let output = fragmentHtml(renderDiagram("d2", "a -> b: hello", config, SourceLocation(path: "masks.md", line: 1)))
    let svg = strictXml(output)
    check svg.attr("style") == "--diagram-mask-visible:white;--diagram-mask-hidden:black"
    check "--diagram-fill:" notin svg.attr("style")
    check "--diagram-foreground:" notin svg.attr("style")
    var masks = 0
    proc visit(n: XmlNode) =
      if n.kind != xnElement: return
      if n.tag == "mask":
        inc masks
        var rects: seq[XmlNode]
        for c in n:
          if c.kind == xnElement and c.tag == "rect": rects.add c
        check rects.len == 2
        check rects[0].attr("fill") == "var(--diagram-mask-visible)"
        check rects[1].attr("fill") == "var(--diagram-mask-hidden)"
        check rects[0].attr("width") != rects[1].attr("width")
      for child in n: visit(child)
    visit(svg)
    check masks == 1
  test "corrupt cache and valid XML with unnormalized paints are refused":
    let isolated = DiagramConfig(dotPath: dot, d2Path: d2, cacheDir: work / "corrupt")
    discard renderDiagram("dot", "digraph { a -> b }", isolated, SourceLocation(path: "cache.md", line: 1))
    var entries: seq[string]
    for path in walkFiles(isolated.cacheDir / "*.svg"): entries.add path
    require entries.len == 1
    let original = readFile(entries[0])
    writeFile(entries[0], original & "damage")
    var failure = ""
    try: discard renderDiagram("dot", "digraph { a -> b }", isolated, SourceLocation(path: "cache.md", line: 1))
    except ValueError as e: failure = e.msg
    check "corrupt diagram cache" in failure
    let unsafe = "<svg><rect fill=\"red\"></rect></svg>"
    writeFile(entries[0], $secureHash(unsafe) & "\n" & unsafe)
    expect ValueError:
      discard renderDiagram("dot", "digraph { a -> b }", isolated, SourceLocation(path: "cache.md", line: 1))

  test "cache hits avoid the real CLI and source and executable changes invalidate":
    let counter = work / "calls"
    let executable = instrumentTool(work, "count-dot", dot, "", counter)
    let isolated = DiagramConfig(dotPath: executable, cacheDir: work / "instrumented")
    let location = SourceLocation(path: "count.md", line: 1)
    let initial = renderDiagram("dot", "digraph { a -> b }", isolated, location)
    check readFile(counter).splitLines().len == 2
    check initial == renderDiagram("dot", "digraph { a -> b }", isolated, location)
    check readFile(counter).splitLines().len == 2
    discard renderDiagram("dot", "digraph { a -> c }", isolated, location)
    check readFile(counter).splitLines().len == 3
    writeFile(executable, readFile(executable) & "# changed executable identity\n")
    discard renderDiagram("dot", "digraph { a -> c }", isolated, location)
    check readFile(counter).splitLines().len == 4
  test "valid real SVG with nonzero status is rejected and never cached":
    let executable = instrumentTool(work, "fault-dot", dot,
      "printf 'injected renderer failure\\n' >&2\nexit 23")
    let isolated = DiagramConfig(dotPath: executable, cacheDir: work / "failed")
    var failure = ""
    try: discard renderDiagram("dot", "digraph { a -> b }", isolated, SourceLocation(path: "fault.md", line: 5))
    except ValueError as e: failure = e.msg
    check "fault.md:5: Graphviz exited with status 23" in failure
    check "injected renderer failure" in failure
    check not dirExists(isolated.cacheDir)
  test "malformed and active successful renderer output fails before cache publication":
    for payload in ["<svg><path></svg>", "<svg><script>bad()</script></svg>",
        "<svg><path fill=\"url('https://example.test/a.svg')\"/></svg>"]:
      let executable = instrumentTool(work, "damage-dot", dot,
        "for argument in \"$@\"; do output=\"$argument\"; done\nprintf '%s' " & quoteShell(payload) & " > \"$output\"")
      let isolated = DiagramConfig(dotPath: executable, cacheDir: work / "damaged")
      expect ValueError:
        discard renderDiagram("dot", "digraph { a -> b }", isolated, SourceLocation(path: "damaged.md", line: 1))
      check not dirExists(isolated.cacheDir)
  test "quoted local paint references and accessibility ids survive normalization":
    let payload = "<svg aria-labelledby=\"label\"><title id=\"label\">local</title><defs><linearGradient id=\"paint\"><stop offset=\"0\" stop-color=\"red\"/></linearGradient></defs><rect width=\"10\" height=\"10\" fill=\"url('#paint')\"/></svg>"
    # Fault injection qualifies a passive SVG shape the current CLI fixture
    # does not produce: a quoted local URL and an accessibility reference.
    let executable = instrumentTool(work, "reference-dot", dot,
      "for argument in \"$@\"; do output=\"$argument\"; done\nprintf '%s' " & quoteShell(payload) & " > \"$output\"")
    let isolated = DiagramConfig(dotPath: executable, cacheDir: work / "references")
    let output = fragmentHtml(renderDiagram("dot", "digraph { a -> b }", isolated, SourceLocation(path: "refs.md", line: 1)))
    let svg = strictXml(output)
    check svg.attr("aria-labelledby") != "label"
    check svg.attr("aria-labelledby").endsWith("-label")
    check "url(#diagram-" in output
    check "<linearGradient" in output
    check "stop-color=\"var(--diagram-fill, Canvas)\"" in output
  test "real mixed content exports under the existing no script policy":
    let katex = getEnv("ISONIM_KATEX")
    require katex.len > 0
    let doc = parseMarkdownDocWithHooks(@[mathHooks(katex), diagramHooks(config)],
      "# Formula\n\n$x^2$\n\n```d2\na -> b\n```", "export.md")
    let page = "<!doctype html><html>" & renderPageHeadHtml(DocumentHead(title: "Math and diagrams"), @[], spNone) &
      "<body>" & renderProseHtml(doc) & renderBodyEndScriptsHtml(@[], spNone) & "</body></html>"
    discard exportSite(@[SitePage(route: "/", html: page)], work / "site")
    let written = readFile(work / "site/index.html")
    check "<math " in written
    check "<svg " in written
    check executableScripts(written).len == 0
    check written.count("<script") == 1
    check "<script type=\"application/ld+json\">" in written

  test "absolute D2 imports are refused before and after cache population":
    let external = work / "external.d2"
    writeFile(external, "outside: before")
    let imported = "...@\"" & external & "\""
    proc raw(): string =
      renderWithTool(d2, "D2", imported, "d2", SourceLocation(path: "control.md", line: 1),
        proc(input, output: string): seq[string] = @["--no-xml-tag", "--omit-version", "--bundle=false", input, output])
    let before = raw()
    check "before" in before
    let isolated = DiagramConfig(d2Path: d2, cacheDir: work / "standalone")
    for round in 0 .. 1:
      for source in [imported, "a: @" & external, "a: @\"" & external & "\".outside"]:
        var failure = ""
        try: discard renderDiagram("d2", source, isolated, SourceLocation(path: "imports.md", line: 7))
        except ValueError as e: failure = e.msg
        check "imports.md:7: D2 imports are not supported" in failure
      if round == 0:
        check not dirExists(isolated.cacheDir)
        discard renderDiagram("d2", "a -> b", isolated, SourceLocation(path: "plain.md", line: 1))
        writeFile(external, "outside: after")
    check raw() != before
    var entries = 0
    for path in walkFiles(isolated.cacheDir / "*.svg"): inc entries
    check entries == 1
  test "D2 quoted escaped and commented at signs stay literal":
    for source in ["a: \"mail@example.test\"", "a: 'mail@example.test'", r"a: mail\@example.test",
        "# @absent\na -> b", "\"\"\" @absent \"\"\"\na -> b"]:
      check "<svg " in fragmentHtml(renderDiagram("d2", source, config, SourceLocation(path: "literal.md", line: 1)))
    # An apostrophe inside an unquoted token cannot swallow an import on a
    # later line by being mistaken for the start of a quoted string.
    expect ValueError:
      discard renderDiagram("d2", "a: don't hide\n...@/absent\nb: 'end'", config, SourceLocation(path: "literal.md", line: 1))

  test "real marker and edge arrowheads keep foreground paint over renderer classes":
    for language in ["d2", "dot"]:
      let source = if language == "d2": "a -> b: hello" else: "digraph { a -> b [label=\"hello\"]; b -> c [arrowhead=empty]; c -> d [color=white]; }"
      let svg = strictXml(fragmentHtml(renderDiagram(language, source, config, SourceLocation(path: "paint.md", line: 1))))
      var solid, hollow, labels = 0
      proc visit(n: XmlNode; edge = false) =
        if n.kind != xnElement: return
        let inside = edge or n.tag == "marker" or "edge" in n.attr("class").splitWhitespace()
        if inside and n.tag == "polygon":
          if n.attr("fill") in ["none", "var(--diagram-background, Canvas)"]:
            inc hollow
            check "fill:" & n.attr("fill") in n.attr("style")
          else:
            inc solid
            check n.attr("fill") == "var(--diagram-stroke, currentColor)"
            check "fill:var(--diagram-stroke, currentColor)" in n.attr("style")
        if inside and n.tag == "text":
          inc labels
          check n.attr("fill") == "var(--diagram-foreground, currentColor)"
        for child in n: visit(child, inside)
      visit(svg)
      check solid > 0
      if language == "dot":
        check hollow == 2
        check labels > 0

removeDir(work)
