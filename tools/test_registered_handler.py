#!/usr/bin/env python3
"""Qualify actual compiled private listener calls in real Chromium.

No alternate listener registry, fake DOM, owner or Replay cursor is used. The
finite production source inverses share the unchanged browser assertions with
fresh genuine companions. Output, inputs and command refusals are retained.
"""
from pathlib import Path
import hashlib,itertools,json,os,re,shlex,shutil,subprocess,sys,tempfile,time
from registered_handler_core import (OWNER, bodies, identities, authenticate, historical_graph,
 conserve_common, phase, administrative_controls, processed_modules, reject_added_imports)
expected_graphs={}
ROOT=Path(__file__).resolve().parent.parent
OUT_PARENT=Path(os.environ.get('REGISTERED_EVIDENCE',str(ROOT/'build/registered-handler-evidence')))
OUT_PARENT.mkdir(parents=True,exist_ok=True)
OUT=Path(os.environ['REGISTERED_RESUME']) if os.environ.get('REGISTERED_RESUME') else Path(tempfile.mkdtemp(prefix='run-',dir=OUT_PARENT))
assert OUT.is_dir(),'existing own qualification directory required'
print('Registered handler evidence: '+str(OUT),flush=True)
LEDGER=json.loads((OUT/'LEDGER.json').read_text()) if (OUT/'LEDGER.json').exists() else []
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def guard(name):
 d=shutil.disk_usage(OUT).free;m=int(next(x.split()[1] for x in Path('/proc/meminfo').read_text().splitlines() if x.startswith('MemAvailable:')))*1024
 row=dict(name=name,disk=d,MemAvailable=m,time=time.time(),attempt=time.time_ns())
 with (OUT/(name+'-RESOURCE-'+str(row['attempt'])+'.json')).open('x')as f:json.dump(row,f)
 with (OUT/'RESOURCE-ATTEMPTS.jsonl').open('a') as f:f.write(json.dumps(row)+'\n')
 if not (OUT/(name+'-RESOURCE.json')).exists():(OUT/(name+'-RESOURCE.json')).write_text(json.dumps(row))
 assert min(d,m)>=8*1024**3,'BLOCKED: resource floor '+name

def validate_compile_configs(name,body,metadata):
 if metadata:
  actual=[str(Path(x).resolve())for x in re.findall(r"used config file '([^']+)'",body)]
  assert actual and all(x in bindings and sha(Path(x))==bindings[x]for x in actual),'actual compiler config outside BEFORE bindings '+name
  assert actual==metadata['configs'],'metadata/actual compiler config order mismatch '+name

def generated_files(scope):
 return sorted(p for p in Path(scope).iterdir()if p.is_file()and p.suffix in ['.c','.h','.json','.sh'])

