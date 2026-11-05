#!/usr/bin/env python3
"""Actual scalar lease, compiled Nim, native Chromium delivery and real owner Replay.

No fake DOM, copied observer/WeakMap/codec or Replay cursor. Finite source inverses
compile actual production changes and reach named semantic assertions; each has a
separately rebuilt unchanged same-case companion. Native generation/script/link/
run inputs are retained once, not copied into a second corpus. Resource refusals
and all failed invocations remain evidence and earn no semantic credit.
"""
from pathlib import Path
import hashlib,itertools,json,os,re,shlex,shutil,subprocess,tempfile,time
R=Path(__file__).resolve().parent.parent
BASE=Path(os.environ.get('OBSERVER_EVIDENCE',R/'build/listener-observer-evidence'));BASE.mkdir(parents=True,exist_ok=True)
O=Path(os.environ['OBSERVER_RESUME'])if os.environ.get('OBSERVER_RESUME')else Path(tempfile.mkdtemp(prefix='run-',dir=BASE))
print('Observer proof root: '+str(O),flush=True)
L=json.loads((O/'LEDGER.json').read_text())if(O/'LEDGER.json').exists()else[]
PRIOR=Path(os.environ['OBSERVER_PRIOR_RUN'])if os.environ.get('OBSERVER_PRIOR_RUN')else None
NONCOMPILER_CHANGES={str(R/p)for p in ['tools/test_listener_observer_owner.py','tests/test_listener_observer_owner.mjs','tests/test_listener_observer_unused.mjs']}
def inherit(name,argv,compileOutput=False):
 if PRIOR is None or not(PRIOR/(name+'-RESULT.json')).exists():return None
 guard(name+' inherited compiler/tool bindings')
 q=json.loads((PRIOR/(name+'-RESULT.json')).read_text());assert q['exit']==q['expected']==0 and not q['extra']and q['oracle']is None
 assert sha(PRIOR/(name+'.log'))==q['logSha256']
 actual=list(map(str,argv));reference=q['argv'];differences=[]
 if compileOutput:
  for i,(a,b)in enumerate(zip(actual,reference)):
   if a.startswith('--out:')or a.startswith('--nimcache:'):actual[i]=b
 assert actual==reference,'inherited actual argv drift '+name
 for path,h in q['beforeInputs'].items():
  current=sha(path)
  if current!=h:
   assert path in NONCOMPILER_CHANGES,'inherited compiler/source/config drift '+path
   differences.append(dict(path=path,old=h,new=current,scope='JS assertion/Python orchestration input, not a Nim source/config/compiler input'))
 assert all(sha(path)==h for path,h in q['outputs'].items())
 row=dict(parentEpoch=str(PRIOR),originalResult=str(PRIOR/(name+'-RESULT.json')),originalResultSha256=sha(PRIOR/(name+'-RESULT.json')),originalLogSha256=q['logSha256'],originalArgv=reference,oldOuterInputChanges=differences,compilerSourceConfigUnchanged=True,actualOutputs=q['outputs'],credit='Original execution retained at its own epoch; no new compile/tool invocation or old browser-test relabeling')
 frozen(O/(name+'-REUSED.json'),row);print(name,'authenticated prior unchanged compiler/tool output',flush=True)
 if compileOutput:return Path(next(x.split(':',1)[1]for x in reference if x.startswith('--out:')))
 return(PRIOR/(name+'.log')).read_text(errors='replace')
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def frozen(p,data):
 b=json.dumps(data,indent=2,sort_keys=True)+'\n'
 if p.exists():assert p.read_text()==b,'frozen evidence changed '+str(p)
 else:p.parent.mkdir(parents=True,exist_ok=True);p.write_text(b)
def guard(name):
 m=int(next(x.split()[1]for x in Path('/proc/meminfo').read_text().splitlines()if x.startswith('MemAvailable:')))*1024;d=shutil.disk_usage(O).free;r=dict(time=time.time(),operation=name,memAvailableBytes=m,diskFreeBytes=d,admitted=min(m,d)>=8*1024**3)
 with(O/'RESOURCE.jsonl').open('a')as f:f.write(json.dumps(r)+'\n')
 assert r['admitted'],'BLOCKED resource floor '+name
