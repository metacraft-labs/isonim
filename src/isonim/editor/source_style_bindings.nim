## Compiler-owned bindings for opted-in CSS constants. No DOM, filesystem or
## caller-supplied source paths: the project owns source declarations and the
## rendered catalog owns target identity. Complex/ambiguous rules are refused.
import std/[json, strutils, tables, sha1, options, algorithm]
from std/unicode import Rune, `$`
import isonim/editor/[html_classes, css_patch, source_catalog, source_style_values, types, viewmodels]

type
  SourceReader* = proc(file: string): string {.closure.}
  ReofferedDeclaration* = object
    ## A declaration Reset removed from a compiled rule (and not yet undone),
    ## which the bindings of every element the rule matches keep offering
    ## with no value so it can be set again.
    file*, constName*, selector*, property*: string

func simpleSelectorMatches*(element: SourceHtmlElement; selector: string): bool =
  ## A single compound type/class/ID selector. Combinators, attributes, state
  ## selectors and escapes require richer provenance and are never guessed.
  var at = 0
  if selector.len == 0: return false
  if selector[0] notin {'.', '#'}:
    let start = at
    while at < selector.len and selector[at] in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}: inc at
    if at == start or element.tag != selector[start ..< at].toLowerAscii(): return false
  while at < selector.len:
    let kind = selector[at]
    if kind notin {'.', '#'}: return false
    inc at
    let start = at
    while at < selector.len and selector[at] in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}: inc at
    if at == start: return false
    let name = selector[start ..< at]
    if kind == '#':
      if element.attributes.getOrDefault("id") != name: return false
    elif name notin element.attributes.getOrDefault("class").splitWhitespace(): return false
  true

const shorthandSides = [("padding", @["padding-top", "padding-right", "padding-bottom", "padding-left"]),
  ("border-radius", @["border-top-left-radius", "border-top-right-radius",
    "border-bottom-right-radius", "border-bottom-left-radius"])]

const embeddedStylesheetsField* = "editableStylesheets"
  ## A catalog row's record of the opted-in stylesheets its page embeds, as
  ## `[{"file": ..., "const": ...}]`. The project's catalog producer may
  ## declare it (it knows which constants it embeds: identity by name);
  ## otherwise the native worker's build writes it from the exact constants
  ## it compiled (`recordEmbeddedStylesheets`).

func nimTripleQuotedValue*(body: string): string =
  ## The runtime value of a raw `"""` string with this body: the compiler
  ## reads every line end (CRLF or a lone CR, as in a file checked out with
  ## Windows line ends) as LF, and a newline right after the opening quotes
  ## (whitespace before it allowed) is not part of the value.
  let text = body.replace("\r\n", "\n").replace('\r', '\n')
  var at = 0
  while at < text.len and text[at] in {' ', '\t'}: inc at
  if at < text.len and text[at] == '\n': text[at + 1 .. ^1]
  else: text

proc loadedStylesheets*(documentHtml: string; sheets: seq[tuple[key, css: string]]): seq[string] =
  ## The keys of the `sheets` (key, constant body) whose exact compiled value
  ## a page embeds in one of its `<style>` elements (alone or together with
  ## other stylesheets). Identity is the constant's bytes, not its rules: a
  ## foreign stylesheet with the same selectors is not it. Longer values claim
  ## their bytes first, so a stylesheet whose text only repeats part of a
  ## loaded one is not loaded by that repetition. Opted-in constants with the
  ## same bytes cannot be told apart, so none of them is loaded. Called by the
  ## build on the exact sources it compiled; at describe time only when the
  ## catalog carries no record (a page built from other bytes then loads none).
  var styles = htmlStyleTexts(documentHtml)
  var claimed: seq[seq[bool]]
  for style in styles: claimed.add newSeq[bool](style.len)
  var groups = initOrderedTable[string, seq[string]]()
  for sheet in sheets:
    let value = nimTripleQuotedValue(sheet.css)
    if value.strip().len == 0: continue
    if not groups.hasKey(value): groups[value] = @[]
    if sheet.key notin groups[value]: groups[value].add sheet.key
  var ordered: seq[string]
  for value in groups.keys: ordered.add value
  ordered.sort(proc(a, b: string): int = cmp(b.len, a.len))
  for value in ordered:
    var found = false
    for styleIndex, style in styles:
      var at = style.find(value)
      while at >= 0:
        var free = true
        for offset in 0 ..< value.len:
          if claimed[styleIndex][at + offset]: free = false; break
        if free:
          found = true
          for offset in 0 ..< value.len: claimed[styleIndex][at + offset] = true
          at = style.find(value, at + value.len)
        else: at = style.find(value, at + 1)
    if found and groups[value].len == 1: result.add groups[value][0]

proc optedStylesheets(manifest: JsonNode; readSource: SourceReader): seq[tuple[key, css: string]] =
  if manifest{"editableStyleSources"} == nil or manifest["editableStyleSources"].kind != JArray: return
  var texts = initTable[string, string]()
  for source in manifest["editableStyleSources"]:
    let file = source{"file"}.getStr()
    let name = source{"const"}.getStr()
    if file.len == 0 or name.len == 0: continue
    if not texts.hasKey(file): texts[file] = readSource(file)
    let key = file & "\n" & name
    var listed = false
    for sheet in result:
      if sheet.key == key: listed = true
    if not listed: result.add (key, nimConstBody(texts[file], name))