def run(name,argv,extra=None,split=False,cwd=None,produced=(),generated_scope=None):
 cwd=Path(cwd or ROOT)
 argv=list(argv)
 if len(argv)>1 and Path(argv[0]).name=='nim'and argv[1]in['js','c']:
  for option in ['--hint:Conf:on','--processing:filenames','--filenames:abs']:
   if option not in argv:argv.insert(2,option)
 executable=Path(shutil.which(argv[0])or argv[0])
 selected_executable=[executable,executable.resolve()]if executable.is_file()else[]
 selected=[]
 core_phases={}
 core_roots=[Path(x.split(':',1)[1]) for x in argv if x.startswith('--path:') and (Path(x.split(':',1)[1])/'isonim/core/nondet.nim').is_file()]
 if core_roots:guard(name+'-actual-core-before-binding')
 for scope in core_roots:
  actual={str(p.relative_to(scope)):sha(p)for p in (scope/'isonim/core').rglob('*')if p.is_file()}
  assert str(scope.resolve()) in expected_graphs,'explicit expected core phase required'
  authenticate(scope,expected_graphs[str(scope.resolve())])
  core_phases[str(scope.resolve())]=expected_graphs[str(scope.resolve())]
  selected += [scope/key for key in actual]
 selected += [Path(x) for x in argv if Path(x).is_file() and Path(x).suffix in ['.nim','.mjs','.sh','.json']]
 selected += [Path(x)for x in known_configs] if 'known_configs'in globals() else []
 if 'nim'in globals():selected += [nim,nim.resolve()]
 if extra and extra.get('REGISTERED_BUNDLE'):selected.append(Path(extra['REGISTERED_BUNDLE']))
 selected += selected_executable
 beforeInputs={str(p):sha(p)for p in selected}
 compile_metadata=None
 if len(argv)>1 and Path(argv[0]).name=='nim'and argv[1]in['js','c']:
  compile_metadata=discover(name+'-metadata',argv[-1],argv[2:-1],argv[1])
  assert Path(compile_metadata['metadata']['nimExe']).resolve()==engine.resolve() and Path(compile_metadata['metadata']['libpath']).resolve()==stdlib.resolve(),'selected compiler/stdlib drift'
  assert all(path in bindings and sha(Path(path))==bindings[path]for path in compile_metadata['configs']),'compiler config not bound before consumer'
 cached=[x for x in LEDGER if x['name']==name]
 if cached:
  assert len(cached)==1
  row=cached[0];assert row['argv']==argv and row['env']==(extra or {}) and row['beforeInputs']==beforeInputs and row['cwd']==str(cwd)and row['declaredOutputs']==list(map(str,produced))and row['generatedScope']==(str(generated_scope)if generated_scope else None)and row['compilerMetadata']==compile_metadata and row['corePhases']==core_phases,'frozen command/input drift on resume '+name
  assert sha(OUT/(name+'.log'))==row['logSha'],'retained command log drift '
  if split:assert sha(OUT/(name+'-STDERR.log'))==row['stderrSha256'],'retained metadata stderr drift '
  assert all(Path(p).is_file()and sha(Path(p))==h for p,h in row['outputs'].items()),'retained command artifact drift '
  body=(OUT/(name+'.log')).read_text(errors='replace')
  validate_compile_configs(name,body,compile_metadata)
  if generated_scope:
   assert list(map(str,generated_files(generated_scope)))==row['generatedOutputs'],'retained generated output inventory drift '+name
  print(name,'verified prior receipt; no reexecution',flush=True)
  return row['exit'],body
 assert not (OUT/(name+'-BEFORE.json')).exists(),'unreceipted command evidence: inspect process before resuming '+name
 guard(name)
 before=dict(corePhases=core_phases,argv=argv,env=extra or {},cwd=str(cwd),declaredOutputs=list(map(str,produced)),generatedScope=str(generated_scope)if generated_scope else None,time=time.time(),beforeInputs=beforeInputs,compilerMetadata=compile_metadata)
 with (OUT/(name+'-BEFORE.json')).open('x')as f:json.dump(before,f,indent=2)
 with (OUT/(name+'.log')).open('xb') as f:
  if split:
   with (OUT/(name+'-STDERR.log')).open('xb')as err:p=subprocess.run(argv,cwd=cwd,env=os.environ|(extra or {}),stdout=f,stderr=err)
  else:p=subprocess.run(argv,cwd=cwd,env=os.environ|(extra or {}),stdout=f,stderr=subprocess.STDOUT)
 body=(OUT/(name+'.log')).read_text(errors='replace')
 validate_compile_configs(name,body,compile_metadata)
 if p.returncode==0 and len(argv)>1 and Path(argv[0]).name=='nim'and argv[1]in['js','c']:
  consumed=processed_modules(body)
  for scope in core_roots:
   assert (scope/'isonim/core/nondet.nim').resolve() in consumed,'known imported owner Processing positive control'
   reject_added_imports(body,scope,additions)
  (OUT/(name+'-PROCESSED-MODULES.json')).write_text(json.dumps(sorted(map(str,consumed)),indent=2))
 generated=generated_files(generated_scope)if generated_scope and p.returncode==0 else []
 if generated_scope and p.returncode==0:assert generated,'actual generated outputs required before receipt admission'
 outputs=[Path(x.split(':',1)[1])for x in argv if x.startswith('--out:')]+list(produced)+generated
 if extra and extra.get('REGISTERED_RECEIPT'):outputs.append(Path(extra['REGISTERED_RECEIPT']))
 row=dict(name=name,exit=p.returncode,generatedOutputs=list(map(str,generated)),logSha=sha(OUT/(name+'.log')),stderrSha256=sha(OUT/(name+'-STDERR.log'))if split else None,outputs={str(p):sha(p)for p in outputs if p.is_file()},**before);LEDGER.append(row)
 with (OUT/(name+'-RESULT.json')).open('x')as f:json.dump(row,f,indent=2)
 (OUT/'LEDGER.json').write_text(json.dumps(LEDGER,indent=2))
 print(name,p.returncode,flush=True)
 return p.returncode,body

def snapshot(name,base):
 guard(name)
 rows={str(p.relative_to(base)):sha(p) for p in base.rglob('*') if p.is_file()}
 before=OUT/(name+'.json')
 if before.exists():assert json.loads(before.read_text())==rows,'frozen selected snapshot drift BEFORE overwrite '+name
 else:
  with before.open('x')as f:json.dump(rows,f,sort_keys=True,indent=2)
 return rows

