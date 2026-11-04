#!/usr/bin/env python3
"""Actual compiled projector, installed Recorder/codec, Chromium and native SSR.

The HTTP server only delivers real compiled/serialized bytes. Finite source
inverses are compiled separately and share exact semantic assertions with fresh
unchanged companions. Resource/setup/compiler failures never count as kills.
"""
from pathlib import Path
import argparse,hashlib,itertools,json,os,re,shlex,shutil,subprocess,tempfile,time,sys
parser=argparse.ArgumentParser(description=__doc__)
selection=parser.add_mutually_exclusive_group()
selection.add_argument('--native-provenance-control',action='store_true',help='only actual native provenance infrastructure controls')
selection.add_argument('--focused-corrections',action='store_true',help='only the explicit post-qualification correction scopes')
arguments=parser.parse_args()
assert not os.environ.get('RECORD_ENV_NATIVE_CONTROL')and not os.environ.get('RECORD_ENV_FOCUSED_CORRECTIONS'),'partial scope requires explicit CLI flag, never an environment-selected green full target'
ROOT=Path(__file__).resolve().parent.parent
BASE=Path(os.environ.get('RECORD_ENV_EVIDENCE',ROOT/'build/record-env-evidence'));BASE.mkdir(parents=True,exist_ok=True)
OUT=Path(os.environ['RECORD_ENV_RESUME']) if os.environ.get('RECORD_ENV_RESUME') else Path(tempfile.mkdtemp(prefix='run-',dir=BASE))
print('Record Env evidence: '+str(OUT),flush=True)
LEDGER=json.loads((OUT/'LEDGER.json').read_text()) if (OUT/'LEDGER.json').exists() else []
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def guard(name):
 d=shutil.disk_usage(OUT).free;m=int(next(x.split()[1]for x in Path('/proc/meminfo').read_text().splitlines()if x.startswith('MemAvailable:')))*1024
 row=dict(name=name,diskFreeBytes=d,memAvailableBytes=m,time=time.time(),admitted=min(d,m)>=8*1024**3)
 with (OUT/'RESOURCE.jsonl').open('a')as f:f.write(json.dumps(row)+'\n')
 assert row['admitted'],'BLOCKED: resource floor '+name

def run(name,argv,env=None,cwd=ROOT,expected=0,oracle=None,outputs=()):
 argv=list(map(str,argv));env=env or {}
 guard(name+'-input-authentication')
 before={str(p):sha(p)for p in inputs if Path(p).is_file()}
 executable=Path(shutil.which(argv[0])or argv[0])
 if executable.is_file():
  before[str(executable)]=sha(executable);before[str(executable.resolve())]=sha(executable.resolve())
 # Bind the actual selected inverse body and compiled bundle, not only root.
 for p in [*argv,*env.values()]:
  if isinstance(p,str)and len(p)<250 and '\n'not in p and Path(p).is_file():before[p]=sha(p)
 old=[r for r in LEDGER if r['name']==name]
 if old:
  assert len(old)==1;row=old[0]
  assert row['argv']==argv and row['env']==env and row['beforeInputs']==before and row['cwd']==str(cwd),'frozen command/input drift '+name
  assert sha(OUT/(name+'.log'))==row['logSha256']
  assert all(Path(p).is_file()and sha(p)==h for p,h in row['outputs'].items())
  body=(OUT/(name+'.log')).read_text()
  assert row['expectedExit']==expected and row['oracle']==oracle and row['exit']==expected,'retained command expectation drift '+name
  if oracle:assert oracle in body and 'ENV_ASSERT:'in body,'retained wrong semantic failure '+name
  print(name,'authenticated earlier result',flush=True);return body
 assert not (OUT/(name+'-START.json')).exists(),'unreceipted invocation: inspect before resume '+name
 guard(name)
 start=dict(name=name,argv=argv,env=env,cwd=str(cwd),beforeInputs=before,expectedExit=expected,oracle=oracle,time=time.time())
 (OUT/(name+'-START.json')).write_text(json.dumps(start,indent=2))
 with (OUT/(name+'.log')).open('xb')as f:p=subprocess.run(argv,cwd=cwd,env=os.environ|env,stdout=f,stderr=subprocess.STDOUT)
 body=(OUT/(name+'.log')).read_text(errors='replace')
 row=dict(**start,exit=p.returncode,logSha256=sha(OUT/(name+'.log')),outputs={str(p):sha(p)for p in outputs if Path(p).is_file()})
 LEDGER.append(row);(OUT/'LEDGER.json').write_text(json.dumps(LEDGER,indent=2));(OUT/(name+'-RESULT.json')).write_text(json.dumps(row,indent=2))
 guard(name+'-after-input-authentication')
 assert all(Path(p).is_file()and sha(p)==h for p,h in before.items()),'input changed during command '+name
 assert p.returncode==expected, name+' unexpected exit '+str(p.returncode)+'; see '+str(OUT/(name+'.log'))
 if oracle:assert oracle in body and 'ENV_ASSERT:'in body,'wrong semantic failure '+name
 print(name,p.returncode,flush=True);return body

