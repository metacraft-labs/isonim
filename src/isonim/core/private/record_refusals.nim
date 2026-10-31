## Explicit application tripwire preparation for a trusted owner context.
## The caller owns original capture, policy and setup order. This private leaf
## checks linkage only; importing it neither patches APIs nor selects a backend.
when defined(js):
  # Keep the unused import graph identical with and without the private define.
  import std/jsffi
  import nim_everywhere/raw_nondet

when defined(js) and defined(isonimInternalRecordRefusals):
  proc installInternalRecordRefusals*(context: JsObject)
      {.importjs: """(function(c){
var m=require('\x40codetracer/boundary-shim/dist/browser/seams-refusals.js');
var R=require('\x40codetracer/boundary-shim/dist/browser/recorder.js').Recorder;
if(!c||!c.w||c.w.window!==c.w||typeof c.w.Window!=='function'||!(c.w instanceof c.w.Window)||!(c.rec instanceof R)||typeof c.refuseOnce!=='function')throw new TypeError('internal Record refusals requires actual Window, Recorder and trusted refuseOnce');
c.rec.guard(function(){m.patchRefusals(c);});
})(#)""", tags: [RawNondet].}
