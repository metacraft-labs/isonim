## Genuine owner cursor, supplied prior boot context. No provider mock.
import ./replay_reads_bootstrap
import std/[json, monotimes]
import isonim/core/nondet
import nim_everywhere/time as neTime

proc controls(): cstring {.exportc: "xrMediaControls".} =
  let boot = env()
  let tick = $nondet.now().ticks
  let neMillis = $neTime.monotonicNowMs()
  let missing = storageGet("missing")
  let empty = storageGet("empty")
  let value = storageGet("value")
  let cookie = cookieGet()
  let rect = viewport()
  ($(%*{"env":boot,"tick":tick,"neMillis":neMillis,"missing":missing,
    "empty":empty,"value":value,"cookie":cookie,
    "viewport":{"x":rect.x,"y":rect.y,"width":rect.width,"height":rect.height}})).cstring

proc observedMedia(query: cstring): bool {.exportc: "xrMedia".} =
  matchMedia($query)
