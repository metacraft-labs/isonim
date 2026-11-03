/** Typed private consumer qualification. Real native constructors, signals,
 * Chromium and held local HTTP are used. The local server is the transport
 * fixture explicitly permitted for boundary recording; it withholds the head
 * until an observed real request. Body/allocator wrappers only count genuine
 * calls. Capability absence is established in each fresh realm before capture.
 * No cursor, task, codec, completion or originals object is manufactured.
 */
export async function runTypedHttp7c({assert,page,slot,requests,results}) {
  const rows = [
    {kind:'validation',name:'get-body',badHeader:false},
    {kind:'validation',name:'crlf-header',badHeader:true},
    ...['default','undefined','error','string','null','zero','false','empty'].map(reason=>({kind:'abort',name:'reason-'+reason,reason})),
    {kind:'abort',name:'no-any-error',reason:'error',noAny:true},
    {kind:'abort',name:'no-any-string',reason:'string',noAny:true},
    {kind:'abort',name:'stopped-error',reason:'error',stopped:true},
    {kind:'abort',name:'no-any-stopped-error',reason:'error',noAny:true,stopped:true},
  ];
  for (const row of rows.filter(row=>!process.env.HTTP7C_CASE || row.name===process.env.HTTP7C_CASE)) {
    const id='typed-'+row.name, url=(row.kind==='abort'?'/head':'/ready')+'?id='+id;
    // An independent fresh native realm supplies expected constructor diagnostics
    // or the existing direct compiled RPC projection. It is never a Replay leg.
    const reference=await page();
    let expected;
    if(row.kind==='validation') {
      expected=await reference.evaluate(async ({url,badHeader})=>{
        const RequestCtor=Request, nativeFetch=fetch;
        const init=badHeader?{method:'GET',headers:{'X-Validation':'bad\r\nvalue'}}:{method:'GET',body:'nonempty',headers:{}};
        let constructorError,nativeError;
        try { new RequestCtor(url,init); } catch(e){constructorError={name:e.name,message:e.message};}
        try { await nativeFetch(url,init); } catch(e){nativeError={name:e.name,message:e.message};}
        return {constructorError,nativeError};
      },{url,badHeader:row.badHeader});
      assert.equal(expected.constructorError.name,'TypeError');
      assert.equal(expected.nativeError.name,'TypeError');
      assert.notEqual(expected.constructorError.message,expected.nativeError.message,'independent Request and fetch diagnostic contexts differ');
      assert.match(expected.constructorError.message,/Request/);
    } else {
      await reference.evaluate(({url,row})=>{
        const controller=new AbortController();
        const reason=()=>({error:new Error('typed custom cancellation'),string:'typed cancellation',null:null,zero:0,false:false,empty:''})[row.reason];
        globalThis.typedNative={controller,reason};
        globalThis.typedReferenceState={state:'pending'};
        rhReplayRpc(fetch,url+'-reference','payload',controller.signal,null).then(value=>{typedReferenceState={state:'fulfilled',value};},error=>{typedReferenceState={state:'rejected',error:String(error)};});
      },{url,row});
      await slot(id+'-reference');
      await reference.evaluate((row)=>{if(row.reason==='default')typedNative.controller.abort();else if(row.reason==='undefined')typedNative.controller.abort(undefined);else typedNative.controller.abort(typedNative.reason());},row);
      await reference.waitForFunction(()=>typedReferenceState.state!=='pending');
      expected=await reference.evaluate(()=>({projection:typedReferenceState,reason:String(typedNative.controller.signal.reason)}));
      assert.deepEqual(expected.projection,{state:'fulfilled',value:{status:-1,text:expected.reason,retryAfter:'',commit:''}},'independent native existing RPC projector uses the actual signal reason');
    }
    await reference.close();
    const p=await page();
    await p.evaluate(({row,url})=>{
      const anyDescriptor=Object.getOwnPropertyDescriptor(AbortSignal,'any');
      const capabilityBefore={own:!!anyDescriptor,configurable:anyDescriptor?.configurable,writable:anyDescriptor?.writable,enumerable:anyDescriptor?.enumerable,valueType:typeof anyDescriptor?.value};
      if(row.noAny){if(!anyDescriptor?.configurable)throw Error('actual configurable AbortSignal.any required');delete AbortSignal.any;}
      const a=rhOwner, orig=a.captureOriginals(window);
      if(row.noAny && ('any' in AbortSignal || orig.abortSignalAny!==undefined))throw Error('genuine no-any absence must precede captureOriginals');
      if(orig.finalizationRegistry?.ctor!==FinalizationRegistry || orig.finalizationRegistry.register!==FinalizationRegistry.prototype.register || orig.finalizationRegistry.unregister!==FinalizationRegistry.prototype.unregister || orig.AbortSignal!==AbortSignal || orig.Request!==Request)throw Error('new owner must capture genuine originals including FinalizationRegistry');
      const frames=[], sensitive=a.sensitiveState(window), counts={native:0,body:0,completion:0,task:0,request:0,resolutions:[]}, native=orig.fetch, text=Response.prototype.text;
      orig.fetch=function(...args){counts.native++;return native.apply(this,args);};
      Response.prototype.text=function(...args){counts.body++;return text.apply(this,args);};
      const rec=new a.Recorder({checkpointScheme:'dom-v1',checkpointHash:()=>a.domV1Hash(document),sink:{append:f=>frames.push(f),end:(u,f)=>frames.push(f),halt(){}}});
      rec.start({vocab:1,protocol_level:0,recorder_id:'typed-http',framework:'',build_hash:'a'.repeat(64),session_id:'1'.repeat(32),prev_session:'',capabilities:'[]'},a.readEnvironment(window,orig));
      const ctx={w:window,rec,orig,sensitive,holes:()=>a.currentSensitiveValues(window,sensitive),refuseOnce(feature,detail){rec.guard(()=>rec.emit('Refusal',{feature,detail}));}};
      rhInit(ctx);
      const controller=new AbortController();
      if(row.stopped)controller.signal.addEventListener('abort',e=>e.stopImmediatePropagation());
      const reason=()=>({error:new Error('typed custom cancellation'),string:'typed cancellation',null:null,zero:0,false:false,empty:''})[row.reason];
      globalThis.typedState={a,orig,rec,frames,counts,controller,reason,state:'pending',dispatch:rhDispatch(),capabilityBefore,noAny:!('any' in AbortSignal)};
      const NativePromise=Promise;
      if(row.kind==='validation')window.Promise=class extends NativePromise {
        constructor(executor){const cell={resolve:0,reject:0};counts.resolutions.push(cell);super((resolve,reject)=>executor(function(...args){cell.resolve++;return resolve.apply(this,args);},function(...args){cell.reject++;return reject.apply(this,args);}));}
      };
      let pending;
      try {pending=row.kind==='validation'?rhTypedInvalid(url,row.badHeader):rhRpc(url,'payload',controller.signal,null);} finally {window.Promise=NativePromise;}
      pending.then(value=>{counts.completion++;typedState.value=row.kind==='validation'?rhView(value):value;typedState.state='fulfilled';},error=>{counts.completion++;typedState.error=String(error);typedState.state='rejected';});
    },{row,url});
    if(row.kind==='abort') {
      await slot(id);
      assert.equal(await p.evaluate(()=>typedState.state),'pending','real server witness precedes native abort');
      assert.equal(await p.evaluate(()=>typedState.counts.body),0,'held head has no body consumer');
      await p.evaluate(row=>{if(row.reason==='default')typedState.controller.abort();else if(row.reason==='undefined')typedState.controller.abort(undefined);else typedState.controller.abort(typedState.reason());},row);
    }
    await p.waitForFunction(()=>typedState.state!=='pending');
    const record=await p.evaluate(()=>{
      const t=typedState;t.rec.end(2);const records=t.frames.map(f=>t.a.decodeRecord(f.subarray(4)));let raw='';for(const b of t.a.encodeLog(records))raw+=String.fromCharCode(b);
      return {state:t.state,value:t.value,error:t.error,counts:t.counts,dispatchBefore:t.dispatch,dispatchAfter:rhDispatch(),capabilityBefore:t.capabilityBefore,noAny:t.noAny,log:btoa(raw),records:JSON.parse(JSON.stringify(records,(_,v)=>typeof v==='bigint'?String(v):v))};
    });
    const wanted=row.kind==='validation'?{status:599,text:expected.constructorError.message,headers:[]}:expected.projection.value;
    assert.equal(record.state,'fulfilled');
    assert.deepEqual(record.value,wanted,'semantic: typed7c Record exact native projection '+row.name);
    assert.equal(record.counts.native,row.kind==='validation'?0:1,'captured original native fetch count');
    assert.equal(record.counts.body,0);assert.equal(record.counts.completion,1);
    if(row.kind==='validation')assert.deepEqual(record.counts.resolutions[0],{resolve:1,reject:0},'actual typed Record facade resolver called once');
    assert.equal(record.dispatchAfter,record.dispatchBefore,'private typed Record adds no public dispatch');
    assert.equal(requests.filter(q=>q.id===id).length,row.kind==='validation'?0:1,'exact real typed server request count');
    assert.equal(record.records.filter(r=>r.record==='NetRequest').length,1);
    assert.equal(record.records.filter(r=>r.record==='TaskReg').length,1);
    const req=record.records.find(r=>r.record==='NetRequest');
    const task=record.records.find(r=>r.record==='TaskReg');
    assert.equal(req.req_id,'1');assert.equal(req.method,row.kind==='validation'?'GET':'POST');
    assert.equal(task.task_id,'1');assert.equal(task.kind,4);
    assert(!JSON.stringify(record.records).includes('typed custom cancellation'),'custom reason is not serialized into wire');
    assert(!record.records.some(r=>r.record==='Refusal'),'typed case contains no hidden Refusal');
    if(row.kind==='abort')assert(record.records.some(r=>r.record==='NetResponse'&&r.outcome===3),'semantic: typed7c causal abort outcome '+row.name);
    await p.close();
    const replay=await page();
    const before=requests.length;
    const replayed=await replay.evaluate(async({row,url,log})=>{
      if(row.noAny)delete AbortSignal.any;
      const a=rhOwner,runner=a.installReplayRuntime(window,{log}),ctx=a.newReplayContext(window,runner);
      if(row.noAny && ('any' in AbortSignal || ctx.orig.abortSignalAny!==undefined))throw Error('Replay no-any capture');
      if(!ctx.orig.finalizationRegistry)throw Error('Replay genuine FinalizationRegistry capture');
      const counts={body:0,completion:0,task:0,request:0,resolutions:[]};
      const task=ctx.nextTaskId,request=ctx.nextReqId,text=Response.prototype.text;
      ctx.nextTaskId=()=>{counts.task++;return task();};ctx.nextReqId=()=>{counts.request++;return request();};
      Response.prototype.text=function(...args){counts.body++;return text.apply(this,args);};
      rpInit(ctx);const dispatch=rhDispatch(),controller=new AbortController();
      if(row.stopped)controller.signal.addEventListener('abort',e=>e.stopImmediatePropagation());
      const NativePromise=Promise;
      if(row.kind==='validation')window.Promise=class extends NativePromise {
        constructor(executor){const cell={resolve:0,reject:0};counts.resolutions.push(cell);super((resolve,reject)=>executor(function(...args){cell.resolve++;return resolve.apply(this,args);},function(...args){cell.reject++;return reject.apply(this,args);}));}
      };
      let pending;
      try {pending=row.kind==='validation'?rpTypedInvalid(url,row.badHeader):rpRpc(url,'payload',controller.signal,null);} finally {window.Promise=NativePromise;}
      if(row.kind==='abort') {
        const reason=({error:new Error('typed custom cancellation'),string:'typed cancellation',null:null,zero:0,false:false,empty:''})[row.reason];
        if(row.reason==='default')controller.abort();else if(row.reason==='undefined')controller.abort(undefined);else controller.abort(reason);
      }
      const value=await pending;counts.completion++;
      return {value:row.kind==='validation'?rhView(value):value,counts,dispatchBefore:dispatch,dispatchAfter:rhDispatch()};
    },{row,url,log:record.log});
    assert.deepEqual(replayed.value,wanted,'semantic: typed7c Replay exact native projection '+row.name);
    const {resolutions,...replayCounts}=replayed.counts;
    if(row.kind==='validation')assert.deepEqual(resolutions[0],{resolve:1,reject:0},'actual typed Replay facade resolver called once');
    assert.deepEqual(replayCounts,{body:0,completion:1,task:1,request:1},'one genuine Replay shared allocation/completion and no body consumer');
    assert.equal(replayed.dispatchAfter,replayed.dispatchBefore);
    await replay.waitForFunction(()=>['done','diverged'].includes(__ctReplay.status().state));
    assert.equal((await replay.evaluate(()=>__ctReplay.status())).state,'done','actual typed owner Replay DONE');
    assert.equal(requests.length,before,'typed Replay performs no network');
    const {log,...receipt}=record;results.push({typed7c:row,expected,record:receipt,replayed});
    await replay.close();
    console.log('PASS typed7c '+row.name);
  }
}