# Supported compiler metadata is administrative discovery, bound before any
# generated program/semantic consumer. Never infer an installation layout.
nim=Path(shutil.which('nim')or'')
assert nim.is_file(),'actual selected Nim required'
chromium=Path(os.environ.get('PLAYWRIGHT_CHROMIUM_EXECUTABLE')or shutil.which('chromium')or'')
assert chromium.is_file(),'actual Chromium executable required'
os.environ['PLAYWRIGHT_CHROMIUM_EXECUTABLE']=str(chromium)
def discover(name,fixture,flags=(),backend='js'):
 argv=[str(nim),'dump','--dump.format:json','--hint:Conf:on','--backend:'+backend,*flags,str(fixture)]
 rc,stdout=run(name,argv,split=True)
 assert rc==0,'supported compiler metadata discovery '+name
 metadata=json.loads(stdout)
 configs=[str(Path(x).resolve())for x in re.findall(r"used config file '([^']+)'",(OUT/(name+'-STDERR.log')).read_text())]
 assert configs,'actual used compiler configurations required'
 assert Path(metadata['nimExe']).is_file()and Path(metadata['libpath']).is_dir(),'actual compiler metadata paths required'
 return dict(metadata=metadata,configs=configs,wrapper=str(nim),wrapperSha256=sha(nim),resolvedWrapper=str(nim.resolve()),resolvedWrapperSha256=sha(nim.resolve()))

guard('source-custody')
if not (OUT/'source').exists():
 (OUT/'source/isonim').mkdir(parents=True)
 # Only the genuine core module scope imported by these fixtures is copied.
 # Renderer/site/Yoga corpora are not inputs to this private operation.
 shutil.copytree(ROOT/'src/isonim/core',OUT/'source/isonim/core')
candidate_graph=bodies(ROOT/'src')
expected_graphs[str((OUT/'source').resolve())]=identities(candidate_graph)
authenticate(OUT/'source',identities(candidate_graph))
FIX=OUT/'fixtures';FIX.mkdir(exist_ok=True)
for name in ['registered_handler.nim','registered_handler_native.nim']:
 if (FIX/name).exists():assert (FIX/name).read_bytes()==(ROOT/'tests/fixtures'/name).read_bytes(),'fixture drift on resume'
 else:shutil.copyfile(ROOT/'tests/fixtures'/name,FIX/name)
# Snapshot the real wrapper/engine/stdlib and source before compilation, and the
# real browser, runner and fixture before any consumers. No generated bundle is
# treated as an input from an earlier source revision.
initial=discover('initial-nim-discovery',FIX/'registered_handler.nim',['-d:isonimInternalRegisteredHandlers','--path:'+str(OUT/'source'),'--path:'+str(ROOT.parent/'nim-everywhere/src')])
engine=Path(initial['metadata']['nimExe']).resolve();stdlib=Path(initial['metadata']['libpath']).resolve()
known_configs=initial['configs']
inputs=[Path(shutil.which(x)).resolve() for x in ['nim','node']]
inputs += [Path(sys.executable),Path(sys.executable).resolve(),*(Path(x)for x in known_configs)]
inputs += [FIX/'registered_handler_native.nim',ROOT/'tests/fixtures/registered_handler.nim',ROOT/'tests/fixtures/registered_handler_native.nim']
inputs += [Path(os.environ['PLAYWRIGHT_CHROMIUM_EXECUTABLE']).resolve(),Path(__file__).resolve(),ROOT/'tests/test_registered_handler.mjs',FIX/'registered_handler.nim']
wrapper=Path(shutil.which('nim'));inputs.append(wrapper)
inputs.append(engine)
inputs.append(Path(__file__).with_name('registered_handler_core.py'))
guard('finite-module-input-walk')
inputs.extend(p for p in stdlib.rglob('*') if p.is_file())
inputs.extend(p for p in (ROOT.parent/'nim-everywhere/src').rglob('*') if p.is_file())
inputs.extend(p for p in (ROOT/'src/isonim/core').rglob('*') if p.is_file())
for package in ['playwright','playwright-core']:
 base=(ROOT/'tests/browser/node_modules'/package).resolve()
 inputs.extend(p for p in base.rglob('*') if p.is_file() and p.suffix in ['.js','.mjs','.json'])
guard('input-bindings-before')
bindings={str(p):sha(p) for p in inputs}
if (OUT/'INPUTS-BEFORE.json').exists():assert json.loads((OUT/'INPUTS-BEFORE.json').read_text())==bindings,'frozen inputs drift on resume'
else:(OUT/'INPUTS-BEFORE.json').write_text(json.dumps(bindings,sort_keys=True,indent=2))
source_before=snapshot('source-before',OUT/'source')
guard('owning-core-bindings')
owning_core={'isonim/core/'+key:value for key,value in snapshot('owning-core-before',ROOT/'src/isonim/core').items()}
assert source_before==owning_core,'exact current owning core bodies before consumers'

def native_build_metadata(output,cache):
 candidates=[]
 for file in cache.glob('*.json'):
  data=json.loads(file.read_text())
  if 'outputFile'in data and Path(data['outputFile']).resolve()==output.resolve():candidates.append(data)
 assert len(candidates)==1,'one actual generated native build metadata record required'
 return candidates[0]

