## isonim/ssr/escape.nim
##
## HTML and attribute escaping utilities for server-side rendering.
## Prevents XSS by escaping special characters in rendered output.

proc escapeHtml*(s: string): string =
  ## Escapes <, >, & for HTML content context (OWASP-correct).
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '&': result.add "&amp;"
    else: result.add c

proc escapeAttr*(s: string): string =
  ## Escapes ", & for HTML attribute context (OWASP-correct).
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '"': result.add "&quot;"
    of '&': result.add "&amp;"
    else: result.add c
