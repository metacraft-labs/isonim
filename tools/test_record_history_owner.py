#!/usr/bin/env python3
"""Real current-source compiles/Chromium and precise own-source inverses.

Every mutation retains its full source graph, successful compiler receipt,
unmodified companion DONE and exact independent semantic assertion. No fake
native/owner or generic thrown trap substitutes for a semantic rejection.
"""
from pathlib import Path
import os,subprocess,tempfile,shutil,json,hashlib
root=Path(__file__).resolve().parent.parent
artifact=os.environ.get('CT_ARTIFACT')
if not artifact:raise SystemExit('CT_ARTIFACT required: actual history owner cannot skip')
assert (Path(artifact)/'packages/boundary-shim/dist/browser/recorder.js').is_file()
parent=root/'build/record-history-inverses';parent.mkdir(parents=True,exist_ok=True)
out=Path(tempfile.mkdtemp(prefix='run-',dir=parent));print('retained history qualification: '+str(out),flush=True)
env=dict(os.environ);commands=[];flags=['-d:isonimInternalRecordHistory','-d:isonimInternalRecordClocks']
def run(name,args,extra=None,reject=None):
 p=subprocess.run(args,cwd=root,env=extra or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (out/(name+'.log')).write_text(p.stdout);commands.append({'name':name,'argv':list(map(str,args)),'cwd':str(root),'exit':p.returncode});(out/'commands.json').write_text(json.dumps(commands,indent=2)+'\n');print(name+': exit '+str(p.returncode),flush=True)
 if reject:assert p.returncode==1 and reject in p.stdout and 'TimeoutError' not in p.stdout,(name,p.stdout)
 else:assert p.returncode==0,(name,p.stdout)
 return p
def compile(name,fixture,extra=(),src=None,reject=None,backend='js'):
 dest=out/(name+('.js' if backend=='js' else ''));args=['nim',backend,*extra]
 if src:args+=['--path:'+str(src),'--path:'+str(root.parent/'nim-everywhere/src')]
 args+=['--nimcache:'+str(out/'nimcache'/name),'--out:'+str(dest),str(fixture)]
 run(name+'-compile',args,reject=reject);return dest
boundaries=[[],['-d:historyRaw'],['-d:historyReplace'],['-d:historyCombined']]
for i,boundary in enumerate(boundaries):
 compile('effect'+str(i),'tests/fixtures/record_history_effect.nim',[*flags,*boundary]);compile('effect-reject'+str(i),'tests/fixtures/record_history_effect.nim',[*flags,*boundary,'-d:historyReject'],reject='unlisted effect: RawNondet')
for mode,extra in [('default',[]),('recordable',['-d:isonimRecordable'])]:
 for internal in [False,True]:
  c=compile('omit-c-'+mode+str(internal),'tests/fixtures/record_history_omission.nim',[*extra,*(flags if internal else [])],backend='c');run(c.name+'-run',[str(c)])
 js=compile('omit-js-'+mode,'tests/fixtures/record_history_omission.nim',extra);run(js.stem+'-run',['node',str(js)])
 previous=None
 for internal in [False,True]:
  js=compile('public-'+mode+str(internal),'tests/fixtures/record_history_public.nim',[*extra,*(flags if internal else [])]);
  if previous:assert js.read_bytes()==previous.read_bytes(),'same public imports exact bytes'
  previous=js
 js=compile('import-omitted-'+mode,'tests/fixtures/record_history_public.nim',[*extra,'-d:historyImport']);assert 'boundary-shim' not in js.read_text();run(js.stem+'-run',['node',str(js)])
early=compile('import','tests/fixtures/record_history_import.nim',flags);run('windowless',['node','tests/test_record_history_import.mjs',str(early)])
context=compile('context','tests/fixtures/replay_reads_context.nim')
companion=compile('companion','tests/fixtures/record_history.nim',flags)
rp=compile('replay','tests/fixtures/record_history_replay.nim',['-d:isonimInternalReplayReads'])
env.update(HISTORY_COMPANION=str(companion),HISTORY_REPLAY=str(rp),HISTORY_CONTEXT=str(context),HISTORY_IMPORT=str(early))
def browser(name,js,extra=None,reject=None):
 e={**env,'HISTORY_BUNDLE':str(js),'HISTORY_RESULTS':str(out/(name+'-results.jsonl')),**(extra or {})}
 p=run(name+'-browser',['node','tests/test_record_history_owner.mjs'],e,reject)
 assert 'history companion positive: real Record -> strict codec -> Replay DONE' in p.stdout
 return p
for mode,extra in [('default',[]),('recordable',['-d:isonimRecordable']),('release',['-d:release']),('combined',['-d:isonimRecordable','-d:release'])]:
 js=compile('history-'+mode,'tests/fixtures/record_history.nim',[*flags,*extra]);rr=compile('replay-'+mode,'tests/fixtures/record_history_replay.nim',['-d:isonimInternalReplayReads',*extra]);browser(mode,js,{'HISTORY_REPLAY':str(rr)})
original=(root/'src/isonim/core/private/record_history.nim').read_text()
emit="#.rec.emit('Navigation',{kind:#,url:#})"
mutations={
 'omit-push':(emit,"(function(c,k,u){if(k!==1)c.rec.emit('Navigation',{kind:k,url:u});})(#,#,#)",'navigation record count'),
 'omit-replace':(emit,"(function(c,k,u){if(k!==2)c.rec.emit('Navigation',{kind:k,url:u});})(#,#,#)",'navigation record count'),
 'kind-push':('(if push: 1 else: 2)','(if push: 2 else: 2)','navigation kind'),
 'kind-replace':('(if push: 1 else: 2)','(if push: 1 else: 1)','navigation kind'),
 'relative':('observed.get().cstring','url.cstring','reflected wire URL'),
 'pathname':('observed.get().cstring','wrongPath()','reflected wire URL'),
 'returned':('\n    observed\n','\n    some("wrong-return")\n','ordinary returned bytes'),
 'live-push':('(p?c.push:c.replace).call(h',"(p?c.window.history.pushState:c.replace).call(h",'captured native lookup'),
 'live-replace':('(p?c.push:c.replace).call(h',"(p?c.push:c.window.history.replaceState).call(h",'captured native lookup'),
 'double-push':("(p?c.push:c.replace).call(h,null,'',u);","if(p)c.push.call(h,null,'',u);(p?c.push:c.replace).call(h,null,'',u);",'native call count'),
 'double-replace':("(p?c.push:c.replace).call(h,null,'',u);","if(!p)c.replace.call(h,null,'',u);(p?c.push:c.replace).call(h,null,'',u);",'native call count'),
 'native-guard':("var h=c.window.history;(p?c.push:c.replace).call(h,null,'',u);","var h=c.window.history;c.rec.guard(function(){(p?c.push:c.replace).call(h,null,'',u);});",'native outside guard'),
 'P-guard':('let observed = if raw.isNil: none(string) else: some($raw)','var observed: Option[string]\n    guarded(history.linkage, proc() =\n      observed = if raw.isNil: none(string) else: some($raw))','P exception identity outside guard'),
 'Q-before':('    guarded(history.linkage, proc() =\n      if observed.isNone:', '    let loggingUrl = (if observed.isSome: observed.get().cstring else: cstring(\"\"))\n    guarded(history.linkage, proc() =\n      if observed.isNone:','logging cannot replace native success'),
}
kinds=[];executions=[]
def copied(name,text):
 directory=out/name;directory.mkdir();src=directory/'src';shutil.copytree(root/'src',src);(src/'isonim/core/private/record_history.nim').write_text(text);fixture=directory/'tests/fixtures/record_history.nim';fixture.parent.mkdir(parents=True);shutil.copyfile(root/'tests/fixtures/record_history.nim',fixture)
 shutil.copyfile(root/'tests/fixtures/record_history_effect.nim',fixture.parent/'record_history_effect.nim')
 graph={}
 for path in sorted(directory.rglob('*')):
  if '.git' in path.relative_to(directory).parts:continue
  if path.is_file():graph[str(path.relative_to(directory))]={'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'size':path.stat().st_size,'mode':path.stat().st_mode}
 (directory/'SOURCE-PRECOMPILE.json').write_text(json.dumps(graph,sort_keys=True,indent=2)+'\n')
 return src,fixture
for name,(old,new,assertion) in mutations.items():
 assert original.count(old)==1,(name,original.count(old));text=original.replace(old,new,1)
 if name=='pathname':text=text.replace('  proc unavailable()', '  proc wrongPath(): cstring {.importjs: "(function(){return window.location.pathname;})()".}\n  proc unavailable()')
 if name=='Q-before':text=text.replace('observed.get().cstring))','loggingUrl))')
 src,fixture=copied(name,text);js=compile('inverse-'+name,fixture,flags,src)
 for arm in ['push','replace'] if name in ['native-guard','P-guard','Q-before'] else ['both']:
  browser('inverse-'+name+'-'+arm,js,{'HISTORY_INVERSE':name,'HISTORY_PUSH':arm},'AssertionError [ERR_ASSERTION]: history semantic: '+assertion);executions.append({'kind':name,'arm':arm,'assertion':assertion})
 kinds.append({'kind':name,'sha256':hashlib.sha256(text.encode()).hexdigest()})
# Derived own-production-source return defect only. The real public recording
# getter selects fault/terminal paths; production gains no helper or state read.
assert original.count('\n    observed\n')==1 and original.count('  proc record(history:')==1
text=original.replace('  proc record(history:', '  proc mutantOwnerRecording(linkage: JsObject): bool {.importjs: "#.rec.recording".}\n\n  proc record(history:',1).replace('\n    observed\n','\n    if observed.isSome and not mutantOwnerRecording(history.linkage):\n      some("wrong-fault-return")\n    else:\n      observed\n',1)
src,fixture=copied('fault-return',text);js=compile('inverse-fault-return',fixture,flags,src)
for mode in ['Q','sanitize','encoder','sink','halted','prefaulted','ended','halted:Q','prefaulted:Q','ended:Q']:
 for arm in ['push','replace']:
  assertion='fault and terminal exact ordinary Option bytes'
  browser('inverse-fault-return-'+mode.replace(':','-')+'-'+arm,js,{'HISTORY_INVERSE':'fault-return','HISTORY_FAULT_MODE':mode,'HISTORY_PUSH':arm},'AssertionError [ERR_ASSERTION]: history semantic: '+assertion);executions.append({'kind':'fault-return','condition':mode,'arm':arm,'assertion':assertion})
kinds.append({'kind':'fault-return','sha256':hashlib.sha256(text.encode()).hexdigest(),'derived_helper':'mutant-only public Recorder.recording getter; no production hook/private-state inspection'})
# Deliberate manufactured branch input after real native effect, never a native
# getter-failure claim or a semantic-kill count.
assert original.count("return typeof v==='string'?v:null;")==1
text=original.replace("return typeof v==='string'?v:null;","return null;")
src,fixture=copied('none-stimulus',text);js=compile('none-stimulus',fixture,flags,src);browser('none-stimulus',js,{'HISTORY_NONE':'1'})
for name,text,reject in [('raw-loss',original.replace(', tags: [RawNondet]',''),None),('inferred',original.replace(' {.tags: [RawNondet].}',''),True),('combined',original.replace(' {.tags: [RawNondet].}','').replace(', tags: [RawNondet]',''),False)]:
 src,fixture=copied('effect-'+name,text);effect=fixture.parent/'record_history_effect.nim';shutil.copyfile(root/'tests/fixtures/record_history_effect.nim',effect)
 for i,boundary in enumerate(boundaries):
  fails=('-d:historyRaw' not in boundary) if name=='raw-loss' else reject
  compile('effect-'+name+str(i),effect,[*flags,*boundary,'-d:historyReject'],src,reject='unlisted effect: RawNondet' if fails else None)
missing=dict(env);missing.pop('CT_ARTIFACT',None);run('missing-artifact',['python3',str(Path(__file__))],missing,reject='CT_ARTIFACT required')
for manifest in out.glob('*/SOURCE-PRECOMPILE.json'):
 for rel,meta in json.loads(manifest.read_text()).items():
  path=manifest.parent/rel;assert path.stat().st_mode==meta['mode'] and path.stat().st_size==meta['size'] and hashlib.sha256(path.read_bytes()).hexdigest()==meta['sha256'],str(path)
(out/'INVERSES.json').write_text(json.dumps({'compiled_kinds':kinds,'semantic_executions':executions,'none_stimulus_not_counted':True},indent=2)+'\n')
print('history '+str(len(kinds))+' compiled semantic inverse kinds / '+str(len(executions))+' precise semantic executions PASS; explicit None stimulus separate',flush=True)
