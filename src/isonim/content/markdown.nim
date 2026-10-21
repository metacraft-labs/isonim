## isonim/content/markdown -- the Markdown AST and its parser.
##
## Pure, filesystem-free block and inline Markdown parsing into a typed
## AST (`Block`, `InlineSpan`, `MarkdownDoc`), with stable heading
## anchors from `anchors.nim`. No filesystem access anywhere in this
## module, so it behaves identically on `nim c` and `nim js`.
##
## The dialect is the one isonim-docs established: ATX headings,
## paragraphs, flat lists, fenced code, pipe tables, `:::` admonitions,
## `:::tabs`, the `:::` content directives (`cards`, `hero`, `button`,
## `faq`, `video`, `form`), component tags (`<Name .../>`), and inline
## text, code, links, images and `[[sym:...]]` symbol references. Those
## directives are parsed here because they are block-level syntax; how
## each one looks is the consumer's business (isonim-docs renders them,
## HTML email reports the ones it has no form for), so this module has
## no renderer.
##
## Custom `:::name` directives are wired in through the
## `knownDirective`/`renderDirective` closures; `directives.nim` builds
## those from registered directive renderers.
##
## Moved here from isonim-docs (`src/core/markdown_vm.nim`, which now
## re-exports this module); the AST types are the same types, so every
## consumer of either path sees one `Block` and one `InlineSpan`.

