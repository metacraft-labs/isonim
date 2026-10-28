## Deliberate internal clock primitive preparation, not a selected backend.
## Importing this module never loads an owner or changes platform functions.
when defined(js) and defined(isonimInternalRecordClocks):
  import std/jsffi
  import nim_everywhere/raw_nondet

  type RecordClockPrimitives* = ref object
    linkage: JsObject

  proc prepare(window, recorder, originals: JsObject): JsObject {.importjs: "(function(w,r,o){var m=require('\\x40codetracer/boundary-shim/dist/browser/recorder.js');if(!w||w.window!==w||!w.performance||!o||typeof o.performanceNow!=='function'||typeof o.Date!=='function'||!(r instanceof m.Recorder))throw new TypeError('internal Record clocks require matching Window, captured originals and actual Recorder');return Object.freeze({performance:w.performance,performanceNow:o.performanceNow,Date:o.Date,rec:r,numberToBits:m.numberToBits});})(#,#,#)".}

  proc newInternalRecordClocks*(window, recorder, originals: JsObject): RecordClockPrimitives =
    ## The trusted caller captures originals before patching and owns start/end.
    ## Keep the supplied owner linkage; selection of unrelated clocks is inert.
    RecordClockPrimitives(linkage: prepare(window, recorder, originals))

  proc monotonic(linkage: JsObject): float64 {.importjs: "(function(c){var value=c.performanceNow.call(c.performance);c.rec.guard(function(){c.rec.emit('Clock',{src:2,bits:c.numberToBits(value)});});return value;})(#)", tags: [RawNondet].}
  proc wallEpoch(linkage: JsObject): float64 {.importjs: "(function(c){var value=new c.Date().getTime();c.rec.guard(function(){c.rec.emit('Clock',{src:3,bits:c.numberToBits(value)});});return value;})(#)", tags: [RawNondet].}

  proc recordMonotonicMs*(clocks: RecordClockPrimitives): float64 {.tags: [RawNondet].} =
    ## Native errors precede logging; recorder faults never replace the value.
    monotonic(clocks.linkage)

  proc recordWallEpochMs*(clocks: RecordClockPrimitives): float64 {.tags: [RawNondet].} =
    ## Preserve the raw double BEFORE the stock integer/Time projection.
    wallEpoch(clocks.linkage)
