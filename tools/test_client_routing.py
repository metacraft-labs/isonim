#!/usr/bin/env python3
"""Explicit production routing, native Chromium/SSR and discriminating inverses.

Only a loopback origin replaces hosting. Compiler, renderer, DSL, hydration,
Link, DOM, callbacks and ordinal metadata are actual production paths. All eight
modes and every companion/inverse are mandatory; errors are retained in build/.
"""
from pathlib import Path
import hashlib,json,os,shutil,subprocess,tempfile
from test_client_creation_ordinals import native_failure_ordering_mutation, require_semantic_inverse

def qualify_routing():
    ROOT=Path(__file__).resolve().parent.parent
    ENV=dict(os.environ);ENV.pop('CLIENT_ORDINALS_CASE',None)
    ENV['PLAYWRIGHT_CHROMIUM_EXECUTABLE']=ENV.get('PLAYWRIGHT_CHROMIUM_EXECUTABLE') or shutil.which('chromium') or ''
    assert Path(ENV['PLAYWRIGHT_CHROMIUM_EXECUTABLE']).is_file(),'required Chromium missing'
    P=ROOT/'build/client-routing';P.mkdir(parents=True,exist_ok=True)
    OUT=Path(tempfile.mkdtemp(prefix='run-',dir=P));print('retained '+str(OUT),flush=True)
    W=Path('src/isonim/web/web_renderer.nim');L=Path('src/isonim/routing/navigate.nim')
    def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
    def manifest(paths):return [{'path':str(p),'resolved':str(p.resolve()),'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(set(paths))]
    # The entire fixed source/library/runtime corpus is bound before this epoch,
    # not inferred afterward from HEAD or from the generated fixture alone.
    NIM=Path(shutil.which('nim'));NODE=Path(shutil.which('node'))
    (OUT/'NIM-DUMP-BEFORE.json').write_text(json.dumps({'tool':str(NIM.resolve()),'sha256':sha(NIM.resolve())})+'\n')
    dump=subprocess.run([str(NIM),'dump','--dump.format:json','--skipParentCfg','--skipProjCfg',str(ROOT/'tests/fixtures/client_routing.nim')],cwd=ROOT,env=ENV,text=True,capture_output=True)
    (OUT/'nim-dump.log').write_text(dump.stdout+dump.stderr);dump.check_returncode()
    info=json.loads(dump.stdout);LIB=Path(info['libpath']);ENGINE=LIB.parent/'bin/nim'
    inputs=[NIM,NODE,ENGINE,Path(__file__),Path(ENV['PLAYWRIGHT_CHROMIUM_EXECUTABLE']),ROOT/'Justfile',ROOT/'config.nims']
    for root in [ROOT/'src',ROOT/'tools',ROOT/'tests',ROOT.parent/'nim-everywhere/src',LIB,NIM.parent.parent/'etc/nim',ROOT/'tests/browser/node_modules/playwright',ROOT/'tests/browser/node_modules/playwright-core']:
     inputs.extend(p for p in root.rglob('*') if p.is_file() and not any(x in p.parts for x in ['.git','node_modules','yoga']) and p.suffix in ['.nim','.nims','.py','.mjs','.js','.json'])
    # node_modules is excluded above when walking tests, and enumerated explicitly.
    for root in [ROOT/'tests/browser/node_modules/playwright',ROOT/'tests/browser/node_modules/playwright-core',ROOT/'node_modules/acorn',ROOT/'node_modules/parse5',ROOT/'node_modules/entities']:
     inputs.extend(p for p in root.rglob('*') if p.is_file() and p.suffix in ['.js','.mjs','.json'])
    chromium_wrapper=Path(ENV['PLAYWRIGHT_CHROMIUM_EXECUTABLE']).read_text()
    import re
    for raw in re.findall(r'"(/nix/store/[^"\n]+/chromium)"',chromium_wrapper):
     if Path(raw).is_file():inputs.append(Path(raw))
    inputs.extend(p for p in LIB.rglob('*') if p.is_file())
    inputs.extend(p for p in [ROOT/'build/tailwind.css',ROOT/'build/tailwind-styles.json'] if p.is_file())
    for name in ['python3','cc','gcc','bash']:
     path=shutil.which(name)
     if path: inputs.append(Path(path))
    BOUND=manifest(inputs);(OUT/'INPUTS-BEFORE.json').write_text(json.dumps(BOUND,indent=2)+'\n')
    (OUT/'ENVIRONMENT.json').write_text(json.dumps({k:ENV.get(k) for k in ['PATH','CC','CXX','NIM_CONFIG_PATH','PLAYWRIGHT_CHROMIUM_EXECUTABLE']},indent=2)+'\n')
    def run(name,cmd,source=ROOT,env=ENV,fixture=None,resources=()):
     selected=[source/W,source/L,*([fixture] if fixture else []),*resources];bound=manifest(selected)
     (OUT/(name+'-BEFORE.json')).write_text(json.dumps({'command':list(map(str,cmd)),'cwd':str(ROOT),'selected_inputs':bound},indent=2)+'\n')
     r=subprocess.run(list(map(str,cmd)),cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
     (OUT/(name+'.log')).write_text(r.stdout);(OUT/(name+'-EXIT.json')).write_text(json.dumps({'exit':r.returncode})+'\n');print(name+': '+str(r.returncode),flush=True)
     assert manifest(selected)==bound,'selected source/fixture changed during consumer'
     (OUT/(name+'-AFTER.json')).write_text(json.dumps(bound,indent=2)+'\n')
     if r.returncode:print(r.stdout[-3000:],flush=True)
     return r
    FLAGS=['-d:isonimInternalClientOrdinals','-d:isonimInternalClientRouting']
    COMMON=['--skipParentCfg','--skipProjCfg','-d:nimOldCaseObjects','--path:'+str(ROOT.parent/'nim-everywhere/src')]
    def compile(name,flags=(),source=ROOT,fixture=None,backend='js'):
     fixture=fixture or ROOT/'tests/fixtures/client_routing.nim';target=OUT/(name+('.js' if backend=='js' else '.exe'))
     cache=OUT/'cache'/name;cache.mkdir(parents=True,exist_ok=True)
     selected=[p for p in (source/'src').rglob('*') if p.is_file() and 'yoga' not in p.parts]
     before=manifest([*selected,fixture])
     run(name+'-compile',[NIM,backend,*(['--genScript:on'] if backend=='js' else []),*COMMON,'--path:'+str(source/'src'),*flags,'--nimcache:'+str(cache),'--out:'+str(target),fixture],source,fixture=fixture,resources=selected).check_returncode()
     if backend=='js':
         deps=cache/(fixture.stem+'.deps');assert deps.is_file()
         paths=[Path(p) for p in deps.read_text().splitlines() if p]
         known={row['resolved'] for row in [*BOUND,*before]}
         assert paths and all(str(p.resolve()) in known for p in paths),'unbound actual compiler source'
         (OUT/(name+'-ACTUAL-DEPENDENCIES.json')).write_text(json.dumps(manifest(paths),indent=2)+'\n')
     return target
    ssr=compile('ssr',backend='c');r=run('ssr-run',[ssr]);r.check_returncode();html=OUT/'ssr.html';html.write_text(r.stdout)
    def browser(name,bundle,flags,case=None,source=ROOT):
     env={**ENV,'CLIENT_ORDINALS_BUNDLE':str(bundle),'CLIENT_ORDINALS_SSR':str(html),'CLIENT_ORDINALS_RESULTS':str(OUT/(name+'-RESULT.json')),'CLIENT_NO_METER':'1' if '-d:isonimNoBoundaryMeter' in flags else '0'}
     if case:env['CLIENT_ORDINALS_CASE']=case
     return run(name+'-browser',[NODE,'tests/test_client_routing.mjs'],source,env,bundle,resources=[html])
    w=(ROOT/W).read_text();l=(ROOT/L).read_text()
    assignment='var n=c.next; var successor=n+1n; c.ordinals.set(e,n); c.next=successor; return e;'
    query='var n=c.ordinals.get(e); return n===undefined ? null : n.toString(10);'
    mutations={
    'all-dsl-creates-route':(W,w.replace('    createInternalClientElement(r.context, r.ordinary, tag)','    r.ordinary.createElement(tag)')),
    'one-namespace-through-closures':(W,w.replace('    createInternalClientElement(r.context, r.ordinary, tag)','    createInternalClientElement(newInternalClientCreationOrdinals(), r.ordinary, tag)')),
    'link-route-is-not-ordinary':(L,l.replace('body[first][0][2] = renderer','body[first][0][2] = newCall(bindSym"WebRenderer")')),
    'creation-order-before-lookup':(W,w.replace(assignment,'return e;').replace(query,'var n=c.ordinals.get(e);if(n===undefined){n=c.next;c.ordinals.set(e,n);c.next=n+1n;}return n.toString(10);')),
    'created-element-has-ordinal':(W,w.replace(assignment,'return e;')),
    'fresh-adopted-element-has-no-ordinal':(W,w.replace('      return Element(adopted)','      when declared(context):\n        return assignInternalClientCreationOrdinal(context, Element(adopted))\n      else:\n        return Element(adopted)')),
    'native-failure-does-not-consume':(W,native_failure_ordering_mutation(w)),
    'production-query-is-required':(W,w.replace(query,'return null;'))}
    misleading_native_failure = w.replace('    template numberedElement(native: untyped): untyped =','    proc advance(c: InternalClientCreationOrdinals) {.importjs: "(function(c){c.next=c.next+1n;})(#)", tags:[RawNondet].}\n    template numberedElement(native: untyped): untyped =').replace('      assignInternalClientCreationOrdinal(context, native)','      block:\n        advance(context)\n        assignInternalClientCreationOrdinal(context, native)')
    MODES=[('default',[]),('recordable',['-d:isonimRecordable']),('direct',['-d:isonimDirectNondet']),('release',['-d:release']),('recordable-release',['-d:release','-d:isonimRecordable']),('strict',['-d:isonimStrictNondet']),('default-no-boundary-meter',['-d:isonimNoBoundaryMeter']),('recordable-no-boundary-meter',['-d:isonimRecordable','-d:isonimNoBoundaryMeter'])]
    for mode,flags in MODES:
     bundle=compile(mode,[*FLAGS,*flags]);browser(mode,bundle,flags).check_returncode()
     task=ROOT/'tests/fixtures/client_routing_task.nim'
     task_flags=[*flags,'-d:isonimStableIds','-d:iidProjectRoot='+str(ROOT)]
     server=compile(mode+'-actual-task-ssr',[*task_flags,'-d:isServer'],fixture=task,backend='c')
     server_result=run(mode+'-actual-task-ssr-run',[server],fixture=server);server_result.check_returncode()
     task_html=OUT/(mode+'-actual-task.html');task_html.write_text(server_result.stdout)
     base_catalog=OUT/(mode+'-actual-task-html-AST.json');mismatch_html=OUT/(mode+'-actual-task-title-mismatch.html');mismatch_catalog=OUT/(mode+'-actual-task-mismatch-html-AST.json')
     run(mode+'-actual-task-html-catalog',[NODE,'tools/client_routing_ast.mjs','--html-variants',task_html,base_catalog,mismatch_html,mismatch_catalog],resources=[task_html]).check_returncode()
     markup_a=json.loads(base_catalog.read_text());markup_b=json.loads(mismatch_catalog.read_text())
     assert len(markup_a['scripts'])==1 and markup_a['scripts']==markup_b['scripts'],'same actual inline HY bootstrap'
     for script in markup_a['scripts']:
         assert not any(row['property'] in ['createElement','createElementNS','innerHTML','outerHTML','cloneNode','write'] for row in script['catalog']['members']),'no unaccounted HY bootstrap creation'
     task_bundle=compile(mode+'-actual-task-client',[*FLAGS,*task_flags],fixture=task)
     task_catalog=OUT/(mode+'-actual-task-client-AST.json')
     run(mode+'-actual-task-js-catalog',[NODE,'tools/client_routing_ast.mjs',task_bundle,task_catalog],resources=[task_bundle]).check_returncode()
     task_env={**ENV,'CLIENT_ROUTING_BUNDLE':str(task_bundle),'CLIENT_ROUTING_TASK_SSR':str(task_html),'CLIENT_ROUTING_TASK_MISMATCH_SSR':str(mismatch_html),'CLIENT_ROUTING_RESULTS':str(OUT/(mode+'-actual-task-RESULT.json'))}
     run(mode+'-actual-task-browser',[NODE,'tests/test_client_routing_task.mjs'],env=task_env,fixture=task_bundle,resources=[task_html,mismatch_html,base_catalog,mismatch_catalog,task_catalog]).check_returncode()
     for label,(changed,body) in mutations.items():
      assert body!=(ROOT/changed).read_text(),label
      for kind in ['companion','mutant']:
       name=mode+'-'+label+'-'+kind;source=OUT/name
       shutil.copytree(ROOT/'src',source/'src',ignore=shutil.ignore_patterns('yoga'))
       if kind=='mutant':(source/changed).write_text(body)
       bundle=compile(name,[*FLAGS,*flags],source)
       result=browser(name,bundle,flags,label,source)
       if kind=='companion':result.check_returncode()
       else:
        require_semantic_inverse(result,label)
        if label=='native-failure-does-not-consume':
         witness=json.loads((OUT/(name+'-RESULT.json')).read_text())[0]['nativeFailure']
         assert witness==dict(successOnlyOrdinal='1',invalidThenSuccessOrdinal='2',nativeErrorIdentity=True),'actual routing single-reservation failure-path witness'
     # Rejected inverse candidates are NOT members of the64 intended mutations.
     name=mode+'-rejected-duplicate-advance';source=OUT/name
     shutil.copytree(ROOT/'src',source/'src',ignore=shutil.ignore_patterns('yoga'));(source/W).write_text(misleading_native_failure)
     bundle=compile(name,[*FLAGS,*flags],source)
     result=browser(name,bundle,flags,'native-failure-does-not-consume',source)
     assert result.returncode==1 and 'semantic: native-failure-success-only-control' in result.stdout,'routing duplicate advance fails successful-only control'
     witness=json.loads((OUT/(name+'-RESULT.json')).read_text())[0]['nativeFailure']
     assert witness==dict(successOnlyOrdinal='2'),'actual routing duplicate-advance successful-only ordinal2'
     try:require_semantic_inverse(result,'native-failure-does-not-consume')
     except AssertionError as error:assert str(error)=='precise production semantic inverse native-failure-does-not-consume'
     else:raise AssertionError('routing duplicate advance must not qualify as intended inverse')
     (OUT/(name+'-REJECTED-INVERSE.json')).write_text(json.dumps(dict(compile_exit=0,browser_exit=1,diagnostic='native-failure-success-only-control',qualified_as_native_failure_inverse=False),indent=2)+'\n')
    assert manifest(inputs)==BOUND,'input corpus changed during qualification epoch'
    (OUT/'INPUTS-AFTER.json').write_text(json.dumps(BOUND,indent=2)+'\n')
    print('client routing production matrix PASS:8 modes,64 actual semantic mutants and64 genuine companions;8 duplicate-advance inverse candidates rejected',flush=True)
    return OUT


def main():
    qualify_routing()


if __name__ == "__main__":
    main()
