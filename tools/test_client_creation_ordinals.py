#!/usr/bin/env python3
"""Real compiled renderer metadata, SSR/Chromium and precise source inverses.

Requires the documented development shell and installed Playwright/Chromium.
No provisioning, fake DOM, ordinal stand-in or optional/ignored mode exists.
Every output, including failed compiler/browser attempts, remains under build/.
"""
from pathlib import Path
import hashlib,json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parent.parent
MODULE=ROOT/'src/isonim/web/web_renderer.nim'
ENV=dict(os.environ)
ENV.pop("CLIENT_ORDINALS_CASE",None)
ENV['PLAYWRIGHT_CHROMIUM_EXECUTABLE']=ENV.get('PLAYWRIGHT_CHROMIUM_EXECUTABLE') or shutil.which('chromium') or ''
assert Path(ENV['PLAYWRIGHT_CHROMIUM_EXECUTABLE']).is_file(),'required Chromium missing'
PARENT=ROOT/'build/client-creation-ordinals';PARENT.mkdir(parents=True,exist_ok=True)
OUT=Path(tempfile.mkdtemp(prefix='run-',dir=PARENT));print('retained '+str(OUT),flush=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def run(name,cmd,env=ENV,cwd=ROOT,candidate=MODULE,fixture=None):
 selected=[candidate,*([fixture] if fixture else [])]
 bindings=[dict(path=str(p),sha256=sha(p)) for p in selected]
 (OUT/(name+'-BEFORE.json')).write_text(json.dumps(dict(command=cmd,cwd=str(cwd),candidate=str(candidate),candidate_sha256=sha(candidate),actual_selected_inputs=bindings),indent=2)+'\n')
 r=subprocess.run(cmd,cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (OUT/(name+'.log')).write_text(r.stdout);(OUT/(name+'-EXIT.json')).write_text(json.dumps(dict(exit=r.returncode))+'\n');print(name+': '+str(r.returncode),flush=True)
 for row in bindings:assert sha(Path(row['path']))==row['sha256'],'selected actual candidate/fixture changed during consumer'
 (OUT/(name+'-INPUTS-AFTER.json')).write_text(json.dumps(bindings,indent=2)+'\n')
 if r.returncode:print(r.stdout,flush=True)
 return r
COMMON=['--skipParentCfg','--skipProjCfg','-d:nimOldCaseObjects','--path:'+str(ROOT.parent/'nim-everywhere/src')]
FLAGS=['-d:isonimInternalClientOrdinals']
def compile(name,fixture='client_creation_ordinals.nim',flags=(),source=ROOT,backend='js'):
 path=OUT/(name+('.js' if backend=='js' else '.exe'))
 cmd=['nim',backend,*COMMON,'--path:'+str(source/'src'),*flags,'--nimcache:'+str(OUT/'cache'/name),'--out:'+str(path),str(fixture if isinstance(fixture,Path) else ROOT/'tests/fixtures'/fixture)]
 run(name+'-compile',cmd,candidate=source/'src/isonim/web/web_renderer.nim',fixture=fixture if isinstance(fixture,Path) else ROOT/'tests/fixtures'/fixture).check_returncode();return path
ssr=compile('ssr',backend='c');html=OUT/'ssr.html';r=run('ssr-run',[str(ssr)]);r.check_returncode();html.write_text(r.stdout)
original=MODULE.read_text()
assignment='var n=c.next; var successor=n+1n; c.ordinals.set(e,n); c.next=successor; return e;'
query='var n=c.ordinals.get(e); return n===undefined ? null : n.toString(10);'
projection='      assignInternalClientCreationOrdinal(context, native)'
mutations={
 'creation-order-before-lookup':original.replace(assignment,'return e;').replace(query,'var n=c.ordinals.get(e); if(n===undefined){n=c.next;var successor=n+1n;c.ordinals.set(e,n);c.next=successor;} return n.toString(10);'),
 'created-element-has-ordinal':original.replace(assignment,'return e;'),
 'fresh-adopted-element-has-no-ordinal':original.replace('      return Element(adopted)','      when declared(context):\n        return assignInternalClientCreationOrdinal(context, Element(adopted))\n      else:\n        return Element(adopted)'),
 'native-failure-does-not-consume':original.replace('    template numberedElement(native: untyped): untyped =','    proc advance(c: InternalClientCreationOrdinals) {.importjs: "(function(c){c.next=c.next+1n;})(#)", tags:[RawNondet].}\n    template numberedElement(native: untyped): untyped =').replace(projection,'      block:\n        advance(context)\n        assignInternalClientCreationOrdinal(context, native)'),
 'production-query-is-required':original.replace(query,'return null;')}
for label,text in mutations.items():assert text!=original,label
MODES=[('default',[]),('recordable',['-d:isonimRecordable']),('direct',['-d:isonimDirectNondet']),('release',['-d:release']),('recordable-release',['-d:release','-d:isonimRecordable']),('strict',['-d:isonimStrictNondet']),('default-no-boundary-meter',['-d:isonimNoBoundaryMeter']),('recordable-no-boundary-meter',['-d:isonimRecordable','-d:isonimNoBoundaryMeter'])]
def browser(name,bundle,case=None,no_meter=False,candidate=MODULE):
 env={**ENV,'CLIENT_ORDINALS_BUNDLE':str(bundle),'CLIENT_ORDINALS_SSR':str(html),'CLIENT_ORDINALS_RESULTS':str(OUT/(name+'-results.json')),'CLIENT_NO_METER':'1' if no_meter else '0'}
 if case:env['CLIENT_ORDINALS_CASE']=case
 return run(name+'-browser',['node','tests/test_client_creation_ordinals.mjs'],env,candidate=candidate,fixture=bundle)
for mode,flags in MODES:
 bundle=compile(mode,flags=[*FLAGS,*flags]);browser(mode,bundle,no_meter='-d:isonimNoBoundaryMeter' in flags).check_returncode()
 for label,text in mutations.items():
  for kind,body in [('companion',original),('mutant',text)]:
   name=mode+'-'+label+'-'+kind;source=OUT/name;shutil.copytree(ROOT/'src',source/'src',symlinks=True)
   changed=source/'src/isonim/web/web_renderer.nim';changed.write_text(body)
   differences=[str(p.relative_to(source/'src')) for p in (source/'src').rglob('*') if p.is_file() and sha(p)!=sha(ROOT/'src'/p.relative_to(source/'src'))]
   assert differences==([] if kind=='companion' else ['isonim/web/web_renderer.nim'])
   (source/'SOURCE.json').write_text(json.dumps(dict(differences=differences,source_sha256=sha(changed),fixture_sha256=sha(ROOT/'tests/fixtures/client_creation_ordinals.nim')),indent=2)+'\n')
   bundle=compile(name,flags=[*FLAGS,*flags],source=source)
   emitted=bundle.read_text();assert 'c.ordinals.' in emitted or label=='production-query-is-required';assert 'createInternalClientElement' in emitted and 'ccCreate' in emitted
   result=browser(name,bundle,label,'-d:isonimNoBoundaryMeter' in flags,candidate=changed)
   if kind=='companion':result.check_returncode()
   else:assert result.returncode==1 and 'semantic: '+label in result.stdout,'precise production semantic inverse '+name
# Actual direct importjs declarations and inferred private-wrapper ceilings.
for mode,flags in [('default',[]),('recordable',['-d:isonimRecordable']),('no-meter',['-d:isonimNoBoundaryMeter']),('recordable-no-meter',['-d:isonimRecordable','-d:isonimNoBoundaryMeter'])]:
 compile('effect-'+mode,'client_creation_ordinals_effect.nim',[*FLAGS,*flags])
 for operation in ['Constructor','Query','Private']:
  r=run('effect-'+mode+'-reject'+operation,['nim','js',*COMMON,'--path:'+str(ROOT/'src'),*FLAGS,*flags,'-d:reject'+operation,'--out:'+str(OUT/'reject.js'),str(ROOT/'tests/fixtures/client_creation_ordinals_effect.nim')])
  assert r.returncode!=0 and 'RawNondet' in r.stdout and 'unlisted effect' in r.stdout,'actual RawNondet ceiling '+operation
 r=run('effect-'+mode+'-public',['nim','js',*COMMON,'--path:'+str(ROOT/'src'),*FLAGS,*flags,'-d:rejectPublic','--out:'+str(OUT/'public.js'),str(ROOT/'tests/fixtures/client_creation_ordinals_effect.nim')])
 if '-d:isonimNoBoundaryMeter' in flags:r.check_returncode()
 else:assert r.returncode!=0 and 'TimeEffect' in r.stdout and 'unlisted effect' in r.stdout
# Direct annotation-loss is distinct from inference through the private wrapper.
for mode,flags in [('default',[]),('recordable',['-d:isonimRecordable']),('no-meter',['-d:isonimNoBoundaryMeter']),('recordable-no-meter',['-d:isonimRecordable','-d:isonimNoBoundaryMeter'])]:
 compile('raw-assignment-'+mode,'client_creation_ordinals_raw_effect.nim',[*FLAGS,*flags])
 def raw_rejection(label,source=ROOT,fixture=ROOT/'tests/fixtures/client_creation_ordinals_raw_effect.nim'):
  r=run(label,['nim','js',*COMMON,'--path:'+str(source/'src'),*FLAGS,*flags,'-d:rejectAssignment','--out:'+str(OUT/(label+'.js')),str(fixture)],candidate=source/'src/isonim/web/web_renderer.nim',fixture=fixture)
  assert r.returncode!=0 and 'assignInternalClientCreationOrdinal' in r.stdout and 'RawNondet' in r.stdout and 'unlisted effect' in r.stdout,'actual direct assignment rejects RawNondet ceiling'
  return r
 raw_rejection('raw-assignment-reject-'+mode)
 source=OUT/('raw-tag-loss-'+mode);shutil.copytree(ROOT/'src',source/'src',symlinks=True)
 changed=source/'src/isonim/web/web_renderer.nim'
 marker='})(#,#)""", tags: [RawNondet].}'
 assert original.count(marker)==2
 changed.write_text(original.replace(marker,'})(#,#)""".}',1))
 fixture=source/'tests/fixtures/client_creation_ordinals_raw_effect.nim';fixture.parent.mkdir(parents=True);shutil.copy2(ROOT/'tests/fixtures/client_creation_ordinals_raw_effect.nim',fixture)
 compile('raw-tag-loss-'+mode,fixture,[*FLAGS,*flags,'-d:rejectAssignment'],source)
 try:raw_rejection('raw-tag-loss-unchanged-rejection-'+mode,source,fixture)
 except AssertionError as error:
  assert str(error)=='actual direct assignment rejects RawNondet ceiling'
  assert json.loads((OUT/('raw-tag-loss-unchanged-rejection-'+mode+'-EXIT.json')).read_text())['exit']==0
 else:raise AssertionError('direct annotation loss must falsify unchanged rejection')
 r=run('private-raw-only-'+mode,['nim','js',*COMMON,'--path:'+str(ROOT/'src'),*FLAGS,*flags,'-d:privateRawOnly','--out:'+str(OUT/('private-raw-'+mode+'.js')),str(ROOT/'tests/fixtures/client_creation_ordinals_effect.nim')])
 if '-d:isonimNoBoundaryMeter' in flags:r.check_returncode()
 else:assert r.returncode!=0 and 'TimeEffect' in r.stdout and 'unlisted effect' in r.stdout

for mode,flags in [('default',[]),('recordable',['-d:isonimRecordable']),('no-meter',['-d:isonimNoBoundaryMeter']),('recordable-no-meter',['-d:isonimRecordable','-d:isonimNoBoundaryMeter'])]:
 for operation,symbol in [('Constructor','newInternalClientCreationOrdinals*'),('Query','internalClientCreationOrdinal*')]:
  start=original.index('  proc '+symbol);end=original.index('  proc ',start+8)
  declaration=original[start:end];assert declaration.count(', tags: [RawNondet]')==1
  for kind,body in [('companion',original),('tag-loss',original[:start]+declaration.replace(', tags: [RawNondet]','')+original[end:])]:
   label='direct-'+operation+'-'+mode+'-'+kind;source=OUT/label;shutil.copytree(ROOT/'src',source/'src',symlinks=True);(source/'src/isonim/web/web_renderer.nim').write_text(body)
   def rejection():
    result=run(label,['nim','js',*COMMON,'--path:'+str(source/'src'),*FLAGS,*flags,'-d:reject'+operation,'--out:'+str(OUT/(label+'.js')),str(ROOT/'tests/fixtures/client_creation_ordinals_effect.nim')],candidate=source/'src/isonim/web/web_renderer.nim',fixture=ROOT/'tests/fixtures/client_creation_ordinals_effect.nim')
    assert result.returncode!=0 and 'RawNondet' in result.stdout and 'unlisted effect' in result.stdout,'actual direct '+operation+' rejects RawNondet ceiling'
   if kind=='companion':rejection()
   else:
    compile(label+'-successful-compile','client_creation_ordinals_effect.nim',[*FLAGS,*flags,'-d:reject'+operation],source)
    try:rejection()
    except AssertionError as error:
     assert str(error)=='actual direct '+operation+' rejects RawNondet ceiling'
     assert json.loads((OUT/(label+'-EXIT.json')).read_text())['exit']==0
    else:raise AssertionError('actual direct tag loss must falsify unchanged rejection')

for mode,flags in [('default',[]),('recordable',['-d:isonimRecordable']),('direct',['-d:isonimDirectNondet']),('release',['-d:release'])]:
 a=compile('omission-'+mode,'client_creation_ordinals_omission.nim',[*flags,'--warning:UnusedImport:on','--warningAsError:UnusedImport:on'])
 b=compile('omission-'+mode+'-flag','client_creation_ordinals_omission.nim',[*flags,*FLAGS,'--warning:UnusedImport:on','--warningAsError:UnusedImport:on'])
 assert a.read_bytes()==b.read_bytes(),'exact unused renderer import/flag JS bytes'
 for token in ['InternalClientCreationOrdinal','ordinals: new WeakMap','c.ordinals']:assert token not in a.read_text(),'omitted private metadata'
 env={**ENV,'CLIENT_OMISSION_A':str(a),'CLIENT_OMISSION_B':str(b),'CLIENT_OMISSION_RESULTS':str(OUT/('omission-'+mode+'-runtime.json'))}
 run('omission-'+mode+'-runtime',['node','tests/test_client_creation_ordinals_omission.mjs'],env).check_returncode()
 c=compile('native-omission-'+mode,'client_creation_ordinals_omission.nim',[*flags,*FLAGS],backend='c');run('native-omission-'+mode+'-run',[str(c)]).check_returncode()
 emitted='\n'.join(p.read_text() for p in (OUT/'cache'/('native-omission-'+mode)).rglob('*.c'))
 assert emitted,'actual emitted native C required'
 for token in ['InternalClientCreationOrdinal','ordinals: new WeakMap','c.ordinals']:
  assert token not in emitted,'private implementation absent from real native graph'
print('client creation ordinal qualification PASS:8 active modes,40 semantic mutants and40 genuine companions',flush=True)
