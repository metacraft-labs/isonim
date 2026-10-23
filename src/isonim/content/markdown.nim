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

import std/[strutils, algorithm]
import ./anchors
import ./fragments
export fragments
type
  SourceLocation* = object
    ## One-based line in the supplied source body; loaders may offset it.
    path*: string
    line*: int

  ContentRenderers* = object
    ## Two optional build-time seams. Empty callbacks leave syntax literal;
    ## configured callbacks must return a fragment or raise with provenance.
    math*: proc(tex: string; display: bool; location: SourceLocation): ContentFragment {.closure.}
    diagram*: proc(language, source: string; location: SourceLocation): ContentFragment {.closure.}

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
    ikStrike
    ikFootnoteRef

  LinkOrigin* = enum
    loUnspecified ## Programmatically constructed span; `text` supplies its label.
    loExplicit ## `[label](destination)` or `![alt](destination)`.
    loAngleAutolink
    loBareAutolink

  InlineSpan* = object
    ## One inline run within a paragraph/list-item/admonition-paragraph.
    ## `text` is the display text (or the alt text, for `ikImage`; the
    ## symbol query, for `ikSymRef`); `href` is the link/image/symbol-anchor
    ## target after `normalizeRelativeLink`/`resolveSymbol`.
    kind*: InlineKind
    generated*: ContentFragment ## Optional validated math; `text` retains TeX.
    text*: string
    href*: string
    title*: string ## Optional link/image title, separate from the destination.
    linkOrigin*: LinkOrigin
    labelSource*: string ## Original explicit label, including escape intent.
    children*: seq[InlineSpan] ## Parsed contents of `ikStrike`.
    footnoteNumber*: int ## Zero until a document resolves its definitions.
    referenceId*: string ## Unique anchor for this footnote occurrence.
    escaped*: bool ## Literal punctuation, not another consumer's emphasis run.
    isRelative*: bool ## True when the original markdown target was a
                      ## relative path (content link or asset), not an
                      ## absolute URL or same-page fragment -- the flag
                      ## later broken-link reporting filters on.

  ListKind* = enum
    lkUnordered
    lkOrdered

  TaskState* = enum
    tsNone, tsUnchecked, tsChecked

  DiffLineKind* = enum
    dlAdded, dlRemoved

  DiffLine* = object
    line*: int ## One-based line in the original, unmodified code.
    kind*: DiffLineKind

  FenceAttributes* = object
    title*: string
    highlightLines*: seq[int]
    diff*: bool
    diffLines*: seq[DiffLine]

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
    bkBlockquote
    bkFigure
    bkFootnotes
    bkExcerptBreak

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
    ## One parsed body-level markdown block. Headings retain their original
    ## text for legacy consumers and context-resolved spans for semantic
    ## rendering. Their stable ID is assigned once by the document parser.
    case kind*: BlockKind
    of bkHeading:
      level*: int
      headingText*: string
      headingId*: string
      headingSpans*: seq[InlineSpan] ## Resolved with the document's source context.
    of bkParagraph:
      spans*: seq[InlineSpan]
    of bkList:
      listKind*: ListKind
      items*: seq[seq[InlineSpan]]
      tasks*: seq[TaskState] ## Empty for legacy lists; otherwise parallels items.
    of bkCodeFence:
      lang*: string
      code*: string
      fenceAttrs*: FenceAttributes
      generated*: ContentFragment ## Optional build-time math or diagram output.
    of bkAdmonition:
      admonitionKind*: AdmonitionKind
      bodyParagraphs*: seq[seq[InlineSpan]]
    of bkTable:
      headers*: seq[string]
      rows*: seq[seq[string]]
      headerSpans*: seq[seq[InlineSpan]] ## Populated only for opt-in math.
      cellSpans*: seq[seq[seq[InlineSpan]]]
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
    of bkBlockquote:
      quoteBlocks*: seq[Block]
    of bkFigure:
      figureImage*: InlineSpan
      caption*: seq[InlineSpan]
    of bkFootnotes:
      footnotes*: seq[Footnote]
    of bkExcerptBreak:
      discard

  Footnote* = object
    label*: string
    number*: int
    id*: string
    blocks*: seq[Block]
    referenceIds*: seq[string]

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
    excerpt*: seq[Block]

  ParseContext = ref object
    anchors: AnchorIdRegistry
    definitions: seq[Footnote]
    footnotes: bool
    renderers: ContentRenderers

func `==`*(a, b: InlineSpan): bool =
  ## Explicit recursive equality keeps the public value API usable on Nim
  ## 2.2: its synthesized object/seq equality can infer a spurious side effect
  ## when an individual recursive span is compared before a seq of spans.
  if a.generated != b.generated or a.kind != b.kind or a.text != b.text or a.href != b.href or
      a.title != b.title or a.isRelative != b.isRelative or
      a.linkOrigin != b.linkOrigin or a.labelSource != b.labelSource or
      a.footnoteNumber != b.footnoteNumber or a.referenceId != b.referenceId or
      a.escaped != b.escaped or a.children.len != b.children.len:
    return false
  for i in 0 ..< a.children.len:
    if a.children[i] != b.children[i]: return false
  true

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
  let colon = href.find(':')
  if colon > 0 and href[0] in Letters:
    var scheme = true
    for ch in href[1 ..< colon]:
      if ch notin Letters + Digits + {'+', '-', '.'}: scheme = false
    if scheme: return true
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

proc tickRun(text: string; start: int): int =
  var stop = start
  while stop < text.len and text[stop] == '`': inc stop
  stop - start

proc codeSpanEnd(text: string; start, width: int): int =
  ## CommonMark 0.31.2 §6.1: delimiters are maximal runs of equal length.
  ## https://spec.commonmark.org/0.31.2/#code-spans
  var pos = start + width
  while pos < text.len:
    if text[pos] == '`':
      let size = tickRun(text, pos)
      if size == width: return pos
      pos += size
    else: inc pos
  -1

proc codeSpanText(text: string): string =
  result = text.replace("\r\n", " ").replace('\r', ' ').replace('\n', ' ')
  if result.len >= 2 and result[0] == ' ' and result[^1] == ' ' and
      result.strip(chars = {' '}).len > 0:
    result = result[1 ..< result.len - 1]

