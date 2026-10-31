## Private owner upload linkage; not an active Recording backend or scrub policy.
## The caller captures matching originals before patching, supplies actual owner
## options and pairs the returned sink with the Recorder it later attaches.
when defined(js) and defined(isonimInternalRecordUpload):
  import std/jsffi
  import nim_everywhere/raw_nondet

  type RecordUploadPrimitives* = ref object
    linkage: JsObject

  proc prepare(window, originals, options: JsObject): JsObject
      {.importjs: """(function(w,o,options){
var T=require('\x40codetracer/runtime-browser/dist/batch-transport.js').HttpBatchTransport;
if(!w||w.window!==w||typeof w.Window!=='function'||!(w instanceof w.Window)||!o||!options)throw new TypeError('internal Record upload requires actual Window, captured originals and options');
for(var k of ['setTimeout','clearTimeout','Promise','promiseThen','mathRandom'])if(typeof o[k]!=='function')throw new TypeError('internal Record upload requires captured '+k);
var c={rec:undefined,completion:undefined,transport:undefined,sink:undefined};
var callback=options.onDisabled;
var opts=Object.assign({},options,{window:w,originals:o,onDisabled:function(reason){if(c.rec)c.rec.halt();if(typeof callback==='function')return callback.call(this,reason);}});
c.transport=new T(opts);
c.sink=Object.freeze({append:function(frame,seq){c.transport.append(frame,seq);},end:function(unloading,frame){c.completion=c.transport.end(unloading,frame);},halt:function(){c.transport.halt();}});
return c;
})(#,#,#)""", tags: [RawNondet].}

  proc newInternalRecordUpload*(window, originals, options: JsObject): RecordUploadPrimitives {.tags: [RawNondet].} =
    ## Owner options and scrub callbacks remain a trusted caller obligation.
    ## Optional absent originals follow the owner's documented fallback order.
    RecordUploadPrimitives(linkage: prepare(window, originals, options))

  proc sinkRaw(linkage: JsObject): JsObject
      {.importjs: "#.sink", tags: [RawNondet].}
  proc recordUploadSink*(upload: RecordUploadPrimitives): JsObject {.tags: [RawNondet].} =
    ## Stable owner FrameSink; correct Recorder pairing is a caller precondition.
    sinkRaw(upload.linkage)

  proc attachRaw(linkage, recorder: JsObject)
      {.importjs: """(function(c,r){
var R=require('\x40codetracer/boundary-shim/dist/browser/recorder.js').Recorder;
if(!(r instanceof R))throw new TypeError('internal Record upload requires actual Recorder attachment');
if(c.rec&&c.rec!==r)throw new TypeError('internal Record upload already attached');
c.rec=r;
if(c.transport.status().state==='off')r.halt();
})(#,#)""", tags: [RawNondet].}
  proc attachRecordUploadRecorder*(upload: RecordUploadPrimitives; recorder: JsObject) {.tags: [RawNondet].} =
    ## Brand cannot establish sink pairing; no owner private state is inspected.
    attachRaw(upload.linkage, recorder)

  proc completionRaw(linkage: JsObject): JsObject
      {.importjs: "(function(c){if(c.completion===undefined)throw new Error('internal Record upload has no End completion');return c.completion;})(#)", tags: [RawNondet].}
  proc recordUploadCompletion*(upload: RecordUploadPrimitives): JsObject {.tags: [RawNondet].} =
    ## Exact owner promise, populated only by the actual Recorder sink.end.
    completionRaw(upload.linkage)

  proc consentRaw(linkage, callback: JsObject)
      {.importjs: "#.transport.consent(#)", tags: [RawNondet].}
  proc recordUploadConsent*(upload: RecordUploadPrimitives; callback: JsObject) {.tags: [RawNondet].} =
    ## Preserve the owner immediate callback/native Promise consent contract.
    consentRaw(upload.linkage, callback)
  proc flushRaw(linkage: JsObject)
      {.importjs: "#.transport.flush()", tags: [RawNondet].}
  proc recordUploadFlush*(upload: RecordUploadPrimitives) {.tags: [RawNondet].} =
    ## Request an owner flush without implementing a second deadline policy.
    flushRaw(upload.linkage)
  proc statusRaw(linkage: JsObject): JsObject
      {.importjs: "#.transport.status()", tags: [RawNondet].}
  proc recordUploadStatus*(upload: RecordUploadPrimitives): JsObject {.tags: [RawNondet].} =
    ## Return actual owner diagnostics, without a second lifecycle state machine.
    statusRaw(upload.linkage)
