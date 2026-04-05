## isonim/server/form_action.nim
##
## Form action utilities for the {.action.} pragma.
## Provides URL generation and form-encoded data parsing.

const actionPrefix* = "/api/actions/"

proc actionUrl*(name: string): string =
  ## Returns the URL for a named action.
  ## Used as a form `action` attribute.
  actionPrefix & name

template actionUrlOf*(fn: typed): string =
  ## Returns the URL for a {.action.} proc at compile time.
  ## Usage: form(action = actionUrlOf(createPost))
  actionUrl(astToStr(fn))

when not defined(js):
  import std/[json, tables, strutils]

  proc decodeUrlComponent*(s: string): string =
    ## Decode a URL-encoded string.
    ## Handles %XX hex escapes and '+' as space.
    result = newStringOfCap(s.len)
    var i = 0
    while i < s.len:
      case s[i]
      of '+':
        result.add(' ')
        inc i
      of '%':
        if i + 2 < s.len:
          let hi = s[i + 1]
          let lo = s[i + 2]
          let val = parseHexInt($hi & $lo)
          result.add(chr(val))
          i += 3
        else:
          result.add(s[i])
          inc i
      else:
        result.add(s[i])
        inc i

  proc parseFormData*(body: string): Table[string, string] =
    ## Parse application/x-www-form-urlencoded body.
    ## "title=Hello+World&body=Content" -> {"title": "Hello World", "body": "Content"}
    result = initTable[string, string]()
    if body.len == 0:
      return
    let pairs = body.split('&')
    for pair in pairs:
      let eqPos = pair.find('=')
      if eqPos >= 0:
        let key = decodeUrlComponent(pair[0 ..< eqPos])
        let val = decodeUrlComponent(pair[eqPos + 1 .. ^1])
        result[key] = val
      elif pair.len > 0:
        result[decodeUrlComponent(pair)] = ""

  proc formToJson*(formData: Table[string, string]): JsonNode =
    ## Convert form data table to a JSON object.
    ## Each value is stored as a JSON string.
    result = newJObject()
    for key, val in formData:
      result[key] = newJString(val)

  proc formBodyToJson*(body: string): JsonNode =
    ## Convenience: parse form body directly to JSON.
    formToJson(parseFormData(body))