def bind_native_commands(name,output,cache):
 guard(name+'-native-input-bindings')
 build=native_build_metadata(output,cache)
 previous=OUT/(name+'-NATIVE-INPUTS-BEFORE.json')
 if previous.exists():
  frozen=json.loads(previous.read_text())
  assert build['compile']==frozen['build']['compile']and build['linkcmd']==frozen['build']['linkcmd'],'native command drift on exact resume'
  assert all(Path(p).is_file()and sha(Path(p))==h for p,h in frozen['inputs'].items()),'native tool/input drift on resume'
  for key,value in frozen['environment'].items():
   assert os.environ.get(key)==value,'native compiler environment drift on resume '+key
  actual_output=Path(frozen['scriptOutput'])
  if actual_output.exists():assert any(x['name']==name+'-compile'and x['exit']==0 for x in LEDGER),'unreceipted native artifact needs inspection'
  return frozen
 assert not output.exists()and not list(cache.glob('*.o')),'generation-only must stop before C compiler/linker outputs'
 commands=[x[1]for x in build['compile']]+[build['linkcmd']]+build.get('extraCmds',[])
 scripts=list(cache.glob('*.sh'));assert len(scripts)==1,'one actual Nim-generated native compile script required'
 script=scripts[0]
 lines=[line for line in script.read_text().splitlines()if line and not line.startswith('#')]
 compile_commands=[x[1]for x in build['compile']]
 assert len(lines)==len(commands)and lines[:len(compile_commands)]==compile_commands,'raw generated compile commands must exactly equal authoritative same-generation JSON'
 assert lines[len(compile_commands)+1:]==build.get('extraCmds',[]),'unknown generated post-link commands'
 script_link=shlex.split(lines[len(compile_commands)]);json_link=shlex.split(build['linkcmd'])
 assert len(script_link)==len(json_link)and script_link.count('-o')==json_link.count('-o')==1,'actual linker command shape required'
 output_index=json_link.index('-o')+1
 assert script_link.index('-o')+1==output_index,'linker output position drift'
 script_name=script_link[output_index]
 assert Path(script_name).name==script_name and Path(script_name).name==Path(build['outputFile']).name,'generated script output basename must match configured native output'
 assert Path(json_link[output_index]).resolve()==output.resolve(),'JSON output must match configured native output'
 objects=[]
 for index,(actual,reference)in enumerate(zip(script_link,json_link)):
  if index==output_index:continue
  if reference in build['link']:
   resolved=(cache/actual).resolve()
   assert resolved==Path(reference).resolve(),'generated object operand must resolve to exact JSON object input'
   objects.append(str(resolved))
  else:assert actual==reference,'unknown nonpath linker tool/argument difference'
 assert objects==[str(Path(x).resolve())for x in build['link']],'actual linker object order must match authoritative JSON'
 actual_output=(cache/script_name).resolve()
 assert not actual_output.exists(),'actual generated-script binary must be fresh before C handoff'
 link_representation=dict(rawScriptCommand=lines[len(compile_commands)],rawJsonCommand=build['linkcmd'],cacheCwd=str(cache),scriptOutput=str(actual_output),jsonNormalOutput=build['outputFile'],orderedObjectInputs=objects,nonpathArgumentsExact=True,artifactsNormalized=False)

 shell=Path(shutil.which('sh')or'');assert shell.is_file(),'selected shell required for compiler-generated script'
 selected={str(script):sha(script),str(shell):sha(shell),str(shell.resolve()):sha(shell.resolve())}
 generated=set(cache.glob('*.c'))
 assert generated=={Path(row[0])for row in build['compile']},'all actual generated C files must be accounted for'
 for path in [*cache.glob('*.json'),*cache.glob('*.h')]:selected[str(path)]=sha(path)
 for command in commands:
  argv=shlex.split(command);assert argv,'actual native command required'
  tool=Path(shutil.which(argv[0])or argv[0]).resolve();assert tool.is_file(),'selected native tool must resolve '+argv[0]
  selected[str(tool)]=sha(tool)
  wrapper=Path(shutil.which(argv[0])or argv[0]);selected[str(wrapper)]=sha(wrapper)
 # Supported compiler program queries identify the selected frontend/assembler/
 # linker where the selected GCC/Clang driver reports external executables.
 queries=[]
 for token in sorted({shlex.split(c)[0]for c in commands}):
  tool=Path(shutil.which(token)or token)
  for program in ['cc1','as','ld','collect2']:
   rc,body=run(name+'-tool-query-'+Path(token).name+'-'+program,[str(tool),'-print-prog-name='+program],split=True)
   assert rc==0,'selected compiler program discovery required'
   value=body.strip();resolved=Path(value)if Path(value).is_absolute()else Path(shutil.which(value)or value)
   exists=resolved.is_file()
   queries.append(dict(program=program,reported=value,resolved=str(resolved.resolve())if exists else None,individuallyHashed=exists,resolutionBasis='compiler-reported absolute path'if Path(value).is_absolute()else'captured dev-shell PATH; wrapper-internal search is not intercepted'))
   if exists:selected[str(resolved.resolve())]=sha(resolved.resolve())
 for source,command in build['compile']:
  path=Path(source);assert path.is_file();selected[str(path)]=sha(path)
 actual_configs=[str(Path(x).resolve())for x in build['configFiles']]
 assert actual_configs and all(x in bindings and sha(Path(x))==bindings[x]for x in actual_configs),'native config not bound before C tools'
 env={k:os.environ.get(k)for k in ['PATH','CC','CXX','CFLAGS','CPPFLAGS','CXXFLAGS','LDFLAGS','CPATH','C_INCLUDE_PATH','CPLUS_INCLUDE_PATH','LIBRARY_PATH','COMPILER_PATH','GCC_EXEC_PREFIX','NIX_CFLAGS_COMPILE','NIX_LDFLAGS','NIX_CC','NIX_BINTOOLS']}
 record=dict(build=build,script=str(script),shell=str(shell),cacheCwd=str(cache),scriptOutput=str(actual_output),linkRepresentation=link_representation,inputs=selected,programQueries=queries,environment=env,limits='System headers, linker/runtime libraries and remaining compiler-internal/wrapper execution closure are not individually hashed or intercepted. Absolute compiler-reported subtools are hashed directly; unqualified reported tools are resolved from the captured dev-shell PATH. Campaign evidence states the remaining transitive provenance; this is not a complete toolchain closure census.')
 (OUT/(name+'-NATIVE-INPUTS-BEFORE.json')).write_text(json.dumps(record,indent=2))
 return record