proc closingBracket(text: string; start: int): int =
  ## Code binds more tightly than link labels, so a bracket inside a matched
  ## code span must not close the label. Escapes and nested brackets obey the
  ## same boundary rule without attempting a separate inline parser here.
  var depth = 0
  var i = start
  while i < text.len:
    if text[i] == '\\' and i + 1 < text.len:
      i += 2
      continue
    if text[i] == '`':
      let width = tickRun(text, i)
      let close = codeSpanEnd(text, i, width)
      if close >= 0:
        i = close + width
        continue
      i += width
      continue
    if text[i] == '[': inc depth
    elif text[i] == ']':
      if depth == 0: return i
      dec depth
    inc i
  -1

proc unescapePunctuation(text: string): string =
  var i = 0
  while i < text.len:
    if text[i] == '\\' and i + 1 < text.len and text[i + 1] in PunctuationChars:
      inc i
    result.add text[i]
    inc i

proc linkTarget(text: string; start: int): tuple[stop: int, href, title: string] =
  ## Read after `(`, preserving balanced destination parentheses and keeping
  ## the optional quoted title out of the URL. Failure leaves source literal.
  result.stop = -1
  var i = start
  while i < text.len and text[i] in Whitespace: inc i
  let begin = i
  if i < text.len and text[i] == '<':
    inc i
    let content = i
    while i < text.len and text[i] != '>':
      if text[i] in {'\n', '\r', '<'}: return
      if text[i] == '\\' and i + 1 < text.len: inc i
      inc i
    if i == text.len: return
    result.href = unescapePunctuation(text[content ..< i])
    inc i
  else:
    var depth = 0
    while i < text.len:
      if text[i] == '\\' and i + 1 < text.len:
        i += 2
        continue
      if text[i] == '(':
        inc depth
      elif text[i] == ')':
        if depth == 0: break
        dec depth
      elif text[i] in Whitespace: break
      inc i
    if depth != 0: return
    result.href = unescapePunctuation(text[begin ..< i])
  let beforeSpace = i
  while i < text.len and text[i] in Whitespace: inc i
  if i > beforeSpace and i < text.len and text[i] in {'"', '\'', '('}:
    let closer = if text[i] == '(': ')' else: text[i]
    inc i
    let titleStart = i
    while i < text.len and text[i] != closer:
      if text[i] == '\\' and i + 1 < text.len: inc i
      inc i
    if i == text.len: return
    result.title = unescapePunctuation(text[titleStart ..< i])
    inc i
    while i < text.len and text[i] in Whitespace: inc i
  if i < text.len and text[i] == ')': result.stop = i + 1

