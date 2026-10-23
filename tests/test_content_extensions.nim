## Pure scanner integration tests. The recording callbacks deliberately inspect
## scanner boundaries/provenance; real renderer execution is covered separately
## by test_content_math and test_content_diagrams, never replaced here.
import std/[unittest, strutils]
import isonim/content/[markdown, directives, prose]

type Seen = tuple[text: string, display: bool, line: int]
var seen: seq[Seen]
let recording = ContentRenderers(math:
  proc(tex: string; display: bool; location: SourceLocation): ContentFragment =
    check location.path == "page.md"
    seen.add (tex, display, location.line)
    mathFragment("<math xmlns=\"http://www.w3.org/1998/Math/MathML\"><mi>x</mi></math>"))
proc parse(body: string; firstLine = 1): MarkdownDoc =
  seen = @[]
  parseMarkdownDocWithHooks(@[ParseHooks(renderers: recording)], body,
    sourceRelPath = "page.md", firstLine = firstLine)

suite "content extension scanner":
  test "math is opt in and ordinary output remains literal":
    check renderProseHtml(parseMarkdownDoc("cost $x$")) == "<p>cost $x$</p>"
  test "inline display and fenced math use the shared parser":
    let doc = parse("before $x$ and $$y$$\n\n$$\nz^2\n$$\n\n```math\nw\n```", 10)
    check seen == @[("x", false, 10), ("y", true, 10), ("z^2", true, 12), ("w", true, 16)]
    check renderProseHtml(doc).count("<math ") == 4
  test "code escapes unmatched dollars links and images stay literal":
    discard parse("`$x$` \\$a$ $ dangling [link](https://a/$x$) ![$y$](a.png)\n\n```nim\n$x$\n```\n\n$ good$ $bad $ $ok$")
    check seen == @[("ok", false, 7)]
  test "provenance survives quotes footnotes tabs lists captions admonitions":
    discard parse("> # $a$\n> paragraph\n> $b$\n\n- $c$\n\n![a](a.png)\n*$d$*\n\n:::note\nfirst\n$e$\n:::\n\n:::tabs\n@tab One\n$f$\n:::\n\n[^n]: $g$\n    $h$\n\nuse[^n]")
    check seen == @[("a", false, 1), ("b", false, 3), ("c", false, 5), ("d", false, 8), ("e", false, 12), ("f", false, 17), ("g", false, 20), ("h", false, 21)]
  test "strikes and multiline inline math preserve source coordinates":
    discard parse("first\n~~$a$~~ then $b\n+c$", 30)
    check seen == @[("a", false, 31), ("b\n+c", false, 31)]
  test "a display opener interrupts a paragraph and nested fences keep locations":
    discard parse("intro\n$$x$$\n\n> ```math\n> y\n> ```")
    check seen == @[("x", true, 2), ("y", true, 4)]
  test "empty configured renderer output is an error":
    let empty = ContentRenderers(math: proc(t: string; d: bool; l: SourceLocation): ContentFragment = ContentFragment())
    expect ValueError:
      discard parseMarkdownDoc("$x$", renderers = empty)
  test "escaped dollars inside TeX do not close expressions":
    discard parse(r"price $x + \$5$ then $z$")
    check seen == @[(r"x + \$5", false, 1), ("z", false, 1)]
  test "table cells and explicit link labels use inline math":
    let doc = parse("| $h$ | value |\n| --- | --- |\n| $x$ | [$y$](https://example.test/$no$) |")
    check seen == @[("h", false, 1), ("x", false, 3), ("y", false, 3)]
    check renderProseHtml(doc).count("<math ") == 3
  test "directive bodies retain source lines":
    discard parse(":::cards\n:::card title=\"a\"\n$x$\n\n$y$\n:::\n\n:::faq\n:::q title=\"q\"\n$z$\n:::")
    check seen == @[("x", false, 3), ("y", false, 5), ("z", false, 10)]
  test "fragment constructors reject active malformed and foreign markup":
    for payload in ["<script>alert(1)</script>",
        "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"><mi onclick=\"bad()\">x</mi></math>",
        "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"><mi>x</math>",
        "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"></math><script/>"]:
      expect ValueError: discard mathFragment(payload)
    for payload in ["<svg><script/></svg>", "<svg onload=\"bad()\"/>",
        "<svg><foreignObject><div/></foreignObject></svg>",
        "<svg><use href=\"https://example.test/a.svg#x\"/></svg>",
        "<svg><path mask=\"url(#absent)\"/></svg>",
        "<svg><style>@import 'https://example.test/x.css';</style></svg>",
        "<svg><g id=\"x\"/><g id=\"x\"/></svg>"]:
      expect ValueError: discard diagramFragment(payload)
  test "TeX stays opaque inside strike and tables":
    let strike = parse("~~before $x~~y$ after~~")
    check seen == @[("x~~y", false, 1)]
    check strike.blocks[0].spans[0].kind == ikStrike
    let table = parse("| absolute | value |\n| --- | --- |\n| $|x|$ | $y$ |")
    check seen == @[("|x|", false, 3), ("y", false, 3)]
    check table.blocks[0].rows[0].len == 2
  test "passive SVG grammar refuses remote CSS forms and unsupported selectors":
    for css in ["background-image:image-set('https://example.test/x' 1x)",
        "behavior:none", "fill:red", "--diagram-mask-visible:black"]:
      expect ValueError: discard diagramFragment("<svg style=\"" & css & "\"></svg>")
    for selector in ["path:has(a)", "path > rect", "[href]", "@media screen"]:
      expect ValueError: discard diagramFragment("<svg><style>" & selector & "{fill:none}</style></svg>")
  test "quoted local URLs and accessible labels retain validation":
    let fragment = diagramFragment("<svg aria-labelledby=\"label\"><title id=\"label\">a</title><defs><path id=\"shape\"></path></defs><use href=\"#shape\" style=\"fill:url('#shape')\"></use></svg>")
    check "aria-labelledby=\"label\"" in fragmentHtml(fragment)
    expect ValueError: discard diagramFragment("<svg aria-labelledby=\"missing\"></svg>")
  test "a local paint URL must occupy the complete paint value":
    expect ValueError:
      discard diagramFragment("<svg><defs><path id=\"shape\"/></defs><use href=\"#shape\" style=\"fill:url(#shape) garbage()\"/></svg>")
  test "math in link labels preserves literal syntax without nested anchors":
    let doc = parse("[outer [inner](target.md) [[sym:Missing]] ~~text~~ `$literal$` $x$](outer.md)")
    check seen == @[("x", false, 1)]
    let output = renderProseHtml(doc)
    check output.count("<a ") == 1
    check "[inner](target.md)" in output
    check "[[sym:Missing]]" in output
    check "~~text~~" in output
    check "`$literal$`" in output
    check output.count("<math ") == 1

static:
  doAssert not compiles(ContentFragment(markup: "<script/>"))
