## Real KaTeX integration. No mock renderer or successful tool-absence skips.
## The optional Nix content-tools shell supplies the executable explicitly.
import std/[unittest, os, strutils, tempfiles]
import ./helpers/content_tool_fixture
import isonim/content/[markdown, directives, prose]
import isonim/content/ext/math

let katex = getEnv("ISONIM_KATEX")
doAssert katex.len > 0, "ISONIM_KATEX not configured; enter nix develop .#content-tools"
let hooks = @[mathHooks(katex)]
proc html(body: string; line = 1): string =
  renderProseHtml(parseMarkdownDocWithHooks(hooks, body, "math.md", firstLine = line))

suite "build time math":
  test "real inline display and fenced expressions produce Core MathML":
    let result = html("Inline $x^2 + \\frac{a}{b}$\n\n$$\\sum_{i=1}^n i$$\n\n```math\n\\sqrt{x}\n```")
    check result.count("<math ") == 3
    check result.count("display=\"block\"") == 2
    check "<mfrac>" in result
    check "<msqrt>" in result
    check "<munderover>" in result
    check "<script" notin result
    check "katex" notin result
    check "annotation" notin result
    check "font-face" notin result
  test "invalid expression fails at its actual source line":
    var failure = ""
    try: discard html("first\n\n> text\n> $\\frac{$", 8)
    except ValueError as e: failure = e.msg
    check "math.md:11:" in failure
    check "KaTeX exited with status 1" in failure
    check "ParseError" in failure
  test "missing configuration refuses explicitly":
    expect ValueError:
      discard parseMarkdownDocWithHooks(@[mathHooks("")], "$x$", "missing.md")
    var failure = ""
    try: discard renderMath("x", false, "", SourceLocation(path: "missing.md", line: 4))
    except ValueError as e: failure = e.msg
    check failure == "missing.md:4: KaTeX not configured"
  test "unsupported non Core constructs refuse without losing semantics":
    for expr in [r"\cancel{x}", r"\mathbf{x}"]:
      expect ValueError: discard html("$" & expr & "$")
  test "Core style attributes are preserved and output is deterministic":
    let input = r"$\displaystyle\sum x$ and $\sin x + \alpha$"
    check html(input) == html(input)
    check "displaystyle=\"true\"" in html(input)
  test "code and escaped delimiters are preserved":
    let result = html("`$\\bad$` \\$literal$\n\n```nim\n$$x$$\n```")
    check "<math" notin result
    check "$literal$" in result
  test "escaped TeX dollars render and keep the following expression":
    let result = html(r"price $x + \$5$ then $z$")
    check result.count("<math ") == 2
    check "$" in result
  test "non Core table attributes are refused at the fence line":
    var failure = ""
    try: discard html("```math\n" & r"\begin{matrix}a&b\\c&d\end{matrix}" & "\n```", 19)
    except ValueError as e: failure = e.msg
    check "math.md:19:" in failure
    check "unsupported MathML Core attribute" in failure
  test "real math in labels keeps nested link-looking source literal":
    let result = html("[outer [inner](other.md) $x^2$](target.md)")
    check result.count("<a ") == 1
    check result.count("<math ") == 1
    check "[inner](other.md)" in result

block:
  # A real renderer produces valid output, then the wrapper fails. This proves
  # that output validation cannot mask a swallowed nonzero exit status.
  let work = createTempDir("isonim-math-fault-", "")
  defer: removeDir(work)
  let fault = instrumentTool(work, "katex-failure", katex,
    "printf 'injected renderer failure\\n' >&2\nexit 23")
  suite "math CLI fault boundary":
    test "valid real MathML with nonzero status is rejected with diagnostics":
      var failure = ""
      try: discard renderMath("x", false, fault, SourceLocation(path: "fault.md", line: 5))
      except ValueError as e: failure = e.msg
      check "fault.md:5: KaTeX exited with status 23" in failure
      check "injected renderer failure" in failure
    test "missing executable and no-expression configuration are explicit":
      expect ValueError:
        discard renderMath("x", false, work / "absent", SourceLocation(path: "missing.md", line: 1))
      check renderProseHtml(parseMarkdownDocWithHooks(@[mathHooks("")], "plain")) == "<p>plain</p>"
