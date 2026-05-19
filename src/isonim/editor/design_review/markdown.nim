## REV-M2: Minimal markdown to HTML renderer for the brief tab.
##
## Renders the subset of markdown briefs use:
##
## - ATX headings ``#``, ``##``, ``###`` -> ``<h1>``, ``<h2>``, ``<h3>``
## - Paragraphs (blank-line separated)
## - Fenced code blocks ``` ``` -> ``<pre><code>``
## - Inline code `` `x` `` -> ``<code>``
## - Links ``[text](url)`` -> ``<a href="url">text</a>``
##
## No tables, no images, no setext headings, no lists, no blockquotes,
## no emphasis. Brief bodies that need those will be extended in a
## later milestone.
##
## All text content is HTML-escaped before substitution so brief
## authors can't smuggle script tags into the editor pane.

import std/[strutils]

proc escapeHtml*(s: string): string =
  ## Escape ``&``, ``<``, ``>``, ``"`` so that arbitrary text is safe to
  ## drop into HTML content positions.
  result = newStringOfCap(s.len)
  for ch in s:
    case ch
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    else: result.add ch

proc renderInline(line: string): string =
  ## Render inline markdown (`code`, [text](url)). Operates byte-by-byte
  ## so that escaping HTML special characters and detecting markdown
  ## syntax stay in sync.
  result = ""
  var i = 0
  while i < line.len:
    let ch = line[i]
    # Inline code `...`
    if ch == '`':
      let close = line.find('`', i + 1)
      if close > i:
        let inner = line[i + 1 ..< close]
        result.add("<code>")
        result.add(escapeHtml(inner))
        result.add("</code>")
        i = close + 1
        continue
    # Link [text](url)
    if ch == '[':
      let closeBracket = line.find(']', i + 1)
      if closeBracket > i and closeBracket + 1 < line.len and
          line[closeBracket + 1] == '(':
        let closeParen = line.find(')', closeBracket + 2)
        if closeParen > closeBracket + 1:
          let text = line[i + 1 ..< closeBracket]
          let url = line[closeBracket + 2 ..< closeParen]
          result.add("<a href=\"")
          result.add(escapeHtml(url))
          result.add("\">")
          result.add(escapeHtml(text))
          result.add("</a>")
          i = closeParen + 1
          continue
    # Escape any HTML-special character; everything else is verbatim.
    case ch
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    else: result.add ch
    inc i

proc renderMarkdown*(src: string): string =
  ## Render the supported markdown subset to HTML. Output is a
  ## concatenation of block elements separated by ``\n``; there is no
  ## trailing newline. Unrecognised constructs degrade gracefully:
  ## fences with no closing fence treat the rest of the document as a
  ## code block, and unmatched ``[`` / `` ` `` characters fall through
  ## to escaped text.
  if src.len == 0:
    return ""
  let lines = src.splitLines()
  var blocks: seq[string] = @[]
  var i = 0
  var paragraph: seq[string] = @[]

  proc flushParagraph() =
    if paragraph.len > 0:
      var body = ""
      for j, p in paragraph:
        if j > 0: body.add(' ')
        body.add(renderInline(p))
      blocks.add("<p>" & body & "</p>")
      paragraph.setLen(0)

  while i < lines.len:
    let raw = lines[i]
    let trimmed = raw.strip(leading = true, trailing = false)
    # Fenced code block ``` (optionally followed by language tag).
    if trimmed.startsWith("```"):
      flushParagraph()
      var body: seq[string] = @[]
      inc i
      while i < lines.len:
        let bodyRaw = lines[i]
        if bodyRaw.strip(leading = true, trailing = false).startsWith("```"):
          inc i
          break
        body.add(bodyRaw)
        inc i
      blocks.add("<pre><code>" & escapeHtml(body.join("\n")) & "</code></pre>")
      continue
    # Blank line terminates a paragraph.
    if raw.strip().len == 0:
      flushParagraph()
      inc i
      continue
    # ATX headings (must start at column 0 with the right number of #).
    if raw.startsWith("### "):
      flushParagraph()
      let txt = raw[4 .. ^1].strip(trailing = true)
      blocks.add("<h3>" & renderInline(txt) & "</h3>")
      inc i
      continue
    if raw.startsWith("## "):
      flushParagraph()
      let txt = raw[3 .. ^1].strip(trailing = true)
      blocks.add("<h2>" & renderInline(txt) & "</h2>")
      inc i
      continue
    if raw.startsWith("# "):
      flushParagraph()
      let txt = raw[2 .. ^1].strip(trailing = true)
      blocks.add("<h1>" & renderInline(txt) & "</h1>")
      inc i
      continue
    # Default: accumulate into the open paragraph.
    paragraph.add(raw)
    inc i

  flushParagraph()
  result = blocks.join("\n")
