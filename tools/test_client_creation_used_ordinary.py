#!/usr/bin/env python3
"""Compile real USED ordinary renderer/Link calls with an unused private flag.

This guards exact compiler output, not normalized text or an import-only graph.
The causal inverse restores the production declaration placement that caused
ordinary symbols to move. Both inverse builds must compile successfully before
that same byte assertion fails. Actual C omission uses static declarations plus
an emitted-source check, without runtime assertion strings containing API names.
"""
from pathlib import Path
import hashlib,json,os,re,shutil,subprocess,tempfile

# The native fixture imports the supported common graph, not the JS-only
# renderer. Static namespace checks cover every exported private API; emitted
# C checks additionally cover the private assignment implementation marker.
NATIVE_TOKENS = (
    'InternalClientCreationOrdinals',
    'newInternalClientCreationOrdinals',
    'createInternalClientElement',
    'internalClientCreationOrdinal',
    'assignInternalClientCreationOrdinal',
)


def assert_native_omission(emitted, tokens=NATIVE_TOKENS):
    """Reject actual nonempty native C containing any private API marker."""
    assert emitted, 'native emitted C must be nonempty'
    for token in tokens:
        # Nim prefixes type names with underscore-separated C identifiers. A
        # leading alphabetic fragment denotes another API (notably the new...
        # constructor contains the type spelling), so retain underscore matches
        # while keeping each marker guard independently falsifiable.
        assert re.search(r'(?<![A-Za-z0-9])' + re.escape(token), emitted) is None, 'actual native omission: ' + token