owner=Path(os.environ.get('CT_ARTIFACT',''));assert (owner/'packages/boundary-shim/package.json').is_file(),'supported installed CT_ARTIFACT required'
nim=Path(shutil.which('nim')or'');assert nim.is_file()
node=Path(shutil.which('node')or'');assert node.is_file()
chromium=Path(os.environ.get('PLAYWRIGHT_CHROMIUM_EXECUTABLE')or shutil.which('chromium')or'');assert chromium.is_file()
inputs=[Path(__file__).resolve(),ROOT/'Justfile',ROOT/'repro.nim',ROOT/'repro.lock',ROOT/'flake.nix',ROOT/'flake.lock',ROOT/'tests/test_record_env_owner.mjs',ROOT/'tests/test_record_env_unused.mjs',nim,nim.resolve(),node,node.resolve(),chromium,chromium.resolve()]
guard('finite-source-and-owner-bindings')
for base in [ROOT/'src',ROOT/'tests/fixtures',ROOT.parent/'nim-everywhere/src',owner]:
 inputs.extend(p for p in base.rglob('*')if p.is_file()and p.name!='shell.log')
# Compiler/stdlib provenance comes from the supported dump, never a guessed tree.
probe=ROOT/'tests/fixtures/record_env.nim'
meta=run('compiler-discovery',[nim,'dump','--dump.format:json','--backend:js','--path:'+str(ROOT/'src'),str(probe)])
# `nim dump` may put config hints before JSON on the combined stream.
metadata=json.loads(meta[meta.index('{'):]);engine=Path(metadata['nimExe']);stdlib=Path(metadata['libpath'])
assert engine.is_file()and stdlib.is_dir()
guard('compiler-and-browser-bindings')
inputs.extend([engine])
inputs.extend(p for p in stdlib.rglob('*')if p.is_file())
configs=[Path(x).resolve()for x in re.findall(r"used config file '([^']+)'",meta)]
inputs.extend(configs)
for path in [ROOT/'tests/browser/node_modules/playwright',ROOT/'tests/browser/node_modules/playwright-core']:
 inputs.extend(p for p in path.resolve().rglob('*')if p.is_file()and p.suffix in ['.js','.mjs','.json'])
bindings={str(p):sha(p)for p in inputs}
if (OUT/'INPUTS-BEFORE.json').exists():assert json.loads((OUT/'INPUTS-BEFORE.json').read_text())==bindings
else:(OUT/'INPUTS-BEFORE.json').write_text(json.dumps(bindings,indent=2,sort_keys=True))
source=ROOT/'src/isonim/core/private/record_env.nim';original=source.read_text()
mutations=[]
def mutation(name,old,new,oracle):
 assert original.count(old)==1,(name,old)
 mutations.append(dict(name=name,old=old,new=new,oracle=oracle))