source=R/'src/isonim/core/nondet.nim';original=source.read_text()
cases=[]
def inverse(name,old,new,oracle,replay=False):
 assert original.count(old)==1,(name,'unique inverse source site');cases.append(dict(name=name,old=old,new=new,oracle=oracle,replay=replay))
inverse('click-finalized', 'finalized: false', "finalized: ev.type === 'click'", 'entered-snapshot-not-final')
inverse('no-clear','isonimListenerHook = null; isonimListenerInstallation = null;','isonimListenerInstallation = null;','release-observation-only')
inverse('public-invalidation','isonimListenerInstallation = null; isonimListenerHook = hook;','isonimListenerHook = hook;','public-same-reinstall')
inverse('stale-clear','if (isonimListenerInstallation === token)','if (token)','new-lease-stale-release')
inverse('application-removal','const hook = isonimListenerHook;','const hook = isonimListenerHook; if (!hook) { entry.dispose(); return; }','release-observation-only')
inverse('entered-handler','try { return handler.call(this, ev); }','try { if (hook && isonimListenerHook !== hook) return; return handler.call(this, ev); }','reentrant-entry-finally')
inverse('entered-finally','finally { if (record) {','finally { if (record && isonimListenerHook === hook) {','reentrant-entry-finally')
inverse('nil-admission','if hook == nil:','if false:','nil-occupied-precedence')
inverse('occupied-overwrite','if not rawObserverFree():','if false:','nil-occupied-precedence')
inverse('claim-replay','refuseReadReplay(currentClock, "claimInternalListenerObserver")','discard','replay-refusal-retry',True)
inverse('release-replay','refuseReadReplay(currentClock, "releaseInternalListenerObserver")','discard','replay-refusal-retry',True)
inverse('consume-before-refusal','      refuseReadReplay(currentClock, "releaseInternalListenerObserver")','      let lost = owned\n      owned = nil\n      refuseReadReplay(currentClock, "releaseInternalListenerObserver")\n      owned = lost','replay-refusal-retry',True)
files=['src/isonim/core/nondet.nim','Justfile','tools/test_listener_observer_owner.py','tests/test_listener_observer_owner.mjs','tests/test_listener_observer_unused.mjs','tests/fixtures/listener_observer.nim','tests/fixtures/listener_observer_effects.nim','tests/fixtures/listener_observer_unused.nim']
rows=[dict(release=a,recordable=b,direct=c)for a,b,c in itertools.product([False,True],repeat=3)]
frozen(O/'INVENTORY-AND-INVERSES.json',dict(sourceParent=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),files={p:sha(R/p)for p in files},rows=rows,inverses=cases,scope='All8 positive/omission/parent-byte rows;9nonReplay inverses x8rows plus3Replay inverses x4nondirect rows; every pair separately compiled and same-case executed. Replay positives4nondirect rows. No semantic command has run before this manifest.'))
inputs=[R/p for p in files]
def run(name,argv,extra=None,cwd=R,expected=0,oracle=None,outputs=(),selected=()):
 argv=list(map(str,argv));extra=extra or {};guard(name+' bindings')
 if name in ['compiler-discovery','browser-identity','node-identity','compiler-identity']:
  inherited=inherit(name,argv)
  if inherited is not None:return inherited
 # A declared output never becomes an input merely because a previous
 # invocation produced it (including an output supplied through environment).
 declared={Path(p).resolve()for p in outputs}
 b={}
 def bind_input(value):
  p=Path(value)
  if p.is_file()and p.resolve()not in declared:
   b[str(p)]=sha(p)
   b[str(p.resolve())]=sha(p.resolve())
 for p in [*inputs,*selected]:bind_input(p)
 for token in [argv[0],*extra.values()]:
  if isinstance(token,str)and len(token)<250 and '\n'not in token:
   bind_input(shutil.which(token)or token)
 previous=[x for x in L if x['name']==name]
 if previous:
  assert len(previous)==1;q=previous[0];assert q['argv']==argv and q['extra']==extra and q['cwd']==str(cwd)and q['beforeInputs']==b and q['expected']==expected and q['oracle']==oracle,'retained command drift '+name
  assert q['exit']==expected and sha(O/(name+'.log'))==q['logSha256']
  assert set(q['outputs'])==set(map(str,outputs)),'declared output inventory drift '+name
  for path,h in q['outputs'].items():
   retained=Path(path)
   if name.startswith('literal-')and path==str(O/'literal.js'):
    retained=O/(name+'.js')
    assert retained.is_file(),'missing literal phase capture; inspect original result without rerunning compiler'
   assert sha(retained)==h,'retained actual command output drift '+name
  text=(O/(name+'.log')).read_text(errors='replace')
  if oracle:assert 'OBSERVER_ASSERT: '+oracle in text,'retained wrong semantic diagnostic '+name
  print(name,'verified original result; no rerun',flush=True);return text
 assert not(O/(name+'-START.json')).exists(),'unreceipted command requires inspection '+name;guard(name)
 start=dict(name=name,argv=argv,extra=extra,cwd=str(cwd),time=time.time(),beforeInputs=b,expected=expected,oracle=oracle);frozen(O/(name+'-START.json'),start)
 with(O/(name+'.log')).open('xb')as log:q=subprocess.run(argv,cwd=cwd,env=os.environ|extra,stdout=log,stderr=subprocess.STDOUT)
 text=(O/(name+'.log')).read_text(errors='replace');assert all(Path(p).is_file()for p in outputs),'declared output missing '+name
 row=dict(**start,exit=q.returncode,logSha256=sha(O/(name+'.log')),outputs={str(p):sha(p)for p in outputs if Path(p).is_file()});L.append(row);frozen(O/(name+'-RESULT.json'),row);(O/'LEDGER.json').write_text(json.dumps(L,indent=2)+'\n');print(name,q.returncode,flush=True)
 assert q.returncode==expected,'unexpected actual exit '+name
 if oracle:assert 'OBSERVER_ASSERT: '+oracle in text,'wrong semantic diagnostic '+name
 guard(name+' restored bindings');assert all(sha(p)==h for p,h in b.items()),'input changed '+name
 return text
