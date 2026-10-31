## Actual imported preparation and public clock controls share one Nim graph.
import std/jsffi
import nim_everywhere/raw_nondet
import isonim/core/private/record_refusals
import isonim/core/nondet
import nim_everywhere/fake_time
import nim_everywhere/time as neTime
proc install(context: JsObject) {.exportc: "rfInstall".} =
  installInternalRecordRefusals(context)
proc selected(): ClockBase {.exportc: "rfSelected".} = currentClock
proc dispatch(): int {.exportc: "rfDispatch".} = backend().dispatchSequence.int
type RefusalCustomClock = ref object of ClockBase
method now(clock: RefusalCustomClock): float64 = 321
proc selectClock(kind: int) {.exportc: "rfSelect".} =
  if kind == 0: nondet.install(newRealBackend(1))
  elif kind == 1: nondet.install(newTestBackend())
  else: nondet.install(RefusalCustomClock(scripted: true))
var fake: FakeAsyncContext
var fired: int
proc fakeStart() {.exportc: "rfFakeStart".} =
  fake = newFakeAsyncContext()
  fake.advance(17)
  fake.install()
  fired = 0
  discard neTime.scheduleAt(2, proc() = inc fired)
proc fakeState(): JsObject {.exportc: "rfFakeState".} =
  JsObject{milliseconds: neTime.monotonicNowMs().int, fired: fired}
proc fakeAdvance() {.exportc: "rfFakeAdvance".} = fake.advance(2)
proc fakeEnd() {.exportc: "rfFakeEnd".} = fake.uninstall()

import nim_everywhere/backend as neBackend
proc hookStart() {.exportc: "rfHookStart".} =
  installBackendHook(PlatformBackendHook(monotonicNowMs: proc(): int64 = 777))
proc hook(): PlatformBackendHook {.exportc: "rfHook".} = currentBackendHook
proc hookValue(): int {.exportc: "rfHookValue".} = neTime.monotonicNowMs().int