proc emailAddress(text: string; requireDot = true): bool =
  let at = text.find('@')
  if at <= 0 or at == text.high or text.find('@', at + 1) >= 0: return false
  for c in text[0 ..< at]:
    if c notin Letters + Digits + {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~', '.'}: return false
  let domain = text[at + 1 .. ^1]
  if requireDot and '.' notin domain: return false
  for part in domain.split('.'):
    if part.len == 0 or part[0] == '-' or part[^1] == '-': return false
    for c in part:
      if c notin Letters + Digits + {'-'}: return false
  true

proc autoTarget(text: string): string =
  if text.len == 0: return ""
  for c in text:
    if c in Whitespace or c in {'<', '>'}: return ""
  if emailAddress(text, requireDot = false): return "mailto:" & text
  let colon = text.find(':')
  if colon >= 2 and colon <= 32 and text[0] in Letters:
    for c in text[1 ..< colon]:
      if c notin Letters + Digits + {'+', '-', '.'}: return ""
    return text

proc bareAutolink(text: string; start: int): tuple[stop: int, href: string] =
  result.stop = start
  if start > 0 and text[start - 1] notin Whitespace + {'(', '[', '*', '_', '~'}: return
  var stop = start
  while stop < text.len and text[stop] notin Whitespace + {'<', '>', '"', '\'', '`'}:
    inc stop
  # GFM excludes terminal punctuation and unmatched closing parentheses.
  while stop > start:
    if text[stop - 1] in {'.', ',', ':', ';', '!', '?', ']', '}'}:
      dec stop
    elif text[stop - 1] == ')' and text[start ..< stop].count(')') > text[start ..< stop].count('('):
      dec stop
    else: break
  let value = text[start ..< stop]
  if value.startsWith("http://") or value.startsWith("https://") or value.startsWith("www."):
    let hostStart = if value.startsWith("www."): 0 else: value.find("://") + 3
    let hostEnd = value.find('/', hostStart)
    let host = if hostEnd < 0: value[hostStart .. ^1] else: value[hostStart ..< hostEnd]
    if host.len == 0 or (value.startsWith("www.") and host.count('.') < 2): return
    result = (stop, if value.startsWith("www."): "http://" & value else: value)
  elif emailAddress(value): result = (stop, "mailto:" & value)

proc explicitLink(text: string; start: int):
    tuple[stop: int, label, href, title: string, image: bool] =
  ## One recognition path for both the parser and its delimiter scanner: only
  ## a complete link/image protects its label, destination and title from an
  ## enclosing strike. A malformed construct remains ordinary inline input.
  result.stop = -1
  result.image = text.continuesWith("![", start)
  if not result.image and text[start] != '[': return
  let content = start + (if result.image: 2 else: 1)
  let close = closingBracket(text, content)
  if close < 0 or close + 1 >= text.len or text[close + 1] != '(': return
  let target = linkTarget(text, close + 2)
  if target.stop < 0: return
  result.stop = target.stop
  result.label = text[content ..< close]
  result.href = target.href
  result.title = target.title

proc opaqueInlineEnd(text: string; start: int): int =
  ## A complete already-recognized inline token owns its internal punctuation.
  ## Reuse the token recognizers so strike cannot mistake a URL/title/code's
  ## `~~` for its own closing delimiter, while incomplete syntax stays literal.
  if text[start] == '`':
    let width = tickRun(text, start)
    let close = codeSpanEnd(text, start, width)
    if close >= 0: return close + width
  if text.continuesWith("[[sym:", start):
    let close = text.find("]]", start + 6)
    if close >= 0: return close + 2
  if text.continuesWith("[^", start):
    let close = text.find(']', start + 2)
    if close > start + 2 and text[start + 2 ..< close].find(Whitespace) < 0:
      return close + 1
  let link = explicitLink(text, start)
  if link.stop >= 0: return link.stop
  if text[start] == '<':
    let close = text.find('>', start + 1)
    if close >= 0 and autoTarget(text[start + 1 ..< close]).len > 0:
      return close + 1
  let auto = bareAutolink(text, start)
  if auto.stop > start:
    # Bare links have no explicit closing bracket. A terminal pair can close
    # the enclosing strike; interior pairs stay in the URL. Authors can use
    # an angle/explicit link when the URL itself must end with two tildes.
    if auto.stop >= start + 3 and text.continuesWith("~~", auto.stop - 2) and
        text[auto.stop - 3] != '~': return auto.stop - 2
    return auto.stop
  start

proc contentError*(location: SourceLocation; message: string): ref ValueError =
  ## Shared location format for parser and native tool diagnostics.
  newException(ValueError, (if location.path.len > 0: location.path else: "<markdown>") &
    ":" & $location.line & ": " & message)

proc lineAt(text: string; stop, firstLine: int): int =
  result = firstLine
  for i in 0 ..< stop:
    if text[i] == '\n' or (text[i] == '\r' and (i + 1 == text.len or text[i + 1] != '\n')):
      inc result

proc mathEnd(text: string; start, width: int): int =
  ## Delimiters are recognized here, after the scanner has excluded literal
  ## code/escapes. TeX contents remain opaque to every Markdown rule.
  result = -1
  if start + width >= text.len: return
  if width == 1 and text[start + 1] in Whitespace + {'$'}: return
  var i = start + width
  while i < text.len:
    if text[i] == '\\' and i + 1 < text.len:
      i += 2
      continue
    if text[i] == '$':
      var run = 1
      while i + run < text.len and text[i + run] == '$': inc run
      if run == width:
        if i > start + width and (width == 2 or text[i - 1] notin Whitespace): return i
        return -1
      i += run
    else: inc i

proc requireFragment(fragment: ContentFragment; location: SourceLocation): ContentFragment =
  if fragment.isEmpty: raise contentError(location, "content renderer returned an empty fragment")
  fragment

proc parseInlineSpans*(text: string; sourceRelPath: string = "";
                        resolveContentPath: proc(contentRelPath: string): string {.closure.} = nil;
                        resolveSymbol: proc(sym: string): string {.closure.} = nil;
                        renderers: ContentRenderers = ContentRenderers();
                        firstLine: int = 1; literalLabel: bool = false): seq[InlineSpan] =
  ## Inline syntax is deliberately bounded: code, links/images with optional
  ## titles, symbol refs, strike and footnote refs, plus angle/bare autolinks.
  ## Unknown and unmatched syntax remains literal; raw HTML is never trusted.
  var i = 0
  var plain = ""
  template flushPlain() =
    if plain.len > 0:
      result.add InlineSpan(kind: ikText, text: plain)
      plain = ""
  while i < text.len:
    if text[i] in {'\n', '\r'}:
      plain = plain.strip(leading = false, trailing = true)
      plain.add ' '
      if text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n': inc i
      inc i
      while i < text.len and text[i] in {' ', '\t'}: inc i
      continue
    if text[i] == '\\' and i + 1 < text.len and text[i + 1] in PunctuationChars:
      flushPlain()
      result.add InlineSpan(kind: ikText, text: $text[i + 1], escaped: true)
      i += 2
      continue
    if text[i] == '`':
      let width = tickRun(text, i)
      let close = codeSpanEnd(text, i, width)
      if close >= 0:
        flushPlain()
        if literalLabel:
          result.add InlineSpan(kind: ikText, text: unescapePunctuation(text[i ..< close + width]))
        else:
          result.add InlineSpan(kind: ikCode, text: codeSpanText(text[i + width ..< close]))
        i = close + width
      else:
        plain.add text[i ..< i + width]
        i += width
      continue
    if text[i] == '$' and renderers.math != nil and
        (i == 0 or text[i - 1] != '$'):
      let width = if i + 1 < text.len and text[i + 1] == '$': 2 else: 1
      let close = mathEnd(text, i, width)
      if close >= 0:
        flushPlain()
        let location = SourceLocation(path: sourceRelPath, line: lineAt(text, i, firstLine))
        let tex = text[i + width ..< close]
        result.add InlineSpan(kind: ikText, text: tex,
          generated: requireFragment(renderers.math(tex, width == 2, location), location))
        i = close + width
        continue
    if literalLabel:
      plain.add text[i]
      inc i
      continue
    if text.continuesWith("[[sym:", i):
      let close = text.find("]]", i + 6)
      if close >= 0:
        flushPlain()
        let query = text[i + 6 ..< close].strip()
        let href = if resolveSymbol != nil: resolveSymbol(query) else: ""
        result.add InlineSpan(kind: ikSymRef, text: query, href: href, isRelative: href.len > 0)
        i = close + 2
        continue
    if text.continuesWith("[^", i):
      let close = text.find(']', i + 2)
      if close > i + 2:
        let label = text[i + 2 ..< close]
        if label.find({' ', '\t', '\n', '\r'}) < 0:
          flushPlain()
          result.add InlineSpan(kind: ikFootnoteRef, text: label)
          i = close + 1
          continue
    let link = explicitLink(text, i)
    if link.stop >= 0:
      flushPlain()
      let (href, relative) = normalizeRelativeLink(link.href, sourceRelPath, resolveContentPath)
      result.add InlineSpan(kind: (if link.image: ikImage else: ikLink),
        text: unescapePunctuation(link.label), href: href, title: link.title,
        isRelative: relative, linkOrigin: loExplicit, labelSource: link.label,
        children: (if not link.image and renderers.math != nil:
          parseInlineSpans(link.label, sourceRelPath, resolveContentPath, resolveSymbol,
            renderers, lineAt(text, i, firstLine), literalLabel = true) else: @[]))
      i = link.stop
      continue
    if text.continuesWith("~~", i) and (i == 0 or text[i - 1] != '~') and
        i + 2 < text.len and text[i + 2] notin Whitespace + {'~'}:
      var close = i + 2
      while close < text.len:
        if text[close] == '\\' and close + 1 < text.len:
          close += 2
          continue
        if text[close] == '$' and renderers.math != nil:
          let width = if close + 1 < text.len and text[close + 1] == '$': 2 else: 1
          let mathClose = mathEnd(text, close, width)
          if mathClose >= 0:
            close = mathClose + width
            continue
        let endToken = opaqueInlineEnd(text, close)
        if endToken > close:
          close = endToken
          continue
        if text.continuesWith("~~", close) and text[close - 1] notin Whitespace + {'~'} and
            (close + 2 == text.len or text[close + 2] != '~'): break
        inc close
      if close > i + 2 and close + 1 < text.len:
        flushPlain()
        let children = parseInlineSpans(text[i + 2 ..< close], sourceRelPath, resolveContentPath, resolveSymbol,
          renderers, lineAt(text, i + 2, firstLine))
        result.add InlineSpan(kind: ikStrike, text: spansText(children), children: children)
        i = close + 2
        continue
    if text[i] == '<':
      let close = text.find('>', i + 1)
      if close >= 0:
        let value = text[i + 1 ..< close]
        let href = autoTarget(value)
        if href.len > 0:
          flushPlain()
          result.add InlineSpan(kind: ikLink, text: value, href: href, linkOrigin: loAngleAutolink)
          i = close + 1
          continue
    let auto = bareAutolink(text, i)
    if auto.stop > i:
      flushPlain()
      result.add InlineSpan(kind: ikLink, text: text[i ..< auto.stop], href: auto.href, linkOrigin: loBareAutolink)
      i = auto.stop
      continue
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

proc splitTableRow(line: string; math = false): seq[string] =
  var s = line.strip()
  if s.startsWith("|"): s = s[1 .. ^1]
  if s.endsWith("|"): s = s[0 ..< ^1]
  if not math:
    for cell in s.split('|'): result.add cell.strip()
    return
  var start, i: int
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      i += 2
      continue
    let opaque = opaqueInlineEnd(s, i)
    if opaque > i:
      i = opaque
      continue
    if s[i] == '$':
      let width = if i + 1 < s.len and s[i + 1] == '$': 2 else: 1
      let close = mathEnd(s, i, width)
      if close >= 0:
        i = close + width
        continue
    if s[i] == '|':
      result.add s[start ..< i].strip()
      start = i + 1
    inc i
  result.add s[start .. ^1].strip()

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
  if line.len < 2 or line[0] != '<' or line[1] notin {'A' .. 'Z'}: return false
  let endAngle = line.find('>')
  if endAngle > 0 and autoTarget(line[1 ..< endAngle]).len > 0: return false
  true

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
                         resolveSymbol: proc(sym: string): string {.closure.};
                         renderers: ContentRenderers; firstLine: int): seq[seq[InlineSpan]] =
  ## Splits a directive body into blank-line-separated paragraphs of inline
  ## spans -- the same shape `bkAdmonition.bodyParagraphs` uses, reused for
  ## card descriptions and FAQ answers.
  var currentLines: seq[string] = @[]
  var paragraphLine = firstLine
  for index, raw in bodyLines:
    let s = raw.strip()
    if s.len == 0:
      if currentLines.len > 0:
        result.add parseInlineSpans(currentLines.join(if renderers.math == nil: " " else: "\n"), sourceRelPath, resolveContentPath, resolveSymbol, renderers, paragraphLine)
        currentLines = @[]
    else:
      if currentLines.len == 0: paragraphLine = firstLine + index
      currentLines.add s
  if currentLines.len > 0:
    result.add parseInlineSpans(currentLines.join(if renderers.math == nil: " " else: "\n"), sourceRelPath, resolveContentPath, resolveSymbol, renderers, paragraphLine)

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
                    resolveSymbol: proc(sym: string): string {.closure.};
                         renderers: ContentRenderers; firstLine: int): seq[CardItem] =
  ## Parses the body of a `:::cards` block into `:::card`-delimited items; a
  ## new `:::card` marker implicitly closes the previous card (mirroring how
  ## `@tab` delimits tab panels), so no per-card closing `:::` is required.
  var cur: CardItem
  var have = false
  var itemLine = firstLine
  var itemLines: seq[string] = @[]
  template flush() =
    if have:
      cur.body = parseBodyParagraphs(itemLines, sourceRelPath, resolveContentPath, resolveSymbol, renderers, itemLine)
      result.add cur
  for index, raw in bodyLines:
    let s = raw.strip()
    if isDirectiveMarker(s, "card"):
      flush()
      let props = parseComponentProps(directiveArgs(s))
      cur = CardItem(title: props.getStr("title"), icon: props.getStr("icon"),
                     href: props.getStr("href"))
      have = true
      itemLines = @[]
      itemLine = firstLine + index + 1
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
                   resolveSymbol: proc(sym: string): string {.closure.};
                         renderers: ContentRenderers; firstLine: int): seq[FaqItem] =
  ## Parses the body of a `:::faq` block into `:::q title="…"` items; a new
  ## `:::q` marker implicitly closes the previous question.
  var cur: FaqItem
  var have = false
  var itemLine = firstLine
  var itemLines: seq[string] = @[]
  template flush() =
    if have:
      cur.answer = parseBodyParagraphs(itemLines, sourceRelPath, resolveContentPath, resolveSymbol, renderers, itemLine)
      result.add cur
  for index, raw in bodyLines:
    let s = raw.strip()
    if isDirectiveMarker(s, "q"):
      flush()
      let props = parseComponentProps(directiveArgs(s))
      cur = FaqItem(question: props.getStr("title"))
      have = true
      itemLines = @[]
      itemLine = firstLine + index + 1
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