def compile(name,flags,source=None,fixture=None,target='js',expect=0):
 path=OUT/(name+('.js' if target=='js' else '.exe'))
 cmd=['nim',target,'--hint:Conf:on',*flags,'--path:'+str(source or OUT/'source'),'--path:'+str(ROOT.parent/'nim-everywhere/src'),'--nimcache:'+str(OUT/'cache'/name),'--out:'+str(path),str(fixture or FIX/'registered_handler.nim')]
 if target=='c':
  generated,_=run(name+'-generate-c',[*cmd[:2],'--compileOnly:on','--genScript:on',*cmd[2:]],generated_scope=OUT/'cache'/name)
  assert generated==0,'actual native C generation '+name
  native_before=bind_native_commands(name,path,OUT/'cache'/name)
 if target=='c':
  path=Path(native_before['scriptOutput'])
  objects=[Path(x)for x in native_before['build']['link']]
  rc,log=run(name+'-compile',[native_before['shell'],'-e',native_before['script']],cwd=OUT/'cache'/name,produced=[path,*objects])
  assert all(sha(Path(p))==h for p,h in native_before['inputs'].items()),'native inputs/tool drift'
  assert path.is_file()and all(x.is_file()for x in objects),'actual native object/binary outputs required'
  emitted=dict(binary=str(path),binarySha256=sha(path),objects={str(x):sha(x)for x in objects})
  receipt=OUT/(name+'-NATIVE-OUTPUTS.json')
  if receipt.exists():assert json.loads(receipt.read_text())==emitted,'frozen native output receipt drift'
  else:
   with receipt.open('x')as f:json.dump(emitted,f,indent=2)
 else:rc,log=run(name+'-compile',cmd)
 assert rc==expect,'compiler boundary '+name+' expected '+str(expect)+' got '+str(rc)
 if target=='js' and expect==0:
  raw=path.read_bytes();start=raw.find(b'var isonimEventListeners = (function() {')
  assert start>=0,'actual original emitted listener closure '+name
  end=raw.index(b'})();',start)+len(b'})();');scope=raw[start:end]
  assert scope.count(b'const isonimListeners = new WeakMap();')==1,'one original weak listener storage '
  (OUT/(name+'-EMITTED-SCOPE.json')).write_text(json.dumps(dict(artifact=str(path),artifactSha256=sha(path),start=start,end=end,scopeSha256=hashlib.sha256(scope).hexdigest(),scope=scope.decode()),indent=2))
  typed_start=raw.index(b'function registeredTyped(')
  typed_scope=raw[typed_start:typed_start+4000].decode()
  captured=re.search(r'\.handler = \((callback_[A-Za-z0-9_]+)\)',typed_scope)
  assert captured,'actual retained converted typed callback identity '
  assert re.search(r'listen__[^\n]+, '+re.escape(captured[1])+r', false\)',typed_scope),'same converted typed callback passed to original listen '
  (OUT/(name+'-TYPED-EMISSION.json')).write_text(json.dumps(dict(artifact=str(path),artifactSha256=sha(path),start=typed_start,bytes=4000,capturedVariable=captured[1],scope=typed_scope),indent=2))

 return path,log

