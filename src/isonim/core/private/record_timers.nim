## Fixed native one-shot wire preparation; not a selected Recording backend.
## Native timers own callback lifetime. Importing this module schedules nothing.
when defined(js) and defined(isonimInternalRecordTimers):
  import std/[jsffi, math]
  import nim_everywhere/raw_nondet

  type RecordTimerPrimitives* = ref object
    linkage: JsObject

  proc prepare(window, recorder, originals: JsObject): JsObject
      {.importjs: "(function(w,r,o){var m=require('\\x40codetracer/boundary-shim/dist/browser/recorder.js');if(!w||w.window!==w||typeof w.Window!=='function'||!(w instanceof w.Window)||!(r instanceof m.Recorder)||!o||typeof o.setTimeout!=='function'||typeof o.clearTimeout!=='function')throw new TypeError('internal Record timers require actual Window, captured originals and actual Recorder');return Object.freeze({window:w,rec:r,set:o.setTimeout,clear:o.clearTimeout});})(#,#,#)".}

  proc newInternalRecordTimers*(window, recorder, originals: JsObject): RecordTimerPrimitives =
    ## The trusted caller captures matching originals before any patching and
    ## owns the actual Recorder session. This constructor selects no clock.
    RecordTimerPrimitives(linkage: prepare(window, recorder, originals))

  proc scheduleRaw(linkage: JsObject; delay: int; callback: proc()): int
      {.importjs: "(function(c,d,cb){var forward=function(){return cb();};if(!c.rec.recording)return c.set.call(c.window,forward,d);var task=c.rec.nextTaskId();var run=function(){c.rec.guard(function(){c.rec.task(task,1);});return forward();};var handle=c.set.call(c.window,run,d);c.rec.guard(function(){c.rec.emit('TaskReg',{task_id:task,kind:1,delay_ms:d});});return handle;})(#,#,#)", tags: [RawNondet].}
  proc cancelRaw(linkage: JsObject; handle: int)
      {.importjs: "(function(c,h){c.clear.call(c.window,h);})(#,#)", tags: [RawNondet].}

  proc recordTimeout*(timers: RecordTimerPrimitives; delayMs: float64;
      callback: proc()): int {.tags: [RawNondet].} =
    ## Preserve stock RealClock conversion before allocation/native scheduling.
    ## The forwarding function also preserves asynchronous nil-proc failure.
    let delay = max(0, ceil(delayMs).int)
    scheduleRaw(timers.linkage, delay, callback)

  proc cancelRecordTimeout*(timers: RecordTimerPrimitives; handle: int) {.tags: [RawNondet].} =
    ## Native handles, including unknown/fired handles, go to the captured
    ## platform cancellation unchanged. Cancellation has no wire record.
    cancelRaw(timers.linkage, handle)
