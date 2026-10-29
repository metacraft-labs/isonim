// Actual compiled RPC facade/composition and native Promise/Response in Chromium.
// Fault injections are justified in the shared sample; delayed real I/O runs
// in test_http_response_browser.mjs, never replaced by this timing oracle.
import assert from 'node:assert/strict';
import {readFile,writeFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {chromium} from './browser/node_modules/playwright/index.mjs';
import {rpcModes,rpcSample} from './rpc_projection_sample.mjs';
const fixture=await readFile(process.env.RPC_PROJECTION_FIXTURE ?? 'build/rpc_projection_fixture.js','utf8');
const browser=await chromium.launch({executablePath:execFileSync('which',['chromium'],{encoding:'utf8'}).trim()});
try {
 const page=await browser.newPage();
 const actual=await page.evaluate(async({fixture,modes,source})=>{
  eval(fixture);
  const equal=(a,b,m)=>{if(a!==b)throw Error(m);};
  const assert=Object.assign((v,m)=>{if(!v)throw Error(m);},{equal,deepEqual:(a,b,m)=>equal(JSON.stringify(a),JSON.stringify(b),m)});
  const sample=eval('('+source+')');
  const actual={};
  for(const path of ['facade','raw']) {
   actual[path]={};for(const mode of modes)actual[path][mode]=await sample(rpcProbe,path,mode);
  }
  if(rpcProbe.composition)for(const mode of modes)
   assert.deepEqual(await sample(rpcProbe,'composition',mode),actual.raw[mode],'RPC extracted composition parity '+mode);
  return actual;
 },{fixture,modes:rpcModes,source:rpcSample.toString()});
 if(process.env.CAPTURE_RPC_PROJECTION_ORACLE)await writeFile(process.env.CAPTURE_RPC_PROJECTION_ORACLE,JSON.stringify(actual,null,2)+'\n');
 else assert.deepEqual(actual,JSON.parse(await readFile('tests/oracles/rpc_projection_chromium_isonim_context_headers.json','utf8')),'immutable RPC pre-extraction outcome and Promise-turn oracle');
 console.log('PASS Chromium native RPC projection '+browser.version());
}finally{await browser.close();}