proc fenceWidth(line: string): int =
  if line.len == 0 or line[0] notin {'`', '~'}: return 0
  while result < line.len and line[result] == line[0]: inc result
  if result < 3: result = 0

proc closesFence(line: string; marker: char; width: int): bool =
  let s = line.strip()
  s.len >= width and s[0] == marker and fenceWidth(s) >= width and
    s[fenceWidth(s) .. ^1].strip().len == 0

proc fenceInfo(info: string; lineCount: int): tuple[lang: string, attrs: FenceAttributes] =
  var rest = info.strip()
  let firstSpace = rest.find({' ', '\t', '{'})
  if rest.len > 0 and rest[0] != '{' and not rest.startsWith("title="):
    let stop = if firstSpace < 0: rest.len else: firstSpace
    result.lang = rest[0 ..< stop]
    rest = rest[stop .. ^1].strip()
  # Limit expansions to existing lines: a malformed enormous range cannot
  # allocate arbitrarily, and highlighting a nonexistent line has no effect.
  var brace = -1
  var quote = '\0'
  for pos, ch in rest:
    if quote != '\0':
      if ch == quote: quote = '\0'
    elif ch in {'"', '\''}: quote = ch
    elif ch == '{':
      brace = pos
      break
  let close = if brace >= 0: rest.find('}', brace + 1) else: -1
  if close >= 0:
    for segment in rest[brace + 1 ..< close].split(','):
      let bounds = segment.strip().split('-')
      try:
        let first = parseInt(bounds[0])
        let last = if bounds.len == 2: parseInt(bounds[1]) else: first
        if bounds.len <= 2 and first > 0 and last >= first:
          for n in first .. min(last, lineCount):
            if n notin result.attrs.highlightLines: result.attrs.highlightLines.add n
      except ValueError: discard
    rest = rest[0 ..< brace] & rest[close + 1 .. ^1]
  result.attrs.highlightLines.sort()
  let props = parseComponentProps(rest)
  result.attrs.title = props.getStr("title")
  result.attrs.diff = props.getBool("diff")

