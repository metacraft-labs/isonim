## Validated foreign markup for build-time content extensions. Constructors are
## the trust boundary: source text and arbitrary callback strings cannot bypass
## it. Pure stdlib code, shared by native and JS renderers.
## MathML vocabulary: https://www.w3.org/TR/mathml-core/ (sections 2 and 3).
import std/[strutils, strtabs, xmltree, xmlparser, algorithm]
import ../ssr/escape

type ContentFragment* = object
  markup: string
  displayMath: bool ## Set by `mathFragment` for a `display="block"` root.

proc fragmentHtml*(fragment: ContentFragment): string = fragment.markup
proc isEmpty*(fragment: ContentFragment): bool = fragment.markup.len == 0
proc isDisplayMath*(fragment: ContentFragment): bool =
  ## A display formula: a `<math display="block">` root, whatever other
  ## attributes the root carries (`dir`, for one, is written before it).
  fragment.displayMath
proc `==`*(a, b: ContentFragment): bool = a.markup == b.markup

proc strictXml*(source: string): XmlNode =
  ## std/xmlparser stops after the first root; a wrapper makes trailing roots
  ## visible. DTDs and processing instructions must not be silently discarded.
  if "<?" in source or "<!DOCTYPE" in source.toUpperAscii() or "<!ENTITY" in source.toUpperAscii():
    raise newException(ValueError, "XML declarations/entities are not supported")
  let wrapper = parseXml("<fragment>" & source & "</fragment>")
  for child in wrapper:
    if child.kind == xnComment: continue
    if child.kind == xnText and child.text.strip().len == 0: continue
    if child.kind != xnElement or result != nil:
      raise newException(ValueError, "expected exactly one XML element")
    result = child
  if result == nil: raise newException(ValueError, "empty XML output")

proc compactXml*(node: XmlNode): string =
  ## Stable attribute order and no pretty-printer whitespace in text/formulas.
  case node.kind
  of xnElement:
    result = "<" & node.tag
    var keys: seq[string]
    if node.attrs != nil:
      for key in node.attrs.keys: keys.add key
    keys.sort()
    for key in keys: result.add " " & key & "=\"" & escapeAttr(node.attr(key)) & "\""
    result.add ">"
    for child in node: result.add compactXml(child)
    result.add "</" & node.tag & ">"
  of xnText, xnCData: result = escapeHtml(node.text)
  of xnComment: discard
  of xnEntity:
    # parsexml resolves numeric and predefined XML entities; no DTD expansion.
    raise newException(ValueError, "unsupported XML entity: " & node.text)
  of xnVerbatimText:
    raise newException(ValueError, "verbatim XML is not supported")

proc mathFragment*(source: string): ContentFragment =
  ## Accept only Core presentation vocabulary and attributes with implemented
  ## semantics. Unsupported KaTeX constructs fail instead of degrading silently.
  let root = strictXml(source)
  if root.tag != "math" or root.attr("xmlns") != "http://www.w3.org/1998/Math/MathML":
    raise newException(ValueError, "expected a MathML math root")
  proc visit(node: XmlNode) =
    if node.kind in {xnText, xnComment}: return
    if node.kind != xnElement: raise newException(ValueError, "unsupported MathML node")
    if node.tag notin ["math", "mrow", "mi", "mn", "mo", "mtext", "mspace",
        "ms", "mfrac", "msqrt", "mroot", "mstyle", "mpadded", "mphantom",
        "msub", "msup", "msubsup", "munder", "mover", "munderover",
        "mmultiscripts", "mprescripts", "mtable", "mtr", "mtd"]:
      raise newException(ValueError, "unsupported MathML Core element: " & node.tag)
    if node.attrs != nil:
      for key, value in node.attrs:
        var valid = key in ["dir", "displaystyle", "scriptlevel", "mathcolor", "mathbackground", "mathsize"]
        case node.tag
        of "math": valid = valid or key in ["xmlns", "display"]
        of "mi": valid = valid or (key == "mathvariant" and value == "normal")
        of "mo": valid = valid or key in ["form", "fence", "separator", "lspace", "rspace", "stretchy", "symmetric", "maxsize", "minsize", "largeop", "movablelimits"]
        of "mspace": valid = valid or key in ["width", "height", "depth"]
        of "mpadded": valid = valid or key in ["width", "height", "depth", "lspace", "voffset"]
        of "mfrac": valid = valid or key == "linethickness"
        of "munder": valid = valid or key == "accentunder"
        of "mover": valid = valid or key == "accent"
        of "munderover": valid = valid or key in ["accent", "accentunder"]
        of "mtd": valid = valid or key in ["columnspan", "rowspan"]
        else: discard
        if not valid:
          raise newException(ValueError, "unsupported MathML Core attribute: " & node.tag & "/" & key & "=" & value)
        if "url(" in value.toLowerAscii() or '\\' in value or '<' in value:
          raise newException(ValueError, "unsafe MathML attribute: " & key)
    for child in node: visit(child)
  visit(root)
  result.markup = compactXml(root)
  result.displayMath = root.attr("display") == "block"

