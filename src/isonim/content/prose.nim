## Semantic HTML for the shared Markdown prose dialect. No theme, filesystem,
## scripts or inline styles. Consumers keep their existing block presentation
## by supplying callbacks to the extension renderer (quotes/figures/endnotes).
import std/[sets, strutils]
from std/unicode import nil
import ./markdown
import ../ssr/escape

const
  tableScrollClass* = "table-scroll"
    ## Class of the element wrapping every rendered table. A stylesheet gives
    ## it `overflow-x: auto` so a wide table scrolls inside its own box.
  tableRegionLabel* = "Table"
    ## The word every generated table-region name starts with: the name of
    ## an uncaptioned table with no heading before it, and the prefix of
    ## the heading-derived name (`Table: <heading>`).
  tableCaptionIdBase* = "table_caption-"
    ## The generated `id` of a `<caption>` is this base and an ordinal.
    ## Heading anchors are `[a-z0-9-]` slugs and endnote IDs are `fn-…`, so
    ## the underscore keeps the two namespaces apart.

# Wide content scrolls inside its own box rather than widening the page, so
# every box that can scroll must be reachable from the keyboard: WCAG 2.2
# SC 2.1.1 (https://www.w3.org/TR/WCAG22/#keyboard), checked by axe-core's
# `scrollable-region-focusable` rule
# (https://dequeuniversity.com/rules/axe/4.10/scrollable-region-focusable).
# Not every browser makes a scroller focusable by itself, and without script
# the renderer cannot know which blocks will overflow, so every code block
# and every table wrapper carries `tabindex="0"`, as Hugo and Shiki do for
# code. The table wrapper is a named region, so a screen reader announces
# what received focus (the pattern in
# https://adrianroselli.com/2020/11/under-engineered-responsive-tables.html).
#
# A region landmark needs a name, and a page that repeats a landmark role
# needs a different name for each one (WAI-ARIA Authoring Practices,
# https://www.w3.org/WAI/ARIA/apg/practices/landmark-regions/; axe-core's
# `landmark-unique` rule, which compares names case-insensitively). A
# captioned table names its region from the visible caption with
# `aria-labelledby`, as in the pattern above. A table without a caption is
# named with `aria-label` after the nearest heading before it, since its
# region does not begin with that heading (the APG reserves
# `aria-labelledby` for that case). A name already used in the same
# `ProsePageScope` gets an ordinal, `(2)`, `(3)`, ….
const
  codeBlockOpen = "<pre tabindex=\"0\">"
  tableScrollOpen = "<div class=\"" & tableScrollClass &
    "\" role=\"region\" tabindex=\"0\""

type
  ProsePageScope* = ref object
    ## The IDs and table-region names already used on one output page.
    ## Every rendering that ends up on the same page must share one scope:
    ## a listing that joins several excerpts renders them all through it,
    ## and then no two regions share a name and no generated `id` repeats
    ## one that is already on the page. Pass a fresh scope (the
    ## single-argument `renderProseHtml`) for a document that is a page of
    ## its own.
    idPrefix: string
    ids: HashSet[string]
    names: HashSet[string]       ## Case-folded (`nameKey`), as axe compares them.
    nextCaption: int
    heading: string              ## Visible text of the last heading rendered.
    avoid: ProsePageScope        ## Also counted as used, during one call.

proc newProsePageScope*(idPrefix = ""): ProsePageScope =
  ## A scope with nothing used yet. `idPrefix` is put in front of every ID
  ## the renderer generates through it, so two scopes whose output may meet
  ## on one page (each post's content, and a scope shared by all excerpts)
  ## cannot generate the same ID.
  ProsePageScope(idPrefix: idPrefix, ids: initHashSet[string](),
    names: initHashSet[string]())