# A live observation has an honest effect declaration. The semantic bridge has
# no effect ceiling; the independent strict fixture above continues to reject
# genuine env/raw calls. Widen ONLY this mutant's exported ceiling, not the
# unchanged source or any boundary binding, so its runtime oracle is reachable.
live_binding = """  import nim_everywhere/raw_nondet
  proc liveCached(text: cstring): cstring {.tags: [RawNondet], importjs: "(function(t){var c=JSON.parse(t);c.url=window.location.href;c.viewport={width:window.innerWidth,height:window.innerHeight};c.colorScheme=window.matchMedia('(prefers-color-scheme: dark)').matches?2:1;c.prefersReducedMotion=window.matchMedia('(prefers-reduced-motion: reduce)').matches;return JSON.stringify(c);})(#)".}
"""
live_module=original.replace('  proc projectInternalRecordEnv*(cachedEnv, completedExperimentResource: JsonNode): JsObject {.tags: [].} =',live_binding+'\n  proc projectInternalRecordEnv*(suppliedEnv, completedExperimentResource: JsonNode): JsObject {.tags: [RootEffect].} =\n    let cachedEnv = parseJson($liveCached(cstring($suppliedEnv)))')
assert live_module!=original
mutation('cached-world-isolation',original,live_module,'cached-world-isolation')
mutation('iana-same-offset','let timezone = stringAt(cachedEnv, "timeZone", "cachedEnv.timeZone")','let timezone = $cachedEnv["timezoneOffset"].getInt()','iana-same-offset')
legacy_module=original.replace('    let fields = %*{','    proc legacyMajor(text: cstring): int {.noSideEffect, tags: [], importjs: "Number(#)".}\n    let fields = %*{').replace('ownerMajor(cstring(ua))','legacyMajor(cstring(cachedEnv["browserMajor"].getStr()))')
mutation('ua-owner-match',original,legacy_module,'ua-owner-match')
mutation('viewport-boundaries','let integral = floor(value)','let integral = ceil(value)','viewport-boundaries')
mutation('finite-dpr','if not finite(dpr): invalid("cachedEnv.dpr", "expected finite number")','discard','finite-dpr')
mutation('preference-enums','"color_scheme": color.getInt()','"color_scheme": (if color.getInt() == 2: 2 else: 0)','preference-enums')
for field,value in [('ua','%"altered"'),('ua_major','%12'),('viewport_w','%3'),('viewport_h','%4'),('dpr','%2.75'),('locale','%"altered"'),('tz','%"altered"'),('fonts_digest','%"altered"'),('color_scheme','%0'),('reduced_motion','%0'),('arms','%"{\\\"altered\\\":\\\"1\\\"}"'),('url','%"altered"'),('referrer_origin','%"altered"'),('traceparent','%"altered"')]:
 mutation('all-fields-'+field,'plainJson(cstring($fields))','fields["'+field+'"] = '+value+'\n    plainJson(cstring($fields))','all-fields-'+field)
mutation('frozen-effective-arms','let arms = projectedArms(completedExperimentResource)','let arms = projectedArms(%*{"assign": cachedEnv["assignment"]})','frozen-effective-arms')
mutation('flat-string-arms','$( %($value.getBiggestInt()) )','$value','flat-string-arms')
mutation('own-key-order','compareUtf16(cstring(a), cstring(b))','compareUtf16(cstring(b), cstring(a))','own-key-order')
mutation('own-key-order-plain-object',"result.add('}')", "result.add('}')\n    proc enumerated(text: cstring): cstring {.noSideEffect, tags: [], importjs: \"(function(t){var source=JSON.parse(t),o={};for(var k of Object.keys(source))o[k]=source[k];return JSON.stringify(o);})(#)\".}\n    result = $enumerated(cstring(result))",'own-key-order')
mutation('malformed-arms-fail-closed','invalid(entryPath, "expected nonnegative safe integer")','continue','malformed-arms-fail-closed')
mutation('result-ownership','let url = stringAt(cachedEnv, "url", "cachedEnv.url")','cachedEnv["url"] = %"mutated-production-input"\n    let url = stringAt(cachedEnv, "url", "cachedEnv.url")','result-ownership')
manifest=dict(source=str(source),sourceSha256=sha(source),cases=mutations,scope='compiled actual production changes, unchanged exact semantic runner; each inverse has separately compiled same-case companion',rows=[list(row)for row in itertools.product(['debug','release'],['ordinary','recordable'],['normal','direct'])])
path=OUT/'MUTATION-ORACLE-MANIFEST.json'
if path.exists():assert json.loads(path.read_text())==manifest
else:path.write_text(json.dumps(manifest,indent=2))

