#!/usr/bin/env python3
"""Compile actual production and every independent semantic inverse, then use
real Chromium Storage/cookie, installed owner codec and actual owned Replay.
Local HTTP/FrameSink/fault controls are documented in the browser test header.
No fake storage, recorder or cursor. All outputs/current-source copies retained.
"""
from pathlib import Path
import os,shutil,subprocess,tempfile,json,hashlib

root=Path(__file__).resolve().parent.parent
artifact=os.environ.get('CT_ARTIFACT')
if not artifact:raise SystemExit('CT_ARTIFACT required: actual installed storage owner cannot skip')
assert (Path(artifact)/'packages/boundary-shim/dist/browser/recorder.js').is_file()
parent=root/'build/record-storage-inverses';parent.mkdir(parents=True,exist_ok=True)
out=Path(tempfile.mkdtemp(prefix='run-',dir=parent));print('retained qualification directory: '+str(out),flush=True)
base=['-d:isonimInternalRecordStorage','-d:isonimInternalRecordClocks']
env=dict(os.environ);env.setdefault('PLAYWRIGHT_CHROMIUM_EXECUTABLE',shutil.which('chromium') or '')
commands=[]
def run(name,cmd,extra=None,reject=False,diagnostic=None):
 p=subprocess.run(cmd,cwd=root,env=extra or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (out/(name+'.log')).write_text(p.stdout);commands.append({'name':name,'argv':list(map(str,cmd)),'cwd':str(root),'exit':p.returncode});(out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n')
 print(name+': exit '+str(p.returncode),flush=True)
 if reject:
  assert p.returncode!=0 and diagnostic in p.stdout,(name,p.stdout)
 else:assert p.returncode==0,(name,p.stdout)
 return p
def compile_js(name,fixture,flags=(),source=None,reject=False):
 output=out/(name+'.js');cmd=['nim','js',*flags]
 if source:cmd+=['--path:'+str(source),'--path:'+str(root.parent/'nim-everywhere/src')]
 cmd+=['--nimcache:'+str(out/'nimcache'/name),'--out:'+str(output),str(fixture)]
 p=run(name+'-compile',cmd,reject=reject,diagnostic='RawNondet' if reject else None)
 if reject:assert 'unlisted effect' in p.stdout
 return output
boundaries=[[],['-d:storageRaw'],['-d:storageCookie'],['-d:storageRaw','-d:storageCookie']]
for i,boundary in enumerate(boundaries):
 compile_js('effect-'+str(i),'tests/fixtures/record_storage_effect.nim',[*base,*boundary])
 compile_js('reject-'+str(i),'tests/fixtures/record_storage_effect.nim',[*base,*boundary,'-d:storageReject'],reject=True)
for name,flags in [('default',[]),('recordable',['-d:isonimRecordable'])]:
 js=compile_js('omission-'+name,'tests/fixtures/record_storage_omission.nim',flags)
 assert 'RecordStoragePrimitives' not in js.read_text() and 'boundary-shim' not in js.read_text();run('omission-'+name,['node',str(js)])
 for suffix,extra in [('ordinary',[]),('internal',base)]:
  binary=out/('c-'+name+'-'+suffix)
  run('c-'+name+'-'+suffix,['nim','c',*flags,*extra,'--nimcache:'+str(out/'nimcache'/binary.name),'--out:'+str(binary),'tests/fixtures/record_storage_omission.nim']);run(binary.name+'-run',[str(binary)])
 for internal in [False,True]:
  public=compile_js('public-'+name+('-internal' if internal else ''),'tests/fixtures/record_storage_public.nim',[*flags,*(base if internal else [])])
  # Same ordinary public imports must retain exact emitted bytes when an
  # unused internal define is present. Deliberately importing even an empty
  # Nim module renumbers symbols; that different experiment is retained RED.
  if internal:assert public.read_bytes()==previous.read_bytes(),'ordinary public JS exact same-import bytes'
  previous=public
 inert=compile_js('private-import-'+name,'tests/fixtures/record_storage_public.nim',[*flags,'-d:storageImport'])
 assert 'RecordStoragePrimitives' not in inert.read_text() and 'boundary-shim' not in inert.read_text();run('private-import-'+name,['node',str(inert)])
lazy=compile_js('import','tests/fixtures/record_storage_import.nim',base);run('windowless-import',['node',str(lazy)]);run('windowless-no-owner-load',['node','tests/test_record_storage_import.mjs',str(lazy)])
context=compile_js('context','tests/fixtures/replay_reads_context.nim');rp=compile_js('replay','tests/fixtures/record_storage_replay.nim',['-d:isonimInternalReplayReads'])
companion=compile_js('companion','tests/fixtures/record_storage.nim',base)
env.update(STORAGE_IMPORT=str(lazy),STORAGE_CONTEXT=str(context),STORAGE_REPLAY=str(rp),STORAGE_COMPANION=str(companion))
def browser(name,js,replay=rp,inverse=None,assertion=None):
 e={**env,'STORAGE_BUNDLE':str(js),'STORAGE_REPLAY':str(replay),'STORAGE_RESULTS':str(out/(name+'-results.jsonl'))}
 if inverse:e['STORAGE_INVERSE']=inverse
 p=run(name+'-browser',['node','tests/test_record_storage_owner.mjs'],extra=e,reject=bool(inverse),diagnostic='AssertionError [ERR_ASSERTION]: storage semantic: '+str(assertion))
 assert 'storage companion positive: real Record -> strict codec -> public Replay DONE' in p.stdout
 if inverse:assert p.returncode==1 and 'TimeoutError' not in p.stdout and 'SyntaxError' not in p.stdout,'precise semantic failure only'
for name,flags in [('default',[]),('recordable',['-d:isonimRecordable']),('release',['-d:release']),('recordable-release',['-d:isonimRecordable','-d:release'])]:
 js=compile_js('storage-'+name,'tests/fixtures/record_storage.nim',[*base,*flags]);replay=compile_js('replay-'+name,'tests/fixtures/record_storage_replay.nim',['-d:isonimInternalReplayReads',*flags]);browser(name,js,replay)
original=(root/'src/isonim/core/private/record_storage.nim').read_text()
local_call='emitLocal(storage.linkage, nativeKey, present, value.cstring)'
cookie_call='emitCookie(storage.linkage, value.cstring)'
mutations={
 'local-omit':(local_call,'discard','local record count'),
 'presence':('let present = observed.kind != JNull','let present = true','local presence'),
 'local-area':("{area:1,key:String(k)","{area:2,key:String(k)",'local area'),
 'local-key':('key:String(k)','key:String(k)+\'wrong\'','local native key'),
 'local-wire':("value:p?v:''","value:p?'wrong-wire':''",'local wire value'),
 'local-return':('RecordStorageObservation(present: present, value: value)','RecordStorageObservation(present: present, value: value & "wrong")','local returned bytes'),
 'cookie-omit':(cookie_call,'discard','cookie record count'),
 'cookie-area':("{area:3,key:''","{area:1,key:''",'cookie area'),
 'cookie-key':("area:3,key:''","area:3,key:'wrong'",'cookie key'),
 'cookie-present':("key:'',present:1","key:'',present:0",'cookie present'),
 'cookie-wire':("key:'',present:1,value:v","key:'',present:1,value:'wrong-wire'",'cookie wire value'),
 'cookie-return':('\n    value\n','\n    value & "wrong"\n','cookie returned bytes'),
 'live-area':('var s=c.area.call(c.window);','var s=c.window.localStorage;','captured originals survive live replacements'),
 'live-item':('return c.item.call(s,k);','return s.getItem(k);','captured originals survive live replacements'),
 'cookie-live':('return c.cookie.call(c.document);','return c.document.cookie;','captured originals survive live replacements'),
 'double-area':('var s=c.area.call(c.window);','c.area.call(c.window);var s=c.area.call(c.window);','exact native read counts'),
 'double-item':('return c.item.call(s,k);','c.item.call(s,k);return c.item.call(s,k);','exact native read counts'),
 'cookie-double':('return c.cookie.call(c.document);','c.cookie.call(c.document);return c.cookie.call(c.document);','exact native read counts'),
}
def source_copy(name,text):
 directory=out/name;directory.mkdir();source=directory/'src';shutil.copytree(root/'src',source)
 (source/'isonim/core/private/record_storage.nim').write_text(text);fixtures=directory/'tests/fixtures';fixtures.mkdir(parents=True)
 for file in ['record_storage.nim','record_storage_effect.nim']:shutil.copyfile(root/'tests/fixtures'/file,fixtures/file)
 return source,fixtures
inverse_kinds=[];inverse_executions=[]
def inverse(name,text,arms):
 source,fixtures=source_copy(name,text);js=compile_js('inverse-'+name,fixtures/'record_storage.nim',base,source)
 inverse_kinds.append({'kind':name,'source_sha256':hashlib.sha256(text.encode()).hexdigest(),'arms':[{'name':arm,'assertion':assertion} for arm,assertion in arms]})
 for arm,assertion in arms:
  browser('inverse-'+arm,js,inverse=arm,assertion=assertion);inverse_executions.append(arm)
for name,(old,new,assertion) in mutations.items():
 assert original.count(old)==1,(name,original.count(old));inverse(name,original.replace(old,new,1),[(name,assertion)])
assert original.count('var s=c.area.call(c.window);return c.item.call(s,k);')==1 and original.count('return c.cookie.call(c.document);')==1
native_guard=original.replace('var s=c.area.call(c.window);return c.item.call(s,k);','return c.rec.guard(function(){var s=c.area.call(c.window);return c.item.call(s,k);});').replace('return c.cookie.call(c.document);','return c.rec.guard(function(){return c.cookie.call(c.document);});')
assert native_guard!=original
inverse('native-guard',native_guard,[('guard-area','area-error outside guard'),('guard-item','item-error outside guard'),('guard-cookie','cookie-error outside guard')])
raw_helper='  proc rawString(value: JsObject): cstring {.importjs: "#".}\n'
frontier=original.replace('  proc serialize(',raw_helper+'  proc serialize(').replace(local_call,'emitLocal(storage.linkage, nativeKey, present, rawString(raw))')
inverse('frontier',frontier,[('frontier','local wire value')])
frontier_rows=[json.loads(line) for line in (out/'inverse-frontier-results.jsonl').read_text().splitlines()]
proof=next(r for r in frontier_rows if r['stage']=='fidelity' and r['test']['id']=='high')
assert proof['done']=='done' and all(any(c['name']=='typed frontier phase'+str(i) and c['outcome']=='RED' for c in proof['fidelity']) for i in range(2)),'actual raw frontier reaches DONE and fails both independent typed comparisons'
assert original.count('    let observed = ordinaryObservation(raw)')==2
frontend=original.replace('    let observed = ordinaryObservation(raw)','    var observed: JsonNode\n    guarded(storage.linkage, proc() =\n      observed = ordinaryObservation(raw))')
inverse('projection-guard',frontend,[('projection-guard','ordinary frontend error outside guard'),('cookie-projection-guard','ordinary frontend error outside guard')])
logging_guard=original.replace('    guarded(storage.linkage, proc() =\n      # Logging-only conversion MUST execute in the guarded closure body.\n      '+local_call+')','    let loggingValue = value.cstring\n    guarded(storage.linkage, proc() =\n      emitLocal(storage.linkage, nativeKey, present, loggingValue))').replace('    guarded(storage.linkage, proc() =\n      '+cookie_call+')','    let loggingValue = value.cstring\n    guarded(storage.linkage, proc() =\n      emitCookie(storage.linkage, loggingValue))')
assert logging_guard!=original
inverse('logging-guard',logging_guard,[('logging-guard','owner fault preserves typed result'),('cookie-logging-guard','owner fault preserves typed result')])
for name,text,reject in [('raw-loss',original.replace(', tags: [RawNondet]',''),None),('inferred',original.replace(' {.tags: [RawNondet].}',''),True),('combined',original.replace(' {.tags: [RawNondet].}','').replace(', tags: [RawNondet]',''),False)]:
 source,fixtures=source_copy('effect-'+name,text)
 for i,boundary in enumerate(boundaries):compile_js(name+str(i),fixtures/'record_storage_effect.nim',[*base,*boundary,'-d:storageReject'],source,reject=('-d:storageRaw' not in boundary) if name=='raw-loss' else reject)
missing=dict(env);missing.pop('CT_ARTIFACT',None);run('missing-artifact',['python3',str(Path(__file__))],extra=missing,reject=True,diagnostic='CT_ARTIFACT required')
missing={**env,'STORAGE_BUNDLE':str(companion)};missing.pop('STORAGE_CONTEXT',None);run('missing-context',['node','tests/test_record_storage_owner.mjs'],extra=missing,reject=True,diagnostic='STORAGE_CONTEXT required')
summary={'compiled_kinds':len(inverse_kinds),'semantic_executions':len(inverse_executions),'kinds':inverse_kinds,'executions':inverse_executions}
assert len({r['kind'] for r in inverse_kinds})==len(inverse_kinds) and len(set(inverse_executions))==len(inverse_executions)
(out/'INVERSES.json').write_text(json.dumps(summary,indent=2)+'\n')
print('storage '+str(summary['compiled_kinds'])+' compiled inverse kinds / '+str(summary['semantic_executions'])+' precise semantic executions PASS',flush=True)
