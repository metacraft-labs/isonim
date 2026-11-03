#!/usr/bin/env python3
"""Production live target resolver and complete TaskApp lifecycle qualification.

Real compiler dependencies and complete Acorn output are captured for independent
fixed-artifact review. Candidate inspection is never self-issued admission. Real
Chromium/DOM/app/handlers are used; loopback replaces hosting only. Production
assignment, facade-context and query inverses retain same-path passing companions.
"""
from pathlib import Path
import hashlib,json,os,re,shutil,subprocess,tempfile,sys
import client_routing_admission as admission
from test_client_creation_used_ordinary import assert_native_omission, NATIVE_TOKENS

MODES=[('default',[]),('recordable',['-d:isonimRecordable']),('direct',['-d:isonimDirectNondet']),('release',['-d:release']),('recordable-release',['-d:release','-d:isonimRecordable']),('strict',['-d:isonimStrictNondet']),('default-no-boundary-meter',['-d:isonimNoBoundaryMeter']),('recordable-no-boundary-meter',['-d:isonimRecordable','-d:isonimNoBoundaryMeter'])]

def main():
 R=Path(__file__).resolve().parent.parent;E=dict(os.environ)
 P=R/'build/client-target-resolver';P.mkdir(parents=True,exist_ok=True)
 O=Path(tempfile.mkdtemp(prefix='run-',dir=P));print('retained '+str(O),flush=True)
 nim=Path(shutil.which('nim'));node=Path(shutil.which('node'))
 engine=Path(re.findall(r'exec "([^"]+/nim)"',nim.read_text())[0]);lib=engine.parent.parent/'lib'
 chromium=Path(E['PLAYWRIGHT_CHROMIUM_EXECUTABLE']);minimum=max(8*1024**3,int(E.get('ISONIM_TEST_MIN_AVAILABLE_BYTES','0')))
 E['ISONIM_TEST_MIN_AVAILABLE_BYTES']=str(minimum)
 artifact=E.get('CT_ARTIFACT')
 if not artifact:raise SystemExit('CT_ARTIFACT required: actual installed owner integration cannot skip')
 sdk=Path(artifact).resolve()
 for relative in ['packages/boundary-shim/dist/browser/recorder.js','packages/boundary-shim/dist/browser/install.js','packages/boundary-format/dist/index.js','packages/boundary-shim/package.json']:
  assert (sdk/relative).is_file(),'actual installed supported SDK body required: '+relative
 E['CT_ARTIFACT']=str(sdk)
 def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
 def rows(paths):return {str(p.resolve()):sha(p) for p in sorted(set(paths))}
 def admit_scan(label):
  v=os.statvfs(O);disk=v.f_bavail*v.f_frsize;mem=int(next(line.split()[1] for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith('MemAvailable:')))*1024
  receipt=dict(disk_available_bytes=disk,MemAvailable_bytes=mem,minimum_bytes=minimum)
  (O/(label+'-ADMISSION.json')).write_text(json.dumps(receipt,indent=2)+'\n')
  assert min(disk,mem)>=minimum,'BLOCKED resource admission before full input scan'
 admit_scan('initial-inputs')
 corpus=[nim,engine,node,chromium,R/'config.nims',R/'Justfile',R/'package.json',R/'yarn.lock',R/'build/tailwind.css',R/'build/tailwind-styles.json']
 for root in [R/'src',R/'tools',R/'tests/fixtures',lib,nim.parent.parent/'etc/nim',R.parent/'nim-everywhere/src',R/'node_modules/acorn',R/'node_modules/parse5',R/'node_modules/entities',R/'node_modules/playwright',R/'node_modules/playwright-core']:
  corpus.extend(p for p in root.rglob('*') if p.is_file() and not any(part in p.parts for part in ['.git','yoga','__pycache__']))
 for name in ['gcc','cc','bash','python3']:
  tool=Path(shutil.which(name));corpus.append(tool)
  if tool.read_bytes().startswith(b'#!'):
   corpus.extend(Path(raw) for raw in re.findall(r'/nix/store/[^\s\"\']+/bin/(?:gcc|cc)',tool.read_text()) if Path(raw).is_file())
 corpus.extend(p for p in sdk.rglob('*') if p.is_file())
 corpus += list((R/'tests').glob('*.nims'))+[R/'tests/test_client_target_resolver.mjs',R/'tests/test_client_target_lifecycle.mjs',R/'tests/test_client_routing_task_lifecycle.mjs',R/'tests/test_branded_task_app.mjs']
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
 missing=dict(E);missing.pop('CT_ARTIFACT',None)
 absent=run('missing-artifact',[sys.executable,__file__],env=missing)
 assert absent.returncode!=0 and 'CT_ARTIFACT required: actual installed owner integration cannot skip' in absent.stdout
 flags=['-d:isonimInternalClientOrdinals','-d:isonimInternalClientRouting','-d:isonimInternalClientTargets']
 fixture=Path('tests/fixtures/client_target_resolver.nim');owner=Path('src/isonim/web/web_renderer.nim')
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
 def browser(name,bundle,ordinary=False,stable=True):
  if ordinary:
   env=E|dict(BRANDED_TASK_BUNDLE=str(bundle),BRANDED_TASK_RESULTS=str(O/(name+'-ASSERTIONS.json')),BRANDED_TASK_STYLE='1')
   script='tests/test_branded_task_app.mjs'
  else:
   env=E|dict(CLIENT_TARGET_BUNDLE=str(bundle),CLIENT_TARGET_SSR=str(html),CLIENT_TARGET_STABLE='1' if stable else '0',CLIENT_TARGET_NO_METER='1' if 'no-boundary-meter' in name else '0',CLIENT_TARGET_RESULTS=str(O/(name+'-ASSERTIONS.json')))
   script='tests/test_client_target_resolver.mjs'
  result=run(name+'-browser',[node,script],[bundle,html,R/script,R/'build/tailwind.css'],env)
  sdk_meta=O/(name+'-ASSERTIONS.json.SDK.json')
  if sdk_meta.exists():
   actual_sdk=json.loads(sdk_meta.read_text())
   assert actual_sdk['inputs'] and all(str(Path(raw).resolve()) in bound and sha(Path(raw))==bound[str(Path(raw).resolve())] for raw in actual_sdk['inputs']),'unbound installed SDK compiler input'
  return result
 def lifecycle(name,bundle):
  env=E|dict(CLIENT_ROUTING_TASK_LIFECYCLE_BUNDLE=str(bundle),CLIENT_ROUTING_TASK_LIFECYCLE_RESULTS=str(O/(name+'-ASSERTIONS.json')))
  return run(name+'-browser',[node,'tests/test_client_target_lifecycle.mjs'],[bundle,R/'tests/test_client_target_lifecycle.mjs',R/'build/tailwind.css'],env)
 ssr=compile('ssr',[],entry=Path('tests/fixtures/client_creation_ordinals.nim'),backend='c')
 result=run('ssr-native-run',[ssr],[ssr]);result.check_returncode();html=O/'ssr.html';html.write_text(result.stdout)
 original=(R/owner).read_text()
 index='var n=c.forward.ordinals.get(e); var ref=new WeakRef(e); c.targets.set(n,ref); return e;'
 route='        return createInternalClientTargetElement(r.targets, r.context, r.ordinary, tag)'
 canonical='if(!/^ord:[1-9][0-9]*(?![\\s\\S])/.test(t)) return null;'
 projection='    template indexedElement(native: untyped): untyped =\n      indexInternalClientTarget(context,\n        assignInternalClientCreationOrdinal(forward, native))'
 reserve='    proc reserveTarget(c: InternalClientCreationOrdinals): JsObject {.importjs: "(function(c){var n=c.next;c.next=n+1n;return n;})(#)", tags:[RawNondet].}\n    proc assignReservedTarget(c: InternalClientCreationOrdinals; e: Element; n: JsObject): Element {.importjs: "(function(c,e,n){c.ordinals.set(e,n);return e;})(#,#,#)", tags:[RawNondet].}\n    template indexedElement(native: untyped): untyped =\n      block:\n        let reserved = reserveTarget(forward)\n        indexInternalClientTarget(context, assignReservedTarget(forward, native, reserved))'
 deferred=original.replace(index,'return e;').replace('    internalClientCreationOrdinal(targetForwardContext(context), element)','    discard indexInternalClientTarget(context, element)\n    internalClientCreationOrdinal(targetForwardContext(context), element)')
 adopted=original.replace('      return Element(adopted)','      when declared(forward):\n        return indexInternalClientTarget(context, assignInternalClientCreationOrdinal(forward, Element(adopted)))\n      else:\n        return Element(adopted)')
 # New projection path only; genuine successful-only creation remains1.
 beforethrow=original.replace(projection,reserve)
 mutations={
  'omit-index':(original.replace(index,'return e;'),'inverse-is-at-creation'),
  'defer-index':(deferred,'inverse-is-at-creation'),
  'connected-filter':(original.replace('return ref===undefined ? null : ref.deref() || null;','var e=ref===undefined ? null : ref.deref() || null; return e && e.isConnected ? e : null;'),'detached-live-ordinal-resolves'),
  'fresh-context':(original.replace(route,'        let fresh = newInternalClientTargetRenderer(newInternalClientTargetContext())\n        return createInternalClientTargetElement(fresh.targets, fresh.context, fresh.ordinary, tag)'),'inverse-is-at-creation'),
  'number-adoption':(adopted,'adopted-node-consumes-no-inverse'),
  'advance-before-native':(beforethrow,'native-error-preserves-next'),
  'accept-leading-zero':(original.replace(canonical,canonical.replace('[1-9][0-9]*','[0-9]+')),'canonical-ordinal-is-required'),
  'bypass-iid-validator':(original.replace('        return resolveIidLookup(iid)','        proc bypassIid(iid: cstring): JsObject {.importjs: "globalThis.__isonimIids.get(#)?.deref() || null", tags:[RawNondet].}\n        return bypassIid(iid)'),'production-iid-validation-is-required')}
 assert original.count(index)==original.count(route)==original.count(projection)==original.count(canonical)==1
 assert all(text!=original for text,_ in mutations.values())
 for mode,defines in MODES:
  bundle=compile(mode,[*flags,*defines,'-d:isonimStableIds']);browser(mode,bundle).check_returncode();lifecycle(mode+'-lifecycle',bundle).check_returncode()
  no_iid=compile(mode+'-without-stable', [*flags,*defines]);browser(mode+'-without-stable',no_iid,stable=False).check_returncode()
  a=compile(mode+'-ordinary',defines+['-d:taskLifecycleOrdinaryControl']);b=compile(mode+'-ordinary-unused-private',flags+defines+['-d:taskLifecycleOrdinaryControl']);assert a.read_bytes()==b.read_bytes(),'exact same-import ordinary emitted bytes'
  # C intentionally uses the existing supported common graph, never the JS-only
  # renderer's intentional C error as an omission witness.
  native=compile(mode+'-native-omission',flags+defines,entry=Path('tests/fixtures/client_routing_ordinary.nim'),backend='c');run(mode+'-native-run',[native],[native]).check_returncode()
  emitted='\n'.join(p.read_text() for p in (O/'cache'/(mode+'-native-omission')).rglob('*.c'));assert emitted
  omission_tokens=NATIVE_TOKENS+('InternalClientRenderer','newInternalClientRenderer','internalClientLink','projectClientLink','requireClientContext')
  assert len(omission_tokens)==10
  omission_tokens+=('InternalClientTargetContext','newInternalClientTargetContext','newInternalClientTargetRenderer','resolveInternalClientTarget','internalClientTargetOrdinal','indexInternalClientTarget','targets: new Map')
  assert_native_omission(emitted,omission_tokens)
  ordinal_native=compile(mode+'-native-original-ordinal-guards',flags+defines,entry=Path('tests/fixtures/client_creation_used_ordinary.nim'),backend='c')
  run(mode+'-native-original-ordinal-guards-run',[ordinal_native],[ordinal_native]).check_returncode()
  original_c=list((O/'cache'/(mode+'-native-original-ordinal-guards')).rglob('*.c'))
  assert_native_omission('\n'.join(p.read_text() for p in original_c),omission_tokens)
  (O/(mode+'-OMISSION.json')).write_text(json.dumps(dict(markers=list(omission_tokens),facade_executable=rows([native]),ordinal_executable=rows([ordinal_native]),facade_generated_c=rows(list((O/'cache'/(mode+'-native-omission')).rglob('*.c'))),ordinal_generated_c=rows(original_c),scope='supported ordinary native common graphs with original static guards; JS-only renderer not imported'),indent=2)+'\n')
  for label,(mutated,semantic) in mutations.items():
   for kind in ['companion','mutant']:
    name=mode+'-'+label+'-'+kind;project=O/name
    shutil.copytree(R/'src',project/'src',ignore=shutil.ignore_patterns('yoga'))
    for relative in [fixture,Path('config.nims'),Path('tests/config.nims'),Path('tests/fixtures/config.nims'),Path('build/tailwind-styles.json')]:
     target=project/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(R/relative,target)
    if kind=='mutant':(project/owner).write_text(mutated)
    target=compile(name,[*flags,*defines,'-d:isonimStableIds'],project)
    result=browser(name,target)
    if kind=='companion':result.check_returncode()
    else:
     assert result.returncode==1 and 'semantic: '+semantic in result.stdout,'precise actual production inverse'
     evidence=json.loads((O/(name+'-ASSERTIONS.json')).read_text());assert evidence['checks'][0:2]==[dict(name='native-initial',actual=True,expected=True),dict(name='nonempty-initial',actual=True,expected=True)],'native success precedes inverse'
 # Legitimate actual target owner is accepted above. An unrelated actual
 # compiled native creator must still be refused, with a fresh genuine twin.
 policy=[]
 for mode,defines in MODES:
  name=mode+'-unknown-creation-owner'
  try:compile(name,[*flags,*defines,'-d:isonimStableIds','-d:targetAdmissionUnknownOwner'])
  except admission.AdmissionError as error:
   assert str(error).startswith('unadmitted-native-operation:createElement:unknownTargetCreator__')
   policy.append(dict(mode=mode,refusal=str(error)))
  else:raise AssertionError('unknown compiled native creator was accepted')
  compile(mode+'-new-owner-genuine-companion', [*flags,*defines,'-d:isonimStableIds'])
 (O/'FINITE-POLICY.json').write_text(json.dumps(policy,indent=2)+'\n')
 # All new raw declarations and inferred API wrappers retain exact ceilings.
 direct={'Make':'makeInternalClientTargetContext','Forward':'targetForwardContext',
  'Require':'requireInternalClientTargetContext','Link':'requireInternalClientTargetLink',
  'Has':'hasInternalClientTargets','Index':'indexInternalClientTarget',
  'Iid':'internalClientTargetIid','Lookup':'lookupInternalClientTarget'}
 wrappers=['Constructor','Renderer','Query','Resolver','Creation']
 effect_entry=Path('tests/fixtures/client_target_resolver_effect.nim')
 effects=[]
 def effect(name,defines,project=R,expected=None):
  output=O/(name+'.js');cache=O/'cache'/name
  cache.mkdir(parents=True)
  cmd=[nim,'js','--genScript:on','--path:'+str(project/'src'),'--path:'+str(R.parent/'nim-everywhere/src'),*flags,*defines,'--nimcache:'+str(cache),'--out:'+str(output),project/effect_entry]
  selected=[project/owner,project/effect_entry,nim,engine]
  result=run(name,cmd,selected)
  if expected:
   assert result.returncode!=0 and 'unlisted effect' in result.stdout and expected in result.stdout,'actual intended effect rejection'
  else:result.check_returncode()
  if result.returncode==0:
   selected_inputs=list(p for p in (project/'src').rglob('*') if p.is_file() and 'yoga' not in p.parts)+[project/effect_entry,project/'config.nims',project/'tests/config.nims',project/'tests/fixtures/config.nims']
   known=bound|rows(selected_inputs)
   configs=[Path(path) for path in re.findall(r"used config file '([^']+)'",result.stdout)]
   dependencies=[Path(path) for path in (cache/(effect_entry.stem+'.deps')).read_text().splitlines() if path]
   assert configs and dependencies and all(str(p.resolve()) in known for p in [*configs,*dependencies])
   actual=rows(dependencies)
   if project!=R:
    for raw,digest in actual.items():
     path=Path(raw)
     if path.is_relative_to(project) and path.relative_to(project)!=owner:assert sha(R/path.relative_to(project))==digest
     assert not path.is_relative_to(R/'src'),'mixed original effect source graph'
   descriptor=dict(argv=list(map(str,cmd)),cwd=str(R),loaded_config_order=list(map(str,configs)),loaded_configs=rows(configs),actual_inputs=actual,output_sha256=sha(output))
   (O/(name+'-BUILD.json')).write_text(json.dumps(descriptor,indent=2)+'\n')
  effects.append(dict(name=name,expected=expected,exit_code=result.returncode,output_sha256=sha(output) if output.exists() else None))
  return result
 effect_modes=[(branch+'-'+mode,[*branch_flags,*defines]) for branch,branch_flags in [('without-stable',[]),('with-stable',['-d:isonimStableIds'])] for mode,defines in MODES]
 for mode,defines in effect_modes:
  for label in [*direct,*wrappers]:
   selected=[*defines,'-d:effect'+label]
   effect('effect-'+mode+'-'+label+'-allowed',selected)
   effect('effect-'+mode+'-'+label+'-raw-refused',selected+['-d:effectRejectRaw'],expected='RawNondet')
   if label=='Creation':
    effect('effect-'+mode+'-creation-raw-only',selected+['-d:effectRawOnly'],expected=None if '-d:isonimNoBoundaryMeter' in defines else 'TimeEffect')
   else:effect('effect-'+mode+'-'+label+'-raw-only',selected+['-d:effectRawOnly'])
  for label,symbol in direct.items():
   start=original.index('  proc '+symbol);end=original.index('  proc ',start+8)
   declaration=original[start:end]
   assert declaration.count('tags: [RawNondet]')==1
   changed=original[:start]+declaration.replace('tags: [RawNondet]','tags: []')+original[end:]
   name='effect-'+mode+'-'+label+'-annotation-loss';project=O/name
   shutil.copytree(R/'src',project/'src',ignore=shutil.ignore_patterns('yoga'))
   for relative in [effect_entry,Path('config.nims'),Path('tests/config.nims'),Path('tests/fixtures/config.nims')]:
    target=project/relative;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(R/relative,target)
   (project/owner).write_text(changed)
   selected=[*defines,'-d:effect'+label,'-d:effectRejectRaw']
   effect(name+'-successful-compile',selected,project)
   # The unchanged actual negative oracle must fail AFTER successful compile;
   # a compiler error is never accepted as this annotation-loss control.
   try:effect(name+'-unchanged-oracle',selected,project,expected='RawNondet')
   except AssertionError as error:
    assert str(error)=='actual intended effect rejection'
    assert json.loads((O/(name+'-unchanged-oracle-RESULT.json')).read_text())['exit_code']==0
   else:raise AssertionError('missing direct annotation survived the unchanged effect oracle')
   effect(name+'-genuine-companion',selected,expected='RawNondet')
 (O/'EFFECTS.json').write_text(json.dumps(effects,indent=2)+'\n')
 admit_scan('final-inputs')
 assert rows(corpus)==bound,'fixed source/runtime corpus drift'
 (O/'INPUTS-AFTER.json').write_text(json.dumps(bound,indent=2)+'\n');(O/'CANDIDATES.json').write_text(json.dumps(candidates,indent=2)+'\n')
 print('PASS private targets:8 modes plus8 without-IID,full actual TaskApp lifecycle,64 production inverses and64 genuine companions; independent artifact review still required',flush=True)
if __name__=='__main__':main()