proc reserveIds(scope: ProsePageScope; blocks: seq[Block]) =
  ## Record the IDs the parser assigned (headings, endnotes, references) so
  ## a generated ID never repeats one, in this document or an earlier one.
  proc spans(list: seq[InlineSpan]) =
    for span in list:
      if span.referenceId.len > 0: scope.ids.incl span.referenceId
      spans(span.children)
  for blk in blocks:
    case blk.kind
    of bkHeading:
      scope.ids.incl blk.headingId
      spans(blk.headingSpans)
    of bkParagraph: spans(blk.spans)
    of bkList:
      for item in blk.items: spans(item)
    of bkTable:
      for header in blk.headerSpans: spans(header)
      for row in blk.cellSpans:
        for cell in row: spans(cell)
      spans(blk.tableCaption)
    of bkAdmonition:
      for paragraph in blk.bodyParagraphs: spans(paragraph)
    of bkBlockquote: scope.reserveIds(blk.quoteBlocks)
    of bkTabs:
      for tab in blk.tabs: scope.reserveIds(tab.blocks)
    of bkFigure: spans(blk.caption)
    of bkFootnotes:
      for note in blk.footnotes:
        scope.ids.incl note.id
        for reference in note.referenceIds: scope.ids.incl reference
        scope.reserveIds(note.blocks)
    else: discard

proc nameKey(name: string): string =
  ## The form in which two names are compared. axe-core's `landmark-unique`
  ## lowers the accessible name with JavaScript's `toLowerCase`, which folds
  ## every letter, not only ASCII: "Ärger" and "ärger" are one name to it.
  unicode.toLower(name)

proc nameUsed(scope: ProsePageScope; name: string): bool =
  let key = nameKey(name)
  key in scope.names or (scope.avoid != nil and key in scope.avoid.names)

proc idUsed(scope: ProsePageScope; id: string): bool =
  id in scope.ids or (scope.avoid != nil and id in scope.avoid.ids)

proc uniqueName(scope: ProsePageScope; base: string): string =
  ## `base`, or `base (n)` with the smallest n >= 2 not used yet.
  result = base
  var n = 1
  while scope.nameUsed(result):
    inc n
    result = base & " (" & $n & ")"
  scope.names.incl nameKey(result)

proc captionId(scope: ProsePageScope): string =
  while true:
    inc scope.nextCaption
    result = scope.idPrefix & tableCaptionIdBase & $scope.nextCaption
    if not scope.idUsed(result): break
  scope.ids.incl result

proc plainText(spans: seq[InlineSpan]): string =
  ## Visible text with runs of whitespace collapsed: the accessible name a
  ## browser computes from the same content, near enough to compare.
  headingLabel(spans).splitWhitespace().join(" ")

proc titleAttribute*(title: string): string =
  if title.len > 0: " title=\"" & escapeAttr(title) & "\"" else: ""

proc imageAlt*(span: InlineSpan): string =
  ## The `alt` an image span is rendered with: empty for one marked
  ## `{decorative}`, whatever its brackets hold, else its alt text.
  if span.decorative: "" else: span.text

proc proseImages*(blocks: seq[Block]): seq[InlineSpan] =
  ## Every image span of the prose subset `renderProseHtml` renders, in
  ## document order: in headings, paragraphs, list items, maths-enabled
  ## table cells, admonitions, quotes, figures and footnotes, and inside
  ## struck-through text. A consumer checks them against its own alt-text
  ## policy with `InlineSpan.line` for the location.
  proc spans(list: seq[InlineSpan]; found: var seq[InlineSpan]) =
    for span in list:
      if span.kind == ikImage: found.add span
      spans(span.children, found)
  for blk in blocks:
    case blk.kind
    of bkHeading: spans(blk.headingSpans, result)
    of bkParagraph: spans(blk.spans, result)
    of bkList:
      for item in blk.items: spans(item, result)
    of bkTable:
      for header in blk.headerSpans: spans(header, result)
      for row in blk.cellSpans:
        for cell in row: spans(cell, result)
      spans(blk.tableCaption, result)
    of bkAdmonition:
      for paragraph in blk.bodyParagraphs: spans(paragraph, result)
    of bkBlockquote: result.add proseImages(blk.quoteBlocks)
    of bkFigure:
      spans(@[blk.figureImage], result)
      spans(blk.caption, result)
    of bkFootnotes:
      for note in blk.footnotes: result.add proseImages(note.blocks)
    else: discard

proc footnoteBackLabel*(note: Footnote; occurrence: int): string =
  "Back to reference " & $note.number &
    (if occurrence == 0: "" else: " (" & $(occurrence + 1) & ")")

