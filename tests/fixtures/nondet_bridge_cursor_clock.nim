## Audit only: actual owner cursor binding, no fake replay provider. This module
## imports ClockBase alone; no nondet module or active framework declaration.
import std/random
import isonim/core/clock
proc replayNow(): float64 {.importjs: "globalThis.xrActualCursorNow()".}
type CursorClock = ref object of ClockBase
method now(clock: CursorClock): float64 = replayNow()
proc newCursorClock*(seed: int64): ClockBase =
  CursorClock(randomState: initRand(seed))
proc contextSeed*(): int64 {.importjs: "BigInt((globalThis['_'+String.fromCharCode(36)+'HY']||{}).seed??731)".}
