#!/usr/bin/env python3
"""Qualify actual private document-progress attachment in real Chromium.

No substitute parser, document/resource algorithm, Recorder or codec is used. The
finite production source inverses share the unchanged browser assertions with
fresh genuine companions. Output, inputs and command refusals are retained.
"""
from pathlib import Path
import hashlib,itertools,json,os,re,shlex,shutil,subprocess,sys,tempfile,time
ROOT=Path(__file__).resolve().parent.parent
OUT_PARENT=Path(os.environ.get('DOCUMENT_PROGRESS_EVIDENCE',str(ROOT/'build/record-document-progress-evidence')))
OUT_PARENT.mkdir(parents=True,exist_ok=True)
OUT=Path(os.environ['DOCUMENT_PROGRESS_RESUME']) if os.environ.get('DOCUMENT_PROGRESS_RESUME') else Path(tempfile.mkdtemp(prefix='run-',dir=OUT_PARENT))
assert OUT.is_dir(),'existing own qualification directory required'
print('Document progress evidence: '+str(OUT),flush=True)
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
 if len(argv)>1 and Path(argv[0]).name=='nim'and argv[1]in['js','c']and '--hint:Conf:on'not in argv:argv.insert(2,'--hint:Conf:on')
 executable=Path(shutil.which(argv[0])or argv[0])
 selected_executable=[executable,executable.resolve()]if executable.is_file()else[]
 selected=[]
 core_roots=[Path(x.split(':',1)[1]) for x in argv if x.startswith('--path:') and (Path(x.split(':',1)[1])/'isonim/core/nondet.nim').is_file()]
 if core_roots:guard(name+'-actual-core-before-binding')
 for scope in core_roots:
  actual={str(p.relative_to(scope)):sha(p)for p in (scope/'isonim/core').rglob('*')if p.is_file()}
  if 'source_before'in globals():
   assert set(actual)-{'isonim/core/private/record_document_progress.nim'}=={k for k in source_before if k.startswith('isonim/core/')}-{'isonim/core/private/record_document_progress.nim'},'actual original core inventory drift '
   assert all(value==source_before[key]for key,value in actual.items()if key!='isonim/core/private/record_document_progress.nim'),'nonowner core source drift before consumer'
  selected += [scope/key for key in actual]
 selected += [Path(x) for x in argv if Path(x).suffix in ['.nim','.mjs','.js','.py','.sh','.json'] and Path(x).is_file()]
 selected += [Path(x)for x in known_configs] if 'known_configs'in globals() else []
 if 'nim'in globals():selected += [nim,nim.resolve()]
 if extra and extra.get('DOCUMENT_PROGRESS_BUNDLE'):selected.append(Path(extra['DOCUMENT_PROGRESS_BUNDLE']))
 if extra and extra.get('DOCUMENT_PROGRESS_INPUTS'):selected.append(Path(extra['DOCUMENT_PROGRESS_INPUTS']))
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
  row=cached[0];assert row['argv']==argv and row['env']==(extra or {}) and row['beforeInputs']==beforeInputs and row['cwd']==str(cwd)and row['declaredOutputs']==list(map(str,produced))and row['generatedScope']==(str(generated_scope)if generated_scope else None)and row['compilerMetadata']==compile_metadata,'frozen command/input drift on resume '+name
  assert sha(OUT/(name+'.log'))==row['logSha'],'retained command log drift '
  proofs=[Path(extra['DOCUMENT_PROGRESS_RECEIPT']+suffix)for suffix in['','-metafile.json','-combined.js']]if extra and extra.get('DOCUMENT_PROGRESS_RECEIPT')else[]
  assert row['afterInputsEqualBefore']and row['proofOutputs']==[str(p)for p in proofs if p.is_file()],'retained partial proof inventory drift '+name
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
 before=dict(argv=argv,env=extra or {},cwd=str(cwd),declaredOutputs=list(map(str,produced)),generatedScope=str(generated_scope)if generated_scope else None,time=time.time(),beforeInputs=beforeInputs,compilerMetadata=compile_metadata)
 with (OUT/(name+'-BEFORE.json')).open('x')as f:json.dump(before,f,indent=2)
 with (OUT/(name+'.log')).open('xb') as f:
  if split:
   with (OUT/(name+'-STDERR.log')).open('xb')as err:p=subprocess.run(argv,cwd=cwd,env=os.environ|(extra or {}),stdout=f,stderr=err)
  else:p=subprocess.run(argv,cwd=cwd,env=os.environ|(extra or {}),stdout=f,stderr=subprocess.STDOUT)
 body=(OUT/(name+'.log')).read_text(errors='replace')
 assert all(Path(p).is_file()and sha(Path(p))==h for p,h in beforeInputs.items()),'actual selected consumer input drift after '+name
 validate_compile_configs(name,body,compile_metadata)
 generated=generated_files(generated_scope)if generated_scope and p.returncode==0 else []
 if generated_scope and p.returncode==0:assert generated,'actual generated outputs required before receipt admission'
 outputs=[Path(x.split(':',1)[1])for x in argv if x.startswith('--out:')]+list(produced)+generated
 proofs=[Path(extra['DOCUMENT_PROGRESS_RECEIPT']+suffix)for suffix in['','-metafile.json','-combined.js']]if extra and extra.get('DOCUMENT_PROGRESS_RECEIPT')else[]
 outputs += [p for p in proofs if p.is_file()]
 row=dict(name=name,exit=p.returncode,afterInputsEqualBefore=True,proofOutputs=[str(p)for p in proofs if p.is_file()],generatedOutputs=list(map(str,generated)),logSha=sha(OUT/(name+'.log')),stderrSha256=sha(OUT/(name+'-STDERR.log'))if split else None,outputs={str(p):sha(p)for p in outputs if p.is_file()},**before);LEDGER.append(row)
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
 shutil.copytree(ROOT/'src/isonim/testing',OUT/'source/isonim/testing')