proc svgIdentifier*(value: string): bool =
  ## The CLI output subset uses unescaped ASCII CSS/XML identifiers.
  value.len > 0 and value[0] in Letters + {'_', '-'} and
    value.allCharsInSet(Letters + Digits + {'_', '-'})

proc svgSelectors*(selector: string): seq[string] =
  ## Simple compounds and descendants only; no escapes, combinators, attribute
  ## selectors, pseudo-classes or selector functions to hide side effects in.
  if selector == "@font-face": return @[selector]
  for part in selector.split(','):
    let compounds = part.splitWhitespace()
    if compounds.len == 0: raise newException(ValueError, "empty SVG CSS selector")
    for compound in compounds:
      var i = 0
      while i < compound.len:
        if compound[i] in {'.', '#'}: inc i
        elif i != 0: raise newException(ValueError, "unsupported SVG CSS selector")
        let start = i
        while i < compound.len and compound[i] in Letters + Digits + {'_', '-'}: inc i
        if not svgIdentifier(compound[start ..< i]):
          raise newException(ValueError, "unsupported SVG CSS selector: " & selector)
    result.add compounds.join(" ")

proc cssUrls*(css: string): seq[string] =
  ## Generated CSS uses unescaped url() tokens. Escaped spellings and executable
  ## CSS are refused, never decoded into a second interpretation by a browser.
  let lower = css.toLowerAscii()
  if '\\' in css or '<' in css or "expression" in lower or "@import" in lower:
    raise newException(ValueError, "unsafe SVG stylesheet")
  var i = 0
  while i < css.len:
    let start = lower.find("url(", i)
    if start < 0: break
    let stop = css.find(')', start + 4)
    if stop < 0: raise newException(ValueError, "malformed SVG CSS url")
    let url = css[start + 4 ..< stop].strip().strip(chars = {'\'', '"'})
    if url.startsWith("#") and not svgIdentifier(url[1 .. ^1]):
      raise newException(ValueError, "unsupported SVG fragment identifier")
    if not url.startsWith("#") and not url.startsWith("data:application/font-woff;base64,"):
      raise newException(ValueError, "remote or active SVG resource is not supported")
    result.add url
    i = stop + 1

proc rewriteLocalUrls*(value: string; resolve: proc(id: string): string {.closure.}): string =
  discard cssUrls(value)
  let lower = value.toLowerAscii()
  var i = 0
  while i < value.len:
    let start = lower.find("url(", i)
    if start < 0:
      result.add value[i .. ^1]
      break
    result.add value[i ..< start]
    let stop = value.find(')', start + 4)
    let url = value[start + 4 ..< stop].strip().strip(chars = {'\'', '"'})
    if url.startsWith("#"): result.add "url(#" & resolve(url[1 .. ^1]) & ")"
    else: result.add value[start .. stop]
    i = stop + 1

proc normalizedPaint*(value: string): bool =
  if value in ["none", "transparent", "currentColor"]: return true
  if value.startsWith("url("):
    let urls = cssUrls(value)
    return urls.len == 1 and urls[0].startsWith("#") and value.find(')') == value.high
  if not value.startsWith("var(--diagram-") or not value.endsWith(")"): return false
  let inner = value[4 ..< value.len - 1].split(',')
  if inner.len notin [1, 2] or not svgIdentifier(inner[0].strip()): return false
  inner.len == 1 or inner[1].strip() in ["currentColor", "Canvas", "CanvasText", "transparent"]

proc cssDeclarations*(css: string): seq[tuple[key, value: string]] =
  ## A bounded declaration scanner: semicolons inside quoted font data URLs
  ## are data. Nested CSS rules, escapes and malformed declarations refuse.
  discard cssUrls(css)
  var start, depth: int
  var quote = '\0'
  for i in 0 .. css.len:
    let ch = if i == css.len: ';' else: css[i]
    if quote != '\0':
      if ch == quote: quote = '\0'
    elif ch in {'\'', '"'}: quote = ch
    elif ch == '(': inc depth
    elif ch == ')': dec depth
    elif ch == ';' and depth == 0:
      let item = css[start ..< i].strip()
      if item.len > 0:
        let colon = item.find(':')
        if colon <= 0: raise newException(ValueError, "malformed SVG CSS declaration")
        result.add (item[0 ..< colon].strip(), item[colon + 1 .. ^1].strip())
      start = i + 1
    elif ch in {'{', '}'}: raise newException(ValueError, "nested SVG CSS is not supported")
    if depth < 0: raise newException(ValueError, "unbalanced SVG CSS")
  if quote != '\0' or depth != 0: raise newException(ValueError, "unbalanced SVG CSS")

