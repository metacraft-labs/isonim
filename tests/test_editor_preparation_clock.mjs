/** Pure codec/interval controls with explicit synthetic data, not mocked OS or
 * service acceptance. Real private file and real Python/Node calibration follow.
 * Official scenarios own the actual helper/provider lifecycle evidence.
 * The temporary crypto wrapper counts calls while invoking the real createHash;
 * no hash result, filesystem syscall, metadata or clock is mocked. It proves the
 * disabled diagnostic path does no generation hashing, with an enabled control. */
import assert from 'node:assert/strict';
import {mkdtempSync,writeFileSync,readFileSync,lstatSync,chmodSync,rmSync,existsSync,linkSync,unlinkSync,renameSync,symlinkSync} from 'node:fs';
import os from 'node:os';
import {spawn} from 'node:child_process';
import path from 'node:path';
import crypto from 'node:crypto';
import {syncBuiltinESMExports} from 'node:module';
import {overlapNs,decodePreparation,validateClockCalibration,createPreparationClock} from './helpers/editor_preparation_clock.mjs';
const nonce='unit-controller-nonce';
const data=(start=100n,end=200n,published=220n)=>({schema:'isonim-owned-preparation-clock-v1',nonce,
 generation:{pid:1,starttime:'123',directory:'/unit-codec-input'},startNs:String(start),
 lastAbsentNs:end===null?null:String(end),publishedNs:published===null?null:String(published),completed:published!==null,error:null});
for(const [start,end,expected] of [[0n,90n,0n],[0n,150n,50n],[0n,300n,100n],[150n,180n,30n],[150n,300n,50n],[200n,300n,0n],[250n,300n,0n]])
 assert.equal(overlapNs(start,end,100n,200n),expected);
assert.equal(decodePreparation(data(100n,null),nonce,300n).end,100n);
for(const patch of [{nonce:'old'},{schema:'unknown'},{extra:1},{startNs:100},{lastAbsentNs:'999'},
 {publishedNs:'150'},{completed:1},{generation:null},{startNs:'-1'},{error:'observer failed'},{error:true}])
 assert.throws(()=>decodePreparation({...data(),...patch},nonce,300n));
