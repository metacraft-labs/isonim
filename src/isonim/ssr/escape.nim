## isonim/ssr/escape.nim
##
## HTML and attribute escaping utilities for server-side rendering.
## Prevents XSS by escaping special characters in rendered output.
##
## Two API styles:
## - `escapeHtml(s): string` — returns an escaped copy (allocates)
## - `writeEscapedHtml(stream, s)` — writes escaped output directly
##   to any object with a `write(string)` method

proc escapeHtml*(s: string): string =
  ## Escapes <, >, & for HTML content context (OWASP-correct).
  ## Allocates a new string. For streaming output, use writeEscapedHtml.
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '&': result.add "&amp;"
    else: result.add c

proc escapeAttr*(s: string): string =
  ## Escapes ", & for HTML attribute context (OWASP-correct).
  ## Allocates a new string. For streaming output, use writeEscapedAttr.
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '"': result.add "&quot;"
    of '&': result.add "&amp;"
    else: result.add c

proc writeUnchangedSpan[T](stream: T; s: string; first, last: int) {.inline.} =
  # Keep the slice fast path for writers such as FastStreams. String-only
  # writers (including our SSR OutputStream) need an allocated substring.
  mixin write
  when compiles(stream.write(s.toOpenArray(first, last))):
    stream.write(s.toOpenArray(first, last))
  else:
    stream.write(s[first .. last])

proc writeEscapedHtml*[T](stream: T; s: string) =
  ## Write HTML-escaped content to any writer with a write(string) method.
  ## Writers supporting write(openArray[char]) receive unchanged slices
  ## without allocating intermediate strings; string-only writers receive
  ## allocated substrings for those spans.
  ##
  ## Characters that need no escaping are batched into a single write
  ## call to minimize write overhead.
  var start = 0
  for i in 0 ..< s.len:
    let replacement = case s[i]
      of '<': "&lt;"
      of '>': "&gt;"
      of '&': "&amp;"
      else: ""
    if replacement.len > 0:
      if i > start:
        writeUnchangedSpan(stream, s, start, i - 1)
      stream.write(replacement)
      start = i + 1
  if start < s.len:
    writeUnchangedSpan(stream, s, start, s.len - 1)
  elif start == 0 and s.len == 0:
    discard  # empty string, nothing to write

proc writeEscapedAttr*[T](stream: T; s: string) =
  ## Write attribute-escaped content to any writer with write(string).
  ## Escapes " and &. Unchanged spans use allocation-free slices when the
  ## writer supports write(openArray[char]), or allocated substrings otherwise.
  var start = 0
  for i in 0 ..< s.len:
    let replacement = case s[i]
      of '"': "&quot;"
      of '&': "&amp;"
      else: ""
    if replacement.len > 0:
      if i > start:
        writeUnchangedSpan(stream, s, start, i - 1)
      stream.write(replacement)
      start = i + 1
  if start < s.len:
    writeUnchangedSpan(stream, s, start, s.len - 1)