def browser(name,bundle,case='',inverse=None,native=False):
 before=sha(bundle);(OUT/(name+'-ARTIFACT-BEFORE.json')).write_text(json.dumps(dict(path=str(bundle),sha256=before)))
 rc,log=run(name+'-browser',['node','tests/test_registered_handler.mjs'],dict(REGISTERED_BUNDLE=str(bundle),REGISTERED_CASE=case,REGISTERED_NATIVE_ONLY='1' if native else '0',REGISTERED_RECEIPT=str(OUT/(name+'-RECEIPT.json'))))
 assert sha(bundle)==before,'bundle changed during browser consumption'
 if inverse:
  assert rc==1 and 'REGISTERED_ASSERT: '+inverse in log and 'TimeoutError' not in log and 'TypeError' not in log,'intended unchanged semantic oracle: '+name+'\n'+log
 else:assert rc==0,'real Chromium case '+name+'\n'+log

BASE=OUT/'source/isonim/core/nondet.nim'
text=BASE.read_text()
helper='const entry = entries && entries.find(e => e.type === type && e.handler === handler && e.capture === capture);'
mutants=[
 ('fresh-map',"const entries = isonimListeners.get(node);","const entries = new WeakMap().get(node);",'active','active-registration'),
 ('type',helper,helper.replace('e.type === type && ',''),'tuple','tuple-type'),
 ('handler',helper,helper.replace('e.handler === handler && ',''),'tuple','tuple-handler'),
 ('capture',helper,helper.replace(' && e.capture === capture',''),'tuple','tuple-capture'),
 ('new-disposer','if (prior) return prior.dispose;','if (prior) return function() { prior.dispose(); };','owners','duplicate-disposer'),
 ('duplicate','if (prior) return prior.dispose;','if (false && prior) return prior.dispose;','owners','duplicate-disposer'),
 ('later-owner','if (prior) return prior.dispose;','if (prior) { registered(prior.dispose); return prior.dispose; }','owners','first-owner-retained'),
 ('removal','if (at >= 0) entries.splice(at, 1);','if (false && at >= 0) entries.splice(at, 1);','removal','explicit-removal'),
 ('connected',"if (!entry) throw new Error('isonim registered handler is not active');","if (!entry || !node.isConnected) throw new Error('isonim registered handler is not active');",'detached','detached-live-target'),
 ('return','return entry.handler.call(node, event);','entry.handler.call(node, event);','values','return-identity'),
 ('throw','return entry.handler.call(node, event);','try { return entry.handler.call(node, event); } catch (error) { throw new Error(String(error)); }','values','throw-identity'),
 ('wrapped','return entry.handler.call(node, event);','return entry.wrapped.call(node, event);','accounting','no-extra-bookkeeping'),
]
for name,a,b,case,oracle in mutants:
 assert text.count(a)==1,(name,'precise source site')
 guard('prepare-'+name)
 src=OUT/('mutant-'+name)
 if not src.exists():shutil.copytree(OUT/'source',src)
 replacement=text.replace(a,b,1)
 expected_graphs[str(src.resolve())]=source_before | {OWNER:hashlib.sha256(replacement.encode()).hexdigest()}
 (src/'isonim/core/nondet.nim').write_text(replacement)
(OUT/'MUTANT-SITES.json').write_text(json.dumps([dict(name=n,before=a,after=b,case=c,oracle=o)for n,a,b,c,o in mutants],indent=2))