proc footnoteDefinition(line: string): tuple[label, body: string] =
  if not line.startsWith("[^"): return
  let close = line.find("]:", 2)
  if close <= 2: return
  let label = line[2 ..< close]
  if label.find({' ', '\t', '\r', '\n'}) >= 0: return
  (label, line[close + 2 .. ^1].strip())

proc quoteLine(line: string): bool =
  line.startsWith(">")

proc italicCaption(line: string): bool =
  line.len > 2 and line[0] in {'*', '_'} and line[^1] == line[0] and
    line[1] != line[0] and line[^2] != line[0]

proc headingLabel*(spans: seq[InlineSpan]): string =
  ## Keep heading display compatibility while deriving anchors/ToC from the
  ## visible link/code text. Unparsed punctuation remains literal; in
  ## particular snake_case must keep its established snake-case anchor.
  ## Footnote references are annotations, not part of a heading's stable name.
  for span in spans:
    if span.children.len > 0: result.add headingLabel(span.children)
    elif span.kind != ikFootnoteRef: result.add span.text

proc headingLabel*(text: string): string = headingLabel(parseInlineSpans(text))

proc startsAnotherBlock(line: string): bool =
  ## Whether `line` (already stripped) begins a *different* block kind,
  ## so paragraph accumulation knows where to stop even without a
  ## blank-line separator.
  fenceWidth(line) >= 3 or line.startsWith(":::") or
    quoteLine(line) or line == "<!--more-->" or footnoteDefinition(line).label.len > 0 or
    isUnorderedListItem(line) or isOrderedListItem(line) or
    isTableRow(line) or headingMarkerLevel(line) > 0 or
    isComponentTagLine(line)