def compile(name,fixture,flags=(),replacement=None,target='js'):
 dest=OUT/(name+('.js'if target=='js'else''));cache=OUT/'cache'/name
 argv=[nim,target,'--hint:Conf:on','--path:'+str(ROOT/'src'),'--path:'+str(ROOT.parent/'nim-everywhere/src'),'--nimcache:'+str(cache),'--out:'+str(dest),*flags]
 if replacement is not None:
  scope=OUT/'inverses'/name/'isonim/core/private';scope.mkdir(parents=True,exist_ok=True)
  body=scope/'record_env.nim'
  if body.exists():assert body.read_text()==replacement
  else:body.write_text(replacement)
  argv+=['--path:'+str(scope.parents[2])];inputs.append(body)
 argv.append(ROOT/'tests/fixtures'/fixture)
 if target=='c':
  run(name+'-generate',[*argv[:2],'--compileOnly:on','--genScript:on',*argv[2:]],outputs=[])
  scripts=list(cache.glob('*.sh'));assert len(scripts)==1
  documents=[json.loads(p.read_text())for p in cache.glob('*.json')]
  docs=[x for x in documents if x.get('outputFile')==str(dest)];assert len(docs)==1
  build=docs[0];commands=[r[1]for r in build['compile']];lines=[x for x in scripts[0].read_text().splitlines()if x and not x.startswith('#')]
  assert lines[:len(commands)]==commands
  actual=shlex.split(lines[len(commands)]);reference=shlex.split(build['linkcmd']);assert len(actual)==len(reference)
  oi=reference.index('-o')+1;assert actual.index('-o')+1==oi and Path(actual[oi]).name==dest.name
  objects=[]
  for i,(a,b)in enumerate(zip(actual,reference)):
   if i==oi:continue
   if b in build['link']:assert (cache/a).resolve()==Path(b).resolve();objects.append(str((cache/a).resolve()))
   else:assert a==b
  assert objects==build['link']
  generated=list(cache.glob('*.c'))+list(cache.glob('*.h'))+list(cache.glob('*.json'))+scripts
  toolpaths=[]
  for command in commands+[build['linkcmd']]:
   token=shlex.split(command)[0];tool=Path(shutil.which(token)or token);assert tool.is_file();toolpaths.extend([tool,tool.resolve()])
  guard(name+'-native-provenance-binding')
  provenance=dict(generationResultSha256=sha(OUT/(name+'-generate-RESULT.json')),environment={key:os.environ.get(key)for key in ['PATH','CC','CXX','CFLAGS','CPPFLAGS','CXXFLAGS','LDFLAGS','CPATH','C_INCLUDE_PATH','CPLUS_INCLUDE_PATH','LIBRARY_PATH','COMPILER_PATH','GCC_EXEC_PREFIX','NIX_CFLAGS_COMPILE','NIX_LDFLAGS','NIX_CC','NIX_BINTOOLS']},generated={str(p):sha(p)for p in generated},nativeTools={str(p):sha(p)for p in toolpaths},build=build,actualScript=str(scripts[0]),scriptCwd=str(cache),actualBinary=str(cache/dest.name),orderedObjects=objects,limits='Compiler wrappers and reported tools bound; transitive native headers/libraries are not a complete closure census.')
  provenance_path=OUT/(name+'-NATIVE-BEFORE.json');expected_provenance=json.dumps(provenance,indent=2)
  if provenance_path.exists():
   assert provenance_path.read_text()==expected_provenance,'existing native provenance differs; refused without overwrite'
  else:
   with provenance_path.open('x')as file:file.write(expected_provenance)
  inputs.extend(generated+toolpaths+[provenance_path])
  actualBinary=cache/dest.name
  run(name+'-link',['sh','-e',scripts[0]],cwd=cache,outputs=[actualBinary,*map(Path,objects)])
  return actualBinary
 run(name+'-compile',argv,outputs=[dest]);return dest

def browser(name,bundle,case='all',ssr=None,hydrate=None,plain=None,expected=0,oracle=None):
 receipt=OUT/(name+'-browser.json')
 env=dict(CT_ARTIFACT=str(owner),RECORD_ENV_BUNDLE=str(bundle),RECORD_ENV_CASE=case,RECORD_ENV_RECEIPT=str(receipt),PLAYWRIGHT_CHROMIUM_EXECUTABLE=str(chromium))
 if ssr:env.update(RECORD_ENV_SSR=str(ssr),RECORD_ENV_HYDRATE=str(hydrate),RECORD_ENV_PLAIN=str(plain),RECORD_ENV_SSR_EMPTY=str(empty_ssr))
 run(name,[node,ROOT/'tests/test_record_env_owner.mjs'],env,expected=expected,oracle=oracle,outputs=[receipt,Path(str(receipt)+'-combined.js'),Path(str(receipt)+'-metafile.json')])