const bound=900n*1_000_000_000n;
assert(decodePreparation(data(100n,100n+bound-1n,null),nonce,100n+bound-1n));
assert.throws(()=>decodePreparation(data(100n,100n+bound-1n,null),nonce,100n+bound),/cold900/);
assert.throws(()=>decodePreparation(data(100n,100n+bound-1n,100n+bound),nonce,100n+bound+1n),/cold900/);
validateClockCalibration(100n,110n,120n);
assert.throws(()=>validateClockCalibration(100n,99n,120n));
assert.throws(()=>validateClockCalibration(100n,121n,120n));
const directory=mkdtempSync(path.join(os.tmpdir(),'isonim-clock-codec-'));
try{
 const filename=path.join(directory,'clock.json');
 const disabledListeners=process.listenerCount('exit');
 const clock=await createPreparationClock({filename,nonce,python:process.env.ISONIM_SCENARIO_PYTHON??'python3'});
 assert.equal(process.listenerCount('exit'),disabledListeners);
 const now=clock.now();assert.equal(clock.excluded(now-10n,now),0n);
 const value=data(now-100n,now-40n,now-20n);
 const write=()=>writeFileSync(filename,JSON.stringify(value),{mode:0o600});write();
 const realHash=crypto.createHash;let hashCalls=0;
 try{
  crypto.createHash=function(...args){hashCalls++;return Reflect.apply(realHash,this,args);};syncBuiltinESMExports();
  assert.equal(clock.excluded(now-200n,now),60n);assert.equal(hashCalls,0,'disabled trace must not hash generation');
  const enabled=await createPreparationClock({filename,nonce,python:process.env.ISONIM_SCENARIO_PYTHON??'python3',traceFilename:path.join(directory,'enabled-trace.json')});
  try{hashCalls=0;assert.equal(enabled.excluded(now-200n,now),60n);assert.equal(hashCalls,1,'real enabled trace hashing positive control');}finally{enabled.disposeTrace();}
 }finally{crypto.createHash=realHash;syncBuiltinESMExports();}
 assert.equal(clock.excluded(now-200n,now),60n);assert.equal(clock.excluded(now-10n,now),0n);
 value.generation.starttime='124';write();assert.throws(()=>clock.excluded(now-200n,now),/generation changed/);
 value.generation.starttime='123';value.error='actual reader failed';write();assert.throws(()=>clock.elapsed(now),/observer failed/);
 value.error=null;write();chmodSync(filename,0o644);assert.throws(()=>clock.excluded(now-200n,now),/Private/);
}finally{rmSync(directory,{recursive:true});}
const atomicDirectory=mkdtempSync(path.join(os.tmpdir(),'isonim-clock-atomic-'));
let tracedClock;
try{
 const filename=path.join(atomicDirectory,'clock.json'),done=path.join(atomicDirectory,'done');
 const traceFilename=path.join(atomicDirectory,'trace.json'),listeners=process.listenerCount('exit');
 const clock=await createPreparationClock({filename,nonce,python:process.env.ISONIM_SCENARIO_PYTHON??'python3',traceFilename});tracedClock=clock;
 assert.equal(process.listenerCount('exit'),listeners+1);
 await assert.rejects(createPreparationClock({filename,nonce,python:'python3',traceFilename:filename}),/must not replace/);
 const now=clock.now(),value=data(now-100n,now-40n,now-20n);
 writeFileSync(filename,JSON.stringify(value),{mode:0o600});
 const alias=path.join(atomicDirectory,'alias');symlinkSync(atomicDirectory,alias);
 await assert.rejects(createPreparationClock({filename,nonce,python:'python3',traceFilename:path.join(alias,'clock.json')}),/must not replace/);
 unlinkSync(alias);
 const writer=spawn(process.env.ISONIM_SCENARIO_PYTHON??'python3',['-c',
  'import os,tempfile,json,time,sys\nfrom pathlib import Path\nroot=Path(sys.argv[1]);data=json.loads(sys.argv[2])\nfor _ in range(2000):\n fd,name=tempfile.mkstemp(dir=root)\n with os.fdopen(fd,"w") as stream:json.dump(data,stream)\n os.replace(name,root/"clock.json");time.sleep(.0002)\n(root/"done").write_text("done")',atomicDirectory,JSON.stringify(value)],{stdio:'inherit'});
 const exited=new Promise((resolve,reject)=>{writer.on('error',reject);writer.on('exit',code=>code===0?resolve():reject(Error('Atomic writer failed '+code)));});
 let reads=0;const began=clock.now();
 try{
  while(!existsSync(done)){
   assert(clock.now()-began<10n*1_000_000_000n,'Actual atomic publisher deadline');
   assert.equal(clock.excluded(now-200n,now),60n);reads++;
  }
 }finally{if(!existsSync(done))writer.kill();await exited;}
 assert(reads>100);
 const original=readFileSync(filename);clock.flushTrace();assert.deepEqual(readFileSync(filename),original);
 const trace=JSON.parse(readFileSync(traceFilename,'utf8'));
 assert.equal(trace.events.length,512);assert(trace.totalEvents>512);
 assert.equal(trace.events.at(-1).sequence,trace.totalEvents);
 assert.equal(lstatSync(traceFilename).mode&0o777,0o600);
 assert(!JSON.stringify(trace).includes(nonce));assert(!JSON.stringify(trace).includes(atomicDirectory));
 assert(trace.events.some(event=>event.operation==='fstat'&&event.stat.nlink===1));
 assert(trace.events.some(event=>event.operation==='decoded'&&event.generation.directorySha256));
 const link=path.join(atomicDirectory,'linked');linkSync(filename,link);assert.throws(()=>clock.excluded(now-200n,now),/Private/);
 unlinkSync(link);renameSync(filename,link);symlinkSync(link,filename);assert.throws(()=>clock.excluded(now-200n,now),/ELOOP/);
 unlinkSync(filename);renameSync(link,filename);chmodSync(filename,0o644);assert.throws(()=>clock.excluded(now-200n,now),/Private/);
 assert.equal(JSON.parse(readFileSync(traceFilename,'utf8')).events.at(-1).operation,'failure');
 chmodSync(atomicDirectory,0o755);
 assert.throws(()=>clock.excluded(now-200n,now),error=>/Private controller timing file required/.test(error.message)&&error.clockTraceFailureType==='AssertionError');
 assert.throws(()=>clock.disposeTrace(),error=>error.name==='AssertionError');assert.equal(process.listenerCount('exit'),listeners);
 chmodSync(atomicDirectory,0o700);clock.flushTrace();tracedClock=null;
}finally{if(tracedClock)tracedClock.disposeTrace();rmSync(atomicDirectory,{recursive:true});}
console.log('PASS preparation-clock exact intersections, last-absent/no-sample, malformed/stale/error, cold900, actual clock calibration/private files');
