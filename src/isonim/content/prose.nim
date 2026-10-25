## Semantic HTML for the shared Markdown prose dialect. No theme, filesystem,
## scripts or inline styles. Consumers keep their existing block presentation
## by supplying callbacks to the extension renderer (quotes/figures/endnotes).
import ./markdown
import ../ssr/escape

proc titleAttribute*(title: string): string =
  if title.len > 0: " title=\"" & escapeAttr(title) & "\"" else: ""

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
      result.add "<img src=\"" & escapeAttr(span.href) & "\" alt=\"" & escapeAttr(span.text) & "\"" & titleAttribute(span.title) & ">"
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

proc renderProseHtml*(blocks: seq[Block]): string =
  ## Render the semantic prose subset. Docs-specific components require the
  ## owning consumer renderer; unsupported kinds fail visibly, never vanish.
  for blk in blocks:
    case blk.kind
    of bkHeading:
      let tag = "h" & $blk.level
      result.add "<" & tag & " id=\"" & escapeAttr(blk.headingId) & "\">" &
        (if blk.headingSpans.len > 0: proseSpansHtml(blk.headingSpans)
         else: escapeHtml(blk.headingText)) & "</" & tag & ">"
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
      result.add "<pre><code" & language & ">" & escapeHtml(blk.code) & "</code></pre>"
    of bkTable:
      result.add "<table><thead><tr>"
      for n, header in blk.headers:
        result.add "<th>" & (if n < blk.headerSpans.len: proseSpansHtml(blk.headerSpans[n]) else: escapeHtml(header)) & "</th>"
      result.add "</tr></thead><tbody>"
      for n, row in blk.rows:
        result.add "<tr>"
        for c, cell in row:
          result.add "<td>" & (if n < blk.cellSpans.len and c < blk.cellSpans[n].len: proseSpansHtml(blk.cellSpans[n][c]) else: escapeHtml(cell)) & "</td>"
        result.add "</tr>"
      result.add "</tbody></table>"
    of bkAdmonition:
      result.add "<aside>"
      for para in blk.bodyParagraphs: result.add "<p>" & proseSpansHtml(para) & "</p>"
      result.add "</aside>"
    of bkBlockquote, bkFigure, bkFootnotes, bkExcerptBreak:
      result.add renderProseExtensionHtml(blk, renderProseHtml, proseSpansHtml)
    else: raise newException(ValueError, "A consumer renderer is required for " & $blk.kind)

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
    r.setAttribute(img, "alt", blk.figureImage.text)
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
