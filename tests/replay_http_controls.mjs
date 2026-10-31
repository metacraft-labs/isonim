/** Additional controls invoke the imported private Replay module. Real owner
 * contexts/cursors, native Responses and genuine recorded logs are used. Narrow
 * delegating original/body/getter and next-call sentinels expose exact identity
 * and synchronous-fault boundaries; none substitutes for a network/Replay loop.
 */
export async function runReplayHttpControls({assert,page,results,requests,base,recordSetup}) {
  const resultStart=results.length;
  const good=results.find(r=>r.kind==='http'&&r.scenario==='ready').record.log;
  async function setup(p,log=good) {
    await p.evaluate(log=>{
      const a=rhOwner, runner=a.installReplayRuntime(window,{log}),ctx=a.newReplayContext(window,runner);
      const counts={task:0,request:0},task=ctx.nextTaskId,request=ctx.nextReqId;
      ctx.nextTaskId=()=>{counts.task++;return task();};ctx.nextReqId=()=>{counts.request++;return request();};
      globalThis.rc={a,runner,ctx,counts};
    },log);
  }
  {
    const p=await page();await setup(p);
    const actual=await p.evaluate(()=>{
      const {a,ctx,runner,counts}=rc,before={fetch:fetch,xhr:XMLHttpRequest,beacon:navigator.sendBeacon,text:Response.prototype.text},errors=[];
      for(const change of [null,{...ctx,replay:null},{...ctx,holes:null},{...ctx,nextTaskId:null},{...ctx,nextReqId:null}]) {
        try{rpInit(change);errors.push(null);}catch(e){errors.push({name:e.name,message:e.message});}
      }
      for(const field of ['fetch','Response']) {
        const old=ctx.orig[field];ctx.orig[field]=undefined;
        try{rpInit(ctx);errors.push(null);}catch(e){errors.push({name:e.name,message:e.message});}
        finally{ctx.orig[field]=old;}
      }
      rpInit(ctx);const prepared=rpPreparedFetch(),text=Response.prototype.text;rpInit(ctx);
      const conflicts=[];
      for(const make of [()=>rpInit({...ctx}),()=>a.createReplayFetch(ctx),()=>a.createRecordFetch(ctx)]) {
        const descriptor=Object.getOwnPropertyDescriptor(Response.prototype,'text');
        try{make();conflicts.push(null);}catch(e){conflicts.push({name:e.name,message:e.message,same:descriptor.value===Response.prototype.text});}
      }
      return {errors,conflicts,same:prepared===rpPreparedFetch()&&text===Response.prototype.text,quiet:before.fetch===fetch&&before.xhr===XMLHttpRequest&&before.beacon===navigator.sendBeacon,counts,pending:runner.peek().record.record};
    });
    assert(actual.errors.every(e=>e?.name==='TypeError'&&e.message==='internal Replay HTTP requires actual Window, Replay cursor, captured fetch/Response and owner context'));
    assert(actual.same&&actual.quiet,'actual Replay constructor singleton and unrelated seam identity');
    assert.deepEqual(actual.conflicts,[
      {name:'TypeError',message:'fetch preparation belongs to another context or mode',same:true},
      {name:'TypeError',message:'fetch preparation belongs to another response scope',same:true},
      {name:'TypeError',message:'fetch preparation belongs to another context or mode',same:true},
    ]);
    assert.deepEqual(actual.counts,{task:0,request:0});assert.equal(actual.pending,'NetRequest');
    results.push({replayConstructor:actual});await p.close();
  }
  for(const reenter of [false,true]) {
    const p=await page();await setup(p);
    const actual=await p.evaluate(reenter=>{
      const {ctx}=rc,sentinel={setupFailure:true},old=ctx.orig.headersMutators;let first,second,nested,reads=0;
      Object.defineProperty(ctx.orig,'headersMutators',{configurable:true,get(){reads++;if(reenter){try{rpInit(ctx);}catch(e){nested={name:e.name,message:e.message};}}throw sentinel;}});
      try{rpInit(ctx);}catch(e){first=e===sentinel;}
      Object.defineProperty(ctx.orig,'headersMutators',{configurable:true,writable:true,value:old});
      const text=Response.prototype.text;
      try{rpInit(ctx);}catch(e){second={name:e.name,message:e.message};}
      return {first,second,nested,reads,unchanged:text===Response.prototype.text};
    },reenter);
    assert(actual.first&&actual.unchanged);assert.equal(actual.reads,1);
    assert.deepEqual(actual.second,{name:'TypeError',message:'fetch preparation is incomplete or failed'});
    if(reenter)assert.deepEqual(actual.nested,actual.second);
    results.push({replayFailedPreparation:actual});await p.close();
  }
  // This isolated caller-allocator fault delegates the genuine nextReqId, then
  // throws before immutable cursor.next. No transport/cursor is substituted.
  {
    const p=await page();await setup(p);
    const actual=await p.evaluate(async()=>{
      const {ctx,counts}=rc;rpInit(ctx);const sentinel={ownerFault:true},allocate=ctx.nextReqId;ctx.nextReqId=()=>{allocate();throw sentinel;};
      let thrown=false,rejected=false,rpc=false;
      try{const pending=rpHttp('/ready','payload');try{await pending;}catch(e){rejected=e===sentinel;}}catch(e){thrown=true;}
      try{rpRpc('/ready','payload',null,null);}catch(e){rpc=e===sentinel;}
      return {thrown,rejected,rpc,counts};
    });
    assert(!actual.thrown&&actual.rejected,'semantic: Replay HTTP synchronous owner fault becomes rejection');
    assert(actual.rpc,'Replay RPC owner fault remains synchronous');assert.deepEqual(actual.counts,{task:0,request:2});
    results.push({replayFaultBoundary:actual});await p.close();
  }
  {
    const p=await page();await setup(p);
    const actual=await p.evaluate(async()=>{
      rpInit(rc.ctx);const before=rc.runner.peek(),counts={...rc.counts},sentinel={initFailure:true};let sync=false,same=false,rpcSame=false,pending;
      Object.defineProperty(Object.prototype,'X-Duplicate',{configurable:true,set(){throw sentinel;}});
      try{pending=rpHttp('/init','x');}catch(e){sync=true;same=e===sentinel;}finally{delete Object.prototype['X-Duplicate'];}
      if(pending)await pending.catch(e=>{same=e===sentinel;});
      const extra={};Object.defineProperty(extra,'X-Throw',{enumerable:true,get(){throw sentinel;}});
      try{rpRpc('/init','x',null,extra);}catch(e){rpcSame=e===sentinel;}
      return {sync,same,rpcSame,quiet:JSON.stringify(before,(_,v)=>typeof v==='bigint'?String(v):v)===JSON.stringify(rc.runner.peek(),(_,v)=>typeof v==='bigint'?String(v):v),counts,beforeCounts:{...rc.counts}};
    });
    assert(!actual.sync&&actual.same&&actual.rpcSame&&actual.quiet,'actual Replay helper init faults preserve exact executor and synchronous boundaries');
    assert.deepEqual(actual.counts,actual.beforeCounts);results.push({replayInitFault:actual});await p.close();
  }
  for(const body of [null,'']) {
    const id='replay-body-'+(body===null?'absent':'empty'),url='/ready?id='+id;
    const p=await page();await recordSetup(p);
    const recorded=await p.evaluate(async({body,url})=>{
      const {a,ctx,rec,frames}=control;rhInit(ctx);const value=await rhRpc(url,body,null,{'Isonim-After':'after','Idempotency-Key':'key'});rec.end(2);
      const records=frames.map(f=>a.decodeRecord(f.subarray(4)));let raw='';for(const b of a.encodeLog(records))raw+=String.fromCharCode(b);return {log:btoa(raw),value};
    },{body,url});await p.close();
    const q=await page();await setup(q,recorded.log);const before=requests.filter(r=>r.id===id).length;
    const actual=await q.evaluate(async({body,url})=>{rpInit(rc.ctx);return rpRpc(url,body,null,{'Isonim-After':'after','Idempotency-Key':'key'});},{body,url});
    assert.deepEqual(actual,{status:207,text:'actual:',retryAfter:'3',commit:'commit'});assert.deepEqual(actual,recorded.value);
    await q.waitForFunction(()=>__ctReplay.status().state==='done');assert.equal(requests.filter(r=>r.id===id).length,before);
    results.push({replayNilEmpty:{body,actual}});await q.close();
  }
  // The same genuine good log runs through independent direct helper and the
  // actual imported module. Count exact delegated native continuation order.
  const traces=[];
  for(const direct of [true,false]) {
    const p=await page();await setup(p);
    traces.push(await p.evaluate(async direct=>{
      const {a,ctx,runner}=rc;let f;if(direct)f=a.createFrameworkReplayFetch(ctx);else rpInit(ctx);
      const original=Promise.prototype.then,events=[];
      Promise.prototype.then=function(ok,bad){events.push('then');return original.call(this,
        typeof ok==='function'?function(...args){events.push('fulfilled');return ok.apply(this,args);}:ok,
        typeof bad==='function'?function(...args){events.push('rejected');return bad.apply(this,args);}:bad);};
      try{const value=await(direct?rhReplayHttp(f,'/ready?id=http-ready','payload'):rpHttp('/ready?id=http-ready','payload'));return {events,value:rhView(value)};}
      finally{Promise.prototype.then=original;}
    },direct));
    await p.waitForFunction(()=>__ctReplay.status().state==='done');await p.close();
  }
  assert.deepEqual(traces[1],traces[0],'semantic: no extra Replay continuation before public settlement');
  results.push({replayContinuationTrace:traces});
  const neutralLogs={};
  for(const kind of ['clock','storage']) {
    const p=await page();await recordSetup(p);
    neutralLogs[kind]=await p.evaluate(kind=>{
      const {a,ctx,rec,frames}=control;
      if(kind==='clock'){a.patchTimeSeams(ctx);performance.now();}
      else {localStorage.setItem('replay-neutral','native-storage');a.patchStorage(ctx);localStorage.getItem('replay-neutral');}
      rec.end(2);const records=frames.map(f=>a.decodeRecord(f.subarray(4)));let raw='';for(const b of a.encodeLog(records))raw+=String.fromCharCode(b);
      const observations=records.filter(r=>r.record===(kind==='clock'?'Clock':'StorageRead'));
      if(observations.length!==1)throw Error('expected one actual owner neutral platform read');
      return btoa(raw);
    },kind);await p.close();
  }
  // Each foreign case has a genuine pending network request, actual DONE, or
  // actual latched mismatch. The native body wrapper delegates every call and
  // exposes exact returned Promise/receiver/argument/synchronous exception.
  for(const state of ['pending','clock','storage','done','diverged']) {
    const p=await page();await setup(p,neutralLogs[state]||good);
    const actual=await p.evaluate(async state=>{
      const foreignNative=await fetch('/ready?id=foreign-native-'+state);
      globalThis.rcForeignNative=foreignNative;
      const {ctx,runner,counts}=rc,seen=globalThis.rcSeen=[],sentinel=globalThis.rcSentinel={bodyFault:true};
      for(const name of ['text','json']) {
        const native=Response.prototype[name];
        Response.prototype[name]=function(...args){seen.push({name,receiver:this,args});if(args[0]===sentinel)throw sentinel;globalThis.rcNativePromise=native.apply(this,args);return globalThis.rcNativePromise;};
      }
      rpInit(ctx);
      if(state==='done')await rpHttp('/ready?id=http-ready','payload');
      if(state==='diverged'){try{rpRaw('/wrong',{method:'POST',body:'payload'});}catch(e){}}
    },state);
    if(state==='done')await p.waitForFunction(()=>__ctReplay.status().state==='done');
    const observation=await p.evaluate(async()=>{
      const {ctx,runner,counts}=rc,seen=globalThis.rcSeen,sentinel=globalThis.rcSentinel;
      const before={peek:runner.peek(),status:runner.status(),counts:{...counts}},identity=[],values=[];
      for(const [name,response] of [['text',new Response('native')],['json',new Response('{"native":true}')],['text',new Response('clone').clone()],['text',globalThis.rcForeignNative]]) {
        const arg={argument:name},promise=response[name](arg),last=seen.at(-1);
        identity.push(promise===globalThis.rcNativePromise&&last.receiver===response&&last.args.length===1&&last.args[0]===arg);values.push(await promise);
      }
      let sync=false;try{new Response('x').text(sentinel);}catch(e){sync=e===sentinel;}
      const after={peek:runner.peek(),status:runner.status(),counts:{...counts}};
      return {identity,values,sync,before,after,state:runner.status().state};
    });
    assert(observation.identity.every(Boolean)&&observation.sync,'actual Replay constructor preserves exact foreign native Promise/receiver/arguments/error identity');
    assert.deepEqual(observation.values,['native',{native:true},'clone','actual:']);
    assert.deepEqual(observation.after,observation.before,'foreign reads preserve actual cursor, IDs and latched payload');
    if(['done','diverged'].includes(state))assert.equal(observation.state,state);
    else assert.equal(observation.before.peek.kind,state==='clock'?'Clock':state==='storage'?'StorageRead':'NetRequest');
    results.push({replayForeign:observation});await p.close();
  }
  // First preparation must respect the backend/Fake context selected BEFORE
  // construction, in fresh realms and one real compiled Nim authority graph.
  for(const selected of ['real','test','custom','fake']) {
    const p=await page();await setup(p,neutralLogs.clock);
    const actual=await p.evaluate(async selected=>{
      if(selected==='real')rhPublicSelect(false);else if(selected==='test')rhPublicSelect(true);else rhCustomSelect();
      if(selected==='fake')rhFakeStart();
      try {
        const clock=rpSelectedClock(),before={dispatch:rhDispatch(),peek:rc.runner.peek(),counts:{...rc.counts},fake:selected==='fake'?rhFakeState():null};
        rpInit(rc.ctx);
        const after={dispatch:rhDispatch(),peek:rc.runner.peek(),counts:{...rc.counts},fake:selected==='fake'?rhFakeState():null},same=rpSelectedClock()===clock,rows=[];
        for(const kind of ['http','rpc']) {
          const dispatch=rhDispatch(),value=await(kind==='http'?rhPublicHttp('/ready?id=constructor-'+selected):rhPublicRpc('/ready?id=constructor-'+selected));
          rows.push({kind,value,delta:rhDispatch()-dispatch,same:rpSelectedClock()===clock});
        }
        return {same,before,after,rows,finalCursor:{peek:rc.runner.peek(),counts:{...rc.counts}}};
      } finally {if(selected==='fake')rhFakeEnd();}
    },selected);
    assert(actual.same,'actual Replay constructor preserves the already-selected same-graph ClockBase identity');
    assert.deepEqual(actual.after,actual.before,'first Replay preparation preserves selected state and genuine cursor/allocators');
    if(selected==='fake')assert.deepEqual(actual.before.fake,{selected:true,milliseconds:17,fired:0,dispatch:0});
    for(const row of actual.rows){assert(row.same);assert.equal(row.delta,1);assert.equal(row.value.status,selected==='real'?207:selected==='test'?218:219);}
    assert.deepEqual(actual.finalCursor,{peek:actual.before.peek,counts:actual.before.counts});
    results.push({replaySelectedBeforeConstructor:{selected,actual}});await p.close();
  }
  {
    const p=await page();await setup(p,neutralLogs.clock);
    const actual=await p.evaluate(async()=>{
      rpInit(rc.ctx);const before={peek:rc.runner.peek(),counts:{...rc.counts}},rows=[];
      for(const selected of ['real','test','custom'])for(const kind of ['http','rpc']) {
        if(selected==='custom')rhCustomSelect();else rhPublicSelect(selected==='test');
        const dispatch=rhDispatch(),value=await(kind==='http'?rhPublicHttp('/ready?id=public-'+selected):rhPublicRpc('/ready?id=public-'+selected));
        rows.push({selected,kind,value,dispatchDelta:rhDispatch()-dispatch});
      }
      rhCustomSelect();rhFakeStart();let fake;
      try{const initial=rhFakeState();rhFakeAdvance();const advanced=rhFakeState();fake={initial,advanced};}finally{rhFakeEnd();}
      return {rows,fake,before,after:{peek:rc.runner.peek(),counts:{...rc.counts}}};
    });
    for(const row of actual.rows){assert.equal(row.dispatchDelta,1,'public settlement dispatch remains exactly once after actual Replay preparation');assert.equal(row.value.status,row.selected==='real'?207:row.selected==='test'?218:219);}
    assert.deepEqual(actual.after,actual.before,'selected Real/Test/custom/FakeAsync leaves actual owner neutral cursor and IDs unchanged');
    assert.deepEqual(actual.fake.initial,{selected:true,milliseconds:17,fired:0,dispatch:0});
    assert.deepEqual(actual.fake.advanced,{selected:true,milliseconds:19,fired:1,dispatch:0});
    results.push({replaySelectedAuthority:actual});await p.close();
  }
  // Owned clone consumption remains attached to its original owner even when
  // the unrelated public selected clock switches. Both legs use native I/O and
  // the real owner codec/automatic runtime, never fabricated response records.
  {
    const p=await page();await recordSetup(p);
    const recorded=await p.evaluate(async()=>{
      const {a,ctx,rec,frames}=control;rhInit(ctx);
      const response=await rhRaw('/ready?id=replay-owned-clone',{method:'GET'}),clone=response.clone();
      const values=await Promise.all([response.text(),clone.text()]);rec.end(2);
      const records=frames.map(f=>a.decodeRecord(f.subarray(4)));let raw='';for(const b of a.encodeLog(records))raw+=String.fromCharCode(b);
      return {log:btoa(raw),values};
    });await p.close();
    const q=await page();await setup(q,recorded.log);const beforeCount=requests.filter(r=>r.id==='replay-owned-clone').length;
    const replayed=await q.evaluate(async()=>{
      rpInit(rc.ctx);const dispatchBefore=rhDispatch(),response=await rpRaw('/ready?id=replay-owned-clone',{method:'GET'}),dispatchAfterRaw=rhDispatch(),clone=response.clone();
      rhCustomSelect();const values=await Promise.all([response.text(),clone.text()]);return {values,dispatchBefore,dispatchAfterRaw,dispatch:rhDispatch()};
    });
    assert.deepEqual(recorded.values,['actual:','actual:']);assert.deepEqual(replayed.values,recorded.values);
    await q.waitForFunction(()=>__ctReplay.status().state==='done');
    assert.equal(requests.filter(r=>r.id==='replay-owned-clone').length,beforeCount,'owned clone Replay does no native HTTP');
    assert.equal(replayed.dispatchAfterRaw,replayed.dispatchBefore,'actual rpRaw adds no dispatch before any clock switch');
    assert.equal(replayed.dispatch,0,'owned body reads add no dispatch after selected-clock switch');
    results.push({replayOwnedClone:replayed});await q.close();
  }
  for(const state of ['done','diverged']) {
    const p=await page();await setup(p);
    const actual=await p.evaluate(async state=>{
      const {runner,counts,ctx}=rc;rpInit(ctx);
      if(state==='done')await rpHttp('/ready?id=http-ready','payload');
      else {try{rpRaw('/wrong',{method:'POST',body:'payload'});}catch(e){}}
    },state);
    if(state==='done')await p.waitForFunction(()=>__ctReplay.status().state==='done');
    const terminal=await p.evaluate(()=>{
      const {runner,counts}=rc;
      const before={...counts},previous=runner.failed;let first,second;
      try{rpRaw('/after',{method:'POST',body:'payload'});}catch(e){first=e;}
      try{rpRaw('/again',{method:'POST',body:'payload'});}catch(e){second=e;}
      return {delta:{task:counts.task-before.task,request:counts.request-before.request},distinct:!!first&&!!second&&first!==second,payloadSame:first?.divergence===second?.divergence&&first?.divergence===runner.failed&&(!previous||previous===runner.failed),kind:runner.failed?.kind,state:runner.status().state};
    });
    assert.deepEqual(terminal.delta,{task:2,request:2},'owned terminal calls preserve actual allocation-before-next ordering');
    assert(terminal.distinct&&terminal.payloadSame,'actual owner creates distinct errors with the identical latched report');assert.equal(terminal.state,'diverged');
    if(state==='done')assert.equal(terminal.kind,'ExtraRead');
    results.push({replayTerminal:terminal});await p.close();
  }
  for(let i=resultStart;i<results.length;i++)results[i]=JSON.parse(JSON.stringify(results[i],(_,v)=>typeof v==='bigint'?String(v):v));

}
