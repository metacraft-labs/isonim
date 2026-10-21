## Preserve HTML bytes while replacing canonical links. This scanner only
## recognises tag boundaries and attributes; raw-text bodies stay opaque.
## Script escaped states follow https://html.spec.whatwg.org/multipage/parsing.html#script-data-double-escaped-state.
import std/[strutils, tables]
from std/unicode import Rune, toUTF8
import ./escape

type HtmlTag = object
  finish: int
  name: string
  closing: bool
  attrs: Table[string, string]
  attributeSpans: Table[string, tuple[start, finish: int, hasValue: bool]]

proc attributeValue(value: string): string =
  # Canonical's ASCII rel token can contain numeric references. Named
  # references relevant to its whitespace/token boundaries are decoded too.
  var i = 0
  while i < value.len:
    if value[i] == '&':
      if i + 2 < value.len and value[i+1] == '#':
        var numberStart = i + 2
        let hexadecimal = value[numberStart] in {'x', 'X'}
        if hexadecimal: inc numberStart
        var numberEnd = numberStart
        let digits = if hexadecimal: {'0'..'9', 'a'..'f', 'A'..'F'} else: {'0'..'9'}
        while numberEnd < value.len and value[numberEnd] in digits: inc numberEnd
        if numberEnd > numberStart:
          try:
            let number = if hexadecimal: parseHexInt(value[numberStart ..< numberEnd])
                         else: parseInt(value[numberStart ..< numberEnd])
            if number > 0 and number <= 0x10ffff and number notin 0xd800..0xdfff:
              result.add Rune(number).toUTF8
              i = numberEnd
              if i < value.len and value[i] == ';': inc i
              continue
          except ValueError: discard
      let finish = value.find(';', i + 1)
      if finish >= 0:
        let entity = value[i+1 ..< finish]
        var decoded = ""
        case entity
        of "Tab": decoded = "\t"
        of "NewLine": decoded = "\n"
        of "amp": decoded = "&"
        of "quot": decoded = "\""
        of "apos": decoded = "'"
        of "lt": decoded = "<"
        of "gt": decoded = ">"
        else: discard
        if decoded.len > 0:
          result.add decoded
          i = finish + 1
          continue
    result.add value[i]
    inc i

proc readTag(html: string; start: int): HtmlTag =
  var i = start + 1
  if i < html.len and html[i] == '/':
    result.closing = true
    inc i
  let nameStart = i
  while i < html.len and html[i] in {'a'..'z','A'..'Z','0'..'9',':','-'}: inc i
  if i == nameStart: return
  result.name = html[nameStart ..< i].toLowerAscii
  while i < html.len:
    while i < html.len and html[i] in Whitespace: inc i
    if i >= html.len: break
    if html[i] == '>':
      result.finish = i + 1
      return
    if html[i] == '/':
      inc i
      continue
    let attributeStart = i
    while i < html.len and html[i] notin Whitespace + {'=','>','/'}: inc i
    if i == attributeStart:
      raise newException(ValueError, "invalid HTML attribute in static export")
    let name = html[attributeStart ..< i].toLowerAscii
    var spanStart = i
    var spanFinish = i
    var hasValue = false
    while i < html.len and html[i] in Whitespace: inc i
    var value = ""
    if i < html.len and html[i] == '=':
      hasValue = true
      inc i
      while i < html.len and html[i] in Whitespace: inc i
      spanStart = i
      if i < html.len and html[i] in {'\'', '"'}:
        let quote = html[i]
        inc i
        let valueStart = i
        while i < html.len and html[i] != quote: inc i
        value = html[valueStart ..< i]
        if i < html.len: inc i
      else:
        let valueStart = i
        while i < html.len and html[i] notin Whitespace + {'>'}: inc i
        value = html[valueStart ..< i]
      spanFinish = i
    # HTML uses the first occurrence of a duplicate attribute.
    if name notin result.attrs:
      result.attrs[name] = attributeValue(value)
      result.attributeSpans[name] = (spanStart, spanFinish, hasValue)
  raise newException(ValueError, "unterminated HTML tag in static export")