proc recordEmbeddedStylesheets*(catalog, manifest: JsonNode; readSource: SourceReader) =
  ## Record on each story row which opted-in stylesheets its page embeds,
  ## from the exact constants `readSource` holds -- the sources this build
  ## compiled -- so the record stays valid while declarations are edited
  ## until the next build. A row whose producer declared its stylesheets
  ## keeps that declaration.
  let sheets = optedStylesheets(manifest, readSource)
  if sheets.len == 0 or catalog{"stories"} == nil: return
  for story in catalog["stories"]:
    if story{embeddedStylesheetsField} != nil: continue
    var record = newJArray()
    for key in loadedStylesheets(story{"documentHtml"}.getStr(), sheets):
      let parts = key.split('\n', 1)
      record.add(%* {"file": parts[0], "const": parts[1]})
    story[embeddedStylesheetsField] = record

const cssWhitespace = {' ', '\t', '\n', '\r', '\f'}

func cssEscapeEnd(text: string; at: int): int =
  ## ``text[at]`` is a backslash: the index just past the escape it starts
  ## (CSS Syntax 4.3.7, https://www.w3.org/TR/css-syntax-3/#consume-escaped-code-point):
  ## one to six hex digits and one whitespace after them (`\32 xl` is `2xl`),
  ## or any one other code point (`\:`, `\/`).
  var i = at + 1
  if i >= text.len: return i
  if text[i] in HexDigits:
    var digits = 0
    while i < text.len and digits < 6 and text[i] in HexDigits:
      inc i
      inc digits
    if i < text.len and text[i] in cssWhitespace:
      if text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n': inc i
      inc i
    return i
  # A multi-byte UTF-8 code point is escaped whole.
  if ord(text[i]) >= 0xC0:
    inc i
    while i < text.len and (ord(text[i]) and 0xC0) == 0x80: inc i
    return i
  i + 1

func cssDecodedEscape(text: string; at, stop: int): string =
  ## The code point the escape ``text[at ..< stop]`` stands for, as UTF-8.
  let raw = text[at + 1 ..< stop]
  # Only a hex escape is closed by one whitespace; an escaped space or tab
  # is itself the code point (`.panel\\ x` is the class `panel x`).
  if raw.len == 0 or raw[0] notin HexDigits: return raw
  let body = raw.strip(leading = false, trailing = true, chars = cssWhitespace)
  if body.len > 0 and body[0] in HexDigits:
    var code = 0
    for c in body: code = code * 16 + parseHexInt($c)
    if code == 0 or code > 0x10FFFF or code in 0xD800 .. 0xDFFF: code = 0xFFFD
    return $Rune(code)
  body

func cssIdent(text: string; at: int): tuple[name: string; next: int] =
  ## The name that starts at ``text[at]`` (an identifier, escapes decoded),
  ## and the index after it; an empty name when none starts there.
  var i = at
  while i < text.len:
    let c = text[i]
    if c == '\\':
      if i + 1 >= text.len or text[i + 1] in {'\n', '\r', '\f'}: break
      let stop = text.cssEscapeEnd(i)
      result.name.add text.cssDecodedEscape(i, stop)
      i = stop
    elif c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'} or ord(c) >= 0x80:
      result.name.add c
      inc i
    else: break
  result.next = i

func compoundParts(compound: string): Option[tuple[tag: string;
    classes, ids: seq[string]]] =
  ## A compound of an optional type and `.class` / `#id` parts, names decoded,
  ## or none for anything else (`*`, attributes, pseudo-classes).
  var parts: tuple[tag: string; classes, ids: seq[string]]
  var at = 0
  if compound.len == 0: return
  if compound[0] notin {'.', '#'}:
    let (name, next) = compound.cssIdent(0)
    if name.len == 0: return
    parts.tag = name.toLowerAscii()
    at = next
  while at < compound.len:
    let kind = compound[at]
    if kind notin {'.', '#'}: return
    let (name, next) = compound.cssIdent(at + 1)
    if name.len == 0: return
    if kind == '#': parts.ids.add name else: parts.classes.add name
    at = next
  some(parts)

func compoundMatches(element: SourceHtmlElement; compound: string): Option[bool] =
  ## Whether a type/class/ID compound matches ``element`` (escapes decoded),
  ## or none when the compound is not of that form.
  let parts = compound.compoundParts()
  if parts.isNone: return
  let found = parts.get
  if found.tag.len > 0 and element.tag != found.tag: return some(false)
  let classes = element.attributes.getOrDefault("class").splitWhitespace()
  for name in found.classes:
    if name notin classes: return some(false)
  for name in found.ids:
    if element.attributes.getOrDefault("id") != name: return some(false)
  some(true)