FIX=OUT/'fixtures';FIX.mkdir(exist_ok=True)
for name in ['record_document_progress.nim','record_document_progress_absent.nim','record_document_progress_lazy.nim']:
 if (FIX/name).exists():assert (FIX/name).read_bytes()==(ROOT/'tests/fixtures'/name).read_bytes(),'fixture drift on resume'
 else:shutil.copyfile(ROOT/'tests/fixtures'/name,FIX/name)
# Snapshot the real wrapper/engine/stdlib and source before compilation, and the
# real browser, runner and fixture before any consumers. No generated bundle is
# treated as an input from an earlier source revision.
initial=discover('initial-nim-discovery',FIX/'record_document_progress.nim',['-d:isonimInternalRecordDocumentProgress','--path:'+str(OUT/'source'),'--path:'+str(ROOT.parent/'nim-everywhere/src')])
engine=Path(initial['metadata']['nimExe']).resolve();stdlib=Path(initial['metadata']['libpath']).resolve()
known_configs=initial['configs']
inputs=[Path(shutil.which(x)).resolve() for x in ['nim','node']]
inputs += [ROOT/'Justfile',ROOT/'repro.nim',ROOT/'repro.lock',ROOT/'flake.nix',ROOT/'flake.lock',ROOT/'tools/run_nim_js_test.py',ROOT/'tests/browser/package.json',ROOT/'tests/browser/package-lock.json',ROOT/'tests/test_clock.nim',ROOT/'tests/fixtures/record_document_progress_lazy.nim']
inputs += [Path(sys.executable),Path(sys.executable).resolve(),*(Path(x)for x in known_configs)]
inputs += [FIX/'record_document_progress_absent.nim',ROOT/'tests/fixtures/record_document_progress.nim',ROOT/'tests/fixtures/record_document_progress_absent.nim']
inputs += [Path(os.environ['PLAYWRIGHT_CHROMIUM_EXECUTABLE']).resolve(),Path(__file__).resolve(),ROOT/'tests/test_record_document_progress_owner.mjs',FIX/'record_document_progress.nim']
wrapper=Path(shutil.which('nim'));inputs.append(wrapper)
inputs.append(engine)
guard('finite-module-input-walk')
inputs.extend(p for p in stdlib.rglob('*') if p.is_file())
inputs.extend(p for p in (ROOT.parent/'nim-everywhere/src').rglob('*') if p.is_file())
inputs.extend(p for p in (ROOT/'src/isonim/core').rglob('*') if p.is_file())
inputs.extend(p for p in (ROOT/'src/isonim/testing').rglob('*') if p.is_file())
for package in ['playwright','playwright-core']:
 base=(ROOT/'tests/browser/node_modules'/package).resolve()
 assert (base/'package.json').is_file(),'actual installed '+package+' required before consumers'
 inputs.extend(p for p in base.rglob('*') if p.is_file() and p.suffix in ['.js','.mjs','.json'])
