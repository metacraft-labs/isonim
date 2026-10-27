## Actual public Clock/TestClock, NE facades and FakeAsyncContext. The supported
## scripted transport is intentional: assert bridge routing, not network I/O;
## the full nondet gate separately exercises real HTTP and Chromium. Timers run
## on the actual existing TestClock/FakeAsyncContext schedulers, never a mock hook.
import ./nondet_bridge_bootstrap
import std/[json, monotimes]
import isonim/core/nondet
import nim_everywhere/[backend, platform, async_compat, fake_time]
import nim_everywhere/time as neTime
import nim_everywhere/http as neHttp

when defined(js):
  proc hasWindow(): bool {.importjs: "(typeof window !== 'undefined')".}
else:
  proc hasWindow(): bool = false

let initiallySelected = currentClock
when defined(bridgeExplicit):
  if hasWindow() and not defined(bridgePreselect):
    # Original browser nil-clock bootstrap replaces even an explicit NE hook.
    doAssert currentClock of RealClock
    doAssert currentBackendHook != explicitHook,
      "nil-clock browser bootstrap must retain original replacement policy"
  else:
    doAssert currentBackendHook == explicitHook,
      "selected/native explicit hook identity must survive initialization"
    doAssert neTime.monotonicNowMs() == 777
else:
  doAssert currentBackendHook != nil,
    "nondet initialization must register a lazy forwarding bridge"

if not hasWindow() and not defined(bridgePreselect):
  doAssert initiallySelected == nil, "native/windowless import must not seed a clock"

when defined(bridgeClear):
  nondet.install(NondetBackend(nil))
  doAssert currentClock == nil and currentBackendHook == nil,
    "explicit clear must immediately restore absent clock and hook"
  discard neTime.monotonicNowMs()
  doAssert currentClock == nil and currentBackendHook == nil,
    "NE defaults after explicit clear must not reenter nondet implicitly"

# Existing FakeAsyncContext takes priority even when the lazy bridge has no clock.
let fake = newFakeAsyncContext()
fake.advance(17)
fake.install()
doAssert neTime.monotonicNowMs() == 17
if not hasWindow() and not defined(bridgePreselect):
  doAssert currentClock == nil, "fake facade read must not initialize RealClock"
fake.uninstall()

var selected: TestClock
when defined(bridgePreselect): selected = TestClock(currentClock)
else:
  selected = newTestClock(123.25)
  currentClock = selected

when defined(bridgeExplicit):
  # An explicit framework install is the existing opt-in to replace a custom hook.
  nondet.install(selected)
when defined(bridgeClear):
  doAssert currentBackendHook == nil
  # Reentry is a nondet backend request, not a promise to intercept an NE call
  # while its hook is explicitly disabled.
  discard nondet.now()

doAssert neTime.monotonicNowMs() == 123,
  "selected clock must drive NE monotonic time without a prior Real install"
doAssert nondet.now().ticks == 123_250_000

var fired: seq[string]
let first = neTime.scheduleAt(2, proc() = fired.add("first"))
let cancelled = neTime.scheduleAt(3, proc() = fired.add("cancelled"))
neTime.cancelTimer(first)
# Cancellation keeps the clock which actually owns this handle across selection.
currentClock = newTestClock(500)
neTime.cancelTimer(cancelled)
selected.advance(5)
doAssert fired.len == 0
currentClock = selected
discard neTime.scheduleAt(2, proc() = fired.add("selected"))
selected.advance(2)
doAssert fired == @["selected"]

# Fake time still owns its timers and monotonic reads while installed.
fake.install()
let fakeStart = fake.nowMs
var fakeFired = false
discard neTime.scheduleAt(2, proc() = fakeFired = true)
selected.advance(10)
doAssert not fakeFired
fake.advance(2)
doAssert fakeFired and neTime.monotonicNowMs() == fakeStart + 2
fake.uninstall()
doAssert neTime.monotonicNowMs() == int64(selected.currentTime)

var requests: seq[string]
selected.fetchResponse = proc(request: HttpRequest): PlatformFuture[HttpResponse] =
  requests.add(request.url & ":" & request.body)
  newCompletedFuture(HttpResponse(status: 231, body: "routed"))
discard neHttp.fetchHttp(HttpRequest(url: "/bridge", body: "payload"))
doAssert requests == @["/bridge:payload"], "cold bridge must route the real public fetch facade"

# Explicit clear remains immediate after this bridge has actually been used.
nondet.install(NondetBackend(nil))
doAssert currentClock == nil and currentBackendHook == nil
currentClock = selected
discard nondet.now()
doAssert currentBackendHook != nil and neTime.monotonicNowMs() == int64(selected.currentTime),
  "a selected backend request must repair an absent bridge after explicit clear"
echo "nondet-bridge-initialization: PASS"
