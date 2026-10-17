## Shared meaningful compiled-class minimum for nominal and quota envelopes.
## The producer records larger relevance minima in existing availability data;
## quota compaction must not infer them from partial HTML/property snapshots.
import std/strutils

const CompiledClassMinimumPrefix* = "availableTailwindClasses: required minimum "
const CompiledClassMinimumSuffix* = " compiled classes (current preview/selection/edits)"

proc compiledClassMinimum*(inventoryCount: int; relevanceCount = 0): int =
  max(min(128, inventoryCount), min(inventoryCount, relevanceCount))

proc compiledClassMinimumMarker*(count: int): string =
  CompiledClassMinimumPrefix & $count & CompiledClassMinimumSuffix

proc declaredCompiledClassMinimum*(marker: string): int =
  if not marker.startsWith("availableTailwindClasses: required minimum"): return 0
  if not marker.startsWith(CompiledClassMinimumPrefix) or
      not marker.endsWith(CompiledClassMinimumSuffix): return -1
  let value = marker[CompiledClassMinimumPrefix.len ..< marker.len - CompiledClassMinimumSuffix.len]
  if value.len == 0 or value[0] == '0': return -1
  for ch in value:
    if ch notin {'0'..'9'}: return -1
  try: result = parseInt(value)
  except ValueError: return -1
  if result <= 128: result = -1