func selectorCouldMatch(element: SourceHtmlElement; selector: string): bool =
  ## Only required terminal type/class/ID can prove a rule unrelated. Attribute,
  ## ancestor and state predicates are never evaluated to infer a winner.
  ## Escapes are decoded (CSS Syntax 4.3.7), so a utility class such as
  ## Tailwind's `.md\:p-4` or `.w-1\/2` is ruled in or out by its name, and a
  ## hex escape's trailing whitespace (`.\32 xl`) is part of the name, not a
  ## descendant combinator.
  if selector.strip() == ":root": return element.tag == "html"
  var start, depth, brackets = 0
  var quote: char
  var index = 0
  while index < selector.len:
    let character = selector[index]
    if character == '\\' and quote == '\0':
      index = selector.cssEscapeEnd(index)
      continue
    if quote != '\0':
      if character == '\\': index = selector.cssEscapeEnd(index); continue
      if character == quote: quote = '\0'
      inc index
      continue
    if character in {'\'', '"'}:
      quote = character
    elif character == '[': inc brackets
    elif character == ']':
      dec brackets
      if brackets < 0: return true
    elif brackets == 0:
      if character == '(': inc depth
      elif character == ')':
        dec depth
        if depth < 0: return true
      elif depth == 0 and character in {' ', '\t', '\n', '\r', '>', '+', '~'}:
        start = index + 1
    inc index
  if depth != 0 or brackets != 0 or quote != '\0': return true
  let subject = selector[start .. ^1].strip()
  # The compound's type/class/ID part: up to its first pseudo-class or
  # attribute selector, an escaped `:` or `[` being part of a name.
  var stop = subject.len
  var at = 0
  while at < subject.len:
    if subject[at] == '\\':
      at = subject.cssEscapeEnd(at)
      continue
    if subject[at] in {':', '['}:
      stop = at
      break
    inc at
  # An `:is()` / `:where()` / `:matches()` in the compound requires one of its
  # arguments to match the element itself: none can, none does.
  var i = stop
  while i < subject.len:
    if subject[i] == '\\':
      i = subject.cssEscapeEnd(i)
      continue
    if subject[i] == ':' and (i == 0 or subject[i - 1] != ':'):
      let (name, next) = subject.cssIdent(i + 1)
      let lower = name.toLowerAscii()
      if lower in ["is", "where", "matches"] and next < subject.len and subject[next] == '(':
        var depth = 0
        var close = -1
        var j = next
        while j < subject.len:
          let past = subject.skipCssOpaque(j)
          if past > j:
            j = past
            continue
          if subject[j] == '(': inc depth
          elif subject[j] == ')':
            dec depth
            if depth == 0:
              close = j
              break
          inc j
        if close < 0: return true
        var any = false
        for member in subject[next + 1 ..< close].splitSelectorList():
          if element.selectorCouldMatch(member): any = true
        if not any: return false
        i = close + 1
        continue
    inc i
  let simple = subject[0 ..< stop]
  if simple.len == 0 or '*' in simple: return true
  let matched = element.compoundMatches(simple)
  if matched.isNone: return true
  matched.get

func readableSpecificity(selector: string): Option[(int, int, int)] =
  ## A selector's specificity (ids, classes/attributes/pseudo-classes, types),
  ## when it can be read here: `:where()` counts nothing, `:is()`, `:not()`,
  ## `:has()` their most specific argument, another functional pseudo-class
  ## one; none for `:nth-child(... of S)`, a string, a nesting `&` or a
  ## namespace. Escapes are decoded as part of
  ## the name they occur in (`.md\:p-4` is one class; `.\32 xl` is one class
  ## and its space is not a combinator).
  var a, b, c = 0
  var at = 0
  var compoundStart = true
  while at < selector.len:
    let ch = selector[at]
    if ch in {'(', ')', '"', '\'', '&', '|'}: return none((int, int, int))
    if ch in {' ', '\t', '\n', '\r', '>', '+', '~'}:
      compoundStart = true
      inc at
      continue
    if ch == '*':
      compoundStart = false
      inc at
      continue
    if ch == '[':
      inc b
      while at < selector.len and selector[at] != ']':
        if selector[at] == '\\': at = selector.cssEscapeEnd(at) else: inc at
      inc at
      compoundStart = false
      continue
    if ch in {'#', '.', ':'}:
      var element = false
      if ch == ':' and at + 1 < selector.len and selector[at + 1] == ':':
        element = true
        inc at
      let (name, next) = selector.cssIdent(at + 1)
      if name.len == 0: return none((int, int, int))
      at = next
      compoundStart = false
      if not element and ch == ':' and at < selector.len and selector[at] == '(':
        # A functional pseudo-class: its arguments up to the matching `)`.
        var depth = 0
        var close = -1
        var i = at
        while i < selector.len:
          let x = selector[i]
          if x == '\\':
            i = selector.cssEscapeEnd(i)
            continue
          if x in {'"', '\''}: return none((int, int, int))
          if x == '(': inc depth
          elif x == ')':
            dec depth
            if depth == 0:
              close = i
              break
          inc i
        if close < 0: return none((int, int, int))
        let arguments = selector[at + 1 ..< close]
        at = close + 1
        case name.toLowerAscii()
        of "where": discard
        of "is", "not", "has", "matches":
          # The most specific selector of the list.
          var best = (0, 0, 0)
          let members = arguments.splitSelectorList()
          if members.len == 0: return none((int, int, int))
          for member in members:
            let one = readableSpecificity(member)
            if one.isNone: return none((int, int, int))
            if one.get > best: best = one.get
          a += best[0]
          b += best[1]
          c += best[2]
        else:
          # `:nth-child(2n of S)` counts S too: not read here.
          if " of " in arguments.toLowerAscii(): return none((int, int, int))
          inc b
        continue
      if ch == '#': inc a
      elif element: inc c
      else: inc b
      continue
    if compoundStart and (ch in {'a'..'z', 'A'..'Z', '_', '-', '\\'} or ord(ch) >= 0x80):
      let (name, next) = selector.cssIdent(at)
      if name.len == 0: return none((int, int, int))
      inc c
      at = next
      compoundStart = false
      continue
    return none((int, int, int))
  some((a, b, c))

type PageOwner = tuple[selector, condition, property: string; important: bool;
    after: seq[string]]
  ## An owner among a page's own `<style>` rules, and the opted-in constants
  ## (`file\nconst` keys) whose last copy in the page comes before it.

