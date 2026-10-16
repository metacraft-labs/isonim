/** Pure mapping codec fixtures deliberately isolate wrong/missing host namespace
 * mappings at either checkpoint. Synthetic identity records are necessary to
 * exhaust invalid states without fabricated processes/ACKs or inference. They
 * prove validator sensitivity, never actual native identity/runtime continuity.
 */
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {spawn} from 'node:child_process';
import {assertKernelCheckpoints,assertKernelReaped} from './helpers/editor_sdk_kernel_evidence.mjs';
const identity={pid:17,starttime:'1234',loadedSha256:'a'.repeat(64)};
const point={pid:500,namespace_pids:[500,17],starttime:'1234',loaded_sha256:'a'.repeat(64)};
const valid={'first-complete':structuredClone(point),'second-complete':structuredClone(point)};
assert.equal(assertKernelCheckpoints(identity,valid),500);
let rejected=0;
for(const phase of Object.keys(valid)){
 for(const [key,value] of [['pid',17],['namespace_pids',[499,17]],['namespace_pids',[500,18]],['namespace_pids',[]],['namespace_pids',[500,'17']],['namespace_pids',null],['starttime','other'],['loaded_sha256','other']]){
  const bad=structuredClone(valid);bad[phase][key]=value;assert.throws(()=>assertKernelCheckpoints(identity,bad));rejected++;
 }
 for(const key of ['pid','namespace_pids','starttime','loaded_sha256']){
  const bad=structuredClone(valid);delete bad[phase][key];assert.throws(()=>assertKernelCheckpoints(identity,bad));rejected++;
 }
 const bad=structuredClone(valid);delete bad[phase];assert.throws(()=>assertKernelCheckpoints(identity,bad));rejected++;
}
assert.throws(()=>assertKernelCheckpoints(identity,{...valid,extra:point}));rejected++;
for(const key of ['pid','starttime','loadedSha256']){const bad={...identity};delete bad[key];assert.throws(()=>assertKernelCheckpoints(bad,valid));rejected++;}
console.log(JSON.stringify({scope:'pure namespace mapping codec',positive:1,rejected}));

// Real owned native child and /proc boundary, no process/status mock. A stale
// identity fixture against that existing PID tests the explicit startticks rule.
const child=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'});
const ended=new Promise((resolve,reject)=>{child.once('close',resolve);child.once('error',reject);});
try{
 await new Promise((resolve,reject)=>{child.once('spawn',resolve);child.once('error',reject);});
 const start=readFileSync(`/proc/${child.pid}/stat`,'utf8').split(') ')[1].split(' ')[19];
 assert.throws(()=>assertKernelReaped(child.pid,start));
 assertKernelReaped(child.pid,String(BigInt(start)+1n));
 child.kill('SIGTERM');
 let timer;await Promise.race([ended,new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('Owned mapping control failed15s reap')),15000);})]).finally(()=>clearTimeout(timer));
 assertKernelReaped(child.pid,start);
 console.log(JSON.stringify({actualOwnedChildLiveRejected:true,staleStartticksDistinguished:true,actualOwnedChildReaped:true}));
}finally{if(child.exitCode===null&&child.signalCode===null){child.kill('SIGKILL');await ended;}}
