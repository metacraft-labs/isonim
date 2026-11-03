#!/usr/bin/env python3
"""Complete production TaskApp lifecycle on the explicit private typed renderer.

Real compiler dependencies and complete Acorn output are captured for independent
fixed-artifact review. Candidate inspection is never self-issued admission. Real
Chromium/DOM/app/handlers are used; loopback replaces hosting only. Production
assignment, facade-context and query inverses retain same-path passing companions.
"""
from pathlib import Path
import hashlib,json,os,re,shutil,subprocess,tempfile
import client_routing_admission as admission
from test_client_creation_used_ordinary import assert_native_omission, NATIVE_TOKENS

MODES=[('default',[]),('recordable',['-d:isonimRecordable']),('direct',['-d:isonimDirectNondet']),('release',['-d:release']),('recordable-release',['-d:release','-d:isonimRecordable']),('strict',['-d:isonimStrictNondet']),('default-no-boundary-meter',['-d:isonimNoBoundaryMeter']),('recordable-no-boundary-meter',['-d:isonimRecordable','-d:isonimNoBoundaryMeter'])]

def main():
 R=Path(__file__).resolve().parent.parent;E=dict(os.environ)
 P=R/'build/client-routing-task-lifecycle';P.mkdir(parents=True,exist_ok=True)
 O=Path(tempfile.mkdtemp(prefix='run-',dir=P));print('retained '+str(O),flush=True)
 nim=Path(shutil.which('nim'));node=Path(shutil.which('node'))
 engine=Path(re.findall(r'exec "([^"]+/nim)"',nim.read_text())[0]);lib=engine.parent.parent/'lib'
 chromium=Path(E['PLAYWRIGHT_CHROMIUM_EXECUTABLE']);minimum=max(8*1024**3,int(E.get('ISONIM_TEST_MIN_AVAILABLE_BYTES','0')))
 E['ISONIM_TEST_MIN_AVAILABLE_BYTES']=str(minimum)
 def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
 def rows(paths):return {str(p.resolve()):sha(p) for p in sorted(set(paths))}
 corpus=[nim,engine,node,chromium,R/'config.nims',R/'Justfile',R/'package.json',R/'yarn.lock',R/'build/tailwind.css',R/'build/tailwind-styles.json']
 for root in [R/'src',R/'tools',R/'tests/fixtures',lib,nim.parent.parent/'etc/nim',R.parent/'nim-everywhere/src',R/'node_modules/acorn',R/'node_modules/parse5',R/'node_modules/entities',R/'node_modules/playwright',R/'node_modules/playwright-core']:
  corpus.extend(p for p in root.rglob('*') if p.is_file() and not any(part in p.parts for part in ['.git','yoga','__pycache__']))
 for name in ['gcc','cc','bash','python3']:
  tool=Path(shutil.which(name));corpus.append(tool)
  if tool.read_bytes().startswith(b'#!'):
   corpus.extend(Path(raw) for raw in re.findall(r'/nix/store/[^\s\"\']+/bin/(?:gcc|cc)',tool.read_text()) if Path(raw).is_file())
 corpus += list((R/'tests').glob('*.nims'))+[R/'tests/test_client_routing_task_lifecycle.mjs',R/'tests/test_branded_task_app.mjs']
 bound=rows(corpus);(O/'INPUTS-BEFORE.json').write_text(json.dumps(bound,indent=2)+'\n')
 def run(name,args,inputs=(),env=E):
  before=rows(inputs);v=os.statvfs(O);disk=v.f_bavail*v.f_frsize;mem=int(next(line.split()[1] for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith('MemAvailable:')))*1024
  receipt=dict(argv=list(map(str,args)),cwd=str(R),inputs=before,disk_available_bytes=disk,MemAvailable_bytes=mem,minimum_bytes=minimum)
  (O/(name+'-BEFORE.json')).write_text(json.dumps(receipt,indent=2)+'\n')
  if min(disk,mem)<minimum:
   (O/(name+'-BLOCKED.json')).write_text(json.dumps(dict(reason='resource admission',**receipt),indent=2)+'\n')
   raise AssertionError('BLOCKED resource admission')
  result=subprocess.run(list(map(str,args)),cwd=R,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
  (O/(name+'.log')).write_text(result.stdout);receipt['exit_code']=result.returncode;receipt['inputs_after']=rows(inputs);assert receipt['inputs_after']==before
  (O/(name+'-RESULT.json')).write_text(json.dumps(receipt,indent=2)+'\n');print(name,result.returncode,flush=True)
  if result.returncode:print(result.stdout[-1800:],flush=True)
  return result
 flags=['-d:isonimInternalClientOrdinals','-d:isonimInternalClientRouting']
 fixture=Path('tests/fixtures/client_routing_task_lifecycle.nim');owner=Path('src/isonim/web/web_renderer.nim')
 candidates=[]
 def compile(name,defines,project=R,entry=fixture,backend='js'):
  target=O/(name+('.js' if backend=='js' else '.exe'));cache=O/'cache'/name;cache.mkdir(parents=True)
  selected=list(p for p in (project/'src').rglob('*') if p.is_file() and 'yoga' not in p.parts)+[project/entry,project/'config.nims',project/'tests/config.nims',project/'tests/fixtures/config.nims',project/'build/tailwind-styles.json']
  known=bound|rows(selected)
  args=[nim,backend,'--genScript:on','--path:'+str(project/'src'),'--path:'+str(R.parent/'nim-everywhere/src'),*defines,'--nimcache:'+str(cache),'--out:'+str(target),project/entry]
  result=run(name+'-compile',args,selected+[nim,engine]);result.check_returncode()
  if backend=='c':
   # --genScript produces the authoritative .deps and emitted C but stops
   # before linking. Compile normally from the same bound sources/cache.
   native_args=[arg for arg in args if arg!='--genScript:on']
   run(name+'-native-link',native_args,selected+[nim,engine]).check_returncode()
  configs=[Path(path) for path in re.findall(r"used config file '([^']+)'",result.stdout)]
  assert configs and all(str(p.resolve()) in known for p in configs),'unbound compiler configuration'
  dependencies=[Path(path) for path in (cache/((project/entry).stem+'.deps')).read_text().splitlines() if path]
  assert dependencies and all(str(p.resolve()) in known for p in dependencies),'unbound actual compiler dependency'
  actual=rows(dependencies)
  if project!=R:
   for raw,digest in actual.items():
    path=Path(raw)
    if path.is_relative_to(project):
     relative=path.relative_to(project)
     if relative!=owner:
      assert sha(R/relative)==digest,'nonowner actual project source differs'
    else:
     assert not path.is_relative_to(R/'src'),'mixed original and isolated owner graphs'
  descriptor=dict(argv=list(map(str,args)),cwd=str(R),entry=rows([project/entry]),compiler=rows([nim,engine]),loaded_configs=rows(configs),loaded_config_order=list(map(str,configs)),actual_inputs=actual,output_sha256=sha(target))
  (O/(name+'-BUILD.json')).write_text(json.dumps(descriptor,indent=2)+'\n')
  if backend=='js':
   catalog=O/(name+'-AST.json');run(name+'-acorn',[node,'tools/client_routing_ast.mjs',target,catalog],[target,R/'tools/client_routing_ast.mjs']).check_returncode()
   ast=json.loads(catalog.read_text());assert ast['output_sha256']==sha(target)
   if '-d:taskLifecycleOrdinaryControl' not in defines:
    inspected=admission.inspect_candidate(target,ast,actual,actual,ast,descriptor,descriptor)
    # This captures a candidate's finite complete syntax and native operation
    # policy, never a reviewed manifest. The independent reviewer must inspect
    # every function/initializer/call/constructor and select pinned identities.
    assert inspected['status']=='candidate-inspected-review-pending'
    for row in ast['members']:
     if row['property'] in admission.CREATION_MEMBERS:
      kind='clearChildrenEmpty' if row['property']=='innerHTML' and row['empty_assignment'] else row['property']
      assert not admission.unadmitted_operation(kind,row['owner']),'unaccounted compiled native creation'
    candidates.append(dict(name=name,build=descriptor,catalog_sha256=sha(catalog),inspection=inspected))
  return target
 def browser(name,bundle,ordinary=False):
  if ordinary:
   env=E|dict(BRANDED_TASK_BUNDLE=str(bundle),BRANDED_TASK_RESULTS=str(O/(name+'-ASSERTIONS.json')),BRANDED_TASK_STYLE='1')
   script='tests/test_branded_task_app.mjs'
  else:
   env=E|dict(CLIENT_ROUTING_TASK_LIFECYCLE_BUNDLE=str(bundle),CLIENT_ROUTING_TASK_LIFECYCLE_RESULTS=str(O/(name+'-ASSERTIONS.json')))
   script='tests/test_client_routing_task_lifecycle.mjs'
  return run(name+'-browser',[node,script],[bundle,R/script,R/'build/tailwind.css'],env)
 original=(R/owner).read_text();assignment='var n=c.next; var successor=n+1n; c.ordinals.set(e,n); c.next=successor; return e;';query='var n=c.ordinals.get(e); return n===undefined ? null : n.toString(10);';route='    createInternalClientElement(r.context, r.ordinary, tag)'
 mutations={'assignment':(assignment,'return e;','all-task-creates-have-ordinals'),'context':(route,'    createInternalClientElement(newInternalClientCreationOrdinals(), r.ordinary, tag)','all-task-creates-have-ordinals'),'query':(query,'return null;','all-task-creates-have-ordinals')}
 for mode,defines in MODES:
  bundle=compile(mode,[*flags,*defines]);browser(mode,bundle).check_returncode();browser(mode+'-original-oracles',bundle,True).check_returncode()
  a=compile(mode+'-ordinary',defines+['-d:taskLifecycleOrdinaryControl']);b=compile(mode+'-ordinary-unused-private',flags+defines+['-d:taskLifecycleOrdinaryControl']);assert a.read_bytes()==b.read_bytes(),'exact same-import ordinary emitted bytes'
  # C intentionally uses the existing supported common graph, never the JS-only
  # renderer's intentional C error as an omission witness.
  native=compile(mode+'-native-omission',flags+defines,entry=Path('tests/fixtures/client_routing_ordinary.nim'),backend='c');run(mode+'-native-run',[native],[native]).check_returncode()
  emitted='\n'.join(p.read_text() for p in (O/'cache'/(mode+'-native-omission')).rglob('*.c'));assert emitted
  omission_tokens=NATIVE_TOKENS+('InternalClientRenderer','newInternalClientRenderer','internalClientLink','projectClientLink','requireClientContext')
  assert len(omission_tokens)==10
  assert_native_omission(emitted,omission_tokens)
  ordinal_native=compile(mode+'-native-original-ordinal-guards',flags+defines,entry=Path('tests/fixtures/client_creation_used_ordinary.nim'),backend='c')
  run(mode+'-native-original-ordinal-guards-run',[ordinal_native],[ordinal_native]).check_returncode()
  original_c=list((O/'cache'/(mode+'-native-original-ordinal-guards')).rglob('*.c'))
  assert_native_omission('\n'.join(p.read_text() for p in original_c),omission_tokens)
  (O/(mode+'-OMISSION.json')).write_text(json.dumps(dict(markers=list(omission_tokens),facade_executable=rows([native]),ordinal_executable=rows([ordinal_native]),facade_generated_c=rows(list((O/'cache'/(mode+'-native-omission')).rglob('*.c'))),ordinal_generated_c=rows(original_c),scope='supported ordinary native common graphs with original static guards; JS-only renderer not imported'),indent=2)+'\n')
  for label,(anchor,replacement,semantic) in mutations.items():
   assert original.count(anchor)==1,'inverse anchor drift'
   for kind in ['companion','mutant']:
    name=mode+'-'+label+'-'+kind;project=O/name
    shutil.copytree(R/'src',project/'src',ignore=shutil.ignore_patterns('yoga'))
    for relative in [fixture,Path('config.nims'),Path('tests/config.nims'),Path('tests/fixtures/config.nims'),Path('build/tailwind-styles.json')]:
     target=project/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(R/relative,target)
    if kind=='mutant':(project/owner).write_text(original.replace(anchor,replacement))
    target=compile(name,[*flags,*defines],project)
    result=browser(name,target)
    if kind=='companion':result.check_returncode()
    else:
     assert result.returncode==1 and 'semantic: '+semantic in result.stdout,'precise actual production inverse'
     evidence=json.loads((O/(name+'-ASSERTIONS.json')).read_text());assert evidence['checks'][0:2]==[dict(name='native-initial',actual=True,expected=True),dict(name='nonempty-initial',actual=True,expected=True)],'native success precedes inverse'
 assert rows(corpus)==bound,'fixed source/runtime corpus drift'
 (O/'INPUTS-AFTER.json').write_text(json.dumps(bound,indent=2)+'\n');(O/'CANDIDATES.json').write_text(json.dumps(candidates,indent=2)+'\n')
 print('PASS complete private task lifecycle:8 modes,original64 browser/style oracles per mode,24 production inverses and24 genuine companions; independent artifact review still required',flush=True)
if __name__=='__main__':main()
