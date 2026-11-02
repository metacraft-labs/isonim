#!/usr/bin/env python3
"""Actual effect/omission/byte contracts and shared Link source inverses.

Uses stock compilers and actual Chromium. The only controlled replacement is
that test mutants alter the specified production source, never the oracle.
"""
from pathlib import Path
import hashlib,json,os,re,shutil,subprocess,tempfile
from test_client_creation_used_ordinary import assert_native_omission

ROUTING_TOKENS=('InternalClientRenderer','newInternalClientRenderer','internalClientLink','projectClientLink','requireClientContext')

def qualify_routing_contract():
    ROOT=Path(__file__).resolve().parent.parent
    P=ROOT/'build/client-routing-contract';P.mkdir(parents=True,exist_ok=True)
    OUT=Path(tempfile.mkdtemp(prefix='run-',dir=P));print('retained '+str(OUT),flush=True)
    ENV=dict(os.environ);NIM=Path(shutil.which('nim'));NODE=Path(shutil.which('node'))
    def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
    def rows(paths):return [{'path':str(p),'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(set(paths))]
    engine=Path(re.findall(r'exec "([^"]+/nim)"',NIM.read_text())[0]);library=engine.parent.parent/'lib'
    inputs=[Path(__file__),NIM,NODE,engine,ROOT/'Justfile',ROOT/'config.nims',ROOT/'tools/test_client_creation_used_ordinary.py']
    for root in [ROOT/'src',ROOT.parent/'nim-everywhere/src',library,NIM.parent.parent/'etc/nim',ROOT/'tests/browser/node_modules/playwright',ROOT/'tests/browser/node_modules/playwright-core']:
     inputs.extend(p for p in root.rglob('*') if p.is_file() and 'yoga' not in p.parts)
    inputs.extend(p for p in (ROOT/'tests/fixtures').glob('client_routing*.nim'))
    inputs.extend(p for p in [ROOT/'build/tailwind.css',ROOT/'build/tailwind-styles.json'] if p.is_file())
    inputs.append(ROOT/'tests/test_client_routing_link_controls.mjs')
    for name in ['python3','cc','gcc','bash','chromium']:
     path=shutil.which(name)
     if path:inputs.append(Path(path))
    chromium=Path(shutil.which('chromium'))
    for path in re.findall(r'"(/nix/store/[^"\n]+/chromium)"',chromium.read_text()):
     if Path(path).is_file():inputs.append(Path(path))
    BOUND=rows(inputs);(OUT/'INPUTS-BEFORE.json').write_text(json.dumps(BOUND,indent=2)+'\n')
    def run(name,cmd,source=ROOT,selected=(),env=ENV):
     bound=rows([source/'src/isonim/web/web_renderer.nim',source/'src/isonim/routing/navigate.nim',source/'src/isonim/core/nondet.nim',*selected])
     (OUT/(name+'-BEFORE.json')).write_text(json.dumps({'command':list(map(str,cmd)),'inputs':bound},indent=2)+'\n')
     r=subprocess.run(list(map(str,cmd)),cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
     (OUT/(name+'.log')).write_text(r.stdout);(OUT/(name+'-EXIT.json')).write_text(json.dumps({'exit':r.returncode})+'\n');print(name+': '+str(r.returncode),flush=True)
     assert rows([source/'src/isonim/web/web_renderer.nim',source/'src/isonim/routing/navigate.nim',source/'src/isonim/core/nondet.nim',*selected])==bound
     if r.returncode:print(r.stdout[-1800:],flush=True)
     return r
    FLAGS=['-d:isonimInternalClientOrdinals','-d:isonimInternalClientRouting']
    COMMON=['--skipParentCfg','--skipProjCfg','-d:nimOldCaseObjects','--path:'+str(ROOT.parent/'nim-everywhere/src')]
    MODES=[('default',[]),('recordable',['-d:isonimRecordable']),('direct',['-d:isonimDirectNondet']),('release',['-d:release']),('recordable-release',['-d:release','-d:isonimRecordable']),('strict',['-d:isonimStrictNondet']),('default-no-boundary-meter',['-d:isonimNoBoundaryMeter']),('recordable-no-boundary-meter',['-d:isonimRecordable','-d:isonimNoBoundaryMeter'])]
    def compile(name,fixture,flags,source=ROOT,backend='js'):
     target=OUT/(name+('.js' if backend=='js' else '.exe'))
     r=run(name,[NIM,backend,*COMMON,'--path:'+str(source/'src'),*flags,'--nimcache:'+str(OUT/'cache'/name),'--out:'+str(target),fixture],source,[fixture]);return r,target
    EFFECT=ROOT/'tests/fixtures/client_routing_effect.nim';ORDINARY=ROOT/'tests/fixtures/client_routing_ordinary.nim';LINK=ROOT/'tests/fixtures/client_routing_link_controls.nim'
    for mode,flags in MODES:
     r,_=compile(mode+'-effects',EFFECT,[*FLAGS,*flags]);r.check_returncode()
     for case in ['Factory','Route','Validator']:
      r,_=compile(mode+'-reject'+case,EFFECT,[*FLAGS,*flags,'-d:reject'+case]);assert r.returncode!=0 and 'RawNondet' in r.stdout and 'unlisted effect' in r.stdout
     r,_=compile(mode+'-rawOnly',EFFECT,[*FLAGS,*flags,'-d:rawOnly'])
     if '-d:isonimNoBoundaryMeter' in flags:r.check_returncode()
     else:assert r.returncode!=0 and 'TimeEffect' in r.stdout and 'unlisted effect' in r.stdout
     # Direct raw validator annotation loss must actually compile, separately from
     # inferred effects through a facade. No unrelated diagnostic is an inverse.
     source=OUT/(mode+'-tag-loss');shutil.copytree(ROOT/'src',source/'src',ignore=shutil.ignore_patterns('yoga'))
     p=source/'src/isonim/web/web_renderer.nim';text=p.read_text();start=text.index('  proc requireClientContext(');end=text.index('  proc newInternalClientRenderer',start);part=text[start:end];assert part.count('tags: [RawNondet]')==1
     p.write_text(text[:start]+part.replace('tags: [RawNondet]','tags: []')+text[end:])
     r,_=compile(mode+'-tag-loss-actual',EFFECT,[*FLAGS,*flags,'-d:rejectValidator'],source);r.check_returncode()
     try:assert r.returncode!=0 and 'RawNondet' in r.stdout and 'unlisted effect' in r.stdout,'direct validator effect rejection'
     except AssertionError as error:assert str(error)=='direct validator effect rejection'
     else:raise AssertionError('tag loss must falsify unchanged rejection')
     # The same actual USED ordinary imports/calls, with no output normalization.
     r,a=compile(mode+'-ordinary',ORDINARY,flags);r.check_returncode()
     r,b=compile(mode+'-ordinary-unused-private',ORDINARY,[*FLAGS,*flags]);r.check_returncode()
     assert a.read_bytes()==b.read_bytes(),'exact ordinary emitted bytes '+mode
     r,c=compile(mode+'-native-omission',ORDINARY,[*FLAGS,*flags],backend='c');r.check_returncode();run(mode+'-native-run',[c]).check_returncode()
     emitted='\n'.join(p.read_text() for p in (OUT/'cache'/(mode+'-native-omission')).rglob('*.c'));assert emitted
     assert_native_omission(emitted,ROUTING_TOKENS)
     # The unchanged successful companion runs EVERY native/key/reactive
     # assertion before its discriminating public-source mutation below.
     r,link_companion=compile(mode+'-Link-controls',LINK,[*FLAGS,*flags,'-d:isonimStableIds','-d:iidProjectRoot='+str(ROOT)]);r.check_returncode()
     companion_env={**ENV,'CLIENT_ROUTING_BUNDLE':str(link_companion),'CLIENT_ROUTING_RESULTS':str(OUT/(mode+'-Link-controls-RESULT.json')),'CLIENT_NO_METER':'1' if '-d:isonimNoBoundaryMeter' in flags else '0','PLAYWRIGHT_CHROMIUM_EXECUTABLE':ENV.get('PLAYWRIGHT_CHROMIUM_EXECUTABLE') or shutil.which('chromium')}
     run(mode+'-Link-controls-browser',[NODE,'tests/test_client_routing_link_controls.mjs'],ROOT,[link_companion],companion_env).check_returncode()
     # Actual public-tail mutation: native anchor/tail precede the failing check.
     # The positive companion above proves native event, key and reactive behavior.
     source=OUT/(mode+'-Link-double-append');shutil.copytree(ROOT/'src',source/'src',ignore=shutil.ignore_patterns('yoga'))
     p=source/'src/isonim/routing/navigate.nim';text=p.read_text();assert text.count('    discard parent.appendChild(a)')==1;p.write_text(text.replace('    discard parent.appendChild(a)','    discard parent.appendChild(a)\n    discard parent.appendChild(a)'))
     r,bundle=compile(mode+'-Link-double-append',LINK,[*FLAGS,*flags,'-d:isonimStableIds','-d:iidProjectRoot='+str(ROOT)],source);r.check_returncode()
     env={**ENV,'CLIENT_ROUTING_BUNDLE':str(bundle),'CLIENT_ROUTING_RESULTS':str(OUT/(mode+'-Link-double-append-RESULT.json')),'CLIENT_NO_METER':'1' if '-d:isonimNoBoundaryMeter' in flags else '0','PLAYWRIGHT_CHROMIUM_EXECUTABLE':ENV.get('PLAYWRIGHT_CHROMIUM_EXECUTABLE') or shutil.which('chromium')}
     r=run(mode+'-Link-double-append-browser',[NODE,'tests/test_client_routing_link_controls.mjs'],source,[bundle],env);assert r.returncode==1 and 'semantic: direct-single-native-append' in r.stdout
    # Distinct native COMMON-graph namespaces and raw emitted-C controls. This
    # never imports the JS-only renderer to use its intentional C error as proof.
    declarations=['type InternalClientRenderer* = object','proc newInternalClientRenderer*(): int = 0','proc internalClientLink*(): int = 0']
    assert len(declarations)==3 and len(ROUTING_TOKENS)==5
    for i,(token,declaration) in enumerate(zip(ROUTING_TOKENS[:3],declarations)):
     source=OUT/('native-static-'+str(i));shutil.copytree(ROOT/'src',source/'src',ignore=shutil.ignore_patterns('yoga'))
     p=source/'src/isonim/core/nondet.nim';p.write_text(p.read_text()+'\n'+declaration+'\n')
     fixture=source/'ordinary_companion.nim';text=ORDINARY.read_text();guard='    doAssert not declared('+token+')\n';assert text.count(guard)==1;fixture.write_text(text.replace(guard,''))
     r,exe=compile('native-static-'+str(i)+'-companion',fixture,FLAGS,source,'c');r.check_returncode();run('native-static-'+str(i)+'-companion-run',[exe],source,[fixture]).check_returncode()
     r,_=compile('native-static-'+str(i)+'-refusal',ORDINARY,FLAGS,source,'c');assert r.returncode!=0 and '`not declared('+token+')`' in r.stdout and 'AssertionDefect' in r.stdout
    artifacts=[]
    for i,token in enumerate(ROUTING_TOKENS):
     source=OUT/('native-emitted-'+str(i));shutil.copytree(ROOT/'src',source/'src',ignore=shutil.ignore_patterns('yoga'))
     p=source/'src/isonim/core/nondet.nim';p.write_text(p.read_text()+'\n{.emit: "static volatile int '+token+'_omissionCanary=0;".}\n')
     name='native-emitted-'+str(i);r,exe=compile(name,ORDINARY,FLAGS,source,'c');r.check_returncode();run(name+'-run',[exe],source).check_returncode()
     emitted='\n'.join(p.read_text() for p in (OUT/'cache'/name).rglob('*.c'));assert emitted
     try:assert_native_omission(emitted,ROUTING_TOKENS)
     except AssertionError as error:assert str(error)=='actual native omission: '+token
     else:raise AssertionError('actual C marker must fail unchanged scanner')
     remaining=tuple(t for t in ROUTING_TOKENS if t!=token);assert len(remaining)==4;assert_native_omission(emitted,remaining);artifacts.append((token,emitted,remaining))
    for token,emitted,remaining in artifacts:
     other_token,other_emitted,_=next(row for row in artifacts if row[0]!=token)
     try:assert_native_omission(other_emitted,remaining)
     except AssertionError as error:assert str(error)=='actual native omission: '+other_token
     else:raise AssertionError('unrelated actual C marker guard must remain active')
    (OUT/'NATIVE-CANARIES.json').write_text(json.dumps({'static_exports':list(ROUTING_TOKENS[:3]),'static_exact_guard_companions_compile_run':True,'exact_static_AssertionDefects':True,'emitted_markers':list(ROUTING_TOKENS),'emitted_compile_run_before_refusal':True,'same_artifact_exact_token_removal_admits':True,'another_actual_marker_artifact_still_refuses':True,'scope':'supported ordinary native-compatible common graph only'},indent=2)+'\n')
    assert rows(inputs)==BOUND
    (OUT/'INPUTS-AFTER.json').write_text(json.dumps(BOUND,indent=2)+'\n')
    print('routing contract PASS:8 exact ordinary byte/native omission/effect/direct-tag-loss and actual public-body Link mutation controls',flush=True)
    return OUT


def main():
    qualify_routing_contract()


if __name__ == "__main__":
    main()
