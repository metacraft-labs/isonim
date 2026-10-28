## Existing selected public Replay consumes the actual primitive-produced log.
import ./replay_reads_bootstrap
import std/json
import isonim/core/nondet
proc read(): cstring {.exportc: "rlReplay".} =
  let r = viewport()
  ($(%*{"x":r.x,"y":r.y,"width":r.width,"height":r.height})).cstring