flags=['-d:isonimInternalRecordEnv']
# Infrastructure-only control mode is explicit in the invoking command. A full
# normal target never enters it. It permits actual same-generation resume and
# changed-provenance refusal controls without repeating unrelated green suites.
if arguments.native_provenance_control:
 binary=compile('native-provenance-control','record_env_unused.nim',flags,target='c')
 run('native-provenance-control-run',[binary],outputs=[binary])
 (OUT/'NATIVE-CONTROL-COMPLETE.json').write_text(json.dumps(dict(sourceSha256=sha(source),mode='native-provenance-infrastructure-only',ledgerEntries=len(LEDGER)),indent=2))
 print('native provenance infrastructure control PASS',flush=True)
 sys.exit(0)
if arguments.focused_corrections:
 for release,recordable,direct in itertools.product([False,True],repeat=3):
  name='correction-'+('-'.join(['release'if release else'debug','recordable'if recordable else'ordinary','direct'if direct else'normal']))
  row=flags+(['-d:release']if release else[])+(['-d:isonimRecordable']if recordable else[])+(['-d:isonimDirectNondet']if direct else[])
  bundle=compile(name,'record_env_boot.nim',row)
  browser(name+'-owner',bundle,'cached-world-isolation')
 for case in ['cached-world-isolation','iana-same-offset','flat-string-arms']:
  m=next(item for item in mutations if item['name']==case)
  changed=original.replace(m['old'],m['new'])
  inverse=compile('correction-inverse-'+case,'record_env_boot.nim',flags,replacement=changed)
  browser('correction-inverse-'+case+'-run',inverse,case,expected=1,oracle='ENV_ASSERT: '+case)
  companion=compile('correction-companion-'+case,'record_env_boot.nim',flags,replacement=original)
  browser('correction-companion-'+case+'-run',companion,case)
 (OUT/'FOCUSED-CORRECTIONS-COMPLETE.json').write_text(json.dumps(dict(sourceSha256=sha(source),mode='focused-corrections-only',browserRows=8,inverseCompanionPairs=3,ledgerEntries=len(LEDGER)),indent=2))
 print('focused Record Env corrections PASS',flush=True)
 sys.exit(0)
for effect,diagnostic in [('Env','DomEventEffect'),('Raw','RawNondet')]:
 for forbidden in [False,True]:
  name='strict-'+effect+('-negative'if forbidden else'-companion')
  run(name,[nim,'js','--path:'+str(ROOT/'src'),'--path:'+str(ROOT.parent/'nim-everywhere/src'),'--nimcache:'+str(OUT/'cache'/name),'--out:'+str(OUT/(name+'.js')),*flags,*(['-d:recordEnvEffect'+effect]if forbidden else[]),ROOT/'tests/fixtures/record_env_effects.nim'],expected=1 if forbidden else 0)
  if forbidden:assert diagnostic in (OUT/(name+'.log')).read_text(),'targeted actual effect diagnostic missing'

# Real SSR and hydration are built once; browser assertions consume these bytes.
ssrExe=compile('experiments-ssr','record_env_experiments.nim',['-d:isServer'],target='c')
markup=run('experiments-ssr-run',[ssrExe]);ssr=OUT/'ssr.html';ssr.write_text(markup)
emptyExe=compile('experiments-empty-ssr','record_env_experiments.nim',['-d:isServer','-d:recordEnvNoResource'],target='c')
empty_markup=run('experiments-empty-ssr-run',[emptyExe]);empty_ssr=OUT/'empty-ssr.html';empty_ssr.write_text(empty_markup)
hydrate=compile('experiments-hydrate','record_env_experiments.nim')
plain=compile('experiments-plain','record_env_experiments.nim',['-d:recordEnvPlainHydrate'])
for release,recordable,direct in itertools.product([False,True],repeat=3):
 name='-'.join(['release'if release else'debug','recordable'if recordable else'ordinary','direct'if direct else'normal'])
 row=flags+(['-d:release']if release else[])+(['-d:isonimRecordable']if recordable else[])+(['-d:isonimDirectNondet']if direct else[])
 bundle=compile(name,'record_env_boot.nim',row)
 browser(name+'-owner',bundle,ssr=ssr,hydrate=hydrate,plain=plain)
 absent=compile(name+'-absent','record_env_unused.nim',[x for x in row if x!='-d:isonimInternalRecordEnv'])
 lazy=compile(name+'-unused','record_env_unused.nim',row)
 run(name+'-omission',[node,ROOT/'tests/test_record_env_unused.mjs',absent,lazy],dict(PLAYWRIGHT_CHROMIUM_EXECUTABLE=str(chromium),RECORD_ENV_UNUSED_RECEIPT=str(OUT/(name+'-unused.json'))),outputs=[OUT/(name+'-unused.json')])