def qualify_used_ordinary():
    """Run the exact eight-mode qualification and return its retained directory.

    Importing this module performs no qualification or artifact creation.
    """
    ROOT=Path(__file__).resolve().parent.parent
    P=ROOT/'build/client-creation-used-ordinary';P.mkdir(parents=True,exist_ok=True)
    OUT=Path(tempfile.mkdtemp(prefix='run-',dir=P));print('retained '+str(OUT),flush=True)
    ENV=dict(os.environ);NIM=Path(shutil.which('nim'));FIXTURE=ROOT/'tests/fixtures/client_creation_used_ordinary.nim'
    def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
    def rows(paths):return [{'path':str(p),'resolved':str(p.resolve()),'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(set(paths))]
    # Administrative discovery is separately bound before it runs. The discovered
    # engine/library/configuration are then bound before any compiling consumer.
    cmd=[str(NIM),'dump','--dump.format:json','--skipParentCfg','--skipProjCfg',str(FIXTURE)]
    (OUT/'NIM-DUMP-BEFORE.json').write_text(json.dumps({'command':cmd,'tool':str(NIM),'sha256':sha(NIM)})+'\n')
    dump=subprocess.run(cmd,cwd=ROOT,env=ENV,text=True,capture_output=True)
    (OUT/'nim-dump.stdout').write_text(dump.stdout);(OUT/'nim-dump.stderr').write_text(dump.stderr);dump.check_returncode()
    metadata=json.loads(dump.stdout);library=Path(metadata['libpath']);engine=Path(metadata['nimExe'])
    inputs=[Path(__file__),FIXTURE,NIM,engine,ROOT/'Justfile',ROOT/'config.nims']
    for root in [ROOT/'src',ROOT.parent/'nim-everywhere/src',library]:
     inputs.extend(p for p in root.rglob('*') if p.is_file() and 'yoga' not in p.parts)
    inputs.extend(Path(p) for p in re.findall(r"used config file '([^']+)'",dump.stderr))
    inputs.extend(p for p in [ROOT/'build/tailwind-styles.json',ROOT/'build/tailwind.css'] if p.is_file())
    for name in ['python3','cc','gcc','bash']:
     path=shutil.which(name)
     if path:inputs.append(Path(path))
    BOUND=rows(inputs);(OUT/'INPUTS-BEFORE.json').write_text(json.dumps(BOUND,indent=2)+'\n')
    COMMON=['--skipParentCfg','--skipProjCfg','-d:nimOldCaseObjects','--path:'+str(ROOT.parent/'nim-everywhere/src')]
    MODES=[('default',[]),('recordable',['-d:isonimRecordable']),('direct',['-d:isonimDirectNondet']),('release',['-d:release']),('recordable-release',['-d:release','-d:isonimRecordable']),('strict',['-d:isonimStrictNondet']),('default-no-boundary-meter',['-d:isonimNoBoundaryMeter']),('recordable-no-boundary-meter',['-d:isonimRecordable','-d:isonimNoBoundaryMeter'])]
    def run(name,cmd,source=ROOT,fixture=FIXTURE,expected_assertion=None):
     selected_paths=[source/'src/isonim/web/web_renderer.nim',source/'src/isonim/core/nondet.nim',fixture]
     selected=rows(selected_paths)
     (OUT/(name+'-BEFORE.json')).write_text(json.dumps({'command':list(map(str,cmd)),'selected':selected},indent=2)+'\n')
     r=subprocess.run(list(map(str,cmd)),cwd=ROOT,env=ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
     (OUT/(name+'.log')).write_text(r.stdout);(OUT/(name+'-EXIT.json')).write_text(json.dumps({'exit':r.returncode})+'\n');print(name+': '+str(r.returncode),flush=True)
     assert rows(selected_paths)==selected
     if r.returncode:print(r.stdout[-1800:],flush=True)
     if expected_assertion is not None:
      assert r.returncode != 0 and expected_assertion in r.stdout and 'AssertionDefect' in r.stdout, 'expected exact static omission assertion'
     else:r.check_returncode()
     return r

    def compile(name,flags,source=ROOT,backend='js',fixture=FIXTURE,expected_assertion=None):
     output=OUT/(name+('.js' if backend=='js' else '.exe'))
     run(name,[NIM,backend,*COMMON,'--path:'+str(source/'src'),*flags,'--nimcache:'+str(OUT/'cache'/name),'--out:'+str(output),fixture],source,fixture,expected_assertion);return output
    text=(ROOT/'src/isonim/web/web_renderer.nim').read_text()
    start=text.index('when defined(js) and defined(isonimInternalClientOrdinals):')
    end=text.index('    createElementBody(tag, numberedElement)\n',start)+len('    createElementBody(tag, numberedElement)\n')
    block=text[start:end].rstrip()+'\n\n';without=text[:start]+text[end:]
    a=without.index('# Private compiler declarations live after all ordinary operations below.')
    b=without.index('proc createTextNode*',a)
    restored=without[:a]+block+without[b:];assert restored!=text
    for mode,flags in MODES:
     a=compile(mode+'-ordinary',flags);b=compile(mode+'-unused-private',[*flags,'-d:isonimInternalClientOrdinals'])
     assert a.read_bytes()==b.read_bytes(),'exact USED ordinary bytes '+mode
     assert b'ordinals: new WeakMap' not in b.read_bytes(),'unused metadata omitted'
     source=OUT/(mode+'-placement-restored');shutil.copytree(ROOT/'src',source/'src',ignore=shutil.ignore_patterns('yoga'))
     (source/'src/isonim/web/web_renderer.nim').write_text(restored)
     c=compile(mode+'-inverse-ordinary',flags,source);d=compile(mode+'-inverse-unused-private',[*flags,'-d:isonimInternalClientOrdinals'],source)
     try:assert c.read_bytes()==d.read_bytes(),'exact USED ordinary bytes '+mode
     except AssertionError as error:assert str(error)=='exact USED ordinary bytes '+mode
     else:raise AssertionError('restored placement must falsify unchanged byte oracle')
     native=compile(mode+'-native-omission',[*flags,'-d:isonimInternalClientOrdinals'],backend='c');run(mode+'-native-run',[native])
     emitted='\n'.join(p.read_text() for p in (OUT/'cache'/(mode+'-native-omission')).rglob('*.c'));assert emitted
     assert_native_omission(emitted)
     (OUT/(mode+'-RESULT.json')).write_text(json.dumps({'ordinary_sha256':sha(a),'unused_private_sha256':sha(b),'exact_bytes':True,'restored_placement_compiles':True,'unchanged_byte_oracle_fails':True,'native_static_declaration_and_emitted_source_omission':True})+'\n')
    # Genuine native canaries run in the same imported common module as the
    # ordinary fixture. Compile/run the exact assertion-removal companion first;
    # then retain only an exact static AssertionDefect as the expected refusal.
    declarations = [
        'type InternalClientCreationOrdinals* = object',
        'proc newInternalClientCreationOrdinals*(): int = 0',
        'proc createInternalClientElement*(): int = 0',
        'proc internalClientCreationOrdinal*(): int = 0',
    ]
    native_flags=['-d:isonimInternalClientOrdinals']
    assert len(declarations)==4 and len(NATIVE_TOKENS)==5
    for index,(token,declaration) in enumerate(zip(NATIVE_TOKENS[:4],declarations)):
     source=OUT/('native-static-canary-'+str(index));shutil.copytree(ROOT/'src',source/'src',ignore=shutil.ignore_patterns('yoga'))
     common=source/'src/isonim/core/nondet.nim';common.write_text(common.read_text()+'\n'+declaration+'\n')
     companion=source/'ordinary_companion.nim';original=FIXTURE.read_text();guard='    doAssert not declared('+token+')\n';assert original.count(guard)==1
     companion.write_text(original.replace(guard,''))
     exe=compile('static-'+str(index)+'-companion',native_flags,source,'c',companion);run('static-'+str(index)+'-companion-run',[exe],source,companion)
     compile('static-'+str(index)+'-refusal',native_flags,source,'c',expected_assertion='not declared('+token+')')
    emitted_canaries=[]
    for index,token in enumerate(NATIVE_TOKENS):
     source=OUT/('native-emitted-canary-'+str(index));shutil.copytree(ROOT/'src',source/'src',ignore=shutil.ignore_patterns('yoga'))
     common=source/'src/isonim/core/nondet.nim'
     common.write_text(common.read_text()+'\n{.emit: "static volatile int '+token+'_omissionCanary = 0;".}\n')
     name='emitted-'+str(index);exe=compile(name,native_flags,source,'c');run(name+'-run',[exe],source)
     emitted='\n'.join(p.read_text() for p in (OUT/'cache'/name).rglob('*.c'));assert emitted
     try:assert_native_omission(emitted)
     except AssertionError as error:assert str(error)=='actual native omission: '+token
     else:raise AssertionError('actual emitted marker must fail unchanged scanner')
     remaining=tuple(t for t in NATIVE_TOKENS if t!=token)
     assert len(remaining)==4
     assert_native_omission(emitted,remaining)  # SAME compiled/run artifact.
     emitted_canaries.append((token,emitted,remaining))
    # Removing one exact guard leaves every other real marker guard alive.
    for token,emitted,remaining in emitted_canaries:
     other_token,other_emitted,_=next(row for row in emitted_canaries if row[0]!=token)
     try:assert_native_omission(other_emitted,remaining)
     except AssertionError as error:assert str(error)=='actual native omission: '+other_token
     else:raise AssertionError('unrelated emitted marker guard must remain active')
    (OUT/'NATIVE-CANARIES.json').write_text(json.dumps({'static_exports':list(NATIVE_TOKENS[:4]),'static_companions_compile_and_run':True,'exact_static_assertion_refusals':True,'emitted_markers':list(NATIVE_TOKENS),'emitted_artifacts_compile_and_run':True,'same_artifact_exact_token_removal_admits':True,'unrelated_guards_alive':True,'scope':'supported native-compatible ordinary common graph only'},indent=2)+'\n')
    assert rows(inputs)==BOUND
    (OUT/'INPUTS-AFTER.json').write_text(json.dumps(BOUND,indent=2)+'\n')
    print('USED ordinary private-flag byte regression PASS:8 modes,8 compiling production placement inverses,8 actual native omission runs',flush=True)
    return OUT


def main():
    qualify_used_ordinary()


if __name__ == "__main__":
    main()
