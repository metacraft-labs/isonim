## Optional D2/Graphviz build-time adapters with a validated content cache.
## No renderer is discovered on PATH. Theme paints are inherited CSS variables;
## reserved mask paints preserve luminance geometry independently of the palette.
import std/[os, strutils, strtabs, xmltree, sha1, tempfiles, tables, algorithm]
import ../[markdown, directives, fragments]
import ./tool_runner

type DiagramConfig* = object
  d2Path*, dotPath*: string
  cacheDir*: string ## Required when a diagram is authored.

const FormatVersion = "isonim-passive-svg-4"
const MaskStyle = "--diagram-mask-visible:white;--diagram-mask-hidden:black"

proc paint(value, property: string; mask = false): string =
  let lower = value.strip().toLowerAscii()
  if lower in ["none", "transparent"] or lower.startsWith("var(--diagram-"):
    return value
  if lower.startsWith("url("):
    let urls = cssUrls(value)
    if urls.len != 1 or not urls[0].startsWith("#"):
      raise newException(ValueError, "only local paint references are supported")
    return rewriteLocalUrls(value, proc(id: string): string = id)
  if mask:
    if lower in ["white", "#fff", "#ffffff"]: return "var(--diagram-mask-visible)"
    if lower in ["black", "#000", "#000000"]: return "var(--diagram-mask-hidden)"
    raise newException(ValueError, "only binary luminance masks are supported")
  if property == "stroke" or (property == "edge" and lower notin ["white", "#fff", "#ffffff"]): return "var(--diagram-stroke, currentColor)"
  if property in ["color", "text"]: return "var(--diagram-foreground, currentColor)"
  if lower in ["white", "#fff", "#ffffff"]: return "var(--diagram-background, Canvas)"
  "var(--diagram-fill, Canvas)"

proc normalizeDeclarations(css: string; text = false; mask = false; edge = false): string =
  for (key, value) in cssDeclarations(css):
    if result.len > 0: result.add ';'
    result.add key & ":"
    if key in ["fill", "stroke", "color", "background-color", "stop-color"] or key.startsWith("--color-"):
      let role = if text and key == "fill": "text" elif edge and key == "fill": "edge" else: key
      result.add paint(value, role, mask)
    else: result.add value

proc fontFamilies(value: string): seq[string] =
  ## The family names of a `font-family` value, unquoted
  ## (https://www.w3.org/TR/css-fonts-4/#font-family-prop). The scanner
  ## upstream has refused escapes, so a comma always separates names.
  for family in value.split(','):
    let name = family.strip().strip(chars = {'\'', '"'}).strip()
    if name.len > 0: result.add name

proc droppedFaceStyle(family: string): seq[string] =
  ## What an embedded face stood for, in terms that need no font of its own.
  ## A face's own descriptors are not written by D2, whose
  ## faces are named `<diagram>-font-<style>` with the style one of
  ## `regular`, `semibold`, `bold` or `italic`, optionally after `mono-`
  ## (d2renderers/d2svg/d2svg.go, `EmbedFonts`, at
  ## https://github.com/terrastruct/d2/blob/v0.7.1/d2renderers/d2svg/d2svg.go).
  ## Bold and italic labels keep their emphasis in the page's font. A
  ## monospace face becomes the generic `monospace` family
  ## (https://www.w3.org/TR/css-fonts-4/#generic-font-families): code that
  ## loses its fixed width no longer lines up, and a generic family loads
  ## nothing, so a policy's `font-src` does not come into it.
  let tokens = family.toLowerAscii().split('-')
  if "mono" in tokens: result.add "font-family:monospace"
  if "semibold" in tokens: result.add "font-weight:600"
  elif "bold" in tokens: result.add "font-weight:bold"
  if "italic" in tokens: result.add "font-style:italic"