proc validateSvgCss(css: string; stylesheet: bool) =
  proc validate(body: string) =
    for (key, value) in cssDeclarations(body):
      if key notin ["fill", "stroke", "color", "background-color", "stop-color",
          "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-dasharray",
          "stroke-dashoffset", "stroke-miterlimit", "fill-rule", "clip-rule",
          "fill-opacity", "stroke-opacity", "opacity", "font-family", "font-size",
          "font-weight", "font-style", "font-variant", "text-anchor", "dominant-baseline",
          "shape-rendering", "text-rendering", "mix-blend-mode", "display", "src",
          "--diagram-mask-visible", "--diagram-mask-hidden"] and not key.startsWith("--color-"):
        raise newException(ValueError, "unsupported SVG CSS property: " & key)
      if key in ["fill", "stroke", "color", "background-color", "stop-color"] and not normalizedPaint(value):
        raise newException(ValueError, "SVG paint must use a diagram CSS variable or local reference")
      if key == "--diagram-mask-visible" and value != "white":
        raise newException(ValueError, "invalid structural mask reveal paint")
      if key == "--diagram-mask-hidden" and value != "black":
        raise newException(ValueError, "invalid structural mask hide paint")
      if key == "src" and (not value.startsWith("url(\"data:application/font-woff;base64,") or not value.endsWith("\")")):
        raise newException(ValueError, "only embedded WOFF fonts are supported")
  if not stylesheet:
    validate(css)
    return
  var i = 0
  while i < css.len:
    let open = css.find('{', i)
    if open < 0:
      if css[i .. ^1].strip().len > 0: raise newException(ValueError, "malformed SVG stylesheet")
      break
    let close = css.find('}', open + 1)
    if close < 0: raise newException(ValueError, "unclosed SVG stylesheet rule")
    let selector = css[i ..< open].strip()
    discard svgSelectors(selector)
    validate(css[open + 1 ..< close])
    i = close + 1

proc diagramFragment*(source: string): ContentFragment =
  ## Validate passive inline SVG; IDs/references are checked together so a
  ## cache entry cannot quietly lose a marker, mask, gradient or clip path.
  let root = strictXml(source)
  if root.tag != "svg": raise newException(ValueError, "expected an SVG root")
  var ids, references: seq[string]
  proc visit(node: XmlNode) =
    if node.kind in {xnText, xnComment}: return
    if node.kind != xnElement: raise newException(ValueError, "unsupported SVG node")
    if node.tag notin ["svg", "g", "defs", "title", "desc", "path", "rect",
        "circle", "ellipse", "line", "polyline", "polygon", "text", "tspan",
        "textPath", "marker", "mask", "clipPath", "linearGradient", "radialGradient",
        "stop", "pattern", "use", "style"]:
      raise newException(ValueError, "unsupported SVG element: " & node.tag)
    if node.attrs != nil:
      for key, value in node.attrs:
        if key == "style":
          # A Content-Security-Policy without 'unsafe-inline' ignores style
          # attributes; normalized declarations live in a <style> element.
          raise newException(ValueError, "SVG style attributes are not supported; use the stylesheet")
        if key notin ["xmlns", "xmlns:xlink", "id", "class", "viewBox", "width", "height",
            "x", "y", "x1", "x2", "y1", "y2", "cx", "cy", "rx", "ry", "r",
            "dx", "dy", "d", "points", "transform", "preserveAspectRatio",
            "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin",
            "stroke-dasharray", "stroke-dashoffset", "stroke-miterlimit", "fill-rule",
            "clip-rule", "fill-opacity", "stroke-opacity", "opacity",
            "font-family", "font-size", "font-weight", "font-style", "text-anchor",
            "dominant-baseline", "textLength", "lengthAdjust", "rotate", "type",
            "marker-start", "marker-mid", "marker-end", "markerWidth", "markerHeight",
            "refX", "refY", "orient", "markerUnits", "mask", "maskUnits", "maskContentUnits",
            "clip-path", "clipPathUnits", "gradientUnits", "gradientTransform", "spreadMethod",
            "offset", "stop-color", "stop-opacity", "fx", "fy", "fr",
            "patternUnits", "patternContentUnits", "patternTransform", "href", "xlink:href",
            "role", "aria-label", "aria-labelledby", "aria-hidden", "focusable"]:
          raise newException(ValueError, "unsupported SVG attribute: " & key)
        if key == "xmlns" and value != "http://www.w3.org/2000/svg":
          raise newException(ValueError, "invalid SVG namespace")
        if key == "xmlns:xlink" and value != "http://www.w3.org/1999/xlink":
          raise newException(ValueError, "invalid XLink namespace")
        if key == "id":
          if not svgIdentifier(value) or value in ids: raise newException(ValueError, "duplicate/empty SVG id")
          ids.add value
        if key in ["fill", "stroke", "stop-color"] and not normalizedPaint(value):
          raise newException(ValueError, "SVG paint must use a diagram CSS variable or local reference")
        if key == "aria-labelledby":
          references.add value.splitWhitespace()
        if key in ["href", "xlink:href"]:
          if not value.startsWith("#"): raise newException(ValueError, "external SVG href is not supported")
          references.add value[1 .. ^1]
        for url in cssUrls(value):
          if url.startsWith("#"): references.add url[1 .. ^1]
    if node.tag == "style":
      validateSvgCss(node.innerText, true)
      for url in cssUrls(node.innerText):
        if url.startsWith("#"): references.add url[1 .. ^1]
    for child in node: visit(child)
  visit(root)
  for reference in references:
    if reference notin ids: raise newException(ValueError, "dangling SVG reference: " & reference)
  result.markup = compactXml(root)
