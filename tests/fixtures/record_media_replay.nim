## Existing public Replay consumes the actual primitive-produced media records.
import ./replay_reads_bootstrap
import isonim/core/nondet
import nim_everywhere/time as neTime
proc read(query:cstring):bool {.exportc:"rmReplay".} = matchMedia($query)

proc mono():float64 {.exportc:"rmReplayMono".} = currentClock.now()
proc neMono():cstring {.exportc:"rmReplayNeMono".} = ($neTime.monotonicNowMs()).cstring