proc normalizeCss(css: string; classes: seq[string]): string =
  ## D2 includes unused palette/sketch rules whose references have no defs.
  ## Drop only selectors requiring classes absent from this SVG, and scope
  ## every rule that can apply under the SVG root's ID.
  ##
  ## Embedded fonts are dropped on purpose: an `@font-face` with a `data:`
  ## source is blocked by a policy whose `font-src` does not list `data:`
  ## (https://www.w3.org/TR/CSP3/#directive-font-src), and labels are meant
  ## to read in the page's own font. A `font-family` declaration naming only
  ## dropped faces goes with them; what the face stood for stays as
  ## `font-weight`, `font-style` or the generic `monospace` family, and a rule
  ## left with no declarations is not written. The shape, connection and palette rules
  ## are kept.
  discard cssUrls(css)
  if "/*" in css: raise newException(ValueError, "CSS comments are not supported in SVG stylesheets")
  var rules: seq[tuple[selector, body: string]]
  var dropped: seq[string]
  var i = 0
  while i < css.len:
    let open = css.find('{', i)
    if open < 0:
      if css[i .. ^1].strip().len > 0: raise newException(ValueError, "malformed SVG stylesheet")
      break
    let close = css.find('}', open + 1)
    if close < 0: raise newException(ValueError, "unclosed SVG stylesheet rule")
    let selector = css[i ..< open].strip()
    let body = css[open + 1 ..< close]
    if selector == "@font-face":
      for (key, value) in cssDeclarations(body):
        if key == "font-family": dropped.add fontFamilies(value)
    elif selector.startsWith("@"):
      raise newException(ValueError, "unsupported SVG stylesheet rule: " & selector)
    else:
      rules.add (selector, body)
    i = close + 1
  for (selector, body) in rules:
    var kept: seq[string]
    for part in svgSelectors(selector):
      var applies = true
      var c = 0
      while c < part.len:
        if part[c] == '.':
          inc c
          let start = c
          while c < part.len and part[c] in Letters + Digits + {'-', '_'}: inc c
          if part[start ..< c] notin classes: applies = false
        else: inc c
      if applies:
        kept.add "#isonim-diagram-root " & part.strip()
    if kept.len == 0: continue
    var declarations: seq[string]
    var hasWeight, hasStyle = false
    for (key, value) in cssDeclarations(body):
      # The generated rules outrank renderer rules by specificity alone, and
      # an `!important` renderer declaration would defeat that
      # (https://www.w3.org/TR/css-cascade-4/#importance).
      if "!" in value: raise newException(ValueError, "SVG stylesheet declaration outranks normalized paint: " & key)
      if key == "font-weight": hasWeight = true
      if key == "font-style": hasStyle = true
    for (key, value) in cssDeclarations(body):
      let families = if key == "font-family": fontFamilies(value) else: @[]
      var onlyDropped = families.len > 0
      for family in families:
        if family notin dropped: onlyDropped = false
      if onlyDropped:
        for family in families:
          for implied in droppedFaceStyle(family):
            if implied.startsWith("font-weight:") and hasWeight: continue
            if implied.startsWith("font-style:") and hasStyle: continue
            if implied notin declarations: declarations.add implied
      else:
        declarations.add key & ":" & value
    if declarations.len == 0: continue
    result.add kept.join(",") & "{" & normalizeDeclarations(declarations.join(";"),
      text = ".text" in selector or ".color-" in selector or ".fill-N1" in selector or ".fill-N2" in selector) & "}"

const InlineClassPrefix = "isonim-diagram-s"