proc parseBlocks(body: string; ctx: ParseContext; sourceRelPath: string = "";
                           resolveContentPath: proc(contentRelPath: string): string {.closure.} = nil;
                           resolveSymbol: proc(sym: string): string {.closure.} = nil;
                           isComponentKnown: proc(name: string): bool {.closure.} = nil;
                           knownDirective: proc(name: string): bool {.closure.} = nil;
                           renderDirective: proc(name, args, body: string): seq[Block] {.closure.} = nil;
                           firstLine: int = 1): seq[Block] =
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
  var i = 0
  while i < lines.len:
    let blockLine = firstLine + i
    let stripped = lines[i].strip()
    if stripped.len == 0:
      inc i
      continue

    let width = fenceWidth(stripped)
    if width >= 3:
      let marker = stripped[0]
      let info = stripped[width .. ^1].strip()
      inc i
      var codeLines: seq[string] = @[]
      while i < lines.len and not closesFence(lines[i], marker, width):
        codeLines.add lines[i]
        inc i
      if i < lines.len: inc i
      var (lang, attrs) = fenceInfo(info, codeLines.len)
      if attrs.diff:
        for index, line in codeLines:
          if line.len > 0 and line[0] in {'+', '-'}:
            attrs.diffLines.add DiffLine(line: index + 1,
              kind: (if line[0] == '+': dlAdded else: dlRemoved))
      let code = codeLines.join("\n")
      let location = SourceLocation(path: sourceRelPath, line: blockLine)
      var generated: ContentFragment
      if lang == "math" and ctx.renderers.math != nil:
        generated = requireFragment(ctx.renderers.math(code, true, location), location)
      elif lang in ["d2", "dot"] and ctx.renderers.diagram != nil:
        generated = requireFragment(ctx.renderers.diagram(lang, code, location), location)
      result.add Block(kind: bkCodeFence, lang: lang, code: code, fenceAttrs: attrs, generated: generated)
      continue

    if ctx.renderers.math != nil and stripped.startsWith("$$"):
      # Only a whole display block claims the block boundary. Inline display
      # math with surrounding text stays in the normal paragraph scanner.
      let remaining = lines[i .. ^1].join("\n").strip(leading = true, trailing = false)
      let close = mathEnd(remaining, 0, 2)
      if close >= 0:
        let tail = remaining[close + 2 .. ^1]
        let newline = tail.find({'\r', '\n'})
        let rest = if newline < 0: tail else: tail[0 ..< newline]
        if rest.strip().len == 0:
          let tex = remaining[2 ..< close].strip()
          let location = SourceLocation(path: sourceRelPath, line: blockLine)
          result.add Block(kind: bkCodeFence, lang: "math", code: tex,
            generated: requireFragment(ctx.renderers.math(tex, true, location), location))
          i += lineAt(remaining, close + 2, 1)
          continue

    if stripped == "<!--more-->":
      result.add Block(kind: bkExcerptBreak)
      inc i
      continue

    let definition = footnoteDefinition(stripped)
    if ctx.footnotes and definition.label.len > 0:
      var bodyLines = @[definition.body]
      inc i
      while i < lines.len:
        if lines[i].startsWith("    "):
          bodyLines.add lines[i][4 .. ^1]
          inc i
        elif lines[i].strip().len == 0 and i + 1 < lines.len and lines[i + 1].startsWith("    "):
          bodyLines.add ""
          inc i
        else: break
      var duplicate = false
      for note in ctx.definitions:
        if note.label == definition.label: duplicate = true
      if not duplicate:
        let noteBlocks = parseBlocks(bodyLines.join("\n"), ctx, sourceRelPath,
          resolveContentPath, resolveSymbol, isComponentKnown, knownDirective, renderDirective, blockLine)
        ctx.definitions.add Footnote(label: definition.label, blocks: noteBlocks)
      continue

    if quoteLine(stripped):
      var quoteLines: seq[string]
      while i < lines.len and quoteLine(lines[i].strip()):
        var line = lines[i].strip(leading = true, trailing = false)[1 .. ^1]
        if line.len > 0 and line[0] == ' ': line = line[1 .. ^1]
        quoteLines.add line
        inc i
      result.add Block(kind: bkBlockquote, quoteBlocks: parseBlocks(quoteLines.join("\n"), ctx,
        sourceRelPath, resolveContentPath, resolveSymbol, isComponentKnown, knownDirective, renderDirective, blockLine))
      continue

    if stripped == ":::figure":
      inc i
      var figureLines: seq[string]
      var figureLineNumbers: seq[int]
      while i < lines.len and lines[i].strip() != ":::":
        if lines[i].strip().len > 0:
          figureLines.add lines[i].strip()
          figureLineNumbers.add firstLine + i
        inc i
      if i < lines.len: inc i
      let image = if figureLines.len > 0: parseInlineSpans(figureLines[0], sourceRelPath, resolveContentPath, resolveSymbol) else: @[]
      if image.len == 1 and image[0].kind == ikImage:
        var caption = figureLines[1 .. ^1].join(" ")
        if ctx.renderers.math != nil and figureLines.len > 1:
          caption = figureLines[1]
          for n in 2 ..< figureLines.len:
            caption.add repeat("\n", figureLineNumbers[n] - figureLineNumbers[n - 1]) & figureLines[n]
        if italicCaption(caption): caption = caption[1 ..< caption.len - 1]
        result.add Block(kind: bkFigure, figureImage: image[0],
          caption: parseInlineSpans(caption, sourceRelPath, resolveContentPath, resolveSymbol, ctx.renderers, (if figureLineNumbers.len > 1: figureLineNumbers[1] else: blockLine + 1)))
      else:
        # Malformed author input remains visible, never an empty figure.
        result.add Block(kind: bkParagraph, spans: parseInlineSpans(figureLines.join("\n"), sourceRelPath, resolveContentPath, resolveSymbol, ctx.renderers, blockLine + 1))
      continue

    if stripped.startsWith("!["):
      let image = parseInlineSpans(stripped, sourceRelPath, resolveContentPath, resolveSymbol)
      var captionLine = i + 1
      if captionLine < lines.len and lines[captionLine].strip().len == 0: inc captionLine
      if image.len == 1 and image[0].kind == ikImage and captionLine < lines.len and italicCaption(lines[captionLine].strip()):
        let caption = lines[captionLine].strip()
        result.add Block(kind: bkFigure, figureImage: image[0],
          caption: parseInlineSpans(caption[1 ..< caption.len - 1], sourceRelPath, resolveContentPath, resolveSymbol, ctx.renderers, firstLine + captionLine))
        i = captionLine + 1
        continue

    if stripped.startsWith(":::") and stripped[3 .. ^1].strip().toLowerAscii() == "tabs":
      inc i
      var tabs: seq[TabPanel] = @[]
      var title = ""
      var panelLines: seq[string] = @[]
      var haveTab = false
      var panelLine = blockLine + 1
      template flushTab() =
        if haveTab:
          tabs.add TabPanel(title: title,
            blocks: parseBlocks(panelLines.join("\n"), ctx, sourceRelPath, resolveContentPath, resolveSymbol, isComponentKnown, knownDirective, renderDirective, panelLine))
      while i < lines.len and lines[i].strip() != ":::":
        let rawLine = lines[i]
        let lineStripped = rawLine.strip()
        if lineStripped.startsWith("@tab") and
            (lineStripped.len == 4 or lineStripped[4] == ' '):
          flushTab()
          title = lineStripped[4 .. ^1].strip()
          panelLines = @[]
          panelLine = firstLine + i + 1
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
        cards: parseCardItems(bodyLines, sourceRelPath, resolveContentPath, resolveSymbol, ctx.renderers, blockLine + 1),
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
        faqItems: parseFaqItems(bodyLines, sourceRelPath, resolveContentPath, resolveSymbol, ctx.renderers, blockLine + 1))
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
      var paragraphLine = firstLine + i
      while i < lines.len and lines[i].strip() != ":::":
        let bodyLine = lines[i].strip()
        if bodyLine.len == 0:
          if currentLines.len > 0:
            paragraphs.add parseInlineSpans(currentLines.join(if ctx.renderers.math == nil: " " else: "\n"), sourceRelPath, resolveContentPath, resolveSymbol, ctx.renderers, paragraphLine)
            currentLines = @[]
        else:
          if currentLines.len == 0: paragraphLine = firstLine + i
          currentLines.add bodyLine
        inc i
      if currentLines.len > 0:
        paragraphs.add parseInlineSpans(currentLines.join(if ctx.renderers.math == nil: " " else: "\n"), sourceRelPath, resolveContentPath, resolveSymbol, ctx.renderers, paragraphLine)
      if i < lines.len: inc i
      result.add Block(kind: bkAdmonition, admonitionKind: admonitionKind, bodyParagraphs: paragraphs)
      continue

    let level = headingMarkerLevel(stripped)
    if level > 0:
      let headingText = stripped[level + 1 .. ^1].strip()
      let headingSpans = parseInlineSpans(headingText, sourceRelPath, resolveContentPath, resolveSymbol, ctx.renderers, blockLine)
      result.add Block(kind: bkHeading, level: level, headingText: headingText,
        headingSpans: headingSpans)
      inc i
      continue

    if isTableRow(stripped) and i + 1 < lines.len and isTableSeparatorRow(lines[i + 1]):
      let headers = splitTableRow(stripped, ctx.renderers.math != nil)
      i += 2
      var rows: seq[seq[string]] = @[]
      while i < lines.len and isTableRow(lines[i].strip()):
        rows.add splitTableRow(lines[i], ctx.renderers.math != nil)
        inc i
      var headerSpans: seq[seq[InlineSpan]]
      var cellSpans: seq[seq[seq[InlineSpan]]]
      if ctx.renderers.math != nil:
        for header in headers:
          headerSpans.add parseInlineSpans(header, sourceRelPath, resolveContentPath, resolveSymbol, ctx.renderers, blockLine)
        for n, row in rows:
          var cells: seq[seq[InlineSpan]]
          for cell in row:
            cells.add parseInlineSpans(cell, sourceRelPath, resolveContentPath, resolveSymbol, ctx.renderers, blockLine + 2 + n)
          cellSpans.add cells
      result.add Block(kind: bkTable, headers: headers, rows: rows,
        headerSpans: headerSpans, cellSpans: cellSpans)
      continue

    if isUnorderedListItem(stripped) or isOrderedListItem(stripped):
      let ordered = isOrderedListItem(stripped)
      var items: seq[seq[InlineSpan]] = @[]
      var tasks: seq[TaskState]
      var hasTasks = false
      while i < lines.len:
        let itemLine = lines[i].strip()
        if itemLine.len == 0: break
        if ordered != isOrderedListItem(itemLine): break
        if not ordered and not isUnorderedListItem(itemLine): break
        var content = listItemText(itemLine)
        var task = tsNone
        if content.len >= 3 and content[0] == '[' and content[1] in {' ', 'x', 'X'} and content[2] == ']' and (content.len == 3 or content[3] in {' ', '\t'}):
          task = if content[1] == ' ': tsUnchecked else: tsChecked
          content = content[3 .. ^1].strip(leading = true, trailing = false)
          hasTasks = true
        tasks.add task
        items.add parseInlineSpans(content, sourceRelPath, resolveContentPath, resolveSymbol, ctx.renderers, firstLine + i)
        inc i
      result.add Block(kind: bkList, listKind: (if ordered: lkOrdered else: lkUnordered), items: items, tasks: (if hasTasks: tasks else: @[]))
      continue

    var paraLines: seq[string] = @[lines[i].strip(leading = true, trailing = false)]
    inc i
    while i < lines.len:
      let nextStripped = lines[i].strip()
      if nextStripped.len == 0 or startsAnotherBlock(nextStripped) or (ctx.renderers.math != nil and nextStripped.startsWith("$$")): break
      paraLines.add lines[i]
      inc i
    result.add Block(kind: bkParagraph, spans: parseInlineSpans(paraLines.join("\n").strip(), sourceRelPath, resolveContentPath, resolveSymbol, ctx.renderers, blockLine))

