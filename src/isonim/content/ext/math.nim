## Optional KaTeX adapter. The executable is injected by absolute path; importing
## the parser never imports this module or adds KaTeX to a library dependency.
## https://katex.org/docs/cli -- MathML output and default throwing errors.
## See docs/contributors/content-extensions.md for the qualified MathML Core subset.
import std/[xmltree, strtabs]
import ../[markdown, directives, fragments]
import ./tool_runner

proc renderMath*(tex: string; display: bool; katexPath: string;
    location: SourceLocation): ContentFragment =
  let output = renderWithTool(katexPath, "KaTeX", tex, "tex", location,
    proc(input, output: string): seq[string] =
      result = @["--format", "mathml", "--input", input, "--output", output]
      if display: result.add "--display-mode")
  try:
    let wrapper = strictXml(output)
    if wrapper.tag != "span" or wrapper.attr("class") != "katex" or wrapper.len != 1 or wrapper.attrs.len != 1:
      raise newException(ValueError, "unexpected KaTeX wrapper")
    let math = wrapper[0]
    if math.kind != xnElement or math.tag != "math" or math.len != 1 or
        math[0].kind != xnElement or math[0].tag != "semantics":
      raise newException(ValueError, "unexpected KaTeX MathML structure")
    let semantics = math[0]
    if semantics.len != 2 or semantics[1].kind != xnElement or semantics[1].tag != "annotation" or
        semantics[1].attr("encoding") != "application/x-tex" or semantics[1].attrs.len != 1 or
        (semantics.attrs != nil and semantics.attrs.len != 0):
      raise newException(ValueError, "unexpected KaTeX semantics/annotation")
    # TeX annotation is metadata, not part of the presentation. Keep the
    # complete presentation subtree; validation refuses non-Core semantics.
    let root = newElement("math")
    root.attrs = math.attrs
    root.add semantics[0]
    result = mathFragment(compactXml(root))
  except ValueError as error:
    raise contentError(location, "KaTeX output: " & error.msg)

proc mathHooks*(katexPath: string): ParseHooks =
  ## Register even an empty path: authored math must then report "not
  ## configured", whereas documents without math need no executable at all.
  result.name = "math"
  result.renderers.math = proc(tex: string; display: bool; location: SourceLocation): ContentFragment =
    renderMath(tex, display, katexPath, location)