proc moveInlineStyles(root: XmlNode; rendererCss: string) =
  ## A page served with a Content-Security-Policy whose `style-src` has no
  ## 'unsafe-inline' applies no `style` attribute (allowing one by its hash
  ## needs 'unsafe-hashes'; https://www.w3.org/TR/CSP3/#directive-style-src),
  ## while a `<style>` element can be allowed by the hash of its text. So the
  ## normalized declarations leave the attributes for one generated stylesheet,
  ## appended to the root: the normalized renderer rules, the root's own under
  ## its ID, every other distinct declaration list under a class added to the
  ## elements that carried it. One element is one hash per diagram in the
  ## page's policy, whatever number of stylesheets the renderer wrote.
  ##
  ## An attribute outranks every stylesheet rule, which is what lets a
  ## semantic paint win over the renderer's palette classes. The generated
  ## rules keep that precedence through specificity
  ## (https://www.w3.org/TR/selectors-4/#specificity-rules): every renderer
  ## rule is scoped under the root ID, so a generated rule repeating its class
  ## once more than the most class-heavy renderer selector is more specific
  ## than all of them. A renderer selector with a second ID could not be
  ## outranked and is refused.
  var mostClasses = 0
  var i = 0
  while i < rendererCss.len:
    let open = rendererCss.find('{', i)
    if open < 0: break
    let close = rendererCss.find('}', open + 1)
    if close < 0: raise newException(ValueError, "unclosed SVG stylesheet rule")
    for part in rendererCss[i ..< open].split(','):
      if part.count('#') > 1:
        raise newException(ValueError, "SVG stylesheet selector outranks normalized paint: " & part.strip())
      mostClasses = max(mostClasses, part.count('.'))
    i = close + 1
  var lists: seq[string]
  proc collect(node: XmlNode) =
    if node.kind != xnElement: return
    if node.attrs != nil and node.attrs.hasKey("style"):
      # An empty or blank attribute declares nothing: it is dropped and gets
      # no class, as the validator refuses every style attribute.
      let declarations = node.attr("style")
      if declarations.strip().len > 0:
        var index = lists.find(declarations)
        if index < 0:
          index = lists.len
          lists.add declarations
        node.attrs["class"] = (node.attr("class") & " " & InlineClassPrefix & $index).strip()
      node.attrs.del("style")
    for child in node: collect(child)
  for child in root: collect(child)
  var css = rendererCss & "#isonim-diagram-root{" & root.attr("style") & "}"
  root.attrs.del("style")
  for index, declarations in lists:
    css.add "#isonim-diagram-root " & repeat("." & InlineClassPrefix & $index, mostClasses + 1) &
      "{" & declarations & "}"
  let element = newElement("style")
  element.add newText(css)
  root.add element

proc normalizeSvg(output: string): string =
  let root = strictXml(output)
  if root.tag != "svg": raise newException(ValueError, "expected an SVG root")
  var classes: seq[string]
  proc collect(node: XmlNode) =
    if node.kind != xnElement: return
    if node.attr("id") == "isonim-diagram-root": raise newException(ValueError, "reserved SVG id")
    for name in node.attr("class").splitWhitespace():
      if name.startsWith(InlineClassPrefix): raise newException(ValueError, "reserved SVG class: " & name)
      if name notin classes: classes.add name
    for child in node: collect(child)
  collect(root)
  var rendererCss = ""
  proc visit(node: XmlNode; mask = false; edge = false) =
    if node.kind != xnElement: return
    let inMask = mask or node.tag == "mask"
    let inEdge = edge or node.tag == "marker" or "edge" in node.attr("class").splitWhitespace() or "connection" in node.attr("class").splitWhitespace()
    if node.tag == "style":
      # The element goes away below, so an attribute that scopes it (`media`,
      # say) would be lost with it rather than honoured.
      if node.attrs != nil:
        for key, value in node.attrs:
          if key != "type" or value != "text/css":
            raise newException(ValueError, "unsupported SVG stylesheet attribute: " & key)
      rendererCss.add normalizeCss(stylesheetText(node), classes)
    if node.attrs != nil:
      var keys: seq[string]
      for key in node.attrs.keys: keys.add key
      for key in keys:
        if key in ["fill", "stroke", "stop-color"]:
          node.attrs[key] = paint(node.attr(key), (if node.tag in ["text", "tspan"] and key == "fill": "text" elif inEdge and key == "fill": "edge" else: key), inMask)
        elif key == "style":
          node.attrs[key] = normalizeDeclarations(node.attr(key), text = node.tag in ["text", "tspan"], mask = inMask, edge = inEdge)
    if node.tag in ["text", "tspan"] and node.attr("fill").len == 0:
      if node.attrs == nil: node.attrs = newStringTable()
      node.attrs["fill"] = "var(--diagram-foreground, currentColor)"
    # D2 repeats paints as both attributes and palette class rules. Inline
    # declarations give the semantic role precedence over those class rules,
    # without removing geometry, masks or useful stylesheet structure.
    for property in ["fill", "stroke"]:
      if node.attr(property).len > 0:
        let previous = node.attr("style")
        node.attrs["style"] = previous & (if previous.len > 0: ";" else: "") & property & ":" & node.attr(property)
    for child in node: visit(child, inMask, inEdge)
  visit(root)
  # The rules now live in `rendererCss`, written as plain text (never CDATA)
  # into the one generated element, so the page carries the exact bytes a
  # hash-based style-src allows.
  proc removeStyles(node: XmlNode) =
    if node.kind != xnElement: return
    var c = 0
    while c < node.len:
      let child = node[c]
      if child.kind == xnElement and child.tag == "style":
        node.delete(c)
      else:
        removeStyles(child)
        inc c
  removeStyles(root)
  if root.attrs == nil: root.attrs = newStringTable()
  if root.attr("id").len > 0: raise newException(ValueError, "renderer root IDs are not supported")
  root.attrs["id"] = "isonim-diagram-root"
  root.attrs["class"] = (root.attr("class") & " isonim-diagram").strip()
  root.attrs["fill"] = "var(--diagram-fill, Canvas)"
  root.attrs["xmlns"] = "http://www.w3.org/2000/svg"
  root.attrs["style"] = (if root.attr("style").len > 0: root.attr("style") & ";" else: "") & MaskStyle
  moveInlineStyles(root, rendererCss)
  fragmentHtml(diagramFragment(compactXml(root)))