import std/strutils
import ./anchors
type
  InlineKind* = enum
    ikText
    ikCode
    ikLink
    ikImage
    ikSymRef ## M8 deliverable 2: a `[[sym:MyType.myProc]]` code-symbol
             ## cross-reference. `text` is the symbol query (also the
             ## display text); `href` is the resolved symbol-anchor link
             ## when a `resolveSymbol` closure resolved it (rendered as a
             ## link), or "" when unresolved -- an unresolved symref renders
             ## as plain code and is FLAGGED by the reference checker
             ## (`references.checkPageReferences`) with source provenance.

  InlineSpan* = object
    ## One inline run within a paragraph/list-item/admonition-paragraph.
    ## `text` is the display text (or the alt text, for `ikImage`; the
    ## symbol query, for `ikSymRef`); `href` is the link/image/symbol-anchor
    ## target after `normalizeRelativeLink`/`resolveSymbol`.
    kind*: InlineKind
    text*: string
    href*: string
    isRelative*: bool ## True when the original markdown target was a
                      ## relative path (content link or asset), not an
                      ## absolute URL or same-page fragment -- the flag
                      ## later broken-link reporting filters on.

  ListKind* = enum
    lkUnordered
    lkOrdered

  AdmonitionKind* = enum
    akNote
    akTip
    akImportant ## metacraft-theme M3 (Gap D): `:::important` (violet).
    akWarning
    akCaution   ## metacraft-theme M3 (Gap D): `:::caution` (red).
    akDanger

  PropValueKind* = enum
    ## M9 deliverable 1: the parsed type of one custom-component prop
    ## value. A quoted value is always `pvkString`; an unquoted bare token
    ## is typed as `pvkInt` when it's all digits (optionally signed),
    ## `pvkBool` when it's `true`/`false`, else `pvkString`; a valueless
    ## attribute (`disabled`) is `pvkBool` true. Every prop keeps its
    ## original `strVal` too, so a consumer can always read the raw text
    ## regardless of the inferred type.
    pvkString
    pvkInt
    pvkBool

  ComponentProp* = object
    ## One `name="value"` pair parsed off a `<MyButton .../>` tag. A flat
    ## (non-variant) record deliberately: the JS backend's deep-copy path
    ## can corrupt `seq`s of variant objects (see `signals.nim`'s own
    ## note), and these props are carried inside a `bkComponent` `Block`
    ## that gets copied around on both targets. `strVal` always holds the
    ## raw text; `intVal`/`boolVal` are meaningful only for their `kind`.
    name*: string
    kind*: PropValueKind
    strVal*: string
    intVal*: int
    boolVal*: bool

  BlockKind* = enum
    bkHeading
    bkParagraph
    bkList
    bkCodeFence
    bkAdmonition
    bkTable
    bkTabs
    bkComponent
    bkCardGrid ## metacraft-theme-parity M2: a `:::cards` grid of `:::card` items.
    bkHero     ## metacraft-theme-parity M2: a `:::hero` (title + subtitle + buttons).
    bkButton   ## metacraft-theme-parity M2: a standalone `:::button` action link.
    bkFaq      ## metacraft-theme-parity M2: a `:::faq` accordion of `:::q` items.
    bkVideo    ## metacraft-theme-parity M3: a `:::video` responsive embed.
    bkForm     ## metacraft-theme-parity: a `:::form` semantic contact/auth form
               ## of `@field` lines (WebFlow `.support-form` / `.user-form`).
               ## Added at the END of the enum so every existing `BlockKind`
               ## ordinal is preserved (several modules `case` on it).

  CardItem* = object
    ## metacraft-theme-parity M2: one `:::card title="…" icon="…" href="…"`
    ## entry inside a `:::cards` grid. Flat (non-variant) record on purpose
    ## -- the same JS-backend deep-copy-of-variant-seq hazard `ComponentProp`
    ## documents applies, and these are carried inside a `bkCardGrid` `Block`
    ## copied around on both targets. `body` is the card description
    ## (blank-line-separated paragraphs of inline spans, exactly like an
    ## admonition body). Each card renders as a focusable `<a href>`.
    title*: string
    icon*: string
    href*: string
    body*: seq[seq[InlineSpan]]

  ButtonSpec* = object
    ## metacraft-theme-parity M2: one action button, either a standalone
    ## `:::button` block or one of a `:::hero`'s action buttons. `variant`
    ## is normalized to "primary" (black `.docs-md-button`) or "secondary"
    ## (white `.docs-md-button-secondary`); `label` is the button's visible
    ## text.
    label*: string
    href*: string
    variant*: string

  FaqItem* = object
    ## metacraft-theme-parity M2: one `:::q title="…"` question inside a
    ## `:::faq` accordion; `answer` is its body (paragraphs of inline spans).
    ## Renders as a native, JS-free `<details>`/`<summary>` disclosure.
    question*: string
    answer*: seq[seq[InlineSpan]]

  FormFieldKind* = enum
    ## metacraft-theme-parity: the input type of one `:::form` `@field`. The
    ## default (`ffkText`) covers a bare `type=text`/unknown/missing type, so a
    ## typo never crashes -- it just renders a plain text input.
    ffkText
    ffkEmail
    ffkPassword
    ffkTextarea
    ffkSelect
    ffkCheckbox

  FormField* = object
    ## metacraft-theme-parity: one field of a `:::form`. Flat (non-variant)
    ## record on purpose -- the same JS-backend deep-copy-of-variant-seq hazard
    ## `ComponentProp`/`CardItem` document applies, and these are carried inside
    ## a `bkForm` `Block` copied around on both targets. `name` is the field's
    ## form name (and the `id`/`for` a11y binding); `label` its visible label;
    ## `placeholder` an optional input placeholder; `options` the `<option>`
    ## values for a `ffkSelect`; `required` marks it `required`.
    name*: string
    label*: string
    placeholder*: string
    kind*: FormFieldKind
    options*: seq[string]
    required*: bool

  TabPanel* = object
    ## One `@tab Title` panel inside a `:::tabs` block: the panel's own
    ## title and its body re-parsed as a full nested block list (so a
    ## panel can hold anything a top-level document can -- code fences,
    ## lists, nested admonitions -- not just paragraphs, unlike
    ## `bkAdmonition`'s flatter `bodyParagraphs`).
    title*: string
    blocks*: seq[Block]

  Block* = object
    ## One parsed body-level markdown block. Headings carry a stable
    ## `headingId` (`anchors.nextId`) rather than inline spans -- heading
    ## text is rendered plain, keeping anchor generation simple and the
    ## heading tree trivially derivable from the flat block list.
    case kind*: BlockKind
    of bkHeading:
      level*: int
      headingText*: string
      headingId*: string
    of bkParagraph:
      spans*: seq[InlineSpan]
    of bkList:
      listKind*: ListKind
      items*: seq[seq[InlineSpan]]
    of bkCodeFence:
      lang*: string
      code*: string
    of bkAdmonition:
      admonitionKind*: AdmonitionKind
      bodyParagraphs*: seq[seq[InlineSpan]]
    of bkTable:
      headers*: seq[string]
      rows*: seq[seq[string]]
    of bkTabs:
      tabs*: seq[TabPanel]
    of bkComponent:
      ## M9 deliverable 1: a custom component tag (`<MyButton .../>`, or a
      ## paired `<MyButton>...</MyButton>`) extracted from markdown and
      ## bound BY NAME to a consumer-registered component (resolved at
      ## render time against a `ComponentRegistry`, see
      ## `components/component_view.nim`). `componentName` is the tag's
      ## Capitalized name; `props` are the parsed attribute pairs;
      ## `componentChildren` is the paired form's raw inner text ("" for a
      ## self-closing tag). `componentError` is "" for a well-formed tag,
      ## or a human-readable reason (e.g. an unknown component name) when
      ## the extractor was given a registry predicate that rejected it --
      ## a TYPED fallback node, never a crash and never silent corruption.
      componentName*: string
      props*: seq[ComponentProp]
      componentChildren*: string
      componentError*: string
    of bkCardGrid:
      ## metacraft-theme-parity M2: the parsed `:::card` items, in author
      ## order. Empty `cards` renders an empty grid container.
      cards*: seq[CardItem]
      gridVariant*: string ## metacraft-theme-parity M6: the `:::cards
                           ## variant="…"` modifier. "" (the default, and any
                           ## unrecognized value) renders the standard
                           ## category-card grid exactly as pre-M6 -- so
                           ## `:::cards` without a variant is byte-unchanged.
                           ## "compact" selects the WebFlow popular-article-card
                           ## look (a distinct `docs-md-card-grid--compact` /
                           ## `docs-md-card--compact` class the theme styles).
    of bkHero:
      ## metacraft-theme-parity M2: the hero's title/subtitle text and its
      ## ordered action buttons.
      heroTitle*: string
      heroSubtitle*: string
      heroButtons*: seq[ButtonSpec]
    of bkButton:
      ## metacraft-theme-parity M2: a single standalone action button.
      button*: ButtonSpec
    of bkFaq:
      ## metacraft-theme-parity M2: the parsed `:::q` accordion items.
      faqItems*: seq[FaqItem]
    of bkVideo:
      ## metacraft-theme-parity M3: a responsive video embed. `videoId` is a
      ## resolved YouTube id (rendered as a privacy-friendly
      ## youtube-nocookie embed); `videoSrc` is an explicit iframe `src`
      ## override (used verbatim when set); `videoTitle` is the iframe's a11y
      ## title. When both id and src are empty the renderer emits a safe
      ## empty wrapper (no iframe) rather than a broken embed.
      videoId*: string
      videoSrc*: string
      videoTitle*: string
    of bkForm:
      ## metacraft-theme-parity: a semantic `<form>`. `formAction`/`formMethod`
      ## are the form's own attributes (there is no backend -- a `mailto:` or a
      ## no-op relative action is fine, matching WebFlow's own client-only
      ## forms); `formSubmit` is the submit button's label; `formFields` the
      ## ordered, labeled fields.
      formAction*: string
      formMethod*: string
      formSubmit*: string
      formFields*: seq[FormField]

  HeadingNode* = object
    ## One node of the document's heading tree, nested by heading level
    ## regardless of how many levels are skipped between a parent and
    ## its first child (a heading tree built straight off real authored
    ## content can't assume perfectly monotonic nesting).
    level*: int
    text*: string
    id*: string
    children*: seq[HeadingNode]

  MarkdownDoc* = object
    blocks*: seq[Block]
    headingTree*: seq[HeadingNode]

# --- Relative link / asset-reference normalization ----------------------

proc contentPathSlug*(relPath: string): string =
  ## The slug a content file is addressed by when nothing overrides it:
  ## its basename with a `.md` extension stripped
  ## ("guide/getting-started.md" -> "getting-started"). Works on
  ## forward-slash-joined relative paths only (never an OS path), so it is
  ## the same on every target.
  result = relPath
  let slashIdx = result.rfind('/')
  if slashIdx >= 0:
    result = result[slashIdx + 1 .. ^1]
  if result.endsWith(".md"):
    result = result[0 ..< result.len - 3]

proc contentPathSection*(relPath: string): string =
  ## The section a content file belongs to when nothing overrides it: its
  ## parent directory relative to the content root ("" at the root).
  let slashIdx = relPath.rfind('/')
  if slashIdx >= 0: relPath[0 ..< slashIdx] else: ""

