## Existing selected public Replay receives the real private-produced frames.
import ./replay_reads_bootstrap
import isonim/core/nondet
import isonim/core/private/replay_reads
import nim_everywhere/time as neTime
proc mono():float64 {.exportc:"rtReplayMono".} = currentClock.now()
proc neMono():cstring {.exportc:"rtReplayNeMono".} = ($neTime.monotonicNowMs()).cstring
proc schedule(delay:float64;cb:proc()):int {.exportc:"rtReplaySchedule".} = scheduleAt(delay,cb)
proc every(delay:float64;cb:proc()):int {.exportc:"rtReplayEvery".} = scheduleEvery(delay,cb)
proc cancelTimer(id:int) {.exportc:"rtReplayCancel".} = nondet.cancel(id)
proc dispose() {.exportc:"rtReplayDispose".} = disposeInternalReadReplay(currentClock)
