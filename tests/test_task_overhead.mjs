// Arithmetic and fail-closed input controls complement the real Chromium run.
// Synthetic numbers here do not claim app or recording performance coverage.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {spawn} from 'node:child_process';
import {mkdtempSync, writeFileSync, readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {benchmark, median, interval, noiseBand, qualify} from '../tools/task_overhead.mjs';

test('paired statistics and immutable environmental ceiling',()=>{
  assert.equal(median([3,1,2]),2);
  assert.equal(median([4,1,2,3]),2.5);
  assert.deepEqual(interval(Array(30).fill(2)),[2,2]);
  assert.throws(()=>median([]),/invalid samples/);
  assert.throws(()=>median([NaN]),/invalid samples/);
  assert.throws(()=>noiseBand(Array(30).fill(.1),0),/invalid clock/);
  assert.throws(()=>noiseBand(Array(30).fill(2),.1),/precision ceiling/);
  assert.throws(()=>noiseBand([], .1),/invalid calibration/);
  assert.throws(()=>qualify([0],2),/invalid noise band/);
  const band=noiseBand(Array(30).fill(.1),.1);
  assert.equal(band,.1);
  assert(qualify(Array(30).fill(.05),band).withinNoise);
  assert(!qualify(Array(30).fill(.2),band).withinNoise);
  assert(!qualify(Array(30).fill(11),band).withinRecorderBudget);
});

test('missing artifacts refuse before browser dependency access',async()=>{
  const temporary=mkdtempSync(join(tmpdir(),'task-overhead-missing-'));
  try {
    const output=join(temporary,'receipt.json');
    await assert.rejects(()=>benchmark({root:'/nonexistent/task-overhead',output,playwright:'/unused',executable:'/unused'}),/ENOENT.*provenance.json/);
    assert.match(JSON.parse(readFileSync(output,'utf8')).failure,/provenance.json/);
  } finally {rmSync(temporary,{recursive:true,force:true});}
});

test('a prior receipt is never overwritten',async()=>{
  const temporary=mkdtempSync(join(tmpdir(),'task-overhead-receipt-'));
  try {
    const output=join(temporary,'receipt.json');
    writeFileSync(output,'preserved');
    await assert.rejects(()=>benchmark({root:'/nonexistent',output}),/receipt already exists/);
  } finally {rmSync(temporary,{recursive:true,force:true});}
});

test('concurrent filesystem receipt reservation has exactly one owner',async()=>{
  const temporary=mkdtempSync(join(tmpdir(),'task-overhead-concurrent-'));
  try {
    const output=join(temporary,'receipt.json');
    const source=`import {benchmark} from ${JSON.stringify(new URL('../tools/task_overhead.mjs',import.meta.url).href)};try {await benchmark({root:'/nonexistent/task-overhead',output:${JSON.stringify(output)}});}catch(error){console.log(String(error));process.exitCode=1;}`;
    const attempt=()=>new Promise((done,reject)=>{
      const child=spawn(process.execPath,['--input-type=module','-e',source],{stdio:['ignore','pipe','pipe']});
      let text='';child.stdout.on('data',chunk=>text+=chunk);child.stderr.on('data',chunk=>text+=chunk);
      child.on('error',reject);child.on('close',code=>done({code,text}));
    });
    const results=await Promise.all([attempt(),attempt()]);
    assert(results.every(r=>r.code===1));
    assert.equal(results.filter(r=>/receipt already exists/.test(r.text)).length,1);
    assert.equal(results.filter(r=>/ENOENT.*provenance.json/.test(r.text)).length,1);
    assert.match(JSON.parse(readFileSync(output,'utf8')).failure,/ENOENT.*provenance.json/);
  } finally {rmSync(temporary,{recursive:true,force:true});}
});