proc contentRoutePath*(section, slug: string): string =
  ## The route a (section, slug) pair binds to: slug "index" is the
  ## section's own root ("/" for the content root); everything else is
  ## "/section/slug", or "/slug" with no section.
  if slug == "index":
    (if section.len == 0: "/" else: "/" & section)
  else:
    (if section.len == 0: "/" & slug else: "/" & section & "/" & slug)

proc resolveRelativePath*(baseDir, target: string): string =
  ## Resolves a `./`/`../`-relative `target` against `baseDir` (both
  ## forward-slash-joined content-relative paths) into a clean,
  ## content-root-relative path with no `.`/`..` segments left. Pure
  ## segment-stack join -- same on every target.
  var segments: seq[string] = @[]
  if baseDir.len > 0:
    for seg in baseDir.split('/'):
      if seg.len > 0: segments.add seg
  for seg in target.split('/'):
    if seg.len == 0 or seg == ".":
      continue
    elif seg == "..":
      if segments.len > 0: segments.setLen(segments.len - 1)
    else:
      segments.add seg
  segments.join("/")

proc isExternalOrAbsoluteLink(href: string): bool =
  href.len == 0 or href.startsWith("http://") or href.startsWith("https://") or
    href.startsWith("//") or href.startsWith("#") or href.startsWith("/") or
    href.startsWith("mailto:")

proc normalizeRelativeLink*(href: string; sourceRelPath: string;
                             resolveContentPath: proc(contentRelPath: string): string {.closure.} = nil):
    tuple[href: string, isRelative: bool] =
  ## Normalizes one markdown link/image target found in the page at
  ## `sourceRelPath` (a content-root-relative path, e.g.
  ## "guide/getting-started.md"). Absolute URLs, protocol-relative URLs,
  ## same-page fragments, site-absolute paths, and `mailto:` links pass
  ## through unchanged and are reported as non-relative (nothing for
  ## broken-link reporting to resolve against the content graph). A
  ## relative `.md` target's own `#fragment` (if any) is split off before
  ## resolution and reattached afterwards, so an anchor-fragment link to
  ## another page (e.g. "./dsl.md#elements") normalizes its route part
  ## exactly like a bare page link, rather than the fragment corrupting
  ## the ".md" suffix check below. The route part itself resolves via
  ## `resolveContentPath` when the caller supplies one (a site passes its
  ## route manifest's own `contentPath -> route` binding, so a link target
  ## and its destination page's *actual* serving route always agree). With
  ## no resolver given, the route part falls back to the path-derived
  ## convention: `contentRoutePath(contentPathSection(p),
  ## contentPathSlug(p))`, i.e. "guide/intro.md" -> "/guide/intro". Any
  ## other relative target is treated as a static asset reference and
  ## resolved to a site-rooted path.
  if isExternalOrAbsoluteLink(href):
    return (href, false)
  let baseDir = block:
    let slashIdx = sourceRelPath.rfind('/')
    if slashIdx >= 0: sourceRelPath[0 ..< slashIdx] else: ""
  let hashIdx = href.find('#')
  let target = if hashIdx >= 0: href[0 ..< hashIdx] else: href
  let fragment = if hashIdx >= 0: href[hashIdx .. ^1] else: ""
  let resolved = resolveRelativePath(baseDir, target)
  if resolved.endsWith(".md"):
    let routePath =
      if resolveContentPath != nil:
        resolveContentPath(resolved)
      else:
        contentRoutePath(contentPathSection(resolved), contentPathSlug(resolved))
    (routePath & fragment, true)
  else:
    ("/" & resolved & fragment, true)

# --- Inline parsing -------------------------------------------------------

# --- Custom-component prop accessors (M9 deliverable 1) ------------------

proc hasProp*(props: seq[ComponentProp]; name: string): bool =
  for p in props:
    if p.name == name: return true
  false

proc getProp*(props: seq[ComponentProp]; name: string): ComponentProp =
  ## Returns the named prop, or an empty (`pvkString`, "") prop if absent.
  for p in props:
    if p.name == name: return p
  ComponentProp(name: name, kind: pvkString)

proc getStr*(props: seq[ComponentProp]; name: string; default = ""): string =
  ## The prop's raw string value (works for any prop kind -- `strVal` is
  ## always populated), or `default` when the prop is absent.
  for p in props:
    if p.name == name: return p.strVal
  default

proc getInt*(props: seq[ComponentProp]; name: string; default = 0): int =
  ## The prop's integer value -- from `intVal` when it parsed as `pvkInt`,
  ## else re-parsed leniently from `strVal` (so a quoted `count="3"` reads
  ## as `3` too), else `default` (including when absent). Never raises.
  for p in props:
    if p.name == name:
      if p.kind == pvkInt: return p.intVal
      try: return parseInt(p.strVal.strip())
      except ValueError: return default
  default

proc getBool*(props: seq[ComponentProp]; name: string; default = false): bool =
  ## The prop's boolean value -- from `boolVal` when it parsed as `pvkBool`,
  ## else re-parsed leniently from `strVal` (so a quoted `active="true"`
  ## reads as `true` too), else `default`.
  for p in props:
    if p.name == name:
      if p.kind == pvkBool: return p.boolVal
      case p.strVal.strip().toLowerAscii()
      of "true": return true
      of "false": return false
      else: return default
  default

proc spansText*(spans: seq[InlineSpan]): string =
  ## Flattens a run of inline spans back to plain text (link/image spans
  ## contribute their visible text, not their target) -- a convenience
  ## for consumers/tests that don't need per-span structure.
  for s in spans: result.add s.text

