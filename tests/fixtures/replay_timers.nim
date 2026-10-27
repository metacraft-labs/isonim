## Native timer instrumentation, not a substitute Recording backend: observe
## actual RealClock callbacks through actual owner Recorder methods. No fake
## timers/tasks/cursor. Replay uses the production private clock/owned loop.
when defined(replayTimersEarly):
  import ./replay_reads_bootstrap
import std/[json, math, jsffi, monotimes]
import isonim/core/nondet
import isonim/core/private/replay_reads
import nim_everywhere/time as neTime
import nim_everywhere/[backend, fake_time]

type ObservedClock = ref object of RealClock
type TimerCustomClock = ref object of ClockBase
method now(clock: TimerCustomClock): float64 = 13.0
proc ownerId(): JsObject {.importjs: "globalThis.timerRecorder.nextTaskId()".}
proc ownerReg(task: JsObject; delay: int) {.importjs: "globalThis.timerRecorder.guard(()=>globalThis.timerRecorder.emit('TaskReg',{task_id:#,kind:1,delay_ms:#}))".}
proc ownerTask(task: JsObject) {.importjs: "globalThis.timerRecorder.guard(()=>globalThis.timerRecorder.task(#,1))".}
proc ownerClock(value: float64) {.importjs: "globalThis.timerClock(#)".}
method now(c: ObservedClock): float64 =
  result = procCall now(RealClock(c))
  ownerClock(result)
method schedule(c: ObservedClock; cb: proc(); delay: float64): int =
  # Normalize before allocating the owner id, as RealClock does before its
  # native timer registration. The real method still performs the operation.
  let normalized = max(0, ceil(delay).int)
  let task = ownerId()
  result = procCall schedule(RealClock(c), proc() =
    ownerTask(task)
    cb(), delay)
  ownerReg(task, normalized)

var selected, other: ClockBase
var savedCancel: proc()
var retainedHandle: int
proc trace(s: cstring) {.importjs: "(function(s){globalThis.timerTrace.push(s);document.querySelector('main').textContent=globalThis.timerTrace.join(',');})(#)".}
proc saveHandle(name: cstring; id: int) {.importjs: "(globalThis.timerHandles||(globalThis.timerHandles={}))[#]=#".}
proc microtask(cb: proc()) {.importjs: "queueMicrotask(#)".}
proc suppliedContext(): cstring {.importjs: "JSON.stringify(globalThis.timerContext)".}
proc context(): cstring {.exportc: "timerBoot".} = ($env()).cstring
proc record() {.exportc: "timerSelectRecord".} =
  selected = ObservedClock(bootEnv: env())
  install(selected)
proc replay() {.exportc: "timerSelectReplay".} =
  when defined(replayTimersEarly): selected = currentClock
  else: selected = newInternalReadReplay(parseJson($suppliedContext()))
  install(selected)
proc neutral(): cstring {.exportc: "timerNeutral".} =
  let snapshot = env()
  let tick = nondet.now().ticks
  ($(%*{"context":snapshot,"tick": $tick})).cstring
proc disposal() {.exportc: "timerDispose".} = disposeInternalReadReplay(selected)
proc disposalOther() {.exportc: "timerDisposeOther".} = disposeInternalReadReplay(other)
proc dispatches(): cstring {.exportc: "timerDispatches".} =
  ($(%*{"selected": $selected.dispatchSequence,
    "other":(if other == nil: "0" else: $other.dispatchSequence)})).cstring
proc cancelUnknown() {.exportc: "timerUnknownCancel".} =
  nondet.cancel(999999)
  selected.cancel(999999)
proc cancelRetained() {.exportc: "timerCancelRetained".} = nondet.cancel(retainedHandle)
proc scheduleDisposed() {.exportc: "timerScheduleDisposed".} =
  discard selected.schedule(proc() = trace("disposed"), 0)
proc switchAway() {.exportc: "timerSwitchAway".} = install(newTestBackend())
proc switchNil() {.exportc: "timerSwitchNil".} = install(ClockBase(nil))
proc reselect() {.exportc: "timerReselect".} = install(selected)
proc invokeSavedCancel() {.exportc: "timerSavedCancel".} = savedCancel()

