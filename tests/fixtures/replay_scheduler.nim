## Observe the actual synchronous queue and original RealClock reads/callbacks.
## Existing frame/timer fixtures justify observation instrumentation and preserve
## one Nim runtime per realm; none supplies a fake scheduler/cursor/task releaser.
include ./replay_frames
import isonim/core/scheduler

proc ownerStorage(present: bool; value: cstring) {.importjs: "globalThis.timerRecorder.guard(()=>globalThis.timerRecorder.emit('StorageRead',{area:1,key:'scheduler-control',present:#?1:0,value:#}))".}
proc schedulerStorage(): cstring {.exportc: "schedulerStorage".} =
  # Observe the exact native facade's single presence/value read. The replay
  # branch uses that same facade and actual cursor, never a synthetic provider.
  let observed = storageObservation("scheduler-control")
  if selected of ObservedClock: ownerStorage(observed.present, observed.value.cstring)
  observed.value.cstring

var queued: seq[Task]
var names: seq[string]
var shouldThrow: bool
var callbackError: ref ValueError
proc enqueue(name: string; timeout = 5000.0): Task =
  result = requestCallback(proc(t: bool) = trace((name & ":" & $t).cstring), timeout)
  queued.add(result)
  names.add(name)
proc schedulerSnapshot(): cstring {.exportc: "schedulerSnapshot".} =
  var entries = newJArray()
  for i, task in queued:
    entries.add(%*{"name": names[i], "id": task.id, "start": $task.startTime,
      "expiration": $task.expirationTime, "cancelled": task.cancelled,
      "functionNil": task.fn == nil})
  ($entries).cstring
proc schedulerFlush(): cstring {.exportc: "schedulerFlush".} =
  try:
    flushTasks()
    "ok"
  except ValueError as error:
    ($(%*{"same": error == callbackError, "message": error.msg})).cstring
proc schedulerFlushRaw() {.exportc: "schedulerFlushRaw".} = flushTasks()
proc schedulerPrepare(mode: cstring) {.exportc: "schedulerPrepare".} =
  case $mode
  of "basic":
    discard enqueue("late", 5000)
    discard enqueue("early", -5000)
    cancelCallback(enqueue("cancelled", 0))
  of "nested":
    var removed: Task
    discard requestCallback(timeoutMs = NegInf, fn = proc(t: bool) =
      trace(("outer:" & $t).cstring)
      cancelCallback(removed)
      discard enqueue("nested", 0)
      flushTasks()
      trace("after-reentry"))
    removed = enqueue("cancelled", Inf)
  of "nested-reorder":
    var appended = false
    discard requestCallback(timeoutMs = 0, fn = proc(t: bool) =
      trace(("outer:" & $t).cstring)
      if not appended:
        appended = true
        discard enqueue("nested-before-cursor", NegInf))
    discard enqueue("later", Inf)
  of "error", "error-owned":
    shouldThrow = true
    callbackError = newException(ValueError, "original scheduler callback")
    discard enqueue("prior", NegInf)
    discard requestCallback(timeoutMs = 0, fn = proc(t: bool) =
      trace(("throw:" & $t).cstring)
      if shouldThrow:
        shouldThrow = false
        raise callbackError)
    discard enqueue("after", Inf)
    if $mode == "error-owned":
      discard nondet.scheduleAt(0, proc() =
        discard nondet.scheduleAt(0, proc() = flushTasks())
        flushTasks())
  of "timer", "frame":
    let callback = proc() =
      discard enqueue("inside", 0)
      cancelCallback(enqueue("cancelled", 0))
      trace("before-flush")
      flushTasks()
      microtask(proc() = trace("micro"))
    if $mode == "timer": discard nondet.scheduleAt(0, callback)
    else: discard observedFrame(callback)
  of "two":
    discard enqueue("first", 5000)
    if selected of ObservedClock: other = ObservedClock()
    else: other = newInternalReadReplay(parseJson($suppliedContext()))
    install(other)
    discard enqueue("second", -5000)
  of "switch":
    let removed = enqueue("cancelled", 0)
    discard enqueue("retained", 1)
    install(ClockBase(nil))
    cancelCallback(removed)
    flushTasks()
    discard enqueue("nil", 0)
    flushTasks()
    install(newTestClock(100))
    discard enqueue("test-late", 10)
    discard enqueue("test-early", -10)
    flushTasks()
    install(TimerCustomClock())
    discard enqueue("custom", 0)
    flushTasks()
    install(selected)
    discard enqueue("resumed", 0)
    flushTasks()
  of "priority":
    install(newTestClock(100))
    discard enqueue("late", 10)
    discard enqueue("early", -10)
  of "hooks":
    let fake = newFakeAsyncContext()
    fake.install()
    doAssert neTime.monotonicNowMs() == 0
    discard enqueue("fake-selection", 0)
    flushTasks()
    fake.uninstall()
    installBackendHook(PlatformBackendHook(monotonicNowMs: proc(): int64 = 13))
    doAssert neTime.monotonicNowMs() == 13
    discard enqueue("hook-selection", 0)
    flushTasks()
    install(selected)
  else:
    raise newException(ValueError, "unknown scheduler mode")
proc schedulerNilCancel(): cstring {.exportc: "schedulerNilCancel".} =
  try:
    cancelCallback(nil)
    "accepted"
  except Defect as error:
    ("Defect:" & error.msg).cstring
proc schedulerPrepareChecked(mode: cstring): cstring {.exportc: "schedulerPrepareChecked".} =
  ## The refusal inverse must prove an actual Nim ValueError, not any thrown JS
  ## setup error; ordinary owner divergence uses the unwrapped entry above.
  try:
    schedulerPrepare(mode)
    "ok"
  except ValueError as error:
    ($(%*{"type": $error.name, "message": error.msg})).cstring