proc parseInlineSpans*(text: string; sourceRelPath: string = "";
                        resolveContentPath: proc(contentRelPath: string): string {.closure.} = nil;
                        resolveSymbol: proc(sym: string): string {.closure.} = nil): seq[InlineSpan] =
  ## Scans one already-joined line of body text for `![alt](src)`,
  ## `[text](href)`, `` `code` ``, and `[[sym:Symbol]]` markers, normalizing
  ## every link/image target against `sourceRelPath` (see
  ## `normalizeRelativeLink` for what `resolveContentPath` does) and
  ## resolving every `[[sym:...]]` cross-reference through `resolveSymbol`
  ## (M8 deliverable 2: returns the symbol-anchor href, or "" for an unknown
  ## symbol). Any marker left unterminated (no matching closer) degrades
  ## gracefully to plain text rather than raising, since hand-authored
  ## markdown will eventually contain a stray backtick or bracket.
  var i = 0
  var plain = ""
  template flushPlain() =
    if plain.len > 0:
      result.add InlineSpan(kind: ikText, text: plain)
      plain = ""

  while i < text.len:
    if text[i] == '[' and text.continuesWith("[[sym:", i):
      let close = text.find("]]", i + 6)
      if close >= 0:
        flushPlain()
        let query = text[i + 6 ..< close].strip()
        let href = if resolveSymbol != nil: resolveSymbol(query) else: ""
        result.add InlineSpan(kind: ikSymRef, text: query, href: href,
                              isRelative: href.len > 0)
        i = close + 2
        continue
      plain.add text[i]
      inc i
    elif text[i] == '!' and i + 1 < text.len and text[i + 1] == '[':
      let closeBracket = text.find(']', i + 2)
      if closeBracket >= 0 and closeBracket + 1 < text.len and text[closeBracket + 1] == '(':
        let closeParen = text.find(')', closeBracket + 2)
        if closeParen >= 0:
          flushPlain()
          let alt = text[i + 2 ..< closeBracket]
          let src = text[closeBracket + 2 ..< closeParen]
          let (normHref, isRel) = normalizeRelativeLink(src, sourceRelPath, resolveContentPath)
          result.add InlineSpan(kind: ikImage, text: alt, href: normHref, isRelative: isRel)
          i = closeParen + 1
          continue
      plain.add text[i]
      inc i
    elif text[i] == '[':
      let closeBracket = text.find(']', i + 1)
      if closeBracket >= 0 and closeBracket + 1 < text.len and text[closeBracket + 1] == '(':
        let closeParen = text.find(')', closeBracket + 2)
        if closeParen >= 0:
          flushPlain()
          let linkText = text[i + 1 ..< closeBracket]
          let href = text[closeBracket + 2 ..< closeParen]
          let (normHref, isRel) = normalizeRelativeLink(href, sourceRelPath, resolveContentPath)
          result.add InlineSpan(kind: ikLink, text: linkText, href: normHref, isRelative: isRel)
          i = closeParen + 1
          continue
      plain.add text[i]
      inc i
    elif text[i] == '`':
      let closeTick = text.find('`', i + 1)
      if closeTick >= 0:
        flushPlain()
        result.add InlineSpan(kind: ikCode, text: text[i + 1 ..< closeTick])
        i = closeTick + 1
        continue
      plain.add text[i]
      inc i
    else:
      plain.add text[i]
      inc i
  flushPlain()

# --- Block-level parsing --------------------------------------------------

proc isOrderedListItem(line: string): bool =
  var i = 0
  while i < line.len and line[i] in Digits: inc i
  i > 0 and i + 1 < line.len and line[i] == '.' and line[i + 1] == ' '

proc isUnorderedListItem(line: string): bool =
  line.len >= 2 and (line[0] == '-' or line[0] == '*') and line[1] == ' '

proc listItemText(line: string): string =
  if isOrderedListItem(line):
    var i = 0
    while line[i] in Digits: inc i
    line[i + 2 .. ^1]
  else:
    line[2 .. ^1]

proc isTableRow(line: string): bool =
  line.startsWith("|")

proc isTableSeparatorRow(line: string): bool =
  let s = line.strip()
  if not s.startsWith("|"): return false
  for ch in s:
    if ch notin {'|', '-', ':', ' '}: return false
  true

proc splitTableRow(line: string): seq[string] =
  var s = line.strip()
  if s.startsWith("|"): s = s[1 .. ^1]
  if s.endsWith("|"): s = s[0 ..< ^1]
  for cell in s.split('|'):
    result.add cell.strip()

proc headingMarkerLevel(line: string): int =
  ## Returns the heading level (1-6) if `line` is `#`..`######` followed
  ## by a space, or 0 if it isn't a heading line at all.
  var hi = 0
  while hi < line.len and line[hi] == '#': inc hi
  if hi > 0 and hi <= 6 and hi < line.len and line[hi] == ' ': hi else: 0

proc isComponentTagLine(line: string): bool =
  ## True when a stripped line opens a custom component tag: `<` followed
  ## immediately by an uppercase letter (the JSX-style Capitalized-name
  ## convention that distinguishes a component from ordinary lowercase
  ## HTML like `<div>`/`<br/>`, which stays plain markdown text).
  line.len >= 2 and line[0] == '<' and line[1] in {'A' .. 'Z'}

proc parseComponentProps(attrs: string): seq[ComponentProp] =
  ## Parses the attribute run of a component tag (everything between the
  ## tag name and the closing `>`/`/>`) into typed props. Supports
  ## `name="v"`, `name='v'` (string), `name=123` (int), `name=true`/
  ## `name=false` (bool), and a valueless `name` (bool true). Quoted
  ## values are always strings; unquoted values are type-inferred. A
  ## malformed fragment is skipped rather than raising -- hand-authored
  ## markup should never crash the parser.
  var i = 0
  let s = attrs
  while i < s.len:
    while i < s.len and s[i] in {' ', '\t', '\n', '\r'}: inc i
    if i >= s.len: break
    var nameEnd = i
    while nameEnd < s.len and s[nameEnd] notin {'=', ' ', '\t', '\n', '\r'}: inc nameEnd
    let name = s[i ..< nameEnd]
    i = nameEnd
    if name.len == 0:
      inc i
      continue
    # Skip whitespace before a possible '='.
    var j = i
    while j < s.len and s[j] in {' ', '\t', '\n', '\r'}: inc j
    if j >= s.len or s[j] != '=':
      # Valueless attribute -> boolean true.
      result.add ComponentProp(name: name, kind: pvkBool, strVal: "true", boolVal: true)
      i = j
      continue
    inc j # consume '='
    while j < s.len and s[j] in {' ', '\t', '\n', '\r'}: inc j
    if j < s.len and (s[j] == '"' or s[j] == '\''):
      let quote = s[j]
      inc j
      let valStart = j
      while j < s.len and s[j] != quote: inc j
      let raw = s[valStart ..< j]
      if j < s.len: inc j # consume closing quote
      result.add ComponentProp(name: name, kind: pvkString, strVal: raw)
      i = j
    else:
      let valStart = j
      while j < s.len and s[j] notin {' ', '\t', '\n', '\r'}: inc j
      let raw = s[valStart ..< j]
      i = j
      if raw.len == 0:
        result.add ComponentProp(name: name, kind: pvkBool, strVal: "true", boolVal: true)
      elif raw == "true" or raw == "false":
        result.add ComponentProp(name: name, kind: pvkBool, strVal: raw, boolVal: raw == "true")
      else:
        var isInt = raw.len > 0
        var k = 0
        if raw[0] == '-' or raw[0] == '+':
          k = 1
          if raw.len == 1: isInt = false
        while k < raw.len:
          if raw[k] notin Digits: isInt = false; break
          inc k
        if isInt:
          var n = 0
          try: n = parseInt(raw)
          except ValueError: isInt = false
          if isInt:
            result.add ComponentProp(name: name, kind: pvkInt, strVal: raw, intVal: n)
          else:
            result.add ComponentProp(name: name, kind: pvkString, strVal: raw)
        else:
          result.add ComponentProp(name: name, kind: pvkString, strVal: raw)