func couldOutrank(owner: PageOwner; declarationSelector, sheet: string;
    layered: bool): bool =
  ## Whether a page stylesheet's owner of a property could decide it over the
  ## opted-in declaration of ``declarationSelector`` in ``sheet`` (a
  ## top-level, unconditional normal declaration -- `cssUnconditionalLiterals`
  ## offers no other), by the cascade
  ## (https://www.w3.org/TR/css-cascade-5/#cascade-sort): `!important`
  ## always could; when the page wraps the opted-in constant in a layer or
  ## another block (``layered``) any owner could; a normal owner inside
  ## `@layer` never can over the unlayered declaration; otherwise one of
  ## higher specificity can, one of equal specificity only when it comes after
  ## the constant's last copy in the page, and one of lower specificity never,
  ## whatever its condition. Anything this cannot read (a selector
  ## `readableSpecificity` cannot count, `@scope`, an unknown at-rule) could.
  ## So a universal reset or a type rule (`* { padding: 0 }`, `div { width:
  ## 5px }`) does not withhold a class rule, nor does an earlier rule of the
  ## same specificity -- the opted-in selector's own included.
  if owner.important or layered: return true
  let condition = owner.condition.toLowerAscii()
  var rest = condition
  for known in ["@media", "@supports", "@layer"]:
    rest = rest.replace(known, "")
  if "@" in rest: return true
  if "@layer" in condition: return false
  let mine = readableSpecificity(owner.selector)
  let theirs = readableSpecificity(declarationSelector)
  if mine.isNone or theirs.isNone: return true
  if mine.get != theirs.get: return mine.get > theirs.get
  sheet in owner.after

proc pageStyles(html: string): seq[tuple[text, media: string]] =
  ## The text of every `<style>` element the page applies, in document order,
  ## with its `media` attribute ("" or `all` for every width): as
  ## `htmlStyleTexts`, but a media-limited `<style>` is kept, so its rules
  ## count as conditional owners.
  let tokens = htmlElementTokens(html)
  for index, token in tokens:
    if token.closing or token.tag != "style": continue
    var media = token.attributes.getOrDefault("media").strip()
    if media.toLowerAscii() == "all": media = ""
    # A `<style>` whose every media query is for another medium (`print`,
    # `speech`) or `not all` never applies in a screen preview.
    if media.len > 0:
      var screen = false
      for query in media.splitSelectorList():
        let q = query.toLowerAscii().strip()
        let words = q.splitWhitespace()
        let first = if words.len > 0 and words[0] == "only" and words.len > 1: words[1]
          elif words.len > 0: words[0] else: ""
        if q == "not all" or first in ["print", "speech"]: continue
        screen = true
      if not screen: continue
    if index + 1 < tokens.len and tokens[index + 1].closing and tokens[index + 1].tag == "style":
      result.add (html[token.finish ..< tokens[index + 1].start], media)

func openPreludes(css: string; at: int): seq[string] =
  ## The preludes of the blocks open at ``css[at]``, outermost first
  ## (`@layer base`, `@media (min-width: 1px)`); comments, strings and
  ## `url()` are text (`css_patch.skipCssOpaque`).
  var i = 0
  var start = 0
  while i < at:
    let past = css.skipCssOpaque(i)
    if past > i:
      i = past
      continue
    case css[i]
    of '{':
      result.add css[start ..< i].strip()
      start = i + 1
    of '}':
      if result.len > 0: discard result.pop()
      start = i + 1
    of ';':
      start = i + 1
    else: discard
    inc i

func reordersCascade(preludes: seq[string]): bool =
  ## Whether a block the page wraps an opted-in constant in can change how
  ## its declarations rank: `@media` and `@supports` only decide whether they
  ## apply, not their order, layer or specificity; `@layer`, a style rule
  ## (nesting), `@scope`, `@container` and any other block may.
  for prelude in preludes:
    let lower = prelude.toLowerAscii()
    if not (lower.startsWith("@media") or lower.startsWith("@supports")): return true