proc hasGeneratedContent*(spans: seq[InlineSpan]): bool =
  ## Consumers with legacy literal headings can opt into resolved rendering
  ## only when a generated fragment is actually present.
  for span in spans:
    if not span.generated.isEmpty or hasGeneratedContent(span.children): return true

proc hasFootnoteReference*(spans: seq[InlineSpan]): bool =
  ## Consumers that retain literal legacy headings can use the same predicate
  ## for rendering and reference validation when footnotes need real targets.
  for span in spans:
    if span.kind == ikFootnoteRef or hasFootnoteReference(span.children): return true

proc visitInlineSpans*(blocks: seq[Block]; visitor: proc(span: InlineSpan) {.closure.};
                      includeHeadingSpans: proc(heading: Block): bool {.closure.} = nil) =
  ## Traverse every authored inline location, including nested prose and
  ## directive bodies. Reference checkers share this traversal with excerpts.
  proc spans(items: seq[InlineSpan]) =
    for item in items:
      visitor(item)
      spans(item.children)
  for blk in blocks:
    case blk.kind
    of bkHeading:
      if includeHeadingSpans == nil or includeHeadingSpans(blk): spans(blk.headingSpans)
    of bkParagraph: spans(blk.spans)
    of bkList:
      for item in blk.items: spans(item)
    of bkTable:
      for header in blk.headerSpans: spans(header)
      for row in blk.cellSpans:
        for cell in row: spans(cell)
    of bkAdmonition:
      for para in blk.bodyParagraphs: spans(para)
    of bkTabs:
      for tab in blk.tabs: visitInlineSpans(tab.blocks, visitor, includeHeadingSpans)
    of bkBlockquote: visitInlineSpans(blk.quoteBlocks, visitor, includeHeadingSpans)
    of bkFigure:
      spans(@[blk.figureImage])
      spans(blk.caption)
    of bkFootnotes:
      for note in blk.footnotes: visitInlineSpans(note.blocks, visitor, includeHeadingSpans)
    of bkCardGrid:
      for card in blk.cards:
        for para in card.body: spans(para)
    of bkFaq:
      for item in blk.faqItems:
        for para in item.answer: spans(para)
    else: discard

proc assignHeadingAnchors(blocks: var seq[Block]; registry: var AnchorIdRegistry) =
  ## Resolve references before deriving heading names: an undefined footnote
  ## is visible literal text, while a defined one remains an annotation. Reserve
  ## every rendered heading before allocating endnote/reference IDs so the
  ## complete document shares one collision-free namespace.
  for blk in blocks.mitems:
    case blk.kind
    of bkHeading:
      if blk.headingId.len > 0:
        blk.headingId = registry.nextRawId(blk.headingId)
      else:
        let label = if blk.headingSpans.len > 0: headingLabel(blk.headingSpans)
                    else: blk.headingText
        blk.headingId = registry.nextId(label)
    of bkBlockquote: assignHeadingAnchors(blk.quoteBlocks, registry)
    of bkTabs:
      for tab in blk.tabs.mitems: assignHeadingAnchors(tab.blocks, registry)
    of bkFootnotes:
      for note in blk.footnotes.mitems: assignHeadingAnchors(note.blocks, registry)
    else: discard