# --- metacraft-theme-parity M2: content-component directive parsing ------

proc directiveName(strippedLine: string): string =
  ## The lowercased first token after `:::` on a directive line (already
  ## `strip`ped, known to start with `:::`). "" for a bare `:::`.
  let spec = strippedLine[3 .. ^1].strip()
  var sp = 0
  while sp < spec.len and spec[sp] notin {' ', '\t'}: inc sp
  spec[0 ..< sp].toLowerAscii()

proc directiveArgs(strippedLine: string): string =
  ## The attribute run after the directive name on a `:::name args...`
  ## line -- fed to `parseComponentProps` for `name="value"` pairs.
  let spec = strippedLine[3 .. ^1].strip()
  var sp = 0
  while sp < spec.len and spec[sp] notin {' ', '\t'}: inc sp
  spec[sp .. ^1].strip()

proc isDirectiveMarker(strippedLine, name: string): bool =
  ## True when `strippedLine` opens the directive `:::name` (with the name
  ## followed by whitespace or the end of line), e.g. `:::card ...`.
  let m = ":::" & name
  strippedLine.len >= m.len and strippedLine[0 ..< m.len] == m and
    (strippedLine.len == m.len or strippedLine[m.len] in {' ', '\t'})

proc parseBodyParagraphs(bodyLines: seq[string]; sourceRelPath: string;
                         resolveContentPath: proc(contentRelPath: string): string {.closure.};
                         resolveSymbol: proc(sym: string): string {.closure.}): seq[seq[InlineSpan]] =
  ## Splits a directive body into blank-line-separated paragraphs of inline
  ## spans -- the same shape `bkAdmonition.bodyParagraphs` uses, reused for
  ## card descriptions and FAQ answers.
  var currentLines: seq[string] = @[]
  for raw in bodyLines:
    let s = raw.strip()
    if s.len == 0:
      if currentLines.len > 0:
        result.add parseInlineSpans(currentLines.join(" "), sourceRelPath, resolveContentPath, resolveSymbol)
        currentLines = @[]
    else:
      currentLines.add s
  if currentLines.len > 0:
    result.add parseInlineSpans(currentLines.join(" "), sourceRelPath, resolveContentPath, resolveSymbol)

proc normalizeVariant(v: string): string =
  ## Buttons are either "secondary" (white) or "primary" (black, the
  ## default) -- any other/absent value normalizes to "primary".
  if v.strip().toLowerAscii() == "secondary": "secondary" else: "primary"

proc normalizeCardVariant(v: string): string =
  ## metacraft-theme-parity M6: a `:::cards` grid is either the default
  ## category-card look ("" -- the pre-M6 behaviour) or the "compact"
  ## WebFlow popular-article-card look. Any other/absent value normalizes to
  ## "" so an existing (or typo'd) `:::cards` renders byte-for-byte as today.
  if v.strip().toLowerAscii() == "compact": "compact" else: ""

proc extractYouTubeId*(s: string): string =
  ## metacraft-theme-parity M3: pulls the YouTube video id out of a bare id,
  ## a `watch?v=` URL, a `youtu.be/` short URL, or an `/embed/` URL. A bare
  ## (URL-less) token is returned as-is -- it is already an id; an
  ## unrecognized URL yields "" so the renderer degrades to an empty wrapper
  ## rather than a broken embed. Pure (no `std/uri`), so it is identical on
  ## the C and JS targets.
  let v = s.strip()
  if v.len == 0: return ""
  if v.contains("youtube.com") or v.contains("youtu.be") or
     v.contains("youtube-nocookie.com"):
    let vi = v.find("v=")
    if vi >= 0:
      var j = vi + 2
      while j < v.len and v[j] notin {'&', '#'}: inc j
      return v[vi + 2 ..< j]
    for marker in ["/embed/", "youtu.be/", "/v/"]:
      let mi = v.find(marker)
      if mi >= 0:
        let st = mi + marker.len
        var j = st
        while j < v.len and v[j] notin {'?', '&', '/', '#'}: inc j
        return v[st ..< j]
    return ""
  v

proc parseVideoDirective(args: string): tuple[id, src, title: string] =
  ## metacraft-theme-parity M3: parses a `:::video` directive's arguments --
  ## an optional leading bare token (a YouTube id or URL), plus optional
  ## `src="..."` / `id="..."` / `title="..."` props. `src` (when given) is
  ## used verbatim as the iframe source; otherwise the resolved id drives a
  ## privacy-friendly youtube-nocookie embed. Malformed input never raises;
  ## it degrades to empty fields.
  var a = args.strip()
  var bare = ""
  if a.len > 0 and a[0] notin {'"', '\''}:
    var sp = 0
    while sp < a.len and a[sp] notin {' ', '\t'}: inc sp
    let tok = a[0 ..< sp]
    # A leading token is a bare id/URL unless it looks like a `name=value`
    # prop -- i.e. the text before its first `=` is a valid attribute name.
    # A URL (`https://...watch?v=ID`) contains `=` yet its pre-`=` segment
    # holds `:`/`/`/`?`, so it is correctly treated as a bare arg.
    var isProp = false
    let eq = tok.find('=')
    if eq > 0:
      isProp = true
      for ch in tok[0 ..< eq]:
        if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '-'}:
          isProp = false
          break
    if not isProp:
      bare = tok
      a = a[sp .. ^1].strip()
  let props = parseComponentProps(a)
  let src = props.getStr("src")
  let idProp = props.getStr("id")
  let title = props.getStr("title")
  let id =
    if idProp.len > 0: extractYouTubeId(idProp)
    elif bare.len > 0: extractYouTubeId(bare)
    else: ""
  (id, src, title)