nim=Path(shutil.which('nim')or'');node=Path(shutil.which('node')or'');chrome=Path(os.environ.get('PLAYWRIGHT_CHROMIUM_EXECUTABLE',''));owner=Path(os.environ.get('CT_ARTIFACT',''))
assert nim.is_file()and node.is_file()and chrome.is_file()and(owner/'packages/boundary-shim/package.json').is_file()
guard('finite source/config/tool bindings')
inputs += [nim,nim.resolve(),node,node.resolve(),chrome,chrome.resolve()]
for base in [R/'src/isonim/core',R/'tests/fixtures',R.parent/'nim-everywhere/src']:
 inputs.extend(p for p in base.rglob('*')if p.is_file()and p.suffix in ['.nim','.nims','.js','.json'])
for p in [R/'config.nims',R/'tests/config.nims',R/'nim.cfg',R/'repro.nim',R/'repro.lock',R/'flake.nix',R/'flake.lock']:
 if p.is_file():inputs.append(p)
for package in ['playwright','playwright-core']:
 p=(R/'tests/browser/node_modules'/package).resolve();assert json.loads((p/'package.json').read_text())['version']=='1.59.1';inputs.extend(q for q in p.rglob('*')if q.is_file()and q.suffix in ['.js','.mjs','.json'])
# Hash installed owner code/config, not generated source/native bodies or an old
# proof corpus. Bundle metafiles bind the actual subset consumed in browser rows.
for base in [owner/'packages/boundary-shim',owner/'packages/boundary-format',owner/'packages/boundary-replay',owner/'packages/runtime-browser']:
 if base.is_dir():inputs.extend(p for p in base.rglob('*')if p.is_file()and p.suffix in ['.js','.mjs','.json'])
