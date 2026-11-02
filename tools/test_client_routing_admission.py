#!/usr/bin/env python3
"""Real compiler/Acorn candidate inspection and exact refusal-removal controls.

The positive reference and controlled negative variants are review candidates,
not author-issued final authorizations. No negative artifact executes as an
admitted application. Only a loopback/native browser replaces hosting; source
mutations change the actual guard, never substitute a parser, DOM or compiler.
"""
from pathlib import Path
import hashlib,json,os,re,shutil,subprocess,tempfile,importlib.util
import client_routing_admission as admission

MODES=[('default',[]),('recordable',['-d:isonimRecordable']),('direct',['-d:isonimDirectNondet']),('release',['-d:release']),('recordable-release',['-d:release','-d:isonimRecordable']),('strict',['-d:isonimStrictNondet']),('default-no-boundary-meter',['-d:isonimNoBoundaryMeter']),('recordable-no-boundary-meter',['-d:isonimRecordable','-d:isonimNoBoundaryMeter'])]
CASES=['Template','HydrationRaw','Clone','DirectDom','OrdinaryRenderer','OldLink','Foreign','Bracket','Alias','Dynamic','Constructor','Callback','Reflect','UnknownFunction','UnknownInit']


def qualify_routing_admission(probe=False):
    ROOT=Path(__file__).resolve().parent.parent
    P=ROOT/'build/client-routing-admission';P.mkdir(parents=True,exist_ok=True)
    OUT=Path(tempfile.mkdtemp(prefix='run-',dir=P));print('retained '+str(OUT),flush=True)
    ENV=dict(os.environ);NIM=Path(shutil.which('nim'));NODE=Path(shutil.which('node'))
    def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
    def rows(paths):return [{'path':str(p),'resolved':str(p.resolve()),'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(set(paths))]
    wrapper=NIM.read_text();engines=re.findall(r'exec "([^"]+/nim)"',wrapper);assert len(engines)==1
    ENGINE=Path(engines[0]);LIB=ENGINE.parent.parent/'lib'
    inputs=[NIM,NODE,ENGINE,Path(__file__),ROOT/'Justfile',ROOT/'config.nims',ROOT/'package.json',ROOT/'yarn.lock']
    for root in [ROOT/'src',ROOT/'tools',ROOT/'tests/fixtures',ROOT.parent/'nim-everywhere/src',LIB,NIM.parent.parent/'etc/nim',ROOT/'node_modules/acorn',ROOT/'node_modules/parse5',ROOT/'node_modules/entities',ROOT/'tests/browser/node_modules/playwright',ROOT/'tests/browser/node_modules/playwright-core']:
        inputs.extend(p for p in root.rglob('*') if p.is_file() and 'yoga' not in p.parts and '__pycache__' not in p.parts)
    inputs.extend(p for p in [ROOT/'build/tailwind.css',ROOT/'build/tailwind-styles.json'] if p.is_file())
    inputs.extend(p for p in (ROOT/'tests').glob('test_client_routing*.mjs'))
    for name in ['python3','cc','gcc','bash','chromium']:
        path=shutil.which(name)
        if path:inputs.append(Path(path))
    chromium=Path(shutil.which('chromium'))
    for path in re.findall(r'"(/nix/store/[^"\n]+/chromium)"',chromium.read_text()):
        if Path(path).is_file():inputs.append(Path(path))
    BOUND=rows(inputs);(OUT/'INPUTS-BEFORE.json').write_text(json.dumps(BOUND,indent=2)+'\n')
    FIXTURE=ROOT/'tests/fixtures/client_routing_admission.nim'
    FLAGS=['-d:isonimInternalClientOrdinals','-d:isonimInternalClientRouting']
    COMMON=['--skipParentCfg','--skipProjCfg','-d:nimOldCaseObjects','--path:'+str(ROOT.parent/'nim-everywhere/src')]
    def run(name,cmd,selected=(),env=ENV):
        bound=rows(selected);(OUT/(name+'-BEFORE.json')).write_text(json.dumps({'command':list(map(str,cmd)),'selected':bound},indent=2)+'\n')
        r=subprocess.run(list(map(str,cmd)),cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        (OUT/(name+'.log')).write_text(r.stdout);(OUT/(name+'-EXIT.json')).write_text(json.dumps({'exit':r.returncode})+'\n');print(name+': '+str(r.returncode),flush=True)
        assert rows(selected)==bound
        if r.returncode:print(r.stdout[-1600:],flush=True)
        return r
    builds={}
    def compile(name,flags,fixture=FIXTURE,source=ROOT,project_config=None):
        target=OUT/(name+'.js');cache=OUT/'cache'/name;cache.mkdir(parents=True)
        selected=[p for p in (source/'src').rglob('*') if p.is_file() and 'yoga' not in p.parts]+[fixture]
        if project_config is not None:selected.append(project_config)
        before=rows(selected)
        common=[item for item in COMMON if project_config is None or item!='--skipProjCfg']
        command=[NIM,'js','--genScript:on',*common,'--path:'+str(source/'src'),*flags,'--nimcache:'+str(cache),'--out:'+str(target),fixture]
        prebound=[*BOUND,*before]
        descriptor={'argv':list(map(str,command)),'cwd':str(ROOT),'entry':rows([fixture]),'compiler':rows([NIM,ENGINE]),'source_inputs_sha256':admission.catalog_digest(prebound),'prebound_configs':[row for row in prebound if Path(row['path']).suffix in ('.cfg','.nims')]}
        (OUT/(name+'-BUILD-BEFORE.json')).write_text(json.dumps(descriptor,indent=2)+'\n')
        r=run(name,command,[*selected,NIM,ENGINE])
        known={row['resolved']:row for row in prebound}
        configs=[Path(path) for path in re.findall(r"used config file '([^']+)'",r.stdout)]
        assert configs and all(str(path.resolve()) in known for path in configs),'unbound actual compiler config'
        descriptor['loaded_configs']=rows(configs)
        descriptor['loaded_config_order']=list(map(str,configs))
        if project_config is not None:assert str(project_config) in descriptor['loaded_config_order']
        builds[str(target)]=descriptor
        (OUT/(name+'-BUILD.json')).write_text(json.dumps(descriptor,indent=2)+'\n')
        if r.returncode==0:
            deps=cache/(fixture.stem+'.deps');assert deps.is_file()
            known={row['resolved'] for row in [*BOUND,*before]}
            paths=[Path(p) for p in deps.read_text().splitlines() if p]
            assert paths and all(str(p.resolve()) in known for p in paths),'unbound actual compiler dependency'
            (OUT/(name+'-ACTUAL-DEPENDENCIES.json')).write_text(json.dumps(rows(paths),indent=2)+'\n')
            run(name+'-syntax',[NODE,'--check',target],[target]).check_returncode()
        return r,target
    def catalog(name,bundle):
        path=OUT/(name+'-AST.json')
        run(name+'-acorn',[NODE,'tools/client_routing_ast.mjs',bundle,path],[bundle,ROOT/'tools/client_routing_ast.mjs',ROOT/'node_modules/acorn/dist/acorn.mjs']).check_returncode()
        return json.loads(path.read_text())
    ssr_fixture=ROOT/'tests/fixtures/client_routing_rejected_ssr.nim'
    ssr_cache=OUT/'cache/rejected-ssr';ssr_cache.mkdir(parents=True)
    ssr_exe=OUT/'rejected-ssr.exe'
    run('rejected-ssr-compile',[NIM,'c',*COMMON,'--path:'+str(ROOT/'src'),'--nimcache:'+str(ssr_cache),'--out:'+str(ssr_exe),ssr_fixture],[ssr_fixture]).check_returncode()
    markup=run('rejected-ssr-run',[ssr_exe],[ssr_exe]);markup.check_returncode();ssr_html=OUT/'rejected-ssr.html';ssr_html.write_text(markup.stdout)
    ssr_catalog=OUT/'rejected-ssr-AST.json'
    run('rejected-ssr-catalog',[NODE,'tools/client_routing_ast.mjs','--html',ssr_html,ssr_catalog],[ssr_html]).check_returncode()
    parsed_ssr=json.loads(ssr_catalog.read_text());assert len(parsed_ssr['scripts'])==1
    assert not any(row['property'] in admission.CREATION_MEMBERS for script in parsed_ssr['scripts'] for row in script['catalog']['members'])
    def witness(name,bundle,case):
        env={**ENV,'CLIENT_ROUTING_BUNDLE':str(bundle),'CLIENT_ROUTING_REJECTED_SSR':str(ssr_html),'CLIENT_ROUTING_REJECTED_CASE':case,'CLIENT_ROUTING_RESULTS':str(OUT/(name+'-NATIVE-WITNESS.json')),'PLAYWRIGHT_CHROMIUM_EXECUTABLE':ENV.get('PLAYWRIGHT_CHROMIUM_EXECUTABLE') or shutil.which('chromium')}
        run(name+'-native-witness',[NODE,'tests/test_client_routing_rejected.mjs'],[bundle,ssr_html,ssr_catalog],env).check_returncode()
    original=(ROOT/'tools/client_routing_admission.py').read_text()
    def inspect(bundle,ast,reference,module=admission,actual=None):
        return module.inspect_candidate(bundle,ast,rows(inputs) if actual is None else actual,BOUND,reference,builds[str(bundle)],builds[str(bundle)])
    def rejection(bundle,ast,reference,module=admission):
        try:inspect(bundle,ast,reference,module)
        except module.AdmissionError as error:return str(error)
        raise AssertionError('actual unsupported artifact accepted')
    selected_modes=MODES[:1] if probe else MODES
    for mode,flags in selected_modes:
        r,bundle=compile(mode,[*FLAGS,*flags]);r.check_returncode();reference=catalog(mode,bundle)
        report=inspect(bundle,reference,reference);assert report['status']=='candidate-inspected-review-pending'
        (OUT/(mode+'-CANDIDATE.json')).write_text(json.dumps(report,indent=2)+'\n')
        # Self-hashed candidate identity cannot produce final authorization.
        try:admission.qualify(bundle,reference,BOUND,None,None)
        except admission.AdmissionError as error:assert str(error)=='independent-review-required'
        else:raise AssertionError('author candidate must not self-authorize')
        env={**ENV,'CLIENT_ROUTING_BUNDLE':str(bundle),'CLIENT_ROUTING_RESULTS':str(OUT/(mode+'-FIXED-RESULT.json')),'PLAYWRIGHT_CHROMIUM_EXECUTABLE':ENV.get('PLAYWRIGHT_CHROMIUM_EXECUTABLE') or shutil.which('chromium')}
        run(mode+'-fixed-browser',[NODE,'tests/test_client_routing_fixed.mjs'],[bundle],env).check_returncode()
        negatives={}
        for case in CASES:
            name=mode+'-'+case;extra=['-d:admit'+case]
            r,bad=compile(name,[*FLAGS,*flags,*extra]);r.check_returncode();ast=catalog(name,bad)
            diagnostic=rejection(bad,ast,reference);problems=admission.violations(ast,reference);assert problems
            negatives[case]=(bad,ast,diagnostic,problems)
            # Ordinary builds of the SAME supported paths still compile. Their
            # artifacts are controls, never private admission/recording claims.
            r,_=compile(name+'-ordinary',[*flags,*extra]);r.check_returncode()
        for case,(bad,ast,diagnostic,problems) in negatives.items():
            removed={(reason,*admission.site_key(reason,row)) for reason,row in problems}
            target='    return True\n';assert original.count(target)==1
            changed=original.replace(target,'    if (reason, *site_key(reason, row)) in '+repr(removed)+':\n        return False\n'+target)
            path=OUT/(mode+'-'+case+'-exact-site-guard-removed.py');path.write_text(changed)
            spec=importlib.util.spec_from_file_location('fixed_site_guard_mutant',path);mutant=importlib.util.module_from_spec(spec);spec.loader.exec_module(mutant)
            inspect(bad,ast,reference,mutant)
            witness(mode+'-'+case,bad,case)
            try:rejection(bad,ast,reference,mutant)
            except AssertionError as error:assert str(error)=='actual unsupported artifact accepted'
            else:raise AssertionError('exact site guard removal must falsify unchanged oracle')
            # ANOTHER genuine compiled artifact, not a synthetic classifier pair.
            unrelated=next((row for other,row in negatives.items() if other!=case and any((reason,*admission.site_key(reason,site)) not in removed for reason,site in row[3])),None)
            assert unrelated is not None
            other_bad,other_ast,_,_=unrelated
            other_diagnostic=rejection(other_bad,other_ast,reference,mutant)
            assert other_diagnostic
            (OUT/(mode+'-'+case+'-INVERSE.json')).write_text(json.dumps({'compile_exit':0,'diagnostic':diagnostic,'same_artifact_exact_site_guard_removal_admits':True,'unchanged_oracle_fails':True,'unrelated_actual_bundle':str(other_bad),'unrelated_actual_diagnostic':other_diagnostic,'removed_exact_sites':sorted(removed)},indent=2)+'\n')
        for case,message,method in [('RawHtml','parsed raw HTML','appendRawHtml'),('InnerHtml','parsed inner HTML','setInnerHtml')]:
            name=mode+'-'+case;r,_=compile(name,[*FLAGS,*flags,'-d:admit'+case]);assert r.returncode!=0 and message in r.stdout
            source=OUT/(name+'-refusal-removed');shutil.copytree(ROOT/'src',source/'src',ignore=shutil.ignore_patterns('yoga'))
            p=source/'src/isonim/web/web_renderer.nim';text=p.read_text();pattern='{.error: "private client routing does not admit '+message+'".}';assert text.count(pattern)==1
            p.write_text(text.replace(pattern,'=\n    r.ordinary.'+method+'('+('parent' if case=='RawHtml' else 'node')+', html)'))
            r,companion=compile(name+'-companion',[*FLAGS,*flags,'-d:admit'+case],source=source);r.check_returncode()
            witness(name+'-companion',companion,case)
            try:assert r.returncode!=0 and message in r.stdout,'actual private compiler refusal'
            except AssertionError as error:assert str(error)=='actual private compiler refusal'
            else:raise AssertionError('removed refusal must falsify unchanged oracle')
            other='InnerHtml' if case=='RawHtml' else 'RawHtml';other_message='parsed inner HTML' if case=='RawHtml' else 'parsed raw HTML'
            r,_=compile(name+'-unrelated-refusal',[*FLAGS,*flags,'-d:admit'+other],source=source);assert r.returncode!=0 and other_message in r.stdout
            r,_=compile(name+'-ordinary',[*flags,'-d:admit'+case]);r.check_returncode()
        # Effective symbols, rather than textual argv, govern the whole HMR mode.
        hmr_message='private client routing does not admit HMR mode'
        hmr_source=OUT/(mode+'-hmr-refusal-removed')
        shutil.copytree(ROOT/'src',hmr_source/'src',ignore=shutil.ignore_patterns('yoga'))
        renderer=hmr_source/'src/isonim/web/web_renderer.nim'
        text=renderer.read_text();guard='{.error: "'+hmr_message+'".}'
        assert text.count(guard)==1;renderer.write_text(text.replace(guard,'discard'))
        config_dir=OUT/(mode+'-project-config');config_dir.mkdir()
        cfg=config_dir/'config.nims';cfg.write_text('switch("define", "isonimHmr")\n')
        config_entry=config_dir/'hmr_entry.nim';config_entry.write_bytes(FIXTURE.read_bytes())
        hmr_cases=[('used',['-d:isonimHmr','-d:admitHmr'],FIXTURE,None),('unused',['-d:isonimHmr'],FIXTURE,None),('alias',['--define:isonimHmr'],FIXTURE,None),('config',[],config_entry,cfg)]
        for label,extra,entry,config in hmr_cases:
            name=mode+'-Hmr-'+label
            r,_=compile(name,[*FLAGS,*flags,*extra],fixture=entry,project_config=config)
            assert r.returncode!=0 and hmr_message in r.stdout
            r,companion=compile(name+'-companion',[*FLAGS,*flags,*extra],fixture=entry,source=hmr_source,project_config=config);r.check_returncode()
            if label=='used':witness(name,companion,'Hmr')
            else:
                env={**ENV,'CLIENT_ROUTING_BUNDLE':str(companion),'CLIENT_ROUTING_RESULTS':str(OUT/(name+'-NATIVE-WITNESS.json')),'PLAYWRIGHT_CHROMIUM_EXECUTABLE':ENV.get('PLAYWRIGHT_CHROMIUM_EXECUTABLE') or shutil.which('chromium')}
                run(name+'-native-witness',[NODE,'tests/test_client_routing_fixed.mjs'],[companion],env).check_returncode()
            try:assert r.returncode!=0 and hmr_message in r.stdout,'actual whole-HMR compiler refusal'
            except AssertionError as error:assert str(error)=='actual whole-HMR compiler refusal'
            else:raise AssertionError('HMR guard removal must falsify unchanged oracle')
            r,_=compile(name+'-unrelated-refusal',[*FLAGS,*flags,*extra,'-d:admitRawHtml'],fixture=entry,source=hmr_source,project_config=config)
            assert r.returncode!=0 and 'parsed raw HTML' in r.stdout
            r,_=compile(name+'-ordinary',[*flags,*extra],fixture=entry,project_config=config);r.check_returncode()
        # Identical output cannot authorize different/missing build identities.
        for kind,old,actual_build,bound_build in [
            ('missing','if not actual_build or not bound_build:',None,None),
            ('argv','if actual_build != bound_build:',{**builds[str(bundle)],'argv':[*builds[str(bundle)]['argv'],'-d:isonimHmr']},builds[str(bundle)]),
            ('config','if actual_build != bound_build:',{**builds[str(bundle)],'loaded_configs':[{**row,'sha256':'0'*64} for row in builds[str(bundle)]['loaded_configs']]},builds[str(bundle)])]:
            def build_oracle(module):
                try:module.inspect_candidate(bundle,reference,BOUND,BOUND,reference,actual_build,bound_build)
                except module.AdmissionError as error:assert str(error)==('missing' if kind=='missing' else 'unknown')+'-build-descriptor'
                else:raise AssertionError('unknown build accepted')
            build_oracle(admission)
            assert original.count(old)==1
            path=OUT/(mode+'-'+kind+'-build-guard-removed.py');path.write_text(original.replace(old,'if False:'))
            spec=importlib.util.spec_from_file_location('build_guard_mutant',path);mutant=importlib.util.module_from_spec(spec);spec.loader.exec_module(mutant)
            mutant.inspect_candidate(bundle,reference,BOUND,BOUND,reference,actual_build,bound_build)
            try:build_oracle(mutant)
            except AssertionError as error:assert str(error)=='unknown build accepted'
            else:raise AssertionError('build guard removal must falsify unchanged oracle')
            unrelated=negatives['Bracket'];unrelated_diagnostic=rejection(unrelated[0],unrelated[1],reference,mutant);assert unrelated_diagnostic
            (OUT/(mode+'-'+kind+'-BUILD-INVERSE.json')).write_text(json.dumps({'same_artifact':str(bundle),'output_sha256':sha(bundle),'actual_build':actual_build,'bound_build':bound_build,'exact_guard':old,'unchanged_oracle_fails':True,'unrelated_actual_bundle':str(unrelated[0]),'unrelated_diagnostic':unrelated_diagnostic},indent=2)+'\n')
        # Unknown actual input and compiled-output drift have their own guards.
        for kind,old in [('source','if actual_inputs != bound_inputs:'),('output',"if digest(raw) != catalog['output_sha256']:")]:
            actual=[*BOUND,{'path':'unknown-source','bytes':0,'sha256':'unknown'}] if kind=='source' else BOUND
            ast=reference if kind=='source' else {**reference,'output_sha256':'0'*64}
            def identity_oracle(module):
                try:inspect(bundle,ast,reference,module,actual)
                except module.AdmissionError as error:assert str(error)=='unknown-'+('source-input' if kind=='source' else 'compiled-output')
                else:raise AssertionError('unknown identity accepted')
            identity_oracle(admission)
            path=OUT/(mode+'-'+kind+'-identity-guard-removed.py');assert original.count(old)==1;path.write_text(original.replace(old,'if False:'))
            spec=importlib.util.spec_from_file_location('identity_guard_mutant',path);mutant=importlib.util.module_from_spec(spec);spec.loader.exec_module(mutant)
            inspect(bundle,ast,reference,mutant,actual)
            try:identity_oracle(mutant)
            except AssertionError as error:assert str(error)=='unknown identity accepted'
            else:raise AssertionError('actual identity guard removal must falsify unchanged oracle')
            unrelated=negatives['Bracket'];assert rejection(unrelated[0],unrelated[1],reference,mutant)
        assert rows(inputs)==BOUND
    (OUT/'INPUTS-AFTER.json').write_text(json.dumps(BOUND,indent=2)+'\n')
    (OUT/'RESULT.json').write_text(json.dumps({'modes':len(selected_modes),'probe_only':probe,'candidate_inspection':'PASS','independent_qualification':'PENDING NEW REVIEW; never self-authorized','unsupported_paths_per_mode':len(CASES)+6,'all_same_artifact_exact_guard_inverses':True,'all_unrelated_controls_are_actual_compiled_artifacts':True},indent=2)+'\n')
    print('routing AST candidate inspection PASS:'+str(len(selected_modes))+' modes; independently reviewed qualification PENDING',flush=True)
    return OUT


def main():
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('--probe',action='store_true',help='diagnostic default-mode pairs only; never full qualification')
    args=parser.parse_args();qualify_routing_admission(args.probe)


if __name__=='__main__':
    main()