proc parseCardItems(bodyLines: seq[string]; sourceRelPath: string;
                    resolveContentPath: proc(contentRelPath: string): string {.closure.};
                    resolveSymbol: proc(sym: string): string {.closure.}): seq[CardItem] =
  ## Parses the body of a `:::cards` block into `:::card`-delimited items; a
  ## new `:::card` marker implicitly closes the previous card (mirroring how
  ## `@tab` delimits tab panels), so no per-card closing `:::` is required.
  var cur: CardItem
  var have = false
  var itemLines: seq[string] = @[]
  template flush() =
    if have:
      cur.body = parseBodyParagraphs(itemLines, sourceRelPath, resolveContentPath, resolveSymbol)
      result.add cur
  for raw in bodyLines:
    let s = raw.strip()
    if isDirectiveMarker(s, "card"):
      flush()
      let props = parseComponentProps(directiveArgs(s))
      cur = CardItem(title: props.getStr("title"), icon: props.getStr("icon"),
                     href: props.getStr("href"))
      have = true
      itemLines = @[]
    else:
      itemLines.add raw
  flush()

proc parseButtonSpecs(bodyLines: seq[string]): seq[ButtonSpec] =
  ## Parses `:::button`-delimited action buttons out of a `:::hero` body;
  ## a button's label is its body text.
  var cur: ButtonSpec
  var have = false
  var labelLines: seq[string] = @[]
  template flush() =
    if have:
      cur.label = labelLines.join(" ").strip()
      result.add cur
  for raw in bodyLines:
    let s = raw.strip()
    if isDirectiveMarker(s, "button"):
      flush()
      let props = parseComponentProps(directiveArgs(s))
      cur = ButtonSpec(href: props.getStr("href"),
                       variant: normalizeVariant(props.getStr("variant")))
      have = true
      labelLines = @[]
    elif s.len > 0:
      labelLines.add s
  flush()

proc parseFaqItems(bodyLines: seq[string]; sourceRelPath: string;
                   resolveContentPath: proc(contentRelPath: string): string {.closure.};
                   resolveSymbol: proc(sym: string): string {.closure.}): seq[FaqItem] =
  ## Parses the body of a `:::faq` block into `:::q title="…"` items; a new
  ## `:::q` marker implicitly closes the previous question.
  var cur: FaqItem
  var have = false
  var itemLines: seq[string] = @[]
  template flush() =
    if have:
      cur.answer = parseBodyParagraphs(itemLines, sourceRelPath, resolveContentPath, resolveSymbol)
      result.add cur
  for raw in bodyLines:
    let s = raw.strip()
    if isDirectiveMarker(s, "q"):
      flush()
      let props = parseComponentProps(directiveArgs(s))
      cur = FaqItem(question: props.getStr("title"))
      have = true
      itemLines = @[]
    else:
      itemLines.add raw
  flush()

proc parseFormFieldKind(t: string): FormFieldKind =
  ## Maps a `@field ... type=` token to a `FormFieldKind`. An unknown/absent
  ## type is a plain text input -- a typo never crashes the parser.
  case t.strip().toLowerAscii()
  of "email": ffkEmail
  of "password": ffkPassword
  of "textarea": ffkTextarea
  of "select": ffkSelect
  of "checkbox": ffkCheckbox
  else: ffkText

proc parseFormFields(bodyLines: seq[string]): seq[FormField] =
  ## Parses the body of a `:::form` block into `@field ...` items. Each field
  ## line's attributes are `name`, `label`, `type`, `placeholder`,
  ## `options="a,b,c"` (for a `select`), and a valueless `required`. A line that
  ## is not an `@field` (blank, stray text) is ignored rather than raising --
  ## hand-authored markup never crashes the parser.
  for raw in bodyLines:
    let s = raw.strip()
    if s.len == 0: continue
    if not (s.startsWith("@field") and (s.len == 6 or s[6] in {' ', '\t'})):
      continue
    let props = parseComponentProps(s[6 .. ^1].strip())
    var options: seq[string] = @[]
    let optRaw = props.getStr("options")
    if optRaw.len > 0:
      for part in optRaw.split(','):
        let trimmed = part.strip()
        if trimmed.len > 0: options.add trimmed
    result.add FormField(
      name: props.getStr("name"),
      label: props.getStr("label"),
      placeholder: props.getStr("placeholder"),
      kind: parseFormFieldKind(props.getStr("type")),
      options: options,
      required: props.getBool("required"))

proc startsAnotherBlock(line: string): bool =
  ## Whether `line` (already stripped) begins a *different* block kind,
  ## so paragraph accumulation knows where to stop even without a
  ## blank-line separator.
  line.startsWith("```") or line.startsWith(":::") or
    isUnorderedListItem(line) or isOrderedListItem(line) or
    isTableRow(line) or headingMarkerLevel(line) > 0 or
    isComponentTagLine(line)