assert sha(chrome)=='9de39c68aac4980d36b24f7cc0a56a95e4c66f701a79f714872e91ff7cc4e147'
assert sha(node)=='d37303e5fa1e7df0f0e04b8f7799966eb2ace28c62ff4a9ef18ce75f6a1caf9a'
metadata=run('compiler-discovery',[nim,'dump','--dump.format:json','--backend:js','--path:'+str(R/'src'),R/'tests/fixtures/listener_observer.nim'])
meta=json.loads(metadata[metadata.index('{'):]);engine=Path(meta['nimExe']);stdlib=Path(meta['libpath']);assert sha(engine)=='1553ba143a8516624aa522c9348f44fbaf1e4f4123034840b20eee37f90790ac'
inputs.extend([engine]);inputs.extend(p for p in stdlib.rglob('*')if p.is_file());inputs.extend(Path(x)for x in re.findall(r"used config file '([^']+)'",metadata))
frozen(O/'INPUTS-BEFORE.json',{str(p):sha(p)for p in inputs});run('browser-identity',[chrome,'--version']);run('node-identity',[node,'--version']);run('compiler-identity',[nim,'--version'])
core={str(p.relative_to(R/'src')):p for p in(R/'src/isonim/core').rglob('*')if p.is_file()}
def compile(name,fixture,flags=(),replacement=None,native=False):
 dest=O/(name+(''if native else'.js'));cache=O/'cache'/name;argv=[nim,'c'if native else'js','--hint:Conf:on','--path:'+str(R/'src'),'--path:'+str(R.parent/'nim-everywhere/src'),'--nimcache:'+str(cache),'--out:'+str(dest),*flags]
 selected=[]
 if replacement is not None:
  scope=O/'inverse-source'/name
  for relative,p in core.items():
   target=scope/relative;target.parent.mkdir(parents=True,exist_ok=True)
   if relative=='isonim/core/nondet.nim':
    if target.exists():assert target.read_text()==replacement
    else:target.write_text(replacement)
   elif not target.exists():target.symlink_to(p)
   selected.append(target)
  argv+=['--path:'+str(scope)]
 argv.append(R/'tests/fixtures'/fixture)
 if not native:
  if replacement is None:
   inherited=inherit(name+'-compile',argv,True)
   if inherited is not None:return inherited
  run(name+'-compile',argv,outputs=[dest],selected=selected);return dest
 run(name+'-generate',[*argv[:2],'--compileOnly:on','--genScript:on',*argv[2:]],selected=selected)
 scripts=list(cache.glob('*.sh'));assert len(scripts)==1;documents=[json.loads(p.read_text())for p in cache.glob('*.json')];build=next(x for x in documents if x.get('outputFile')==str(dest));commands=[x[1]for x in build['compile']];lines=[x for x in scripts[0].read_text().splitlines()if x and not x.startswith('#')];assert lines[:len(commands)]==commands
 actual=shlex.split(lines[len(commands)]);reference=shlex.split(build['linkcmd']);assert len(actual)==len(reference);oi=reference.index('-o')+1;assert actual.index('-o')+1==oi and Path(actual[oi]).name==dest.name
 objects=[]
 for i,(a,b)in enumerate(zip(actual,reference)):
  if i==oi:continue
  if b in build['link']:assert(cache/a).resolve()==Path(b).resolve();objects.append(str((cache/a).resolve()))
  else:assert a==b
 assert objects==build['link'];generated=[p for p in cache.iterdir()if p.is_file()and p.suffix in ['.c','.h','.json','.sh']];tools=[]
 for cmd in commands+[build['linkcmd']]:p=Path(shutil.which(shlex.split(cmd)[0])or shlex.split(cmd)[0]);assert p.is_file();tools.extend([p,p.resolve()])
 guard(name+' generation provenance');provenance=dict(generationResultSha256=sha(O/(name+'-generate-RESULT.json')),generated={str(p):sha(p)for p in generated},tools={str(p):sha(p)for p in tools},script=str(scripts[0]),cwd=str(cache),binary=str(cache/dest.name),objects=objects,build=build,environment={k:os.environ.get(k)for k in ['PATH','CC','CXX','CFLAGS','CPPFLAGS','LDFLAGS','CPATH','LIBRARY_PATH','NIX_CFLAGS_COMPILE','NIX_LDFLAGS','NIX_CC','NIX_BINTOOLS']},limits='Actual reported script/generated inputs/tools bound, not a complete transitive native headers/libraries closure.')
 frozen(O/(name+'-NATIVE-BEFORE.json'),provenance);binary=cache/dest.name;run(name+'-link',['sh','-e',scripts[0]],cwd=cache,outputs=[binary,*map(Path,objects)],selected=[*generated,*tools,O/(name+'-NATIVE-BEFORE.json')]);text=run(name+'-run',[binary],selected=[binary]);assert 'observer native omission passed'in text,'wrong actual native binary result';return binary

