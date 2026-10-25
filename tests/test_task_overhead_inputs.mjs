// Genuine built app artifacts exercise filesystem/provenance refusals. No
// browser result or timing is mocked: these must fail before browser launch.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {cpSync, mkdtempSync, rmSync, unlinkSync, appendFileSync, readFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {resolve, join} from 'node:path';
import {benchmark} from '../tools/task_overhead.mjs';

const [artifacts,playwright]=process.argv.slice(2);
assert(artifacts && playwright,'usage: test_task_overhead_inputs.mjs BUILT_ARTIFACTS PLAYWRIGHT_INDEX');
test('real artifacts refuse missing browser, missing bundle and changed bytes',async()=>{
  const temporary=mkdtempSync(join(tmpdir(),'task-overhead-inputs-'));
  try {
    for(const name of ['provenance.json','m5','current'])cpSync(resolve(artifacts,name),join(temporary,name),{recursive:true});
    const options={root:temporary,output:join(temporary,'receipt.json'),playwright,executable:'/nonexistent/task-overhead-chromium'};
    await assert.rejects(()=>benchmark(options),/ENOENT.*task-overhead-chromium/);
    const first=readFileSync(options.output,'utf8');
    assert.match(JSON.parse(first).failure,/task-overhead-chromium/);
    options.output=join(temporary,'changed-receipt.json');
    appendFileSync(join(temporary,'current/app.js'),'\n// changed bytes\n');
    await assert.rejects(()=>benchmark(options),/artifact provenance mismatch/);
    assert.match(JSON.parse(readFileSync(options.output,'utf8')).failure,/artifact provenance mismatch/);
    options.output=join(temporary,'missing-receipt.json');
    unlinkSync(join(temporary,'current/app.js'));
    await assert.rejects(()=>benchmark(options),/ENOENT.*app.js/);
    assert.match(JSON.parse(readFileSync(options.output,'utf8')).failure,/ENOENT.*app.js/);
    assert.equal(readFileSync(join(temporary,'receipt.json'),'utf8'),first);
  } finally {rmSync(temporary,{recursive:true,force:true});}
});
