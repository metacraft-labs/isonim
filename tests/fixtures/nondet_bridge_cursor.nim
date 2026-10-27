## Actual owner cursor is bound only by the clock-only helper. These probes are
## deliberately incomplete read backends, never a fake framework declaration or
## accepted record/replay adapter. Storage remains visibly unconsumed.
when defined(bridgeCursorDefault):
  discard
elif defined(bridgeCursorSame):
  import isonim/core/clock
  import ./nondet_bridge_cursor_clock
  currentClock = newCursorClock(contextSeed())
elif defined(bridgeCursorLate):
  import ./nondet_bridge_cursor_late
else:
  import ./nondet_bridge_cursor_early
import isonim/core/nondet
import std/[json, monotimes]
import nim_everywhere/time as neTime
let observedNow = $nondet.now().ticks
let observedNe = $neTime.monotonicNowMs()
let observedStorage = nondet.storageGet("xr-probe")
let observedRandom = $nondet.random()
let observedEnv = nondet.env()
let report = cstring($(%*{"ticks": observedNow, "neMillis": observedNe,
  "storage": observedStorage, "random": observedRandom, "env": observedEnv}))
{.emit: "globalThis.xrNimObservation = JSON.parse(`report`);".}