def browser(name,bundle,case='all',replay=False,negative=False):
 receipt=O/(name+'-browser.json');run(name,[node,R/'tests/test_listener_observer_owner.mjs'],dict(OBSERVER_BUNDLE=str(bundle),OBSERVER_RECEIPT=str(receipt),OBSERVER_CASE=case,OBSERVER_REPLAY='1'if replay else'0',CT_ARTIFACT=str(owner),PLAYWRIGHT_CHROMIUM_EXECUTABLE=str(chrome)),expected=1 if negative else 0,oracle=case if negative else None,outputs=[receipt],selected=[bundle])
 result=json.loads(receipt.read_text())
 if negative:assert result.get('failure',{}).get('name')==case,'exact structured negative oracle '+name
 else:assert all(check['ok']for row in result['results']for check in row['checks']),'unconsumed failed returned check '+name
private=['-d:isonimInternalListenerObserver','-d:isonimInternalRegisteredHandlers']
for row in rows:
 name='-'.join([('release'if row['release']else'debug'),('recordable'if row['recordable']else'ordinary'),('direct'if row['direct']else'normal')]);flags=private+(['-d:release']if row['release']else[])+(['-d:isonimRecordable']if row['recordable']else[])+(['-d:isonimDirectNondet']if row['direct']else[])
 bundle=compile(name,'listener_observer.nim',flags);browser(name+'-browser',bundle)
 if not row['direct']:
  rb=compile(name+'-replay','listener_observer.nim',flags+['-d:isonimInternalReplayReads']);browser(name+'-replay-browser',rb,'replay-refusal-retry',True)
 absent=compile(name+'-absent','listener_observer_unused.nim',[x for x in flags if x not in private]);unused=compile(name+'-unused','listener_observer_unused.nim',[x for x in flags if x!='-d:isonimInternalRegisteredHandlers']);receipt=O/(name+'-unused.json');run(name+'-omission',[node,R/'tests/test_listener_observer_unused.mjs',absent,unused],dict(PLAYWRIGHT_CHROMIUM_EXECUTABLE=str(chrome),OBSERVER_UNUSED_RECEIPT=str(receipt)),outputs=[receipt],selected=[absent,unused])
 for case in cases:
  if case['replay']and row['direct']:continue
  cf=flags+(['-d:isonimInternalReplayReads']if case['replay']else[]);changed=original.replace(case['old'],case['new']);inv=compile(name+'-inverse-'+case['name'],'listener_observer.nim',cf,changed);browser(name+'-inverse-'+case['name']+'-browser',inv,case['oracle'],case['replay'],True);good=compile(name+'-companion-'+case['name'],'listener_observer.nim',cf,original);browser(name+'-companion-'+case['name']+'-browser',good,case['oracle'],case['replay'])
