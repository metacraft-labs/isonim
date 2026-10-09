## Shared Web-renderer identity stamp. Capture reads the actual loaded document,
## never a label assigned to an iframe whose previous document is still loaded.
## Scan markup boundaries without reserializing authored documents: attributes,
## comments and raw-text element contents must retain their original bytes.
import std/strutils
import isonim/editor/types
import isonim/ssr/escape

proc startsAt(value, prefix: string; position: int): bool =
  position + prefix.len <= value.len and value[position ..< position + prefix.len] == prefix

proc tagEnd(html: string; start: int): int =
  var quote = '\0'
  for i in start ..< html.len:
    let ch = html[i]
    if quote != '\0':
      if ch == quote: quote = '\0'
    elif ch in {'\'', '"'}: quote = ch
    elif ch == '>': return i
  -1

proc tagNameEnd(html: string; start: int): int =
  result = start
  while result < html.len and html[result] notin {' ', '\t', '\r', '\n', '\f', '/', '>'}:
    inc result

proc stampPosition(html: string): int =
  # Only leading markup can establish the document head. Before the first
  # implicit-head/content token, inserting metadata lets the browser create its
  # normal implicit head. Never inspect script, RCDATA or template bodies: their
  # apparent tags are authored data, with tokenizer states owned by the browser.
  let lower = html.toLowerAscii()
  var cursor = if html.startsAt("\xEF\xBB\xBF", 0): 3 else: 0
  while cursor < html.len:
    while cursor < html.len and html[cursor] in {' ', '\t', '\r', '\n', '\f'}:
      inc cursor
    if cursor >= html.len: return cursor
    if lower.startsAt("<!--", cursor):
      let finish = lower.find("-->", cursor + 4)
      if finish < 0: return cursor
      cursor = finish + 3
      continue
    if lower.startsAt("<?", cursor):
      # In text/html a leading PI is a comment boundary, not an XML document.
      let finish = html.find('>', cursor + 2)
      if finish < 0: return cursor
      cursor = finish + 1
      continue
    if lower.startsAt("<!doctype", cursor) and cursor + 9 < html.len and
        html[cursor + 9] in {' ', '\t', '\r', '\n', '\f', '>'}:
      let finish = tagEnd(html, cursor + 9)
      if finish < 0: return cursor
      cursor = finish + 1
      continue
    if html[cursor] != '<' or cursor + 1 >= html.len or
        html[cursor + 1] notin {'a'..'z', 'A'..'Z'}:
      return cursor
    let nameEnd = tagNameEnd(html, cursor + 1)
    let name = lower[cursor + 1 ..< nameEnd]
    if name notin ["html", "head"]: return cursor
    let finish = tagEnd(html, nameEnd)
    if finish < 0: return cursor
    if name == "head": return finish + 1
    cursor = finish + 1
  cursor

proc stampedPreviewDocument*(html, identity: string): string =
  ## Add editor metadata at the existing lossless head boundary.
  if html.len == 0: return ""
  let position = stampPosition(html)
  html[0 ..< position] & identity & html[position ..< html.len]

proc identifiedPreviewDocument*(html: string; story: StoryRef; generation: int): string =
  if html.len == 0: return ""
  let identity = "<meta name=\"isonim-rendered-story\" content=\"" &
    escapeAttr(story.group & " / " & story.name) & "\"><meta name=\"isonim-rendered-generation\" content=\"" & $generation & "\">"
  stampedPreviewDocument(html, identity)
