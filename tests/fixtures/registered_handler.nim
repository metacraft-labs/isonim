## Production listen and owner boundary, exercised with real browser nodes/events.
## The exported registration adapter accepts the actual JS callback as the typed
## proc representation; it keeps no registry or copied handler. Its identity is
## independently checked by native delivery followed by the private operation.
## The genuine Nim callback below is explicitly closure-typed BEFORE capture:
## inferred non-closure procs otherwise acquire a different bind(null) identity
## when converted at the existing listen parameter. No production conversion
## or callback contract is changed; the test keeps the exact converted value.
import std/[jsffi, json]
import isonim/core/[nondet, owner]
import nim_everywhere/fake_time
import nim_everywhere/time as neTime

type CountingClock = ref object of ClockBase
var clockReads, scheduledCalls, cancelCalls, checkpoints, fakeFired: int
method now(c: CountingClock): float64 =
  inc clockReads
  321.0
method schedule(c: CountingClock; cb: proc(); delay: float64): int =
  inc scheduledCalls
  1
method cancel(c: CountingClock; id: int) = inc cancelCalls
var fake: FakeAsyncContext
proc select(mode: cstring) {.exportc: "registeredSelect".} =
  if fake != nil:
    fake.uninstall()
    fake = nil
  case $mode
  of "real": install(newRealBackend(1))
  of "test": install(newTestBackend(123))
  of "custom": install(CountingClock())
  of "fake":
    install(newTestBackend(123))
    fake = newFakeAsyncContext()
    fake.install()
    discard neTime.scheduleAt(2, proc() = inc fakeFired)
  else: raise newException(ValueError, "unknown registered-handler test clock")
  when defined(isonimRecordable):
    currentClock.checkpointDispatch = proc() = inc checkpoints
proc state(): cstring {.exportc: "registeredState".} =
  var stamp = %*{"sequence": $currentClock.dispatchSequence,
    "clockReads": clockReads, "scheduled": scheduledCalls,
    "cancelled": cancelCalls, "checkpoints": checkpoints, "fakeFired": fakeFired}
  if fake != nil: stamp["fakeNow"] = %fake.now()
  ($stamp).cstring
proc advanceFake() {.exportc: "registeredAdvanceFake".} = fake.advance(2)
proc register(node: JsObject; kind: cstring; callback: proc(ev: JsObject);
    capture: bool): ListenerDisposer =
  nondet.listen(node, $kind, callback, capture)
proc owned(node: JsObject; kind: cstring; callback: proc(ev: JsObject);
    capture: bool): ListenerDisposer =
  var release: ListenerDisposer
  createRoot proc(dispose: proc()) =
    release = dispose
    discard nondet.listen(node, $kind, callback, capture)
  release
proc hook(callback: proc(record: JsObject)) = setListenerHook(callback)
{.emit: "globalThis.registeredListen=`register`;globalThis.registeredOwned=`owned`;globalThis.registeredHook=`hook`;".}
when defined(isonimInternalRegisteredHandlers):
  proc call(node: JsObject; kind: cstring; callback: JsObject; capture: bool;
      event: JsObject): JsObject =
    callInternalRegisteredHandler(node, kind, callback, capture, event)
  {.emit: "globalThis.registeredCall=`call`;".}
when defined(isonimDirectNondet):
  {.emit: "globalThis.registeredDirect=true;".}
else:
  {.emit: "globalThis.registeredDirect=false;".}
when defined(isonimRecordable):
  {.emit: "globalThis.registeredRecordable=true;".}
else:
  {.emit: "globalThis.registeredRecordable=false;".}

# A genuine Nim void callback is distinct from the identity-level JS callbacks
# used for arbitrary return/throw tests. Retain its callable only in this
# caller-owned test result, never in an additional production registry.
var typedCalls: int
proc typedCount(): int {.exportc: "registeredTypedCount".} = typedCalls
proc typedRegister(node: JsObject): JsObject {.exportc: "registeredTyped".} =
  let callback: proc(event: JsObject) {.closure.} = proc(event: JsObject) = inc typedCalls
  let dispose = nondet.listen(node, "click", callback)
  result = newJsObject()
  result.handler = toJs(callback)
  result.dispose = toJs(dispose)
