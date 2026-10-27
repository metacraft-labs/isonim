## Actual owner cursor only; context supplied by a separate genuine prior realm.
import ./replay_reads_bootstrap
import std/[json, monotimes]
import isonim/core/nondet
import nim_everywhere/time as neTime

proc controls(): cstring {.exportc: "xrViewportControls".} =
  let boot = env()
  let tick = $nondet.now().ticks
  let neMillis = $neTime.monotonicNowMs()
  let missing = storageGet("missing")
  let empty = storageGet("empty")
  let value = storageGet("value")
  let cookie = cookieGet()
  ($(%*{"env":boot,"tick":tick,"neMillis":neMillis,
    "missing":missing,"empty":empty,"value":value,"cookie":cookie})).cstring

proc observedViewport(): cstring {.exportc: "xrViewport".} =
  let rect = viewport()
  ($(%*{"x":rect.x,"y":rect.y,"width":rect.width,"height":rect.height})).cstring
