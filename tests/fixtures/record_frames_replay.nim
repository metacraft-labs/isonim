## Actual selected public Replay. Timestamp access is a test-only private oracle.
import ./replay_reads_bootstrap
import isonim/core/nondet {.all.}
import isonim/core/private/replay_reads
import std/options
import nim_everywhere/time as neTime
proc value(ts:float64) {.importjs:"globalThis.replayFrameValue(#)".}
proc frame(cb:proc()):int {.exportc:"rfReplayFrame".} =
  requestFrameObservation(proc(observation:FrameObservation) =
    doAssert observation.browserTimestamp.isSome
    value(observation.browserTimestamp.get())
    cb())
proc publicFrame(cb:proc()):int {.exportc:"rfReplayPublicFrame".} = requestFrame(cb)
proc timer(delay:float64;cb:proc()):int {.exportc:"rfReplayTimer".} = scheduleAt(delay,cb)
proc cancelFrame(handle:int) {.exportc:"rfReplayCancel".} = nondet.cancel(handle)
proc mono():float64 {.exportc:"rfReplayMono".} = currentClock.now()
proc neMono():cstring {.exportc:"rfReplayNeMono".} = ($neTime.monotonicNowMs()).cstring
proc dispose() {.exportc:"rfReplayDispose".} = disposeInternalReadReplay(currentClock)