proc compiledStyleBindings*(catalog, manifest: JsonNode; readSource: SourceReader;
    reoffer: seq[ReofferedDeclaration] = @[]): JsonNode =
  ## The editable declarations the project's opted-in stylesheets give each
  ## rendered element. A stylesheet's rules bind only the elements of stories
  ## whose compiled page loads it (`loadedStylesheets`), and only the
  ## stylesheets a page loads decide who else owns a property there.
  ## `reoffer` names declarations Reset removed: such a property stays
  ## offered, with no value, to every element the rule matches in a page that
  ## loads it, while the project opts it in, the rule it came from is still
  ## the only place a value for it could go (`cssInsertionHome`, not a
  ## selector list) and nothing else in the opted-in stylesheets that page
  ## loads or that element's inline style sets it for the element. A padding
  ## or border-radius shorthand re-offered that way also offers each of its
  ## sides that the same conditions leave free, as an authored shorthand
  ## does; a value typed for a side is that side's own declaration.
  result = newJArray()
  # A declaration with a priority is not offered (editor spec "Native
  # project source capabilities": declarations with `!important` require an
  # appropriate source capability). CSS allows whitespace between `!` and
  # `important` (`8px ! important`), so the text is read as the writer reads
  # it (`cssPrioritySuffix`), not searched for `!important`.
  func important(value: string): bool =
    "!important" in value.toLowerAscii() or value.cssPrioritySuffix().len > 0
  if manifest{"editableStyleSources"} == nil: return
  if manifest["editableStyleSources"].kind != JArray:
    raise newException(ValueError, "Editable stylesheet declarations must be an array.")
  var declarations = newJArray()
  var tokens = newJArray()
  var optedInCss: seq[string]
  var tokenNames: seq[string]
  var attributionProperties: seq[string]
  var sourceTexts = initTable[string,string]()
  var sourceHashes = initTable[string,string]()
  var sheets: seq[tuple[key, css: string]]
  for source in manifest["editableStyleSources"]:
    if source.kind != JObject or source{"file"} == nil or source{"file"}.kind != JString or
        source{"const"} == nil or source{"const"}.kind != JString or
        source{"properties"} == nil or source{"properties"}.kind != JArray:
      raise newException(ValueError, "Invalid editable stylesheet declaration.")
    let sourceFile = source["file"].getStr()
    if not sourceTexts.hasKey(sourceFile):
      sourceTexts[sourceFile] = readSource(sourceFile)
      sourceHashes[sourceFile] = $secureHash(sourceTexts[sourceFile])
    let text = sourceTexts[sourceFile]
    let sourceHash = sourceHashes[sourceFile]
    let css = nimConstBody(text, source["const"].getStr())
    optedInCss.add css
    if css.len == 0: raise newException(ValueError, "Editable stylesheet constant not found.")
    let sheetKey = sourceFile & "\n" & source["const"].getStr()
    var listed = false
    for sheet in sheets:
      if sheet.key == sheetKey: listed = true
    if not listed: sheets.add (sheetKey, css)
    var allowed: seq[string]
    for property in source["properties"]:
      if property.kind != JString or property.getStr().len == 0:
        raise newException(ValueError, "Invalid editable stylesheet property.")
      allowed.add property.getStr()
      if property.getStr().startsWith("--") and property.getStr() notin tokenNames: tokenNames.add property.getStr()
    var scanAllowed = allowed
    for shorthand in ["padding", "border-radius"]:
      if shorthand notin allowed: continue
      for side in (if shorthand == "padding": @["padding-top","padding-right","padding-bottom","padding-left"] else:
          @["border-top-left-radius","border-top-right-radius","border-bottom-right-radius","border-bottom-left-radius"]):
        if side notin scanAllowed: scanAllowed.add side
    # Even uneditable shorthands can reset an allowed longhand.
    if "background" in allowed or "background-color" in allowed:
      for name in ["background", "background-color"]:
        if name notin scanAllowed: scanAllowed.add name
    for name in scanAllowed:
      if not name.startsWith("--") and name notin attributionProperties:
        attributionProperties.add name
    for rule in cssUnconditionalLiterals(css, scanAllowed):
      var values = newJObject()
      var owners = newJObject()
      var blockedShorthands: seq[string]
      for shorthand in ["padding","border-radius"]:
        if shorthand in rule.blockedProperties: blockedShorthands.add shorthand
      for declaration in rule.values:
        if declaration.property in ["padding","border-radius"] and
            declaration.value.important: blockedShorthands.add declaration.property
      for declaration in rule.values:
        if declaration.value.important: continue
        if ("padding" in blockedShorthands and declaration.property.startsWith("padding-")) or
            ("border-radius" in blockedShorthands and declaration.property in
              ["border-top-left-radius","border-top-right-radius","border-bottom-right-radius","border-bottom-left-radius"]): continue
        if rule.selector == ":root" and declaration.property.startsWith("--"):
          if directCssVariable(declaration.value).len == 0 and "var(" notin declaration.value:
            tokens.add(%* {"file":source["file"],"const":source["const"],"selector":":root",
              "name":declaration.property,"value":declaration.value,"sourceHash":sourceHash})
          continue
        values[declaration.property] = %declaration.value
        owners[declaration.property] = %* {"property":declaration.property,"value":declaration.value}
      # Declaration order decides whether a shorthand or explicit longhand
      # owns a side. Derivation never revives a conditional/duplicate side.
      for shorthand in ["padding", "border-radius"]:
        if values{shorthand} == nil: continue
        let quad = cssQuadValues(shorthand,values[shorthand].getStr())
        if quad.isNone: continue
        let sides = if shorthand == "padding": @["padding-top","padding-right","padding-bottom","padding-left"] else:
          @["border-top-left-radius","border-top-right-radius","border-bottom-right-radius","border-bottom-left-radius"]
        for index,side in sides:
          if side in rule.blockedProperties: continue
          if values{side} != nil:
            var shorthandPosition, sidePosition: int
            for location in rule.declarationPositions:
              if location.property == shorthand: shorthandPosition = location.position
              if location.property == side: sidePosition = location.position
            if sidePosition > shorthandPosition: continue
          values[side] = %quad.get[index]
          owners[side] = %* {"property":shorthand,"value":values[shorthand],"component":index}
      # Background resets its color even when its owner is not editable.
      # Only a supported winning declaration may supply the current value.
      var backgroundPosition, colorPosition = -1
      for location in rule.declarationPositions:
        if location.property == "background": backgroundPosition = location.position
        if location.property == "background-color": colorPosition = location.position
      let backgroundBlocked = "background" in rule.blockedProperties or
        (values{"background"} != nil and values["background"].getStr().important)
      # Priority declarations were withheld above, so inspect the projection too.
      var backgroundPriority = false
      var colorPriority = false
      for declaration in rule.values:
        if declaration.property == "background" and declaration.value.important:
          backgroundPriority = true
        if declaration.property == "background-color" and declaration.value.important:
          colorPriority = true
      if backgroundBlocked or backgroundPriority or colorPriority or "background-color" in rule.blockedProperties:
        if values{"background-color"} != nil: values.delete("background-color")
        if owners{"background-color"} != nil: owners.delete("background-color")
        if values{"background"} != nil: values.delete("background")
        if owners{"background"} != nil: owners.delete("background")
      elif backgroundPosition > colorPosition:
        if values{"background-color"} != nil: values.delete("background-color")
        if owners{"background-color"} != nil: owners.delete("background-color")
        if values{"background"} != nil and "background" in allowed and
            "background-color" notin rule.blockedProperties:
          let raw = values["background"].getStr()
          if directCssVariable(raw).len > 0 or parseCssPropertyValue("background-color",raw).kind == cvkColor:
            values["background-color"] = values["background"]
            owners["background-color"] = owners["background"]
      if values{"background"} != nil:
        let raw = values["background"].getStr()
        if directCssVariable(raw).len == 0 and parseCssPropertyValue("background-color",raw).kind != cvkColor:
          values.delete("background")
          owners.delete("background")
      # Projection-only declarations never gain a write capability.
      if "background" notin allowed:
        if values{"background"} != nil: values.delete("background")
        if owners{"background"} != nil: owners.delete("background")
      if values{"background-color"} != nil:
        let actualOwner = owners["background-color"]["property"].getStr()
        if actualOwner notin allowed:
          values.delete("background-color")
          owners.delete("background-color")
      if colorPosition > backgroundPosition:
        # The earlier shorthand is not the current color owner either.
        if values{"background"} != nil: values.delete("background")
        if owners{"background"} != nil: owners.delete("background")
      if values.len > 0:
        declarations.add(%* {"file": source["file"], "const": source["const"],
          "selector": rule.selector, "values": values, "sourceDeclarations": owners,"sourceHash":sourceHash})
  proc sheetOf(node: JsonNode): string = node["file"].getStr() & "\n" & node["const"].getStr()
  var elements: seq[tuple[story: string, element: SourceHtmlElement]]
  var storySheets = initTable[string, seq[string]]()
  # The text of every `<style>` element a page applies, without the opted-in
  # constants it loads: a rule the project does not opt in can still decide a property for an
  # element (an id rule outranking a shared class rule, a later rule with the
  # same selector), and then the class rule is not that property's origin
  # there; one that cannot outrank it (a universal reset, a type rule) does
  # not count (`couldOutrank`) (editor spec "Native project
  # source capabilities": a possible override prevents the producer from
  # presenting an earlier shared rule as that origin; "Saving": an edit
  # changes the one declaration that owns the property for the element).
  var storyStyles = initTable[string, seq[tuple[text: string; after: seq[string]]]]()
  var storyLayered = initTable[string, bool]()
  for story in catalog{"stories"}:
    let storyId = story{"group"}.getStr() & " / " & story{"name"}.getStr()
    let markup = sourceElementMarkup(story{"documentHtml"}.getStr(), sourceStoryIdentityPrefix(storyId))
    # The build's record names the constants the page embeds; without one
    # (a catalog another tool built) only a page holding a constant's exact
    # current bytes loads it.
    let record = story{embeddedStylesheetsField}
    if record != nil and record.kind == JArray:
      var named: seq[string]
      for row in record:
        let key = row{"file"}.getStr() & "\n" & row{"const"}.getStr()
        for sheet in sheets:
          if sheet.key == key and key notin named: named.add key
      storySheets[storyId] = named
    else:
      storySheets[storyId] = loadedStylesheets(story{"documentHtml"}.getStr(), sheets)
    # The rest of the page's `<style>` text: every copy of an opted-in
    # constant the page loads is taken out (those rules are the opted-in
    # sheets' own owners, `sheetOwners`; a constant embedded once per
    # component instance is still one stylesheet), so what is left is the
    # page's own rules.
    # The page's own rules: its `<style>` text without every copy of the
    # opted-in constants it loads (those are the opted-in sheets' own
    # owners, `sheetOwners`; a constant embedded once per component instance
    # is still one stylesheet), each piece with the constants whose last copy
    # comes before it, for the order of equally specific rules. A page
    # credited by its record with a constant whose current text it does not
    # hold (built before the source was edited, or a producer's declaration)
    # cannot be told apart from its own rules: none of its `<style>` text is
    # read as the page's own then, as before. A constant the page wraps in a
    # block that can reorder the cascade (`@layer base { ... }`, not `@media`
    # or `@supports`, which only decide whether it applies) may lose to any
    # page rule (`couldOutrank`).
    let styles = pageStyles(story{"documentHtml"}.getStr())
    var occurrences: seq[tuple[style, first, stop: int; key: string]]
    var exact = true
    var layered = false
    for sheet in sheets:
      if sheet.key notin storySheets[storyId]: continue
      let value = nimTripleQuotedValue(sheet.css)
      if value.strip().len == 0: continue
      var found = false
      for index, style in styles:
        if style.media.len > 0: continue
        var at = style.text.find(value)
        while at >= 0:
          var free = true
          for other in occurrences:
            if other.style == index and at < other.stop and other.first < at + value.len:
              free = false
          if free:
            found = true
            if style.text.openPreludes(at).reordersCascade(): layered = true
            occurrences.add (index, at, at + value.len, sheet.key)
          at = style.text.find(value, at + 1)
      if not found: exact = false
    var pieces: seq[tuple[text: string; after: seq[string]]]
    if exact:
      var last = initTable[string, (int, int)]()
      for occurrence in occurrences:
        let position = (occurrence.style, occurrence.stop)
        if not last.hasKey(occurrence.key) or last[occurrence.key] < position:
          last[occurrence.key] = position
      for index, style in styles:
        var cuts: seq[(int, int)]
        for occurrence in occurrences:
          if occurrence.style == index: cuts.add (occurrence.first, occurrence.stop)
        cuts.sort()
        var cursor = 0
        proc piece(first, stop: int) =
          var text = style.text[first ..< stop]
          if style.media.len > 0: text = "@media " & style.media & " {\n" & text & "\n}"
          var after: seq[string]
          for key, position in last:
            if position <= (index, first): after.add key
          pieces.add (text, after)
        for (first, stop) in cuts:
          piece(cursor, first)
          cursor = stop
        piece(cursor, style.text.len)
    storyStyles[storyId] = pieces
    storyLayered[storyId] = layered
    for element in markup.elements: elements.add((storyId, element))
  proc loads(story, sheet: string): bool = sheet in storySheets.getOrDefault(story)
  var unsupportedTokens: seq[string]
  var tokenOwnerCount = initCountTable[string]()
  for css in optedInCss:
    for owner in cssCustomPropertyOwners(css,tokenNames):
      tokenOwnerCount.inc owner.property
      if owner.selector != ":root" or owner.condition.len > 0:
        if owner.property notin unsupportedTokens: unsupportedTokens.add owner.property
  for name,count in tokenOwnerCount:
    if count != 1 and name notin unsupportedTokens: unsupportedTokens.add name
  # Inline variable owners also prevent authority from being assigned to root.
  # A shared rule's known usage: the elements it matches in the pages that load it.
  proc usage(sheet, selector: string): int =
    for target in elements:
      if loads(target.story, sheet) and simpleSelectorMatches(target.element, selector): inc result
  var selectorCounts = initTable[string,int]()
  for declaration in declarations:
    let counted = declaration.sheetOf() & "\n" & declaration["selector"].getStr()
    if not selectorCounts.hasKey(counted):
      selectorCounts[counted] = usage(declaration.sheetOf(), declaration["selector"].getStr())
  var sheetOwners = initTable[string, seq[tuple[selector, condition, property: string]]]()
  for sheet in sheets:
    sheetOwners[sheet.key] = cssPropertyOwners(sheet.css,attributionProperties)
  var bindingsByKey = initTable[string,JsonNode]()
  for target in elements:
    let inlineStyle = target.element.attributes.getOrDefault("style")
    if inlineStyle.len > 0:
      for owner in cssCustomPropertyOwners(".inline {" & inlineStyle & "}",tokenNames):
        if owner.property notin unsupportedTokens: unsupportedTokens.add owner.property
  for target in elements:
    let inlineStyle = target.element.attributes.getOrDefault("style")
    var candidates = newJArray()
    var possibleOwners: seq[tuple[selector, condition, property: string]]
    for sheet in storySheets.getOrDefault(target.story): possibleOwners.add sheetOwners[sheet]
    # Every owner among the page's own rules, with its priority: only one that
    # could outrank the opted-in declaration withholds it (`couldOutrank`).
    var pageOwners: seq[PageOwner]
    for piece in storyStyles.getOrDefault(target.story):
      for owner in cssRankedPropertyOwners(piece.text, attributionProperties):
        pageOwners.add (owner.selector, owner.condition, owner.property,
          owner.important, piece.after)
    let layered = storyLayered.getOrDefault(target.story)
    for declaration in declarations:
      if loads(target.story, declaration.sheetOf()) and
          simpleSelectorMatches(target.element, declaration["selector"].getStr()): candidates.add declaration
    for declaration in candidates:
      for property,raw in declaration["values"]:
        var ownerCount = 0
        for candidate in candidates:
          if candidate{"values",property} != nil: inc ownerCount
        if ownerCount != 1: continue
        # This provider hydrates the current property origin, not an explicitly
        # chosen overridden scope. Unknown cascade attribution stays read-only.
        var attributionBlocked = false
        for other in possibleOwners:
          if other.property != property: continue
          let matches = simpleSelectorMatches(target.element,other.selector)
          var selectorSupported = other.selector.len > 0
          for character in other.selector:
            if character notin {'a'..'z','A'..'Z','0'..'9','-','_','.','#'}: selectorSupported = false
          if matches and (other.condition.len > 0 or other.selector != declaration["selector"].getStr()):
            attributionBlocked = true
          elif not selectorSupported and target.element.selectorCouldMatch(other.selector):
            attributionBlocked = true
        # The page's own rules: one that matches the element and could
        # outrank the opted-in declaration withholds it -- a later rule with
        # its very selector included (`couldOutrank`).
        let ownSelector = declaration["selector"].getStr()
        for other in pageOwners:
          if other.property != property: continue
          if not other.couldOutrank(ownSelector, declaration.sheetOf(), layered): continue
          if target.element.selectorCouldMatch(other.selector):
            attributionBlocked = true
        if inlineStyle.len > 0 and cssPropertyOwners(".inline {" & inlineStyle & "}",@[property]).len > 0:
          attributionBlocked = true
        if attributionBlocked: continue
        var value = raw
        var owner = declaration
        var sourceDeclaration = declaration["sourceDeclarations"][property]
        var scope = "shared-class"
        let tokenName = directCssVariable(raw.getStr())
        if tokenName.len > 0:
          if tokenName in unsupportedTokens: continue
          var tokenOwner: JsonNode
          for token in tokens:
            if token["name"].getStr() == tokenName:
              if tokenOwner != nil: tokenOwner = nil; break
              tokenOwner = token
          if tokenOwner == nil or not loads(target.story, tokenOwner.sheetOf()): continue
          value = tokenOwner["value"]
          let parsed = parseCssPropertyValue(property,value.getStr())
          if validateCssPropertyValue(PropertyInfo(name:property,directStyleAllowed:true),
              PropertyEditRequest(property:property,newValue:value.getStr(),kind:pekCss),parsed).len > 0: continue
          owner = tokenOwner
          scope = "semantic-token"
          sourceDeclaration = %* {"property":tokenName,"value":value}
        elif "var(" in raw.getStr(): continue
        let count = selectorCounts[declaration.sheetOf() & "\n" & declaration["selector"].getStr()]
        let key = (if scope == "semantic-token": "tokens.native." else: "classes.native.") &
          $secureHash(target.story & "\n" & target.element.id & "\n" & owner["file"].getStr() &
            "\n" & owner["const"].getStr() & "\n" & owner["selector"].getStr() & "\n" & tokenName)
        var binding = bindingsByKey.getOrDefault(key)
        if binding == nil:
          binding = %* {"key":key,"elementId":target.element.id,"storyId":target.story,
            "file":owner["file"],"const":owner["const"],"selector":owner["selector"],
            "sourceHash":owner["sourceHash"],"properties":[],"values":{},"sourceDeclarations":{},
            "scope":scope,"sharedCount":count,"tokenName":tokenName}
          result.add binding
          bindingsByKey[key] = binding
        binding["properties"].add %property
        binding["values"][property] = value
        binding["sourceDeclarations"][property] = sourceDeclaration
  for declaration in reoffer:
    let property = declaration.property
    if property.len == 0 or property.startsWith("--"): continue
    # Opted in by name, or -- for a side -- through its shorthand, as the
    # declaration path offers an authored side.
    var allowed = false
    for source in manifest["editableStyleSources"]:
      if source["file"].getStr() == declaration.file and
          source["const"].getStr() == declaration.constName:
        for name in source["properties"]:
          if name.getStr() == property: allowed = true
          for (shorthand, sides) in shorthandSides:
            if name.getStr() == shorthand and property in sides: allowed = true
    if not allowed or not sourceTexts.hasKey(declaration.file): continue
    let sheet = declaration.file & "\n" & declaration.constName
    let css = nimConstBody(sourceTexts[declaration.file], declaration.constName)
    # The shorthand, then its sides, as the declaration path presents an
    # authored one; each offered only where the rule is its one home.
    var offered = @[property]
    for (shorthand, sides) in shorthandSides:
      if shorthand == property: offered.add sides
    var homes: seq[string]
    for name in offered:
      if css.cssInsertionHome(declaration.selector, name) and
          css.cssSelectorListRefusal(declaration.selector, name).len == 0: homes.add name
    if homes.len == 0: continue
    let count = usage(sheet, declaration.selector)
    for target in elements:
      if not loads(target.story, sheet) or
          not simpleSelectorMatches(target.element, declaration.selector): continue
      let inlineStyle = target.element.attributes.getOrDefault("style")
      for name in homes:
        var ownedElsewhere = false
        # The page's own rules (`storyStyles`: its `<style>` text without the
        # opted-in constants it loads, which the loop below reads).
        for piece in storyStyles.getOrDefault(target.story):
          for found in cssRankedPropertyOwners(piece.text, @[name]):
            let other: PageOwner = (found.selector, found.condition, found.property,
              found.important, piece.after)
            if not other.couldOutrank(declaration.selector, sheet,
                storyLayered.getOrDefault(target.story)): continue
            if target.element.selectorCouldMatch(other.selector):
              ownedElsewhere = true
        for loaded in storySheets.getOrDefault(target.story):
          for opted in sheets:
            if opted.key != loaded: continue
            for other in cssPropertyOwners(opted.css, @[name]):
              var selectorSupported = other.selector.len > 0
              for character in other.selector:
                if character notin {'a'..'z','A'..'Z','0'..'9','-','_','.','#'}: selectorSupported = false
              if simpleSelectorMatches(target.element, other.selector) or
                  (not selectorSupported and target.element.selectorCouldMatch(other.selector)):
                ownedElsewhere = true
        if inlineStyle.len > 0 and cssPropertyOwners(".inline {" & inlineStyle & "}", @[name]).len > 0:
          ownedElsewhere = true
        if ownedElsewhere: continue
        let key = "classes.native." & $secureHash(target.story & "\n" & target.element.id & "\n" &
          declaration.file & "\n" & declaration.constName & "\n" & declaration.selector & "\n" & "")
        var binding = bindingsByKey.getOrDefault(key)
        if binding == nil:
          binding = %* {"key":key,"elementId":target.element.id,"storyId":target.story,
            "file":declaration.file,"const":declaration.constName,"selector":declaration.selector,
            "sourceHash":sourceHashes[declaration.file],"properties":[],"values":{},"sourceDeclarations":{},
            "scope":"shared-class","sharedCount":count,"tokenName":""}
          result.add binding
          bindingsByKey[key] = binding
        if binding["values"]{name} != nil: continue
        binding["properties"].add %name
        binding["values"][name] = %""
  # Token impact includes every directly bound rendered target, across selectors.
  var knownTokenCounts = initCountTable[string]()
  proc tokenKey(binding:JsonNode): string =
    binding["file"].getStr() & "\n" & binding["const"].getStr() & "\n" & binding["tokenName"].getStr()
  for binding in result:
    if binding["scope"].getStr() == "semantic-token": knownTokenCounts.inc tokenKey(binding)
  for binding in result:
    if binding["scope"].getStr() != "semantic-token": continue
    binding["sharedCount"] = %knownTokenCounts[tokenKey(binding)]
