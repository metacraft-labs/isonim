// Actual compiled NE HTTP facade/composition in Chromium with native Promise,
// Response and Headers. The shared bounded native-throw/ready-result injections
// isolate exact executor and microtask behavior; the existing HTTP response
// browser suite separately supplies real delayed local network/body failures.
// Baseline capture compiles immutable NE80d4, never candidate code.
import {chromium} from './browser/node_modules/playwright/index.mjs';
import {sample,conversionBoundary} from '../../nim-everywhere/tests/http_projection_sample.mjs';
import {readFile,writeFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';
const fixture=await readFile(process.env.HTTP_PROJECTION_FIXTURE ?? '../nim-everywhere/tests/http_projection_fixture.js','utf8');
const browser=await chromium.launch({executablePath:execFileSync('which',['chromium'],{encoding:'utf8'}).trim()});
try {
 const page=await browser.newPage();
 const results=await page.evaluate(async({fixture,sampleSource,conversionSource})=>{
  eval(fixture);
  const assert=Object.assign((v,m)=>{if(!v)throw Error(m);},{equal:(a,b,m)=>{if(a!==b)throw Error(m??'identity mismatch');}});
  const run=eval('('+sampleSource+')');
  eval('('+conversionSource+')')(httpRawRequest);
  const results={};
  for(const mode of ['ready','body','throw','init-throw','head-error','body-error','projection-error','text-throw','head-primitive']) results[mode]=await run(httpFacade,mode);
  if(globalThis.httpComposition) for(const mode of Object.keys(results)) {
   const actual=await run(httpComposition,mode);
   if(JSON.stringify(actual)!==JSON.stringify(results[mode]))throw Error('extracted browser composition parity '+mode);
  }
  return results;
 },{fixture,sampleSource:sample.toString(),conversionSource:conversionBoundary.toString()});
 const oracle='../nim-everywhere/tests/oracles/http_projection_chromium80d4.json';
 if(process.env.CAPTURE_HTTP_PROJECTION_ORACLE)await writeFile(process.env.CAPTURE_HTTP_PROJECTION_ORACLE,JSON.stringify(results,null,2)+'\n');
 else assert.deepEqual(results,JSON.parse(await readFile(oracle,'utf8')),'immutable Chromium80d4 outcome and Promise-turn oracle');
 console.log('PASS Chromium native HTTP projection oracle '+browser.version());
}finally{await browser.close();}
