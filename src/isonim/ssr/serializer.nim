## isonim/ssr/serializer.nim
##
## Resource data serialization for SSR-to-client transfer.
## Embeds resolved resource data into the HTML so the client can reuse it.

import std/json

proc serializeResourceData*(id: string; data: JsonNode): string =
  ## Serializes resource data as a <script> tag for client hydration.
  ## The client reads _$HY.r[id] to restore resource state.
  result = "<script>_$HY.r[\"" & id & "\"]=" & $data & ";</script>"

proc serializeResources*(resources: openArray[(string, JsonNode)]): string =
  ## Serializes multiple resources into a single script block.
  if resources.len == 0: return ""
  result = "<script>"
  for (id, data) in resources:
    result.add "_$HY.r[\"" & id & "\"]=" & $data & ";"
  result.add "</script>"