guard('owner-artifact-input-walk')
artifact=Path(os.environ.get('CT_ARTIFACT',''))
assert (artifact/'packages/boundary-shim/package.json').is_file(),'supported CT_ARTIFACT required'
inputs += [p for p in artifact.rglob('*')if p.is_file()]
guard('input-bindings-before')
bindings={str(p):sha(p) for p in inputs}
if (OUT/'INPUTS-BEFORE.json').exists():assert json.loads((OUT/'INPUTS-BEFORE.json').read_text())==bindings,'frozen inputs drift on resume'
else:(OUT/'INPUTS-BEFORE.json').write_text(json.dumps(bindings,sort_keys=True,indent=2))
source_before=snapshot('source-before',OUT/'source')
guard('owning-core-bindings')
owning_core={'isonim/core/'+key:value for key,value in snapshot('owning-core-before',ROOT/'src/isonim/core').items()}
assert {k:v for k,v in source_before.items()if k.startswith('isonim/core/')}==owning_core,'exact current owning core bodies before consumers'

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

def compile(name,flags,source=None,fixture=None,target='js'):
 path=OUT/(name+('.js'if target=='js'else'.exe'))
 cmd=['nim',target,'--hint:Conf:on',*flags,'--path:'+str(source or OUT/'source'),'--path:'+str(ROOT.parent/'nim-everywhere/src'),'--nimcache:'+str(OUT/'cache'/name),'--out:'+str(path),str(fixture or FIX/'record_document_progress.nim')]
 if target=='c':
  generated,_=run(name+'-generate-c',[*cmd[:2],'--compileOnly:on','--genScript:on',*cmd[2:]],generated_scope=OUT/'cache'/name)
  assert generated==0,'actual same-generation native C generation '+name
  before=bind_native_commands(name,path,OUT/'cache'/name);path=Path(before['scriptOutput']);objects=[Path(x)for x in before['build']['link']]
  rc,log=run(name+'-compile',[before['shell'],'-e',before['script']],cwd=OUT/'cache'/name,produced=[path,*objects])
  assert all(sha(Path(p))==h for p,h in before['inputs'].items()),'native tool/input drift'
  assert path.is_file()and all(p.is_file()for p in objects),'fresh actual native binary/objects'
  body=dict(binary=str(path),binarySha256=sha(path),objects={str(p):sha(p)for p in objects});receipt=OUT/(name+'-NATIVE-OUTPUTS.json')
  if receipt.exists():assert json.loads(receipt.read_text())==body
  else:receipt.write_text(json.dumps(body,indent=2))
 else:rc,log=run(name+'-compile',cmd)
 assert rc==0,'actual compile '+name+'\n'+log
 return path