proc resolveFootnotes(blocks: var seq[Block]; ctx: ParseContext) =
  var order: seq[int]
  proc resolveSpans(spans: var seq[InlineSpan]; assignIds: bool) =
    for span in spans.mitems:
      if span.kind == ikFootnoteRef and assignIds:
        let index = order[span.footnoteNumber - 1]
        let reference = ctx.anchors.nextRawId("fnref-" & $span.footnoteNumber)
        ctx.definitions[index].referenceIds.add reference
        span.href = "#" & ctx.definitions[index].id
        span.referenceId = reference
      elif span.kind == ikFootnoteRef:
        var index = -1
        for n, note in ctx.definitions:
          if note.label == span.text:
            index = n
            break
        if index < 0:
          span = InlineSpan(kind: ikText, text: "[^" & span.text & "]")
        else:
          if ctx.definitions[index].number == 0:
            order.add index
            ctx.definitions[index].number = order.len
          span.footnoteNumber = ctx.definitions[index].number
      resolveSpans(span.children, assignIds)
  proc resolveBlocks(items: var seq[Block]; assignIds = false) =
    for blk in items.mitems:
      case blk.kind
      of bkHeading: resolveSpans(blk.headingSpans, assignIds)
      of bkParagraph: resolveSpans(blk.spans, assignIds)
      of bkList:
        for item in blk.items.mitems: resolveSpans(item, assignIds)
      of bkTable:
        for header in blk.headerSpans.mitems: resolveSpans(header, assignIds)
        for row in blk.cellSpans.mitems:
          for cell in row.mitems: resolveSpans(cell, assignIds)
      of bkAdmonition:
        for para in blk.bodyParagraphs.mitems: resolveSpans(para, assignIds)
      of bkTabs:
        for tab in blk.tabs.mitems: resolveBlocks(tab.blocks, assignIds)
      of bkBlockquote: resolveBlocks(blk.quoteBlocks, assignIds)
      of bkFigure: resolveSpans(blk.caption, assignIds)
      of bkFootnotes:
        for note in blk.footnotes.mitems: resolveBlocks(note.blocks, assignIds)
      of bkCardGrid:
        for card in blk.cards.mitems:
          for para in card.body.mitems: resolveSpans(para, assignIds)
      of bkFaq:
        for item in blk.faqItems.mitems:
          for para in item.answer.mitems: resolveSpans(para, assignIds)
      else: discard
  resolveBlocks(blocks)
  var n = 0
  while n < order.len:
    # Work on a value: a reference discovered here may grow the order list.
    # Each definition is visited once, even for cyclic note references.
    let index = order[n]
    var body = ctx.definitions[index].blocks
    resolveBlocks(body)
    ctx.definitions[index].blocks = body
    inc n
  if order.len > 0:
    var notes: seq[Footnote]
    for index in order: notes.add ctx.definitions[index]
    blocks.add Block(kind: bkFootnotes, footnotes: notes)
  assignHeadingAnchors(blocks, ctx.anchors)
  if order.len > 0:
    for index in order:
      ctx.definitions[index].id = ctx.anchors.nextRawId("fn-" & $ctx.definitions[index].number)
    resolveBlocks(blocks, assignIds = true)
    for note in blocks[^1].footnotes.mitems:
      let definition = ctx.definitions[order[note.number - 1]]
      note.id = definition.id
      note.referenceIds = definition.referenceIds

proc parseMarkdownBlocks*(body: string; sourceRelPath: string = "";
                           resolveContentPath: proc(contentRelPath: string): string {.closure.} = nil;
                           resolveSymbol: proc(sym: string): string {.closure.} = nil;
                           isComponentKnown: proc(name: string): bool {.closure.} = nil;
                           knownDirective: proc(name: string): bool {.closure.} = nil;
                           renderDirective: proc(name, args, body: string): seq[Block] {.closure.} = nil;
                           footnotes: bool = true;
                           renderers: ContentRenderers = ContentRenderers();
                           firstLine: int = 1): seq[Block] =
  ## A fresh context per document keeps heading and footnote IDs unique across
  ## nested containers, without leaking state between parses or backends.
  ## `footnotes = false` keeps definitions in the text stream for targets
  ## whose published contract treats notes literally (for example email).
  let ctx = ParseContext(anchors: newAnchorIdRegistry(), footnotes: footnotes, renderers: renderers)
  result = parseBlocks(body, ctx, sourceRelPath, resolveContentPath, resolveSymbol,
    isComponentKnown, knownDirective, renderDirective, firstLine)
  resolveFootnotes(result, ctx)

proc excerptBlocks*(blocks: seq[Block]): seq[Block] =
  ## The top-level excerpt marker wins; without one use the first paragraph.
  ## Work on the parsed AST so marker-like code cannot truncate an excerpt.
  var marked = false
  for blk in blocks:
    if blk.kind == bkExcerptBreak:
      marked = true
      break
    if blk.kind != bkFootnotes: result.add blk
  if not marked:
    result = @[]
    for blk in blocks:
      if blk.kind == bkParagraph:
        result.add blk
        break
  # Keep referenced endnotes self-contained, including transitive references,
  # but drop backlinks to occurrences outside this excerpt.
  var refs: seq[string]
  proc collect(span: InlineSpan) =
    if span.kind == ikFootnoteRef and span.referenceId notin refs:
      refs.add span.referenceId
  visitInlineSpans(result, collect)
  var notes: seq[Footnote]
  for blk in blocks:
    if blk.kind == bkFootnotes: notes = blk.footnotes
  var selected: seq[int]
  var changed = true
  while changed:
    changed = false
    for n, note in notes:
      if n in selected: continue
      for reference in note.referenceIds:
        if reference in refs:
          selected.add n
          visitInlineSpans(note.blocks, collect)
          changed = true
          break
  if selected.len > 0:
    var kept: seq[Footnote]
    for n, note in notes:
      if n in selected:
        var copy = note
        copy.referenceIds = @[]
        for reference in note.referenceIds:
          if reference in refs: copy.referenceIds.add reference
        kept.add copy
    result.add Block(kind: bkFootnotes, footnotes: kept)

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
                        renderDirective: proc(name, args, body: string): seq[Block] {.closure.} = nil;
                        renderers: ContentRenderers = ContentRenderers();
                        firstLine: int = 1): MarkdownDoc =
  ## The one entry point later callers (the markdown page ViewModel
  ## builder, `test_markdown_vm.nim`, M3's `references.nim`) use: parses
  ## the body into blocks, then derives the heading tree from the
  ## headings found among them. `resolveContentPath`/`resolveSymbol` are
  ## passed straight through to `parseMarkdownBlocks` (see M8 deliverable 2
  ## for the `[[sym:...]]` cross-reference `resolveSymbol` resolves).
  let blocks = parseMarkdownBlocks(body, sourceRelPath, resolveContentPath, resolveSymbol, isComponentKnown, knownDirective, renderDirective, renderers = renderers, firstLine = firstLine)
  var flat: seq[HeadingNode] = @[]
  proc headings(items: seq[Block]) =
    for blk in items:
      case blk.kind
      of bkHeading:
        let label = if blk.headingSpans.len > 0: headingLabel(blk.headingSpans)
                    else: headingLabel(blk.headingText)
        flat.add HeadingNode(level: blk.level, text: label, id: blk.headingId)
      of bkBlockquote: headings(blk.quoteBlocks)
      of bkTabs:
        for tab in blk.tabs: headings(tab.blocks)
      else: discard
  headings(blocks)
  MarkdownDoc(blocks: blocks, headingTree: buildHeadingTree(flat), excerpt: excerptBlocks(blocks))