proc parseMarkdownBlocks*(body: string; sourceRelPath: string = "";
                           resolveContentPath: proc(contentRelPath: string): string {.closure.} = nil;
                           resolveSymbol: proc(sym: string): string {.closure.} = nil;
                           isComponentKnown: proc(name: string): bool {.closure.} = nil;
                           knownDirective: proc(name: string): bool {.closure.} = nil;
                           renderDirective: proc(name, args, body: string): seq[Block] {.closure.} = nil): seq[Block] =
  ## Pure block-level parser over already-loaded body text (no
  ## filesystem access). A caller that keeps the page title as metadata
  ## (isonim-docs strips a page's leading `# Title` line first) passes
  ## the rest of the body, so its heading tree starts at H2.
  ## `resolveContentPath`/`resolveSymbol` are passed straight through to
  ## `parseInlineSpans` for every inline span this parses.
  ## `knownDirective`/`renderDirective` (built by `directives.nim` from
  ## registered directive renderers; nil by default) let a registered custom
  ## `:::name args ... :::` directive be recognised and rendered into
  ## `Block`s in place -- checked BEFORE the built-in admonition handling
  ## so a plugin can define its own `:::` block, but AFTER `:::tabs`, which
  ## stays a built-in.
  let lines = body.splitLines()
  var anchorReg = newAnchorIdRegistry()
  var i = 0
  while i < lines.len:
    let stripped = lines[i].strip()
    if stripped.len == 0:
      inc i
      continue

    if stripped.startsWith("```"):
      let lang = stripped[3 .. ^1].strip()
      inc i
      var codeLines: seq[string] = @[]
      while i < lines.len and lines[i].strip() != "```":
        codeLines.add lines[i]
        inc i
      if i < lines.len: inc i
      result.add Block(kind: bkCodeFence, lang: lang, code: codeLines.join("\n"))
      continue

    if stripped.startsWith(":::") and stripped[3 .. ^1].strip().toLowerAscii() == "tabs":
      inc i
      var tabs: seq[TabPanel] = @[]
      var title = ""
      var panelLines: seq[string] = @[]
      var haveTab = false
      template flushTab() =
        if haveTab:
          tabs.add TabPanel(title: title,
            blocks: parseMarkdownBlocks(panelLines.join("\n"), sourceRelPath, resolveContentPath, resolveSymbol, isComponentKnown, knownDirective, renderDirective))
      while i < lines.len and lines[i].strip() != ":::":
        let rawLine = lines[i]
        let lineStripped = rawLine.strip()
        if lineStripped.startsWith("@tab") and
            (lineStripped.len == 4 or lineStripped[4] == ' '):
          flushTab()
          title = lineStripped[4 .. ^1].strip()
          panelLines = @[]
          haveTab = true
        else:
          panelLines.add rawLine
        inc i
      flushTab()
      if i < lines.len: inc i
      result.add Block(kind: bkTabs, tabs: tabs)
      continue

    ## metacraft-theme-parity M2: content components. Each is a built-in
    ## `:::name` block handled BEFORE the plugin-directive / admonition
    ## fallbacks (exactly like `:::tabs`), reading its raw body up to the
    ## matching bare `:::` closer. Every one emits nothing unless authored,
    ## so the framework default output is unchanged.
    if stripped.startsWith(":::") and directiveName(stripped) == "cards":
      let gridProps = parseComponentProps(directiveArgs(stripped))
      inc i
      var bodyLines: seq[string] = @[]
      while i < lines.len and lines[i].strip() != ":::":
        bodyLines.add lines[i]
        inc i
      if i < lines.len: inc i
      result.add Block(kind: bkCardGrid,
        cards: parseCardItems(bodyLines, sourceRelPath, resolveContentPath, resolveSymbol),
        gridVariant: normalizeCardVariant(gridProps.getStr("variant")))
      continue

    if stripped.startsWith(":::") and directiveName(stripped) == "hero":
      let heroProps = parseComponentProps(directiveArgs(stripped))
      inc i
      var bodyLines: seq[string] = @[]
      while i < lines.len and lines[i].strip() != ":::":
        bodyLines.add lines[i]
        inc i
      if i < lines.len: inc i
      result.add Block(kind: bkHero,
        heroTitle: heroProps.getStr("title"),
        heroSubtitle: heroProps.getStr("subtitle"),
        heroButtons: parseButtonSpecs(bodyLines))
      continue

    if stripped.startsWith(":::") and directiveName(stripped) == "button":
      let btnProps = parseComponentProps(directiveArgs(stripped))
      inc i
      var labelLines: seq[string] = @[]
      while i < lines.len and lines[i].strip() != ":::":
        let ls = lines[i].strip()
        if ls.len > 0: labelLines.add ls
        inc i
      if i < lines.len: inc i
      result.add Block(kind: bkButton, button: ButtonSpec(
        href: btnProps.getStr("href"),
        variant: normalizeVariant(btnProps.getStr("variant")),
        label: labelLines.join(" ").strip()))
      continue

    if stripped.startsWith(":::") and directiveName(stripped) == "faq":
      inc i
      var bodyLines: seq[string] = @[]
      while i < lines.len and lines[i].strip() != ":::":
        bodyLines.add lines[i]
        inc i
      if i < lines.len: inc i
      result.add Block(kind: bkFaq,
        faqItems: parseFaqItems(bodyLines, sourceRelPath, resolveContentPath, resolveSymbol))
      continue

    if stripped.startsWith(":::") and directiveName(stripped) == "form":
      ## metacraft-theme-parity: a `:::form action="…" method="…" submit="…"`
      ## block whose body is a run of `@field ...` lines (mirroring how `:::faq`
      ## delimits its `:::q` items), read up to the matching bare `:::` closer.
      let formProps = parseComponentProps(directiveArgs(stripped))
      inc i
      var bodyLines: seq[string] = @[]
      while i < lines.len and lines[i].strip() != ":::":
        bodyLines.add lines[i]
        inc i
      if i < lines.len: inc i
      let submit = formProps.getStr("submit")
      result.add Block(kind: bkForm,
        formAction: formProps.getStr("action"),
        formMethod: formProps.getStr("method"),
        formSubmit: (if submit.len > 0: submit else: "Submit"),
        formFields: parseFormFields(bodyLines))
      continue

    if stripped.startsWith(":::") and directiveName(stripped) == "video":
      ## metacraft-theme-parity M3: a `:::video <id|url>` (or `src="..."`)
      ## single-line embed directive. The arguments live on the directive
      ## line itself -- there is no body and no closing `:::`, so only this
      ## one line is consumed (unlike the block directives above).
      let (vid, vsrc, vtitle) = parseVideoDirective(directiveArgs(stripped))
      inc i
      result.add Block(kind: bkVideo, videoId: vid, videoSrc: vsrc, videoTitle: vtitle)
      continue

    if isComponentTagLine(stripped):
      ## M9 deliverable 1: extract a custom component tag as its own block.
      ## The opening tag is normally all on one line; gather following
      ## lines only if its closing `>` hasn't been seen yet.
      var lookahead = i
      var openLine = stripped
      while openLine.find('>') < 0 and lookahead + 1 < lines.len:
        inc lookahead
        openLine = openLine & " " & lines[lookahead].strip()
      let gt = openLine.find('>')
      if gt >= 0:
        i = lookahead
        let selfClosing = gt >= 1 and openLine[gt - 1] == '/'
        let bodyEnd = if selfClosing: gt - 1 else: gt
        let tagBody = openLine[1 ..< bodyEnd]
        var ni = 0
        while ni < tagBody.len and tagBody[ni] notin {' ', '\t', '/', '>'}: inc ni
        let name = tagBody[0 ..< ni]
        let props = parseComponentProps(tagBody[ni .. ^1])
        var children = ""
        if not selfClosing:
          let closeTag = "</" & name & ">"
          var collected: seq[string] = @[]
          let afterGt = openLine[gt + 1 .. ^1]
          let inlineClose = afterGt.find(closeTag)
          if inlineClose >= 0:
            collected.add afterGt[0 ..< inlineClose]
          else:
            if afterGt.len > 0: collected.add afterGt
            inc i
            while i < lines.len:
              let idx = lines[i].find(closeTag)
              if idx >= 0:
                collected.add lines[i][0 ..< idx]
                break
              collected.add lines[i]
              inc i
          children = collected.join("\n").strip()
        inc i
        let known = isComponentKnown == nil or isComponentKnown(name)
        result.add Block(kind: bkComponent, componentName: name, props: props,
          componentChildren: children,
          componentError: (if known: "" else: "unknown component: " & name))
        continue

    if stripped.startsWith(":::"):
      ## M11 deliverable 1: a plugin-registered custom directive shadows
      ## the built-in admonition fallback below (but never `:::tabs`, which
      ## was already handled and `continue`d above). The first token after
      ## `:::` is the directive name; the rest of the line is its `args`;
      ## the raw text up to the closing `:::` is its `body`. Unknown
      ## `:::name`s fall through to the admonition handling unchanged.
      let spec = stripped[3 .. ^1].strip()
      var sp = 0
      while sp < spec.len and spec[sp] notin {' ', '\t'}: inc sp
      let dName = spec[0 ..< sp]
      let dArgs = spec[sp .. ^1].strip()
      if knownDirective != nil and renderDirective != nil and knownDirective(dName):
        inc i
        var dBody: seq[string] = @[]
        while i < lines.len and lines[i].strip() != ":::":
          dBody.add lines[i]
          inc i
        if i < lines.len: inc i
        result.add renderDirective(dName, dArgs, dBody.join("\n"))
        continue

    if stripped.startsWith(":::"):
      let kindStr = stripped[3 .. ^1].strip().toLowerAscii()
      let admonitionKind =
        case kindStr
        of "warning": akWarning
        of "tip": akTip
        of "important": akImportant  ## M3 (Gap D)
        of "caution": akCaution      ## M3 (Gap D)
        of "danger": akDanger
        else: akNote
      inc i
      var paragraphs: seq[seq[InlineSpan]] = @[]
      var currentLines: seq[string] = @[]
      while i < lines.len and lines[i].strip() != ":::":
        let bodyLine = lines[i].strip()
        if bodyLine.len == 0:
          if currentLines.len > 0:
            paragraphs.add parseInlineSpans(currentLines.join(" "), sourceRelPath, resolveContentPath, resolveSymbol)
            currentLines = @[]
        else:
          currentLines.add bodyLine
        inc i
      if currentLines.len > 0:
        paragraphs.add parseInlineSpans(currentLines.join(" "), sourceRelPath, resolveContentPath, resolveSymbol)
      if i < lines.len: inc i
      result.add Block(kind: bkAdmonition, admonitionKind: admonitionKind, bodyParagraphs: paragraphs)
      continue

    let level = headingMarkerLevel(stripped)
    if level > 0:
      let headingText = stripped[level + 1 .. ^1].strip()
      let headingId = anchorReg.nextId(headingText)
      result.add Block(kind: bkHeading, level: level, headingText: headingText, headingId: headingId)
      inc i
      continue

    if isTableRow(stripped) and i + 1 < lines.len and isTableSeparatorRow(lines[i + 1]):
      let headers = splitTableRow(stripped)
      i += 2
      var rows: seq[seq[string]] = @[]
      while i < lines.len and isTableRow(lines[i].strip()):
        rows.add splitTableRow(lines[i])
        inc i
      result.add Block(kind: bkTable, headers: headers, rows: rows)
      continue

    if isUnorderedListItem(stripped) or isOrderedListItem(stripped):
      let ordered = isOrderedListItem(stripped)
      var items: seq[seq[InlineSpan]] = @[]
      while i < lines.len:
        let itemLine = lines[i].strip()
        if itemLine.len == 0: break
        if ordered != isOrderedListItem(itemLine): break
        if not ordered and not isUnorderedListItem(itemLine): break
        items.add parseInlineSpans(listItemText(itemLine), sourceRelPath, resolveContentPath, resolveSymbol)
        inc i
      result.add Block(kind: bkList, listKind: (if ordered: lkOrdered else: lkUnordered), items: items)
      continue

    var paraLines: seq[string] = @[stripped]
    inc i
    while i < lines.len:
      let nextStripped = lines[i].strip()
      if nextStripped.len == 0 or startsAnotherBlock(nextStripped): break
      paraLines.add nextStripped
      inc i
    result.add Block(kind: bkParagraph, spans: parseInlineSpans(paraLines.join(" "), sourceRelPath, resolveContentPath, resolveSymbol))

