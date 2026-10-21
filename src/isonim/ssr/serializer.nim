## isonim/ssr/serializer.nim
##
## Resource data serialization for SSR-to-client transfer.
## Embeds resolved resource data into the HTML so the client can reuse it.

import std/[json, strutils]

proc scriptJson(value: JsonNode): string =
  # HTML parses script terminators even inside JavaScript string literals.
  # Escape payload characters, never the surrounding script element itself.
  ($value).replace("<", "\\u003c").replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")

proc resourceAssignment(id: string; data: JsonNode): string =
  # JSON.parse preserves own __proto__ properties. A JavaScript object literal
  # would instead interpret that spelling as a prototype declaration.
  let key = scriptJson(%id)
  let value = "JSON.parse(" & scriptJson(%($data)) & ")"
  if id == "__proto__":
    "Object.defineProperty(_$HY.r," & key & ",{value:" & value &
      ",enumerable:true,writable:true,configurable:true});"
  else:
    "_$HY.r[" & key & "]=" & value & ";"

proc serializeResourceData*(id: string; data: JsonNode): string =
  ## Serializes resource data as a <script> tag for client hydration.
  ## The client reads _$HY.r[id] to restore resource state.
  result = "<script>" & resourceAssignment(id, data) & "</script>"

proc serializeResources*(resources: openArray[(string, JsonNode)]): string =
  ## Serializes multiple resources into a single script block.
  if resources.len == 0: return ""
  result = "<script>"
  for (id, data) in resources:
    result.add resourceAssignment(id, data)
  result.add "</script>"