proc proseSpansHtml*(spans: seq[InlineSpan]): string =
  ## Escape every source-derived value, including destinations and titles.
  for span in spans:
    if not span.generated.isEmpty:
      result.add fragmentHtml(span.generated)
      continue
    case span.kind
    of ikText: result.add escapeHtml(span.text)
    of ikCode: result.add "<code>" & escapeHtml(span.text) & "</code>"
    of ikLink:
      result.add "<a href=\"" & escapeAttr(span.href) & "\"" & titleAttribute(span.title) & ">" & (if span.children.len > 0: proseSpansHtml(span.children) else: escapeHtml(span.text)) & "</a>"
    of ikImage:
      result.add "<img src=\"" & escapeAttr(span.href) & "\" alt=\"" & escapeAttr(imageAlt(span)) & "\"" & titleAttribute(span.title) & ">"
    of ikSymRef:
      if span.href.len > 0: result.add "<a href=\"" & escapeAttr(span.href) & "\">"
      result.add "<code>" & escapeHtml(span.text) & "</code>"
      if span.href.len > 0: result.add "</a>"
    of ikStrike: result.add "<del>" & proseSpansHtml(span.children) & "</del>"
    of ikFootnoteRef:
      if span.footnoteNumber == 0:
        result.add escapeHtml("[^" & span.text & "]")
      else:
        result.add "<sup id=\"" & escapeAttr(span.referenceId) & "\"><a href=\"" &
          escapeAttr(span.href) & "\" role=\"doc-noteref\">" & $span.footnoteNumber & "</a></sup>"

proc renderProseExtensionHtml*(blk: Block;
    renderBlocks: proc(blocks: seq[Block]): string {.closure.};
    renderSpans: proc(spans: seq[InlineSpan]): string {.closure.}): string =
  ## Callback seam: a quote's body uses the caller's normal heading, code and
  ## component rendering, without a second parser or a docs dependency here.
  case blk.kind
  of bkBlockquote:
    result = "<blockquote>" & renderBlocks(blk.quoteBlocks) & "</blockquote>"
  of bkFigure:
    result = "<figure>" & proseSpansHtml(@[blk.figureImage]) & "<figcaption>" &
      renderSpans(blk.caption) & "</figcaption></figure>"
  of bkFootnotes:
    result = "<section class=\"footnotes\" role=\"doc-endnotes\"><ol>"
    for index, note in blk.footnotes:
      let value = if note.number == index + 1: "" else: " value=\"" & $note.number & "\""
      result.add "<li id=\"" & escapeAttr(note.id) & "\"" & value & ">" & renderBlocks(note.blocks)
      for n, reference in note.referenceIds:
        if n > 0: result.add " "
        result.add "<a href=\"#" & escapeAttr(reference) & "\" role=\"doc-backlink\" aria-label=\"" &
          escapeAttr(footnoteBackLabel(note, n)) & "\">↩</a>"
      result.add "</li>"
    result.add "</ol></section>"
  of bkExcerptBreak: result = ""
  else: raise newException(ValueError, "Not a prose extension: " & $blk.kind)

proc tableOpen(blk: Block; scope: ProsePageScope): tuple[open, caption: string] =
  ## The region's start tag, named uniquely within `scope`, and the
  ## table's `<caption>` element ("" when it has none).
  let captionText = plainText(blk.tableCaption)
  if captionText.len > 0:
    let name = scope.uniqueName(captionText)
    if name == captionText:
      let id = scope.captionId()
      return (tableScrollOpen & " aria-labelledby=\"" & escapeAttr(id) & "\">",
        "<caption id=\"" & escapeAttr(id) & "\">" & proseSpansHtml(blk.tableCaption) & "</caption>")
    # The caption's text already names a region on this page: the caption
    # stays as written, and the region gets the numbered name.
    return (tableScrollOpen & " aria-label=\"" & escapeAttr(name) & "\">",
      "<caption>" & proseSpansHtml(blk.tableCaption) & "</caption>")
  let base = if scope.heading.len > 0: tableRegionLabel & ": " & scope.heading
             else: tableRegionLabel
  result.open = tableScrollOpen & " aria-label=\"" & escapeAttr(scope.uniqueName(base)) & "\">"
  if blk.tableCaption.len > 0:
    result.caption = "<caption>" & proseSpansHtml(blk.tableCaption) & "</caption>"