# Genuine parent source comes from the owning Git object, never dirty worktree.
parent='239e39febd3a5a2b9810cabb5915ce6c6b8ee291'
guard('parent-source')
parent_graph=historical_graph(ROOT,parent)
original=parent_graph[OWNER]
(OUT/'GENUINE-PARENT-nondet.nim').write_bytes(original)
conserve_common(parent_graph,candidate_graph)
additions=set(candidate_graph)-set(parent_graph)
(OUT/'CORE-PHASES.json').write_text(json.dumps(dict(parent=parent,parentGraph=identities(parent_graph),candidateGraph=identities(candidate_graph),additions=sorted(additions)),indent=2))
controls=administrative_controls(parent_graph,candidate_graph,OUT)
(OUT/'ADMINISTRATIVE-CONTROLS.json').write_text(json.dumps(controls,indent=2))
# A real compiling new-leaf import must be observed and rejected. This is an
# administrative provenance control, never a production semantic inverse.
guard('provenance-control-source')
probe_source=OUT/'provenance-source'
if not probe_source.exists():shutil.copytree(OUT/'source',probe_source)
probe_leaf='isonim/core/private/registered_provenance_probe.nim'
probe_body=b'const registeredProvenanceWitness* = 7\n'
expected_graphs[str(probe_source.resolve())]=source_before | {probe_leaf:hashlib.sha256(probe_body).hexdigest()}
(probe_source/probe_leaf).parent.mkdir(parents=True,exist_ok=True)
(probe_source/probe_leaf).write_bytes(probe_body)
probe_fixture=FIX/'registered_provenance_import.nim'
probe_fixture.write_text('import isonim/core/nondet\nimport isonim/core/private/registered_provenance_probe\ndoAssert registeredProvenanceWitness == 7\n')
probe_flags=['--path:'+str(probe_source),'--path:'+str(ROOT.parent/'nim-everywhere/src'),'--nimcache:'+str(OUT/'cache/provenance-import'),'--out:'+str(OUT/'provenance-import.js')]
probe_rc,probe_log=run('provenance-import-compile',['nim','js',*probe_flags,str(probe_fixture)])
assert probe_rc==0,'new imported-leaf provenance control genuinely compiles'
try:reject_added_imports(probe_log,probe_source,{probe_leaf})
except AssertionError as error:assert str(error)=='added core leaf consumed by compiler'
else:raise AssertionError('new imported leaf silently exempted')
# An unchanged candidate companion actually compiles, positively names nondet,
# and excludes all later-only leaves in the same supported compiler output.
companion,_=compile('provenance-genuine-companion',[])
(OUT/'PROVENANCE-CONTROLS.json').write_text(json.dumps(dict(actualNewLeafCompiled=True,intendedRejection='added core leaf consumed by compiler',genuineCompanionCompiled=True,knownOwnerImportRequired=True,administrativeOnly=True),indent=2))


for release,recordable,direct in itertools.product([False,True],repeat=3):
 flags=(['-d:release']if release else [])+(['-d:isonimRecordable']if recordable else [])+(['-d:isonimDirectNondet']if direct else [])
 label=('release'if release else'debug')+('-recordable'if recordable else'-ordinary')+('-direct'if direct else'-normal')
 enabled=flags+['-d:isonimInternalRegisteredHandlers']
 genuine,_=compile(label,enabled)
 browser(label,genuine)
 browser(label+'-enabled-unused',genuine,native=True)
 for name,a,b,case,oracle in mutants:
  bundle,_=compile(label+'-'+name,enabled,OUT/('mutant-'+name))
  browser(label+'-'+name,bundle,case,inverse=oracle)
  browser(label+'-'+name+'-companion',genuine,case)
 ordinary,_=compile(label+'-ordinary',flags)
 # Nim includes absolute source paths in debug filenames and symbol names.
 # Compile exact genuine parent at the SAME isolated source path, then restore
 # the candidate before any further consumer. No output normalization occurs.
 with phase(OUT/'source',parent_graph,expected_graphs):
  old,_=compile(label+'-parent',flags)
 authenticate(OUT/'source',source_before)
 assert ordinary.read_bytes()==old.read_bytes(),'raw byte identity '+label
 for marker in [b'callRegistered',b'rawCallInternalRegisteredHandler',b'callInternalRegisteredHandler',b'isonim registered handler is not active']:
  assert marker not in ordinary.read_bytes(),'define-absent marker omission '+label
 browser(label+'-absent-unused',ordinary,native=True)
 absent_fixture=OUT/(label.replace('-','_')+'_absent_api.nim')
 absent_fixture.write_text('import std/jsffi\nimport isonim/core/nondet\ndiscard callInternalRegisteredHandler(JsObject(nil), "click", JsObject(nil), false, JsObject(nil))\n')
 rc,log=run(label+'-absent-api-compile',['nim','js',*flags,'--path:'+str(OUT/'source'),'--path:'+str(ROOT.parent/'nim-everywhere/src'),'--nimcache:'+str(OUT/'cache'/(label+'-absent-api')),'--out:'+str(OUT/(label+'-absent-api.js')),str(absent_fixture)])
 assert rc==1 and "undeclared identifier: 'callInternalRegisteredHandler'"in log,'define-absent API refusal '+label


