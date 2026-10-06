/** Host-only test clocks; no service/session creation or provider inputs. */
import assert from 'node:assert/strict';
import {lstatSync,openSync,fstatSync,closeSync,readSync,constants} from 'node:fs';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import path from 'node:path';

const schema='isonim-owned-preparation-clock-v1';
const coldBoundNs=900n*1_000_000_000n;
export function overlapNs(start,end,first,last){
 assert(start>=0n&&start<=end&&first>=0n&&first<=last,'Invalid monotonic interval');
 const low=start>first?start:first,high=end<last?end:last;
 return high>low?high-low:0n;
}
export function decodePreparation(data,nonce,now){
 assert(data&&typeof data==='object'&&!Array.isArray(data));
 assert.deepEqual(Object.keys(data).sort(),['schema','nonce','generation','startNs','lastAbsentNs','publishedNs','completed','error'].sort());
 assert.equal(data.schema,schema);assert.equal(data.nonce,nonce,'Stale preparation evidence');
 assert.equal(typeof data.completed,'boolean');
 if(data.error!==null){assert.equal(typeof data.error,'string');throw Error('Owned preparation observer failed: '+data.error);}
 if(data.startNs===null){
  assert.equal(data.generation,null);assert.equal(data.lastAbsentNs,null);assert.equal(data.publishedNs,null);assert.equal(data.completed,false);
  return null;
 }
 const generation=data.generation;
 assert(generation&&typeof generation==='object'&&!Array.isArray(generation));
 assert.deepEqual(Object.keys(generation).sort(),['pid','starttime','directory'].sort());
 assert(Number.isSafeInteger(generation.pid)&&generation.pid>0);
 assert.equal(typeof generation.starttime,'string');assert(generation.starttime.length>0);
 assert.equal(typeof generation.directory,'string');assert(path.isAbsolute(generation.directory));
 function integer(key,nullable=false){
  const value=data[key];if(nullable&&value===null)return null;
  assert(typeof value==='string'&&/^[0-9]{1,24}$/.test(value),'Invalid monotonic sample');
  const result=BigInt(value);assert(result<=now,'Future samples cannot grant time');return result;
 }
 const start=integer('startNs'),absent=integer('lastAbsentNs',true),published=integer('publishedNs',true);
 if(absent!==null)assert(absent>=start);
 if(data.completed){assert(published!==null&&published>=start&&(absent===null||published>=absent));}
 else assert.equal(published,null);
 assert((data.completed?published:now)-start<coldBoundNs,'Owned preparation exceeded original cold900s bound');
 return {start,end:absent??start,generation};
}
export function validateClockCalibration(before,sample,after){
 assert(before<=sample&&sample<=after,'Python and Node monotonic clocks do not share a verified domain');
}
export async function createPreparationClock(configuration){
 assert(configuration&&typeof configuration.filename==='string'&&typeof configuration.nonce==='string');
 const before=process.hrtime.bigint();
 const {stdout}=await promisify(execFile)(configuration.python,['-c','import time;print(time.monotonic_ns())'],{timeout:5000});
 const after=process.hrtime.bigint();assert(/^[0-9]+\n$/.test(stdout));
 validateClockCalibration(before,BigInt(stdout.trim()),after);
 let generation=null;
 function interval(now=null){
  for(let attempt=0;attempt<32;attempt++){
   let fd;
   try{fd=openSync(configuration.filename,constants.O_RDONLY|constants.O_NOFOLLOW|constants.O_CLOEXEC);}
   catch(error){if(error.code==='ENOENT')return null;throw error;}
   try{
    const info=fstatSync(fd);
    function current(){try{return lstatSync(configuration.filename);}catch(error){if(error.code==='ENOENT')return null;throw error;}}
    const replaced=other=>other===null||other.dev!==info.dev||other.ino!==info.ino;
    if(info.nlink===0){let retired=false;for(let probe=0;probe<4;probe++){if(replaced(current())){retired=true;break;}Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,1);}if(retired)continue;}
    assert(info.isFile()&&info.uid===process.getuid()&&info.nlink===1&&(info.mode&0o777)===0o600,'Private controller timing file required');
    assert(info.size<=65536,'Oversized preparation evidence');
    const buffer=Buffer.alloc(65537);let count=0,got;
    while(count<buffer.length&&(got=readSync(fd,buffer,count,buffer.length-count,null))>0)count+=got;
    assert(count<=65536,'Oversized preparation evidence');const raw=buffer.subarray(0,count).toString('utf8');
    const latest=current();if(replaced(latest))continue;
    if(latest.nlink===0){let retired=false;for(let probe=0;probe<4;probe++){if(replaced(current())){retired=true;break;}Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,1);}if(retired)continue;}
    assert(latest.isFile()&&latest.uid===process.getuid()&&latest.nlink===1&&(latest.mode&0o777)===0o600,'Private controller timing file required');
    const value=decodePreparation(JSON.parse(raw),configuration.nonce,now??process.hrtime.bigint());
    if(value){if(generation!==null)assert.deepEqual(value.generation,generation,'Stale generation changed');generation=value.generation;}
    return value;
   }finally{closeSync(fd);}
  }
  throw Error('Preparation evidence continuously replaced during bounded read');
 }
 function excluded(start,now=null){
  const value=interval(now),end=now??process.hrtime.bigint();return value?overlapNs(start,end,value.start,value.end):0n;
 }
 function elapsed(start){const value=interval(),now=process.hrtime.bigint();return Number(now-start-(value?overlapNs(start,now,value.start,value.end):0n))/1_000_000;}
 return {now:()=>process.hrtime.bigint(),elapsed,excluded};
}
