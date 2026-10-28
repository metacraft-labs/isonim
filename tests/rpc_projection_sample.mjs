// Native Promise/Response/body streams are real. Bounded ready-result, sync
// fetch/prototype-setter and status-getter faults isolate otherwise unreachable
// exact construction/projection timing. Per-instance then/catch wrappers call
// their native methods unchanged, witnessing actual returned identity without
// adding continuations. These are not transport acceptance: the HTTP browser
// suite separately exercises genuinely delayed local I/O and native aborts.
import assert from 'node:assert/strict';
export const rpcModes = ['ready', 'nil-body', 'empty-body', 'no-content-type',
  'falsy-signal', 'throw', 'init-throw', 'head-error', 'head-primitive',
  'head-abort', 'signal-abort', 'body-error', 'body-abort', 'text-throw',
  'projection-error', 'error-string-throw'];

export async function rpcSample(probe, path, mode) {
  probe.reset();
  const trace = [], calls = [];
  let reads = 0, completions = 0, projected, outcome, nativeBodyFailure;
  const token = Error('native token');
  const abort = new DOMException('native abort', 'AbortError');
  const controller = new AbortController();
  const signal = mode === 'falsy-signal' ? null : controller.signal;
  const body = mode === 'nil-body' ? null : mode === 'empty-body' ? '' : 'payload';
  const contentType = mode === 'no-content-type' || mode === 'init-throw' ? '' : 'text/x-rpc';
  const nativeFetch = globalThis.fetch;
  globalThis.fetch = (url, init) => {
    assert.equal(init.signal, signal || undefined, 'RPC supplied signal identity');
    assert.equal(Object.getPrototypeOf(init.headers), Object.prototype, 'RPC ordinary header object');
    assert.equal(Object.hasOwn(init, 'body'), body !== null, 'RPC nil versus explicit empty body');
    if (body !== null) assert.equal(init.body, body, 'RPC body identity');
    assert.deepEqual(Object.keys(init.headers), contentType === '' ?
      ['X-CSRF-Token', 'X-Isonim-Context'] :
      ['X-CSRF-Token', 'X-Isonim-Context', 'Content-Type'], 'RPC original header insertion order');
    assert.equal(init.headers['X-CSRF-Token'], 'csrf', 'RPC CSRF value');
    assert.equal(init.headers['X-Isonim-Context'], 'context', 'RPC context value');
    if (contentType !== '') assert.equal(init.headers['Content-Type'], contentType, 'RPC content type value');
    assert.equal(init.credentials, 'same-origin', 'RPC same-origin credentials');
    assert.equal(init.method, 'POST', 'RPC method identity');
    assert.equal(url, 'http://example.invalid/rpc', 'RPC URL identity');
    calls.push({url, method:init.method, keys:Object.keys(init), headers:Object.entries(init.headers),
      body:Object.hasOwn(init,'body') ? init.body : null, hasBody:Object.hasOwn(init,'body'),
      signal:Object.hasOwn(init,'signal'), credentials:init.credentials});
    trace.push('fetch');
    if (mode === 'throw') throw token;
    let pending;
    if (mode === 'head-error') pending = Promise.reject(token);
    else if (mode === 'head-primitive') pending = Promise.reject(0);
    else if (mode === 'head-abort') pending = Promise.reject(abort);
    else if (mode === 'signal-abort') { controller.abort(); pending = Promise.reject(token); }
    else if (mode === 'error-string-throw') pending = Promise.reject({toString() {throw token;}});
    else {
      const error = mode === 'body-abort' ? abort : token;
      const response = new Response(mode === 'body-error' || mode === 'body-abort' ?
        new ReadableStream({start(c) {c.error(error);}}) : 'ready', {status:207});
      if(mode === 'projection-error') Object.defineProperty(response,'status',{get() {throw token;}});
      const text = response.text;
      response.text = function() {
        reads++; trace.push('text');
        if(mode === 'text-throw') throw token;
        const result = text.call(this);
        const witness = () => {
          trace.push('body-ready');
          const sentinel = n => queueMicrotask(() => {trace.push('body-turn'+n); if(n<8)sentinel(n+1);});
          sentinel(1);
        };
        result.then(witness,error => {nativeBodyFailure=error;witness();});
        return result;
      };
      pending = Promise.resolve(response);
    }
    const nativeThen = pending.then;
    pending.then = function(...args) {
      const chain = nativeThen.apply(this,args), nativeCatch = chain.catch;
      chain.catch = function(...handlers) { projected = nativeCatch.apply(this,handlers); return projected; };
      return chain;
    };
    return pending;
  };
  // Existing body assignment is outside a Promise and must synchronously throw.
  if (mode === 'init-throw') Object.defineProperty(Object.prototype,'body',{
    configurable:true, set() {throw token;}});
  let pending, caught;
  try { pending = probe[path]('POST','http://example.invalid/rpc',body,'csrf','context',contentType,signal); trace.push('returned'); }
  catch(error) {caught=error;trace.push('threw');}
  finally {if(mode === 'init-throw')delete Object.prototype.body;globalThis.fetch=nativeFetch;}
  const sync = mode === 'throw' || mode === 'init-throw';
  if(sync) {
    assert.equal(caught,token,'RPC init/fetch throws synchronously with original identity');
    assert.equal(pending,undefined,'RPC synchronous fault returns no Promise');
    assert.equal(probe.count(),0,'RPC synchronous fault precedes settled dispatch');
  } else {
    if(caught) throw caught; // Preserve the precise instrumented init assertion.
    assert.equal(caught,undefined,'RPC ordinary call returns normally');
    assert(pending instanceof Promise,'RPC native Promise return');
    assert.equal(pending === projected,path !== 'facade','RPC exact projected native chain return identity');
    pending.then(value => {completions++; trace.push('fulfilled');outcome={status:value.status,text:value.text};},
      error => {completions++;trace.push('rejected');outcome={same:error===token};});
    await pending.catch(()=>{});
    for(let i=0;i<10;i++)await Promise.resolve();
    assert.equal(completions,1,'RPC exactly one completion');
    assert.equal(probe.count(),path === 'facade' ? 1 : 0,'RPC exactly one public settlement dispatch');
    if(mode === 'error-string-throw') assert.deepEqual(outcome,{same:true},'RPC String error rejection identity');
    else {
      // Chromium's real Response.text() can replace an errored stream's reason
      // with its own TypeError. Compare the actual native rejection witnessed
      // above, preserving each engine's error instead of prescribing parity.
      const error = nativeBodyFailure ?? (mode === 'head-abort' ? abort : token);
      const isAbort = mode === 'signal-abort' || (error && error.name === 'AbortError');
      const isFailure = ['head-error','head-primitive','body-error','body-abort','text-throw','projection-error'].includes(mode);
      assert.equal(outcome.status,isAbort ? -1 : isFailure ? 0 : 207,'RPC exact status classification');
      assert.equal(outcome.text,mode === 'head-primitive' ? '0' :
        isAbort || isFailure ? String(error) : 'ready','RPC original String(error) projection '+mode+' actual='+outcome.text);
    }
  }
  assert.equal(calls.length,mode === 'init-throw' ? 0 : 1,'RPC native request count');
  assert.equal(reads,['ready','nil-body','empty-body','no-content-type','falsy-signal','body-error','body-abort','text-throw','projection-error'].includes(mode) ? 1 : 0,'RPC exactly one body consumption');
  return {trace,calls,reads,completions,dispatches:probe.count(),outcome:outcome ?? null,sync};
}