def browser(name,bundle,case='',inverse=None):
 extra=dict(DOCUMENT_PROGRESS_BUNDLE=str(bundle),DOCUMENT_PROGRESS_INPUTS=str(OUT/'INPUTS-BEFORE.json'),DOCUMENT_PROGRESS_CASE=case,DOCUMENT_PROGRESS_RECEIPT=str(OUT/(name+'-RECEIPT.json')))
 rc,log=run(name+'-browser',['node','tests/test_record_document_progress_owner.mjs'],extra)
 receipt=next(row for row in LEDGER if row['name']==name+'-browser')
 assert receipt['proofOutputs']==[extra['DOCUMENT_PROGRESS_RECEIPT']+suffix for suffix in['','-metafile.json','-combined.js']],'complete semantic case/metafile/combined proof outputs required, including inverse rc1 '+name
 if inverse:assert rc==1 and [line for line in log.splitlines()if line.startswith('AssertionError [ERR_ASSERTION]:')]==['AssertionError [ERR_ASSERTION]: DP_ASSERT: '+inverse] and 'TimeoutError'not in log,'precise unchanged semantic assertion '+name+'\n'+log
 else:assert rc==0,'actual Chromium document progression '+name+'\n'+log

BASE=OUT/'source/isonim/core/private/record_document_progress.nim';text=BASE.read_text()
parent='de8855c812ac665871490f0591b83e2cd2c0ad0b'
guard('genuine-parent-source')
rc,body=run('genuine-parent-core-inventory',['git','ls-tree','-r','--name-only',parent,'--','src/isonim/core']);assert rc==0
parent_inventory={line.removeprefix('src/')for line in body.splitlines()}
actual_inventory={key for key in source_before if key.startswith('isonim/core/')}
assert actual_inventory==parent_inventory|{'isonim/core/private/record_document_progress.nim'},'genuine-parent actual core inventory permits only the new owning module'
rc,body=run('genuine-parent-core-diff',['git','diff','--name-only',parent,'--','src/isonim/core']);assert rc==0 and body.splitlines()in[[],['src/isonim/core/private/record_document_progress.nim']],'nonowning tracked core differs from genuine parent'
# Untracked new module is checked explicitly; every tracked original core blob
# must equal its actual parent. Parent does not have the new private module.
assert subprocess.run(['git','cat-file','-e',parent+':src/isonim/core/private/record_document_progress.nim'],cwd=ROOT,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==128
assert subprocess.check_output(['git','show',parent+':tests/test_clock.nim'],cwd=ROOT)==(ROOT/'tests/test_clock.nim').read_bytes(),'genuine existing ordinary entry body'
assert not subprocess.check_output(['git','diff','--name-only',parent,'--','src/isonim/testing'],cwd=ROOT).strip(),'unchanged consumed testing import graph'
# Direct browser seams intentionally bypass scripted backends; the existing
# clock/scheduler entry uses supported ClockBase methods in every flag row.
ordinary_fixture=OUT/'ordinary_clock.nim';ordinary_fixture.write_bytes((ROOT/'tests/test_clock.nim').read_bytes())
delegation="r.guard(function(){require('\\x40codetracer/boundary-shim/dist/browser/document-progress.js').recordDocumentProgress(w,r,o.addEventListener);});"
mutants=[
 ('omit',delegation,'void 0;','parser','parser-loading-script-before-clock'),
 ('no-progress',delegation,"r.guard(function(){r.attachProgress({macrotask:function(){},beforeRecord:function(){},checkpointsAllowed:function(){return true;}});});",'parsing-end','parsing-cadence-suppressed'),
 ('defer',delegation,"w.document.addEventListener('DOMContentLoaded',function(){"+delegation+"},{once:true});",'parser','parser-loading-script-before-clock'),
 ('skip-inactive','if(!r.recording)return;','void 0;','initial-halted','inactive-no-install'),
]
for name,a,b,case,oracle in mutants:
 assert text.count(a)==1,'exact compiled production inverse '+name
 guard('prepare-'+name);src=OUT/('mutant-'+name)
 if not src.exists():shutil.copytree(OUT/'source',src)
 (src/'isonim/core/private/record_document_progress.nim').write_text(text.replace(a,b,1))
(OUT/'MUTANT-SITES.json').write_text(json.dumps([dict(name=n,before=a,after=b,case=c,oracle=o)for n,a,b,c,o in mutants],indent=2))
plan=dict(parent=parent,jsRows=[dict(release=r,recordable=b,direct=d)for r,b,d in itertools.product([False,True],repeat=3)],effectRows=[dict(release=r,recordable=b,direct=d,strict=s)for r,b,d,s in itertools.product([False,True],repeat=4)],nativeRows=[dict(release=r,recordable=b,internal=i)for r,b,i in itertools.product([False,True],repeat=3)],inverses=[dict(name=n,case=c,oracle=o)for n,a,b,c,o in mutants],browserCases=['parser','parsing-end','explicit','initial-ended','initial-halted','terminal-end','terminal-halt','reentrant-halt','reentrant-fault','attach-fault','invalid','upload','selection-real','selection-test','selection-custom','selection-fake'])
if (OUT/'PLAN.json').exists():assert json.loads((OUT/'PLAN.json').read_text())==plan,'frozen finite command plan drift'
else:(OUT/'PLAN.json').write_text(json.dumps(plan,indent=2))
shared=['-d:isonimInternalRecordClocks','-d:isonimInternalRecordUpload']
for release,recordable,direct in itertools.product([False,True],repeat=3):
 flags=(['-d:release']if release else [])+(['-d:isonimRecordable']if recordable else [])+(['-d:isonimDirectNondet']if direct else [])
 label=('release'if release else'debug')+('-recordable'if recordable else'-ordinary')+('-direct'if direct else'-normal')
 enabled=flags+shared+['-d:isonimInternalRecordDocumentProgress']
 genuine=compile(label,enabled);browser(label,genuine)
 for name,a,b,case,oracle in mutants:
  inverse=compile(label+'-'+name,enabled,OUT/('mutant-'+name));browser(label+'-'+name,inverse,case,oracle);browser(label+'-'+name+'-companion',genuine,case)
 absent=compile(label+'-absent',flags,fixture=FIX/'record_document_progress_absent.nim');rc,log=run(label+'-absent-execute',['node',str(absent)]);assert rc==0 and 'common-omission PASS'in log
 assert b'boundary-shim'not in absent.read_bytes()and b'attachInternalRecordDocumentProgress'not in absent.read_bytes()
 lazy=compile(label+'-lazy',flags+['-d:isonimInternalRecordDocumentProgress'],fixture=FIX/'record_document_progress_lazy.nim');assert b'boundary-shim/dist/browser/document-progress.js'in lazy.read_bytes()and b'function dpDeliberateUncalled('in lazy.read_bytes()
 rc,log=run(label+'-lazy-execute',['node','-e',"const a=require('node:assert/strict'),r=require('node:module').createRequire(process.argv[1]);a.throws(()=>r.resolve('@codetracer/boundary-shim/dist/browser/recorder.js'),{code:'MODULE_NOT_FOUND'},'owner-free laziness prerequisite');r(process.argv[1]);",str(lazy)],dict(NODE_PATH=''));assert rc==0 and 'lazy PASS'in log,'import may not evaluate owner, Window or installation'
 current=compile(label+'-ordinary-current',flags,fixture=ordinary_fixture)
 # Existing entry/import graph is genuinely present in the actual parent. Its
 # candidate-only module is absent during this SAME-PATH parent compilation.
 BASE.unlink()
 try:old=compile(label+'-ordinary-parent',flags,fixture=ordinary_fixture)
 finally:BASE.write_text(text)
 assert current.read_bytes()==old.read_bytes(),'literal same-path genuine parent emitted bytes '+label
 rc,log=run(label+'-ordinary-execute',['python3','tools/run_nim_js_test.py',str(current)]);assert rc==0

for release,recordable,direct,strict in itertools.product([False,True],repeat=4):
 flags=(['-d:release']if release else [])+(['-d:isonimRecordable']if recordable else [])+(['-d:isonimDirectNondet']if direct else [])+(['-d:isonimStrictNondet']if strict else [])+['-d:isonimInternalRecordDocumentProgress']
 label='effect-'+''.join(str(int(x))for x in[release,recordable,direct,strict])
 for kind in ['raw','wrapper']:
  name=label+'-'+kind;guard(name+'-source');source=OUT/name
  if not source.exists():shutil.copytree(OUT/'source',source)
  callee='attachRaw'if kind=='raw'else'attachInternalRecordDocumentProgress'
  declaration='\nwhen defined(js):\n  proc documentProgressCeiling(w,r,o:JsObject) {.tags: [].} = '+callee+'(w,r,o)\n'
  target=source/'isonim/core/private/record_document_progress.nim';target.write_text(text+declaration)
  fixture=OUT/(name.replace('-','_')+'.nim');fixture.write_text('import isonim/core/private/record_document_progress\n')
  argv=['nim','js',*flags,'--path:'+str(source),'--path:'+str(ROOT.parent/'nim-everywhere/src'),'--nimcache:'+str(OUT/'cache'/name),'--out:'+str(OUT/(name+'.js')),str(fixture)]
  target.write_text(text+declaration.replace('tags: []','tags: [RawNondet]'))
  allowed,allowedlog=run(name+'-permitted',argv);assert allowed==0,'declared RawNondet ceiling permits actual binding '+name+'\n'+allowedlog
  target.write_text(text+declaration)
  rc,log=run(name+'-reject',argv);line=len((text+declaration).splitlines());column=declaration.splitlines()[-1].index(callee)+len(callee)+1
  expected=str(target)+'('+str(line)+', '+str(column)+') Error: '+callee+'(w, r, o) can have an unlisted effect: RawNondet'
  oracle=lambda rc,log:rc==1 and [x for x in log.splitlines()if ' Error:'in x]==[expected]
  assert oracle(rc,log),'exact intended RawNondet rejection '+name+'\n'+log
  lost=text.replace(', tags: [RawNondet].}',', tags: [].}',1)
  if kind=='wrapper':lost=lost.replace('{.tags: [RawNondet].} =','{.tags: [].} =',1)
  assert lost!=text,'annotation-loss source site';target.write_text(lost+declaration)
  loss,body=run(name+'-annotation-loss',argv[:-2]+['--nimcache:'+str(OUT/'cache'/(name+'-loss')),'--out:'+str(OUT/(name+'-loss.js')),str(fixture)])
  assert loss==0 and not oracle(loss,body),'annotation-loss compiler positive '+name+'\n'+body
  (OUT/(name+'-ORACLE.json')).write_text(json.dumps(dict(genuineRejected=True,annotationLossCompiles=True,required='RawNondet',expectedDiagnostic=expected)))
for release,recordable,internal in itertools.product([False,True],repeat=3):
 flags=(['-d:release']if release else [])+(['-d:isonimRecordable']if recordable else [])+(['-d:isonimInternalRecordDocumentProgress']if internal else [])
 name='native-'+''.join(str(int(x))for x in[release,recordable,internal]);binary=compile(name,flags,fixture=FIX/'record_document_progress_absent.nim',target='c');rc,log=run(name+'-execute',[str(binary)]);assert rc==0 and 'common-omission PASS'in log
 for file in(OUT/'cache'/name).glob('*.c'):assert b'boundary-shim'not in file.read_bytes()and b'attachInternalRecordDocumentProgress'not in file.read_bytes()
assert snapshot('source-after',OUT/'source')==source_before
assert {'isonim/core/'+k:v for k,v in snapshot('owning-core-after',ROOT/'src/isonim/core').items()}==owning_core
assert {str(p):sha(p)for p in inputs}==bindings
(OUT/'INPUTS-AFTER.json').write_text(json.dumps(bindings,sort_keys=True,indent=2))
print('Document progress owner runtime/emission/native/effect matrix PASS',flush=True)