proc instanceSvg(svg, prefix: string): ContentFragment =
  let root = strictXml(svg)
  var ids = initTable[string, string]()
  proc collect(node: XmlNode) =
    if node.kind != xnElement: return
    if node.attr("id").len > 0: ids[node.attr("id")] = prefix & node.attr("id")
    for child in node: collect(child)
  collect(root)
  proc resolve(id: string): string =
    if not ids.hasKey(id): raise newException(ValueError, "dangling SVG reference: " & id)
    ids[id]
  proc references(value: string): string = rewriteLocalUrls(value, resolve)
  proc stylesheet(css: string): string =
    var i = 0
    while i < css.len:
      let open = css.find('{', i)
      let close = css.find('}', open + 1)
      if open < 0 or close < 0: raise newException(ValueError, "malformed SVG stylesheet")
      let selector = css[i ..< open]
      var rewritten = ""
      var n = 0
      while n < selector.len:
        if selector[n] == '#':
          inc n
          let start = n
          while n < selector.len and selector[n] in Letters + Digits + {'_', '-'}: inc n
          rewritten.add "#" & resolve(selector[start ..< n])
        else:
          rewritten.add selector[n]
          inc n
      result.add rewritten & "{" & references(css[open + 1 ..< close]) & "}"
      i = close + 1
  proc visit(node: XmlNode) =
    if node.kind != xnElement: return
    if node.attrs != nil:
      var keys: seq[string]
      for key in node.attrs.keys: keys.add key
      for key in keys:
        let value = node.attr(key)
        if key == "id": node.attrs[key] = ids[value]
        elif key == "aria-labelledby":
          var labels: seq[string]
          for id in value.splitWhitespace(): labels.add resolve(id)
          node.attrs[key] = labels.join(" ")
        elif key in ["href", "xlink:href"] and value.startsWith("#") and ids.hasKey(value[1 .. ^1]):
          node.attrs[key] = "#" & ids[value[1 .. ^1]]
        else: node.attrs[key] = references(value)
    if node.tag == "style":
      let css = stylesheet(stylesheetText(node))
      while node.len > 0: node.delete(0)
      node.add newText(css)
    for child in node: visit(child)
  visit(root)
  diagramFragment(compactXml(root))

