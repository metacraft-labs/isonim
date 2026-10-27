## Real owner integration only. Separate early dependency import or deliberate
## late selection uses genuine explicitly supplied context, not archive delivery.
when not defined(replayWallLate):
  import ./replay_reads_bootstrap
import std/[json, times, monotimes]
import isonim/core/nondet
import isonim/core/private/replay_reads
import nim_everywhere/time as neTime

when defined(replayWallLate):
  var selected: ClockBase
  proc context(): cstring {.importjs: "JSON.stringify(globalThis.xrReadBootContext)".}
  proc selectLate() {.exportc: "xrWallSelectLate".} =
    selected = newInternalReadReplay(parseJson($context()))
    install(selected)

proc snapshot(): cstring {.exportc: "xrWallSnapshot".} = ($env()).cstring
proc observedWall(): cstring {.exportc: "xrWallObserve".} =
  let observed = wallNow()
  ($(%*{"seconds": $observed.toUnix, "nanoseconds": observed.nanosecond})).cstring
proc controls(): cstring {.exportc: "xrWallControls".} =
  let snapshot = env()
  let tick = $nondet.now().ticks
  let neMillis = $neTime.monotonicNowMs()
  let missing = storageGet("missing")
  let empty = storageGet("empty")
  let value = storageGet("value")
  let cookie = cookieGet()
  ($(%*{"env":snapshot,"tick":tick,"neMillis":neMillis,
    "missing":missing,"empty":empty,"value":value,"cookie":cookie})).cstring
proc switchReal() {.exportc:"xrWallSwitchReal".} = install(newRealBackend(731))
proc switchNil() {.exportc:"xrWallSwitchNil".} = install(ClockBase(nil))
proc switchDirectNil() {.exportc:"xrWallSwitchDirectNil".} = currentClock = nil
proc switchTest() {.exportc:"xrWallSwitchTest".} =
  let b = newTestBackend()
  b.script("wallNow", @[%0.5])
  install(b)
type CustomClock = ref object of ClockBase
method now(clock: CustomClock): float64 = 13.0
proc switchCustom() {.exportc:"xrWallSwitchCustom".} = install(CustomClock())