proc correctedCanonical(html: string; start: int; tag: HtmlTag; url: string): string =
  # Only the href value changes. In particular data-hk, CSP nonces, attribute
  # order and their original quoting remain owned by the page renderer.
  if "href" in tag.attributeSpans:
    let span = tag.attributeSpans["href"]
    result = html[start ..< span.start]
    if span.hasValue:
      let quote = if span.start < html.len and html[span.start] in {'\'', '"'}:
                    html[span.start]
                  else: '"'
      let escaped = if quote == '\'': escapeAttr(url).replace("'", "&#39;")
                    else: escapeAttr(url)
      result.add $quote & escaped & $quote
    else:
      result.add "=\"" & escapeAttr(url) & "\""
    result.add html[span.finish ..< tag.finish]
  else:
    var insertAt = tag.finish - 1
    if html[insertAt-1] == '/': dec insertAt
    result = html[start ..< insertAt] & " href=\"" & escapeAttr(url) & "\"" & html[insertAt ..< tag.finish]

proc withCanonicalUrl*(html, url: string): string =
  ## Correct the first head canonical's href, preserving its other attributes;
  ## remove duplicates, or insert a link if absent. Comments and raw text
  ## cannot supply a false head boundary or be rewritten as markup.
  var i = 0
  var copied = 0
  var heads, closes: int
  var inHead = false
  var keptCanonical = false
  while i < html.len:
    if html[i] != '<':
      inc i
      continue
    if html.continuesWith("<!--", i):
      let finish = html.find("-->", i + 4)
      if finish < 0: raise newException(ValueError, "unterminated HTML comment")
      i = finish + 3
      continue
    if i + 1 < html.len and html[i+1] in {'!', '?'}:
      let finish = html.find('>', i + 2)
      if finish < 0: raise newException(ValueError, "unterminated HTML declaration")
      i = finish + 1
      continue
    let tag = readTag(html, i)
    if tag.name.len == 0:
      inc i
      continue
    if tag.name == "head":
      if tag.closing:
        if not inHead: raise newException(ValueError, "unexpected HTML head close")
        inc closes
        inHead = false
        if not keptCanonical:
          result.add html[copied ..< i]
          result.add "<link rel=\"canonical\" href=\"" & escapeAttr(url) & "\">"
          copied = i
      else:
        inc heads
        inHead = true
    if tag.name == "link" and not tag.closing:
      if "canonical" in tag.attrs.getOrDefault("rel").toLowerAscii.splitWhitespace:
        result.add html[copied ..< i]
        if inHead and not keptCanonical:
          result.add correctedCanonical(html, i, tag, url)
          keptCanonical = true
        copied = tag.finish
    i = tag.finish
    if not tag.closing and tag.name in ["script", "style", "title", "textarea", "xmp", "iframe", "noembed", "noframes"]:
      # In HTML these elements treat apparent tags as text until their own
      # closing tag. The closing tag is recognised case-insensitively.
      var found = false
      var scriptEscape = 0 # HTML script data / escaped / double-escaped
      while i < html.len:
        if tag.name == "script":
          # HTML's legacy comment states matter even inside JavaScript string
          # literals. In double-escaped text, </script> returns to escaped
          # text rather than ending the element.
          if scriptEscape == 0 and html.continuesWith("<!--", i):
            scriptEscape = 1
            i += 4
            continue
          if scriptEscape > 0 and html.continuesWith("-->", i):
            scriptEscape = 0
            i += 3
            continue
        if html[i] != '<':
          inc i
          continue
        let candidate = i
        if tag.name == "script" and scriptEscape == 1 and
            candidate + 7 < html.len and html[candidate+1 .. candidate+6].toLowerAscii == "script" and
            html[candidate+7] in Whitespace + {'>', '/'}:
          scriptEscape = 2
          i += 7
          continue
        if candidate + 2 < html.len and html[candidate+1] == '/':
          var nameEnd = candidate + 2
          while nameEnd < html.len and html[nameEnd] in {'a'..'z','A'..'Z','0'..'9',':','-'}: inc nameEnd
          if html[candidate+2 ..< nameEnd].toLowerAscii == tag.name and
              nameEnd < html.len and html[nameEnd] in Whitespace + {'>', '/'}:
            if tag.name == "script" and scriptEscape == 2:
              scriptEscape = 1
              i = nameEnd
              continue
            let ending = readTag(html, candidate)
            i = ending.finish
            found = true
            break
        i = candidate + 1
      if not found: raise newException(ValueError, "unterminated raw HTML element: " & tag.name)
  if heads != 1 or closes != 1:
    raise newException(ValueError, "static export requires exactly one HTML head")
  result.add html[copied ..< html.len]
