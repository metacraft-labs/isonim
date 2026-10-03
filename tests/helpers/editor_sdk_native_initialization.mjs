/** Actual owning SDK/native zero-inference host. Unresolved input emits no users.
 * The tested preload is transparent instrumentation, not a fake subprocess.
 */
import {readFileSync,writeFileSync,readdirSync,readlinkSync,existsSync} from 'node:fs';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const config=JSON.parse(readFileSync(process.argv[2],'utf8'));const {query}=await import(config.sdk);const sha=x=>createHash('sha256').update(x).digest('hex');
let release;const held=new Promise(resolve=>release=resolve);async function* input(){await held;}
const started=performance.now();const q=query({prompt:input(),options:{systemPrompt:{type:'preset',preset:'claude_code',append:readFileSync(config.instructions,'utf8')},pathToClaudeCodeExecutable:config.command,sessionId:'15a77f61-f0a2-4186-a341-50470f8b4d8b',persistSession:false}});
let timer;const bounded=p=>Promise.race([p,new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('Native initialization exceeded20000ms')),20000);})]).finally(()=>clearTimeout(timer));let native,result;
try{
 await bounded(q.initializationResult());const matches=[];
 for(const pid of readdirSync('/proc').filter(x=>/^\d+$/.test(x))){try{const tail=readFileSync(`/proc/${pid}/stat`,'utf8').split(') ')[1].split(' ');if(Number(tail[1])===process.pid && readlinkSync(`/proc/${pid}/exe`)===config.loadedExecutable)matches.push({pid:Number(pid),starttime:tail[19]});}catch(e){if(!['ENOENT','ESRCH','EACCES'].includes(e.code))throw e;}}
 assert.equal(matches.length,1);native=matches[0];
 const env=readFileSync(`/proc/${native.pid}/environ`);const argv=readFileSync(`/proc/${native.pid}/cmdline`);const cwd=readlinkSync(`/proc/${native.pid}/cwd`);const loaded=sha(readFileSync(`/proc/${native.pid}/exe`));
 assert.equal(loaded,config.loadedSha256);assert.equal(cwd,process.cwd());assert(!env.includes(Buffer.from('ISONIM_SDK_OBSERVER_CONFIG=')));assert(!env.includes(Buffer.from('editor_sdk_native_observer.mjs')));
 result={accepted:true,scope:'Real owning SDK/native initialization only; zero human/model turns',pidIdentity:{...native,loadedSha256:loaded},argvSha256:sha(argv),environmentSha256:sha(env),cwdSha256:sha(cwd),observerEnvAbsent:true,preloadAbsentFromNative:true,parentObserverConfigAbsent:!Object.hasOwn(process.env,'ISONIM_SDK_OBSERVER_CONFIG'),parentNodeOptionsRestored:process.env.NODE_OPTIONS===(config.originalNodeOptions.present?config.originalNodeOptions.value:undefined),initializationSeconds:(performance.now()-started)/1000};
}finally{
 q.close();release();if(native){const end=performance.now()+15000;while(existsSync(`/proc/${native.pid}`)&&performance.now()<end)await new Promise(r=>setTimeout(r,20));assert(!existsSync(`/proc/${native.pid}`),'Owned native not reaped');if(result)result.nativeReaped=true;}
}
writeFileSync(config.result,JSON.stringify(result,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(result));