proc renderBlocks(blocks: seq[Block]; scope: ProsePageScope): string =
  for blk in blocks:
    case blk.kind
    of bkHeading:
      let tag = "h" & $blk.level
      result.add "<" & tag & " id=\"" & escapeAttr(blk.headingId) & "\">" &
        (if blk.headingSpans.len > 0: proseSpansHtml(blk.headingSpans)
         else: escapeHtml(blk.headingText)) & "</" & tag & ">"
      scope.heading =
        if blk.headingSpans.len > 0: plainText(blk.headingSpans)
        else: headingLabel(blk.headingText).splitWhitespace().join(" ")
    of bkParagraph: result.add "<p>" & proseSpansHtml(blk.spans) & "</p>"
    of bkList:
      let tag = if blk.listKind == lkOrdered: "ol" else: "ul"
      result.add "<" & tag & ">"
      for n, item in blk.items:
        result.add "<li>"
        if n < blk.tasks.len and blk.tasks[n] != tsNone:
          # The item's text labels its checkbox: a <label> wrapping the
          # input gives it a programmatic accessible name (WCAG 2.2 SC 4.1.2,
          # https://www.w3.org/TR/WCAG22/#name-role-value; HTML label
          # element, https://html.spec.whatwg.org/multipage/forms.html#the-label-element).
          # Adjacent text alone does not name a control, disabled or not.
          result.add "<label><input type=\"checkbox\" disabled"
          if blk.tasks[n] == tsChecked: result.add " checked"
          result.add "> " & proseSpansHtml(item) & "</label></li>"
        else:
          result.add proseSpansHtml(item) & "</li>"
      result.add "</" & tag & ">"
    of bkCodeFence:
      if not blk.generated.isEmpty:
        result.add fragmentHtml(blk.generated)
        continue
      let language = if blk.lang.len > 0: " class=\"language-" & escapeAttr(blk.lang) & "\"" else: ""
      result.add codeBlockOpen & "<code" & language & ">" & escapeHtml(blk.code) & "</code></pre>"
    of bkTable:
      let (open, caption) = tableOpen(blk, scope)
      result.add open & "<table>" & caption & "<thead><tr>"
      for n, header in blk.headers:
        result.add "<th>" & (if n < blk.headerSpans.len: proseSpansHtml(blk.headerSpans[n]) else: escapeHtml(header)) & "</th>"
      result.add "</tr></thead><tbody>"
      for n, row in blk.rows:
        result.add "<tr>"
        for c, cell in row:
          result.add "<td>" & (if n < blk.cellSpans.len and c < blk.cellSpans[n].len: proseSpansHtml(blk.cellSpans[n][c]) else: escapeHtml(cell)) & "</td>"
        result.add "</tr>"
      result.add "</tbody></table></div>"
    of bkAdmonition:
      result.add "<aside>"
      for para in blk.bodyParagraphs: result.add "<p>" & proseSpansHtml(para) & "</p>"
      result.add "</aside>"
    of bkBlockquote, bkFigure, bkFootnotes, bkExcerptBreak:
      let nested = proc(children: seq[Block]): string = renderBlocks(children, scope)
      result.add renderProseExtensionHtml(blk, nested, proseSpansHtml)
    else: raise newException(ValueError, "A consumer renderer is required for " & $blk.kind)

proc renderProseHtml*(blocks: seq[Block]; scope: ProsePageScope;
    heading = ""): string =
  ## Render the semantic prose subset as one document of a page whose IDs
  ## and table-region names `scope` tracks (see `ProsePageScope`).
  ## `heading` is the visible text of the page's heading just before the
  ## document, if the layout puts one there (a listing's post title above
  ## an excerpt): a table before the document's own first heading is named
  ## after it. Docs-specific components require the owning consumer
  ## renderer; unsupported kinds fail visibly, never vanish.
  scope.reserveIds(blocks)
  # A table is named after a heading of its own document, or of the page
  # just before it, never after one of an earlier document.
  scope.heading = heading.splitWhitespace().join(" ")
  renderBlocks(blocks, scope)

