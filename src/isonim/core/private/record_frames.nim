## Fixed captured-native frame wire preparation, not a selected backend.
## Native frame callbacks own lifetime; importing this module performs no work.
when defined(js) and defined(isonimInternalRecordFrames):
  import std/jsffi
  import nim_everywhere/raw_nondet

  type RecordFramePrimitives* = ref object
    linkage: JsObject

  proc prepare(window, recorder, originals: JsObject): JsObject
      {.importjs: "(function(w,r,o){var m=require('\\x40codetracer/boundary-shim/dist/browser/recorder.js');if(!w||w.window!==w||typeof w.Window!=='function'||!(w instanceof w.Window)||!(r instanceof m.Recorder)||!o||typeof o.requestAnimationFrame!=='function'||typeof o.cancelAnimationFrame!=='function')throw new TypeError('internal Record frames require actual Window, captured originals and actual Recorder');return Object.freeze({window:w,rec:r,request:o.requestAnimationFrame,cancel:o.cancelAnimationFrame,bits:m.numberToBits});})(#,#,#)".}

  proc newInternalRecordFrames*(window, recorder, originals: JsObject): RecordFramePrimitives =
    ## Trusted caller captures matching originals before patches and owns session.
    ## Construction neither selects a clock nor schedules a native frame.
    RecordFramePrimitives(linkage: prepare(window, recorder, originals))

  proc requestRaw(linkage: JsObject; callback: proc(timestamp: float64)): int
      {.importjs: "(function(c,cb){var forward=function(ts){return cb(ts);};if(!c.rec.recording)return c.request.call(c.window,forward);var task=c.rec.nextTaskId();var run=function(ts){c.rec.guard(function(){c.rec.task(task,3);c.rec.emit('Clock',{src:4,bits:c.bits(ts)});});return forward(ts);};var handle=c.request.call(c.window,run);c.rec.guard(function(){c.rec.emit('TaskReg',{task_id:task,kind:3,delay_ms:0});});return handle;})(#,#)", tags: [RawNondet].}
  proc cancelRaw(linkage: JsObject; handle: int)
      {.importjs: "(function(c,h){c.cancel.call(c.window,h);})(#,#)", tags: [RawNondet].}

  proc recordFrame*(frames: RecordFramePrimitives;
      callback: proc(timestamp: float64)): int {.tags: [RawNondet].} =
    ## Preserve the exact delivered double and asynchronous nil-proc failure.
    ## Owner guard contains wire work only; application errors escape unchanged.
    requestRaw(frames.linkage, callback)

  proc cancelRecordFrame*(frames: RecordFramePrimitives; handle: int) {.tags: [RawNondet].} =
    ## Original native handle and receiver; cancellation has no wire record.
    cancelRaw(frames.linkage, handle)