proc requireStandaloneD2(source: string; location: SourceLocation) =
  ## Refuse imports before cache lookup. This is a lexical source boundary,
  ## not a D2 parser: literals/comments stay opaque and the real CLI owns
  ## syntax/semantic errors. See D2 v0.7.1 d2parser/parse.go and
  ## https://d2lang.com/tour/imports/ for regular/spread/absolute imports.
  if '\0' in source: raise contentError(location, "D2 source must be UTF-8 text without NUL bytes")
  var i = 0
  var tokenStart = true
  var inValue = false
  while i < source.len:
    let ch = source[i]
    if ch == '#':
      while i < source.len and source[i] notin {'\r', '\n'}: inc i
      continue
    if ch == '\\':
      i += min(2, source.len - i)
      tokenStart = false
      continue
    if tokenStart and source.continuesWith("\"\"\"", i):
      let close = source.find("\"\"\"", i + 3)
      if close < 0: raise contentError(location, "unclosed D2 block comment")
      i = close + 3
      continue
    if tokenStart and ch in {'\'', '"'}:
      let quote = ch
      inc i
      var closed = false
      while i < source.len:
        if source[i] == quote:
          if quote == '\'' and i + 1 < source.len and source[i + 1] == '\'':
            i += 2
            continue
          inc i
          closed = true
          break
        if source[i] == '\\' and i + 1 < source.len and
            (quote == '"' or source[i + 1] == '\n'): i += 2
        else: inc i
      if not closed: raise contentError(location, "unclosed D2 quoted string")
      tokenStart = false
      continue
    if tokenStart and ch == '|':
      inc i
      let start = i
      while i < source.len and source[i] notin Letters + Digits + Whitespace + {'_'} and ord(source[i]) < 128:
        inc i
      let delimiter = source[start ..< i] & "|"
      for ch in source[start ..< i]:
        if ch != source[start]:
          raise contentError(location, "D2 mixed-symbol block delimiters are not supported")
      # Skip the language tag before looking for the matching block delimiter.
      while i < source.len and source[i] notin Whitespace: inc i
      let close = source.find(delimiter, i)
      if close < 0: raise contentError(location, "unclosed D2 block string")
      i = close + delimiter.len
      tokenStart = false
      continue
    if ch == '@':
      raise contentError(location, "D2 imports are not supported in standalone diagrams; quote or escape literal @")
    if ch in {'\r', '\n', ';', '{', '}', '[', ']'}:
      tokenStart = true
      inValue = ch == '['
    elif ch == ':' and not inValue:
      tokenStart = true
      inValue = true
    elif ch in {'.', '<', '>', '-'} and not inValue:
      tokenStart = true
    elif ch notin {' ', '\t'}:
      tokenStart = false
    inc i

proc renderDiagram*(language, source: string; config: DiagramConfig;
    location: SourceLocation; occurrence: string = ""): ContentFragment =
  ## A path/line denotes one instance. When embedding that instance repeatedly,
  ## direct callers supply distinct stable occurrence keys. Reusing a key is
  ## intentionally deterministic; no process-global counter affects output.
  let name = case language
    of "d2": "D2"
    of "dot": "Graphviz"
    else: raise contentError(location, "unsupported diagram language: " & language)
  let path = checkedExecutable((if language == "d2": config.d2Path else: config.dotPath), name, location)
  if language == "d2": requireStandaloneD2(source, location)
  if config.cacheDir.len == 0: raise contentError(location, "diagram cache not configured")
  # A Nix store path identifies its full dependency closure. Hashing the entry
  # executable also invalidates a mutable injected wrapper at the same path.
  let key = $secureHash(FormatVersion & "\0" & language & "\0" & path & "\0" &
    $secureHashFile(path) & "\0" & source)
  let cache = config.cacheDir / (key & ".svg")
  var svg: string
  try:
    if fileExists(cache):
      let stored = readFile(cache)
      let newline = stored.find('\n')
      if newline < 0 or stored[0 ..< newline] != $secureHash(stored[newline + 1 .. ^1]):
        raise newException(ValueError, "corrupt diagram cache: " & cache)
      svg = fragmentHtml(diagramFragment(stored[newline + 1 .. ^1]))
    else:
      let output = renderWithTool(path, name, source, language, location,
        proc(input, output: string): seq[string] =
          if language == "d2":
            @["--no-xml-tag", "--omit-version", "--bundle=false", "--layout=dagre",
              "--theme=0", "--dark-theme=-1", "--pad=16", "--target=", input, output]
          else: @["-Tsvg_inline", input, "-o", output])
      svg = normalizeSvg(output)
      createDir(config.cacheDir)
      let (file, temporary) = createTempFile(key & "-", ".tmp", config.cacheDir)
      try:
        file.write($secureHash(svg) & "\n" & svg)
        file.close()
        moveFile(temporary, cache)
      finally:
        if fileExists(temporary): removeFile(temporary)
    result = instanceSvg(svg, "diagram-" & $secureHash(location.path & ":" & $location.line & ":" & occurrence & ":" & key) & "-")
  except ValueError as error:
    if error.msg.startsWith((if location.path.len > 0: location.path else: "<markdown>") & ":"):
      raise
    raise contentError(location, name & " output: " & error.msg)
  except OSError as error:
    raise contentError(location, name & " cache: " & error.msg)

proc diagramHooks*(config: DiagramConfig): ParseHooks =
  result.name = "diagrams"
  result.renderers.diagram = proc(language, source: string; location: SourceLocation): ContentFragment =
    renderDiagram(language, source, config, location)