proc renderProseHtml*(blocks: seq[Block]; scope, avoid: ProsePageScope;
    heading = ""): string =
  ## Like `renderProseHtml(blocks, scope, heading)`, but the names and IDs
  ## used in `avoid` count as used too, while what this call uses is
  ## recorded in `scope` only. For a document that may share a page with
  ## each of two groups: a post's excerpt sits beside the other excerpts on
  ## a listing (`scope`) and may also sit beside its own post's content
  ## (`avoid`).
  scope.avoid = avoid
  try: result = renderProseHtml(blocks, scope, heading)
  finally: scope.avoid = nil

proc renderProseHtml*(blocks: seq[Block]): string =
  ## Render a document that is a page of its own (a fresh scope).
  renderProseHtml(blocks, newProsePageScope())

proc renderProseHtml*(doc: MarkdownDoc; scope: ProsePageScope;
    heading = ""): string =
  renderProseHtml(doc.blocks, scope, heading)

proc renderProseHtml*(doc: MarkdownDoc; scope, avoid: ProsePageScope;
    heading = ""): string =
  renderProseHtml(doc.blocks, scope, avoid, heading)

proc renderProseHtml*(doc: MarkdownDoc): string = renderProseHtml(doc.blocks)

proc renderTocHtml*(headings: seq[HeadingNode]): string =
  ## The ToC uses the parser's IDs, never a second slug calculation.
  if headings.len == 0: return ""
  result = "<ul>"
  for heading in headings:
    result.add "<li><a href=\"#" & escapeAttr(heading.id) & "\">" &
      escapeHtml(heading.text) & "</a>" & renderTocHtml(heading.children) & "</li>"
  result.add "</ul>"

proc renderProseExtension*[R, E](r: R; blk: Block;
    renderBlock: proc(blk: Block; index: int): E {.closure.};
    appendSpans: proc(parent: E; spans: seq[InlineSpan]) {.closure.}): E =
  ## Tree counterpart for browser and MockRenderer consumers. Source text is
  ## passed through text nodes and attributes, never raw HTML insertion.
  case blk.kind
  of bkBlockquote:
    let el = r.createElement("blockquote")
    for n, child in blk.quoteBlocks: r.appendChild(el, renderBlock(child, n))
    result = el
  of bkFigure:
    let el = r.createElement("figure")
    let img = r.createElement("img")
    r.setAttribute(img, "src", blk.figureImage.href)
    r.setAttribute(img, "alt", imageAlt(blk.figureImage))
    if blk.figureImage.title.len > 0: r.setAttribute(img, "title", blk.figureImage.title)
    r.appendChild(el, img)
    let caption = r.createElement("figcaption")
    appendSpans(caption, blk.caption)
    r.appendChild(el, caption)
    result = el
  of bkFootnotes:
    let el = r.createElement("section")
    r.setAttribute(el, "class", "footnotes")
    r.setAttribute(el, "role", "doc-endnotes")
    let list = r.createElement("ol")
    var childIndex = 0
    for index, note in blk.footnotes:
      let item = r.createElement("li")
      r.setAttribute(item, "id", note.id)
      if note.number != index + 1: r.setAttribute(item, "value", $note.number)
      for child in note.blocks:
        r.appendChild(item, renderBlock(child, childIndex))
        inc childIndex
      for n, reference in note.referenceIds:
        if n > 0: r.appendChild(item, r.createTextNode(" "))
        let link = r.createElement("a")
        r.setAttribute(link, "href", "#" & reference)
        r.setAttribute(link, "role", "doc-backlink")
        r.setAttribute(link, "aria-label", footnoteBackLabel(note, n))
        r.appendChild(link, r.createTextNode("↩"))
        r.appendChild(item, link)
      r.appendChild(list, item)
    r.appendChild(el, list)
    result = el
  of bkExcerptBreak: result = r.createTextNode("")
  else: raise newException(ValueError, "Not a prose extension: " & $blk.kind)