proc buildHeadingTree*(flat: seq[HeadingNode]): seq[HeadingNode] =
  ## Nests a flat, in-order heading list into a tree: a heading becomes
  ## a child of the nearest preceding heading with a strictly lower
  ## level, regardless of how many levels are skipped. `idx` is threaded
  ## through the recursive descent by `var` so each nesting level
  ## resumes exactly where its parent (or the top level) left off; a
  ## `seq` index rather than a pointer into `flat`, since `HeadingNode`
  ## is a value type and a growing result `seq` would invalidate
  ## pointers into it.
  proc build(idx: var int; minLevel: int): seq[HeadingNode] =
    while idx < flat.len and flat[idx].level >= minLevel:
      var node = flat[idx]
      let level = node.level
      inc idx
      node.children = build(idx, level + 1)
      result.add node
  var idx = 0
  build(idx, 1)

proc parseMarkdownDoc*(body: string; sourceRelPath: string = "";
                        resolveContentPath: proc(contentRelPath: string): string {.closure.} = nil;
                        resolveSymbol: proc(sym: string): string {.closure.} = nil;
                        isComponentKnown: proc(name: string): bool {.closure.} = nil;
                        knownDirective: proc(name: string): bool {.closure.} = nil;
                        renderDirective: proc(name, args, body: string): seq[Block] {.closure.} = nil): MarkdownDoc =
  ## The one entry point later callers (the markdown page ViewModel
  ## builder, `test_markdown_vm.nim`, M3's `references.nim`) use: parses
  ## the body into blocks, then derives the heading tree from the
  ## headings found among them. `resolveContentPath`/`resolveSymbol` are
  ## passed straight through to `parseMarkdownBlocks` (see M8 deliverable 2
  ## for the `[[sym:...]]` cross-reference `resolveSymbol` resolves).
  let blocks = parseMarkdownBlocks(body, sourceRelPath, resolveContentPath, resolveSymbol, isComponentKnown, knownDirective, renderDirective)
  var flat: seq[HeadingNode] = @[]
  for blk in blocks:
    if blk.kind == bkHeading:
      flat.add HeadingNode(level: blk.level, text: blk.headingText, id: blk.headingId)
  MarkdownDoc(blocks: blocks, headingTree: buildHeadingTree(flat))