for enabled in [False,True]:
 binary=compile('native-'+str(enabled),'record_env_unused.nim',flags if enabled else[],target='c')
 run('native-'+str(enabled)+'-run',[binary],outputs=[binary])
# Materialize genuine HEAD source and an existing HEAD entry at one exact path.
# No module-name/path or output normalization is used for the byte comparison.
guard('ordinary-parent-materialization')
parent_tip=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
listing=[line.split(' ',1)[1]for line in subprocess.check_output(['git','ls-tree','-r','--format=%(objecttype) %(path)',parent_tip,'src','tests/test_nondet_default.nim','config.nims','tests/config.nims'],cwd=ROOT,text=True).splitlines()if line.startswith('blob ')]
identity_root=OUT/'ordinary-source';identity_root.mkdir(exist_ok=True)
parent_blobs={}
for relative in listing:
 body=subprocess.check_output(['git','show',parent_tip+':'+relative],cwd=ROOT)
 actual=ROOT/relative
 assert actual.is_file()and actual.read_bytes()==body,'existing parent body differs '+relative
 p=identity_root/relative;p.parent.mkdir(parents=True,exist_ok=True)
 if p.exists():assert p.read_bytes()==body
 else:p.write_bytes(body)
 parent_blobs[relative]=hashlib.sha256(body).hexdigest()
 inputs.append(p)
parent_binding=dict(parent=parent_tip,entry='tests/test_nondet_default.nim',files=parent_blobs,sameSourcePath=str(identity_root/'src'),sameEntryPath=str(identity_root/'tests/test_nondet_default.nim'),sameOutputPath=str(OUT/'ordinary.js'))
(OUT/'ORDINARY-PARENT-BINDING.json').write_text(json.dumps(parent_binding,indent=2))
identity=OUT/'ordinary.js';new_module=identity_root/'src/isonim/core/private/record_env.nim'
# On exact resume the candidate-only unused file may remain; remove only that
# known body while restoring the genuine parent materialization.
if new_module.exists():assert new_module.read_text()==original;new_module.unlink()
for label in ['parent','candidate']:
 if label=='candidate':new_module.write_text(original);inputs.append(new_module)
 run('ordinary-'+label,[nim,'js','--path:'+str(identity_root/'src'),'--path:'+str(ROOT.parent/'nim-everywhere/src'),'--nimcache:'+str(OUT/'identity-cache'),'--out:'+str(identity),identity_root/'tests/test_nondet_default.nim'],outputs=[])
 captured=OUT/('ordinary-'+label+'.js')
 if not captured.exists():captured.write_bytes(identity.read_bytes())
 # Bind per-phase literal outputs independently of the shared mutable output.
 assert captured.read_bytes()==identity.read_bytes()
assert (OUT/'ordinary-parent.js').read_bytes()==(OUT/'ordinary-candidate.js').read_bytes(),'literal same-path ordinary bytes differ'
for m in mutations:
 changed=original.replace(m['old'],m['new'])
 mutant=compile('inverse-'+m['name'],'record_env_boot.nim',flags,replacement=changed)
 browser('inverse-'+m['name']+'-run',mutant,m['oracle'],ssr,hydrate,plain,expected=1,oracle='ENV_ASSERT: '+m['oracle'])
 companion=compile('companion-'+m['name'],'record_env_boot.nim',flags,replacement=original)
 browser('companion-'+m['name']+'-run',companion,m['oracle'],ssr,hydrate,plain)
assert source.read_text()==original
(OUT/'COMPLETE.json').write_text(json.dumps(dict(sourceSha256=sha(source),cases=len(mutations),rows=8,ledgerEntries=len(LEDGER)),indent=2))
print('complete Record Env owner qualification PASS',flush=True)
