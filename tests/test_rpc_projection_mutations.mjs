// Compile real owning-source inverses, then require specific runtime assertions
// in Node and Chromium. No compile error or timeout qualifies. All input source,
// emitted JS and raw logs remain in the printed directory for archival/review.
import {mkdtemp,cp,readFile,writeFile,mkdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const work=await mkdtemp(join(tmpdir(),'rpc-projection-inverses-'));
const native=`    let init = buildRpcRequestInitRaw(rawBackendAccess, httpMethod, body, csrf,
      context, contentType, signal)
    let pending = neHttp.fetchBrowserResponseRaw(rawBackendAccess, url, init)
    projectRpcResponseRaw(rawBackendAccess, pending, signal)`;
const mutations=[
 ['promise-executor','isonim/core/nondet.nim',native,`    result = newPromise proc(resolve: proc(value: JsObject)) =
      let init = buildRpcRequestInitRaw(rawBackendAccess, httpMethod, body, csrf,
        context, contentType, signal)
      let pending = neHttp.fetchBrowserResponseRaw(rawBackendAccess, url, init)
      let projected = projectRpcResponseRaw(rawBackendAccess, pending, signal)
      {.emit: "\u0060resolve\u0060(\u0060projected\u0060);".}`,'RPC init/fetch throws synchronously with original identity'],
 ['extra-continuation','isonim/core/private/rpc_http.nim','      });','      }).then(function(value) { return value; });','RPC exact projected native chain return identity'],
 ['extra-body-continuation','isonim/core/private/rpc_http.nim','return r.text().then(function (t)','return r.text().then(function (t) { return t; }).then(function (t)','immutable RPC pre-extraction outcome and Promise-turn oracle'],
 ['abort-signal','isonim/core/private/rpc_http.nim',' || (`signal` && `signal`.aborted)','','RPC exact status classification'],
 ['error-string','isonim/core/private/rpc_http.nim','String(e)','String(e && e.message || e)','RPC original String(error) projection'],
 ['empty-body','isonim/core/private/rpc_http.nim','`body` !== null','`body` !== null && `body` !== ""','RPC nil versus explicit empty body'],
 ['header-order','isonim/core/private/rpc_http.nim','{"X-CSRF-Token": `csrf`, "X-Isonim-Context": `context`}','{"X-Isonim-Context": `context`, "X-CSRF-Token": `csrf`}','RPC original header insertion order'],
];
for(const [name,relative,old,replacement,diagnostic] of mutations) {
 const dir=join(work,name);await cp('src',join(dir,'src'),{recursive:true});await mkdir(join(dir,'tests'));
 const file=join(dir,'src',relative),source=await readFile(file,'utf8');
 assert.equal(source.split(old).length-1,1,'unique source inverse '+name);
 await writeFile(file,source.replace(old,replacement));
 await cp('tests/rpc_projection_fixture.nim',join(dir,'tests/fixture.nim'));
 const output=join(dir,'fixture.js');
 const compile=spawnSync('nim',['js','--path:'+join(dir,'src'),'--path:'+resolve('../nim-everywhere/src'),'--out:'+output,join(dir,'tests/fixture.nim')],{encoding:'utf8'});
 await writeFile(join(dir,'compile.log'),compile.stdout+compile.stderr);
 assert.equal(compile.status,0,compile.stdout+compile.stderr);
 for(const engine of ['node','browser']) {
  const run=spawnSync(process.execPath,['tests/test_rpc_projection'+(engine==='browser'?'_browser':'')+'.mjs'],{
   env:{...process.env,RPC_PROJECTION_FIXTURE:output},encoding:'utf8',timeout:30000});
  await writeFile(join(dir,engine+'.log'),run.stdout+run.stderr);
  assert.equal(run.signal,null,'inverse fails assertion, never timeout '+name);
  assert.notEqual(run.status,0,'inverse survived '+name);
  assert((run.stdout+run.stderr).includes(diagnostic),run.stdout+run.stderr);
  console.log('rejected '+name+' '+engine+': '+diagnostic);
 }
}
console.log('retained RPC inverse inputs/logs '+work);
