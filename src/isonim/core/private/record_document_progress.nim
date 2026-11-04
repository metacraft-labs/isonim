## Private document-loading linkage; importing it never installs an owner.
## The trusted caller starts its Recorder and attaches exactly once, before
## application scripts or platform patching, with matching captured originals.
## The owner retains its listeners and exposes no uninstall contract.
when defined(js) and defined(isonimInternalRecordDocumentProgress):
  import std/jsffi
  import nim_everywhere/raw_nondet

  proc attachRaw(window, recorder, originals: JsObject)
      {.importjs: """(function(w,r,o){
var Recorder=require('\x40codetracer/boundary-shim/dist/browser/recorder.js').Recorder;
if(!w||w.window!==w||typeof w.Window!=='function'||!(w instanceof w.Window)||!(r instanceof Recorder)||!o||typeof o.addEventListener!=='function')throw new TypeError('internal Record document progress requires actual Window, Recorder and captured addEventListener');
if(!r.recording)return;
r.guard(function(){require('\x40codetracer/boundary-shim/dist/browser/document-progress.js').recordDocumentProgress(w,r,o.addEventListener);});
})(#,#,#)""", tags: [RawNondet].}

  proc attachInternalRecordDocumentProgress*(window, recorder, originals: JsObject)
      {.tags: [RawNondet].} =
    ## Public recording admission precedes the owner's own guarded attachment.
    ## Branding cannot prove capture timing, realm pairing or exact-once use.
    attachRaw(window, recorder, originals)
