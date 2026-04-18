## isonim/ssr/escape.nim
##
## HTML and attribute escaping utilities for server-side rendering.
## Prevents XSS by escaping special characters in rendered output.
##
## Two API styles:
## - `escapeHtml(s): string` — returns an escaped copy (allocates)
## - `writeEscapedHtml(stream, s)` — writes escaped output directly
##   to any object with a `write` method (zero allocation)

proc escapeHtml*(s: string): string =
  ## Escapes <, >, & for HTML content context (OWASP-correct).
  ## Allocates a new string. For zero-alloc, use writeEscapedHtml.
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '&': result.add "&amp;"
    else: result.add c

proc escapeAttr*(s: string): string =
  ## Escapes ", & for HTML attribute context (OWASP-correct).
  ## Allocates a new string. For zero-alloc, use writeEscapedAttr.
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '"': result.add "&quot;"
    of '&': result.add "&amp;"
    else: result.add c

proc writeEscapedHtml*[T](stream: T; s: string) =
  ## Write HTML-escaped content directly to a stream without allocating
  ## an intermediate string. Works with any type that has a write(string)
  ## method (FastStreams OutputStream, etc.).
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
        stream.write(s.toOpenArray(start, i - 1))
      stream.write(replacement)
      start = i + 1
  if start < s.len:
    stream.write(s.toOpenArray(start, s.len - 1))
  elif start == 0 and s.len == 0:
    discard  # empty string, nothing to write

proc writeEscapedAttr*[T](stream: T; s: string) =
  ## Write attribute-escaped content directly to a stream without
  ## allocating an intermediate string. Escapes " and &.
  var start = 0
  for i in 0 ..< s.len:
    let replacement = case s[i]
      of '"': "&quot;"
      of '&': "&amp;"
      else: ""
    if replacement.len > 0:
      if i > start:
        stream.write(s.toOpenArray(start, i - 1))
      stream.write(replacement)
      start = i + 1
  if start < s.len:
    stream.write(s.toOpenArray(start, s.len - 1))