# Compiler effect ceilings inspect the actual private raw binding inside its
# owning module. These generated, retained test-only declarations never enter
# production source. No public raw export or effect-erasing cast is introduced.
for release,recordable,direct,strict in itertools.product([False,True],repeat=4):
 flags=(['-d:release']if release else [])+(['-d:isonimRecordable']if recordable else [])+(['-d:isonimDirectNondet']if direct else [])+(['-d:isonimStrictNondet']if strict else [])+['-d:isonimInternalRegisteredHandlers']
 mode='effect-'+''.join(str(int(x))for x in [release,recordable,direct,strict])
 for binding,tags,required in [('wrapper','RawNondet, DomEventEffect',None),('wrapper','RawNondet','DomEventEffect'),('wrapper','DomEventEffect','RawNondet'),('raw','RawNondet',None),('raw','','RawNondet')]:
  name=mode+'-'+binding+'-'+(required or 'permitted')
  source=OUT/name
  guard(name+'-source')
  if not source.exists():shutil.copytree(OUT/'source',source)
  callee='callInternalRegisteredHandler'if binding=='wrapper'else'rawCallInternalRegisteredHandler'
  declaration='\nwhen defined(js):\n  proc registeredEffectCeiling(n,h,e: JsObject): JsObject {.tags: ['+tags+'].} =\n    '+callee+'(n, "click", h, false, e)\n'
  expected_graphs[str(source.resolve())]=source_before | {OWNER:hashlib.sha256((text+declaration).encode()).hexdigest()}
  target=source/'isonim/core/nondet.nim';target.write_text(text+declaration)
  fixture=OUT/(name.replace('-','_')+'.nim');fixture.write_text('import isonim/core/nondet\n')
  rc,log=run(name+'-compile',['nim','js',*flags,'--path:'+str(source),'--path:'+str(ROOT.parent/'nim-everywhere/src'),'--nimcache:'+str(OUT/'cache'/name),'--out:'+str(OUT/(name+'.js')),str(fixture)])
  if required:
   assert rc==1 and required in log and ('unlisted effect' in log or 'can have' in log),'exact missing effect refusal '+name+'\n'+log
   # Remove the actual declaration which provides that effect. Raw absence must
   # also flow through the wrapper's explicit Raw declaration, so both named
   # annotations are removed when testing wrapper Raw propagation.
   lost=text
   if required=='RawNondet':
    lost=lost.replace('tags: [RawNondet].}\n  proc callInternalRegisteredHandler','tags: [].}\n  proc callInternalRegisteredHandler',1)
    if binding=='wrapper':lost=lost.replace('{.tags: [RawNondet, DomEventEffect].} =','{.tags: [DomEventEffect].} =',1)
   else:lost=lost.replace('{.tags: [RawNondet, DomEventEffect].} =','{.tags: [RawNondet].} =',1)
   assert lost!=text,'actual annotation-loss site '
   expected_graphs[str(source.resolve())]=source_before | {OWNER:hashlib.sha256((lost+declaration).encode()).hexdigest()}
   target.write_text(lost+declaration)
   loss,losslog=run(name+'-annotation-loss-compile',['nim','js',*flags,'--path:'+str(source),'--path:'+str(ROOT.parent/'nim-everywhere/src'),'--nimcache:'+str(OUT/'cache'/(name+'-loss')),'--out:'+str(OUT/(name+'-loss.js')),str(fixture)])
   assert loss==0,'annotation-loss inverse must really compile '+name+'\n'+losslog
   # The unchanged refusal oracle explicitly rejects this compiled inverse;
   # compiler/setup failures cannot masquerade as an annotation-loss witness.
   oracle=lambda code,body: code==1 and required in body and ('unlisted effect' in body or 'can have' in body)
   assert oracle(rc,log) and not oracle(loss,losslog),'unchanged effect-refusal oracle must discriminate '+name
   (OUT/(name+'-ORACLE.json')).write_text(json.dumps(dict(required=required,genuineRejected=True,annotationLossCompiled=True,unchangedOracleRejectsLoss=True)))
  else:assert rc==0,'declared effect ceiling must permit '+name+'\n'+log

for release,recordable,internal in itertools.product([False,True],repeat=3):
 flags=(['-d:release']if release else [])+(['-d:isonimRecordable']if recordable else [])+(['-d:isonimInternalRegisteredHandlers']if internal else [])
 name='native-'+''.join(str(int(x))for x in [release,recordable,internal])
 binary,_=compile(name,flags,fixture=FIX/'registered_handler_native.nim',target='c')
 rc,log=run(name+'-execute',[str(binary)])
 assert rc==0 and 'registered-handler-native-common-omission PASS'in log
 # C compilation genuinely linked this common-module binary; the private
 # JS property and diagnostic may not be emitted in native generated files.
 for file in (OUT/'cache'/name).rglob('*.c'):
  raw=file.read_bytes()
  assert b'isonim registered handler is not active'not in raw and b'callRegistered'not in raw

assert snapshot('source-after',OUT/'source')==source_before
assert {'isonim/core/'+key:value for key,value in snapshot('owning-core-after',ROOT/'src/isonim/core').items()}==owning_core,'owning core drift after consumers'
assert {str(p):sha(p)for p in inputs}==bindings
(OUT/'INPUTS-AFTER.json').write_text(json.dumps(bindings,sort_keys=True,indent=2))
print('Registered handler runtime and emission matrix PASS',flush=True)