proc start(mode: cstring) {.exportc: "timerStart".} =
  case $mode
  of "positive":
    trace("start")
    let removed = nondet.scheduleAt(100, proc() = trace("CANCELED"))
    nondet.cancel(removed)
    discard nondet.scheduleAt(0, proc() =
      trace("zero")
      microtask(proc() = trace("micro")))
    discard nondet.scheduleAt(2.25, proc() = trace("fractional"))
    var every: int
    var count = 0
    every = nondet.scheduleEvery(4, proc() =
      inc count
      trace(("tick" & $count).cstring)
      if count == 2: nondet.cancel(every))
    trace("registered")
  of "nested":
    discard nondet.scheduleAt(0, proc() =
      trace("outer")
      discard nondet.scheduleAt(0, proc() = trace("nested"))
      microtask(proc() = trace("micro")))
  of "error":
    discard nondet.scheduleAt(0, proc() =
      trace("error")
      raise newException(ValueError, "timer callback"))
    discard nondet.scheduleAt(2, proc() = trace("after-error"))
  of "premature":
    discard nondet.scheduleAt(0, proc() =
      try:
        disposeInternalReadReplay(selected)
        trace("WRONG disposed")
      except ValueError:
        trace("dispose-refused"))
  of "two":
    saveHandle("first", nondet.scheduleAt(0, proc() = trace("first")))
    if selected of ObservedClock: other = ObservedClock()
    else: other = newInternalReadReplay(parseJson($suppliedContext()))
    install(other)
    saveHandle("second", nondet.scheduleAt(2, proc() = trace("second")))
    install(selected)
  of "pending":
    retainedHandle = nondet.scheduleAt(100000, proc() = trace("pending"))
  of "cancel-mismatch", "task-kind":
    retainedHandle = nondet.scheduleAt(0, proc() = trace("required"))
  of "after-fire":
    retainedHandle = nondet.scheduleAt(0, proc() = trace("fired"))
  of "ne-cancel":
    let handle = neTime.scheduleAt(100, proc() = trace("CANCELED"))
    savedCancel = proc() = neTime.cancelTimer(handle)
    install(newTestBackend())
    savedCancel()
    install(selected)
    discard nondet.scheduleAt(0, proc() = trace("remaining"))
  of "ne-every":
    var count = 0
    var handle: neTime.TimerHandle
    handle = neTime.scheduleEvery(4, proc() =
      inc count
      trace(("ne" & $count).cstring)
      if count == 2: neTime.cancelTimer(handle))
  of "switch-nil":
    discard selected.schedule(proc() = trace("owned-after-nil"), 0)
    install(ClockBase(nil))
  of "switch-test":
    discard selected.schedule(proc() = trace("owned-after-test"), 0)
    install(newTestBackend())
  of "switch-real":
    discard selected.schedule(proc() = trace("owned-after-real"), 0)
    install(newRealBackend(731))
  of "switch-custom":
    discard selected.schedule(proc() = trace("owned-after-custom"), 0)
    install(TimerCustomClock())
  of "priority":
    let before = selected.dispatchSequence
    let fake = newFakeAsyncContext()
    fake.install()
    discard neTime.scheduleAt(2, proc() = trace("fake"))
    fake.advance(2)
    fake.uninstall()
    doAssert selected.dispatchSequence == before
    let scripted = newTestClock()
    installBackendHook(PlatformBackendHook(schedule: proc(ms: int; cb: proc()): proc() =
      let id = scripted.schedule(cb, ms.float64)
      result = proc() = scripted.cancel(id)))
    discard neTime.scheduleAt(2, proc() = trace("explicit"))
    scripted.advance(2)
    doAssert selected.dispatchSequence == before
    install(selected)
  else:
    raise newException(ValueError, "unknown timer test mode")

proc delay(value: float64): cstring {.exportc: "timerDelay".} =
  try:
    discard selected.schedule(proc() = trace("delay"), value)
    "registered"
  except Defect as error:
    ("Defect:" & error.msg).cstring