for absent in [False,True]:compile('native-'+str(absent),'listener_observer_unused.nim',[]if absent else['-d:isonimInternalListenerObserver'],native=True)
for onlyRelease in [False,True]:
 for missing in [None,'Raw','Dom']:
  name='effect-'+('release'if onlyRelease else'claim')+'-'+str(missing);flags=['-d:isonimInternalListenerObserver']+(['-d:observerReleaseOnly']if onlyRelease else[])+(['-d:observerMissing'+missing]if missing else[]);out=O/(name+'.js');text=run(name,[nim,'js','--hint:Conf:on','--path:'+str(R/'src'),'--path:'+str(R.parent/'nim-everywhere/src'),'--nimcache:'+str(O/'cache'/name),'--out:'+str(out),*flags,R/'tests/fixtures/listener_observer_effects.nim'],expected=1 if missing else 0,outputs=[]if missing else[out])
  if missing:assert 'unlisted effect: '+('RawNondet'if missing=='Raw'else'DomEventEffect')in text,'wrong checked effect negative '+name
# One genuine parent materialization, reused at identical source/entry/output paths
# for all8 modes. Only nondet differs in candidate phase, never normalized output.
guard('literal parent source materialization');parent=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip();root=O/'literal-source';entry='tests/fixtures/registered_handler.nim';selected=['src/isonim/core',entry,'config.nims','tests/config.nims'];listing=subprocess.check_output(['git','ls-tree','-r','--name-only',parent,'--',*selected],cwd=R,text=True).splitlines();parentBodies={}
for relative in listing:
 b=subprocess.check_output(['git','show',parent+':'+relative],cwd=R);p=root/relative;p.parent.mkdir(parents=True,exist_ok=True)
 if p.exists()and relative!='src/isonim/core/nondet.nim':assert p.read_bytes()==b
 else:p.write_bytes(b)
 parentBodies[relative]=hashlib.sha256(b).hexdigest()
frozen(O/'PARENT-BINDING.json',dict(parent=parent,files=parentBodies,sameEntryPath=str(root/entry),sameSourcePath=str(root/'src'),sameOutputPath=str(O/'literal.js')))
ownerSource=root/'src/isonim/core/nondet.nim';parentSource=subprocess.check_output(['git','show',parent+':src/isonim/core/nondet.nim'],cwd=R)
for row in rows:
 name='literal-'+str(int(row['release']))+str(int(row['recordable']))+str(int(row['direct']));flags=(['-d:release']if row['release']else[])+(['-d:isonimRecordable']if row['recordable']else[])+(['-d:isonimDirectNondet']if row['direct']else[]);output=O/'literal.js';captures=[]
 for phase,body in [('parent',parentSource),('candidate',original.encode())]:
  ownerSource.write_bytes(body);run(name+'-'+phase,[nim,'js','--hint:Conf:on','--path:'+str(root/'src'),'--path:'+str(R.parent/'nim-everywhere/src'),'--nimcache:'+str(O/'literal-cache'),'--out:'+str(output),*flags,root/entry],selected=[root/p for p in listing],outputs=[output]);capture=O/(name+'-'+phase+'.js')
  phaseResult=json.loads((O/(name+'-'+phase+'-RESULT.json')).read_text())
  expected=phaseResult['outputs'][str(output)]
  if not capture.exists():
   assert sha(output)==expected,'actual phase output differs before capture'
   capture.write_bytes(output.read_bytes())
  assert sha(capture)==expected,'immutable literal phase capture differs from actual original result'
  captures.append(capture)
 assert captures[0].read_bytes()==captures[1].read_bytes(),'literal define-absent bytes differ '+name
assert source.read_text()==original;guard('final selected restoration');after={str(p):sha(p)for p in inputs};assert after==json.loads((O/'INPUTS-BEFORE.json').read_text());frozen(O/'INPUTS-AFTER.json',after);frozen(O/'COMPLETE.json',dict(sourceParent=parent,sourceSha256=sha(source),rows=8,replayRows=4,inverseCompanionPairs=84,nativePrograms=2,commands=len(L),sourceRestored=True));print('Complete owned listener observer qualification PASS',flush=True)
