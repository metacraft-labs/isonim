## Public nil-selector compatibility; no cursor/provider is mocked.
import isonim/core/[clock,scheduler,nondet]
import std/times
import nim_everywhere/time as neTime
when defined(isonimInternalReplayReads):
  import isonim/core/private/replay_reads
  doAssert not isReadReplay(ClockBase(nil))
doAssert currentClock == nil
var calls = 0
let task = requestCallback(proc(didTimeout:bool)=inc calls)
cancelCallback(task)
flushTasks()
doAssert calls == 0
let live = requestCallback(proc(didTimeout:bool)=inc calls)
flushTasks()
doAssert calls == 1 and currentClock == nil
currentClock = nil
cancelCallback(live)
flushTasks()
echo "nil selector exact predicate/public scheduler: PASS"

# Explicit clearing leaves NE defaults active, without selecting a clock.
install(ClockBase(nil))
doAssert currentClock == nil
let ordinaryMillis = neTime.monotonicNowMs()
doAssert ordinaryMillis >= 0 and currentClock == nil
# Public facade requests lazily select the ordinary backend, not TypeError.
doAssert wallNow().toUnix() > 0
doAssert currentClock != nil
nondet.cancel(123456)
# Direct nil retains the bridge; its next NE request must genuinely reenter.
install(newTestBackend())
currentClock = nil
let reenteredMillis = neTime.monotonicNowMs()
doAssert reenteredMillis >= 0 and currentClock != nil
doAssert wallNow().toUnix() > 0
echo "nil selector explicit-clear/direct-nil NE and wall/cancel semantics: PASS"
