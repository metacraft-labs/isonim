#!/usr/bin/env python3
"""Qualify compiled private tripwires against installed owner and real Chromium.

Use the documented dev shell, CT_ARTIFACT and installed Playwright. All outputs
are retained; missing tools/artifacts are hard failures. No provisioning occurs.
"""
from pathlib import Path
import hashlib,json,os,re,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parent.parent
MODULE=ROOT/'src/isonim/core/private/record_refusals.nim'
ARTIFACT=Path(os.environ.get('CT_ARTIFACT',''))
assert os.environ.get('CT_ARTIFACT'),'CT_ARTIFACT required; owner gate cannot skip'
assert (ARTIFACT/'packages/boundary-shim/dist/browser/seams-refusals.js').is_file(),'installed refusal owner required'
ENV=dict(os.environ)
ENV.pop('REFUSALS_INVERSE',None)
ENV['PLAYWRIGHT_CHROMIUM_EXECUTABLE']=ENV.get('PLAYWRIGHT_CHROMIUM_EXECUTABLE') or shutil.which('chromium') or ''
assert Path(ENV['PLAYWRIGHT_CHROMIUM_EXECUTABLE']).is_file(),'actual Chromium required'
PARENT=ROOT/'build/record-refusals-qualification';PARENT.mkdir(parents=True,exist_ok=True)
OUT=Path(tempfile.mkdtemp(prefix='run-',dir=PARENT));print('retained qualification directory: '+str(OUT),flush=True)
FLAGS=['-d:isonimInternalRecordRefusals']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def run(name,cmd,env=ENV,candidate=MODULE):
 (OUT/(name+'-BEFORE.json')).write_text(json.dumps(dict(command=cmd,cwd=str(ROOT),candidate=str(candidate),sha256=sha(candidate)),indent=2)+'\n')
 r=subprocess.run(cmd,cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (OUT/(name+'.log')).write_text(r.stdout);(OUT/(name+'-EXIT.json')).write_text(json.dumps(dict(exit=r.returncode))+'\n')
 print(name+': exit '+str(r.returncode),flush=True)
 if r.returncode:print(r.stdout,flush=True)
 return r
# Bind metadata tooling before its first invocation. Standard library and
# supported nimExe are then discovered using compiler metadata, not path guesses.
nim=Path(shutil.which('nim') or '');assert nim.is_file(),'actual Nim required'
(OUT/'NIM-DUMP-BEFORE.json').write_text(json.dumps(dict(path=str(nim.resolve()),sha256=sha(nim.resolve())))+'\n')
r=subprocess.run([str(nim),'dump','--dump.format:json','--hint:Conf:on','tests/fixtures/record_refusals.nim'],cwd=ROOT,env=ENV,text=True,capture_output=True)
(OUT/'nim-dump.stdout').write_text(r.stdout);(OUT/'nim-dump.stderr').write_text(r.stderr);assert r.returncode==0,'supported metadata discovery required'
metadata=json.loads(r.stdout);inputs=[]
for directory in [ROOT/'src',ROOT/'tests/fixtures',ROOT.parent/'nim-everywhere/src',ROOT/'tests/browser/node_modules',ARTIFACT/'packages',ARTIFACT/'node_modules/esbuild',ARTIFACT/'node_modules/@esbuild',Path(metadata['libpath'])]:
 assert directory.is_dir(),str(directory)+' required'
 for p in sorted(directory.resolve().rglob('*')):
  if p.is_file():inputs.append(dict(path=str(p),size=p.stat().st_size,sha256=sha(p)))
for p in [Path(__file__),ROOT/'tests/test_record_refusals_owner.mjs',ROOT/'Justfile',Path(metadata['nimExe']),*[Path(x) for x in re.findall(r"used config file '([^']+)'",r.stderr)]]:
 assert p.is_file();inputs.append(dict(path=str(p),size=p.stat().st_size,sha256=sha(p)))
for tool in ['nim','node','python3','chromium']:
 p=Path(ENV['PLAYWRIGHT_CHROMIUM_EXECUTABLE'] if tool=='chromium' else shutil.which(tool) or '').resolve();assert p.is_file(),tool+' required';inputs.append(dict(path=str(p),sha256=sha(p),tool=tool))
package_metadata=[]
for name in ['package.json','package-lock.json','pnpm-lock.yaml','yarn.lock','node_modules/.package-lock.json']:
 p=ARTIFACT/name;package_metadata.append(dict(path=str(p),exists=p.is_file(),sha256=sha(p) if p.is_file() else None))
 if p.is_file():inputs.append(dict(path=str(p),size=p.stat().st_size,sha256=sha(p)))
(OUT/'PACKAGE-METADATA-BEFORE.json').write_text(json.dumps(package_metadata,indent=2)+'\n')
(OUT/'INPUTS-BEFORE.json').write_text(json.dumps(inputs,indent=2)+'\n')
def compile(name,fixture='tests/fixtures/record_refusals.nim',flags=()):
 out=OUT/(name+'.js');run(name+'-compile',['nim','js',*flags,'--nimcache:'+str(OUT/'nimcache'/name),'--out:'+str(out),fixture]).check_returncode();return out
def browser(name,bundle,inverse=None,candidate=MODULE):
 env={**ENV,'REFUSALS_BUNDLE':str(bundle),'REFUSALS_RESULTS':str(OUT/(name+'-results.json'))}
 if inverse:env['REFUSALS_INVERSE']=inverse
 return run(name+'-browser',['node','tests/test_record_refusals_owner.mjs'],env,candidate)
for name,flags in [('default',[]),('recordable',['-d:isonimRecordable']),('release',['-d:release']),('recordable-release',['-d:release','-d:isonimRecordable']),('strict',['-d:isonimStrictNondet'])]:
 browser(name,compile(name,flags=[*FLAGS,*flags])).check_returncode()
compile('effect-positive','tests/fixtures/record_refusals_effect.nim',FLAGS)
def rejection(name,fixture,flags,candidate=MODULE):
 r=run(name,['nim','js',*flags,'-d:refusalsReject','--out:'+str(OUT/(name+'.js')),str(fixture)],candidate=candidate)
 assert r.returncode!=0 and 'RawNondet' in r.stdout and 'unlisted effect' in r.stdout and 'Error: installInternalRecordRefusals(' in r.stdout,'semantic: actual direct binding rejects RawNondet ceiling'
rejection('effect-rejection','tests/fixtures/record_refusals_effect.nim',FLAGS)
for name,flags in [('ordinary',[]),('recordable',['-d:isonimRecordable']),('release',['-d:release']),('direct',['-d:isonimDirectNondet'])]:
 a=compile('omission-'+name,'tests/fixtures/record_refusals_omission.nim',flags)
 b=compile('omission-'+name+'-internal','tests/fixtures/record_refusals_omission.nim',[*flags,*FLAGS])
 assert a.read_bytes()==b.read_bytes(),'unused private import/define byte identity'
 for token in ['installInternalRecordRefusals','patchRefusals','boundary-shim']:assert token not in a.read_text(),'private owner omitted '+token
 run('omission-'+name+'-run',['node',str(a)]).check_returncode()
 out=OUT/('native-'+name);cache=OUT/'nativecache'/name
 run('native-'+name,['nim','c',*flags,*FLAGS,'--nimcache:'+str(cache),'--out:'+str(out),'tests/fixtures/record_refusals_omission.nim']).check_returncode();run('native-'+name+'-run',[str(out)]).check_returncode()
 emitted='\n'.join(p.read_text() for p in cache.glob('*.c'))
 assert emitted,'actual emitted native C required'
 for token in ['installInternalRecordRefusals','patchRefusals','boundary-shim']:assert token not in emitted,'native implementation omitted '+token
original=MODULE.read_text()
def isolated(name,text,fixture='record_refusals.nim',extra=()):
 directory=OUT/name;shutil.copytree(ROOT/'src',directory/'src',symlinks=True)
 source=directory/'src/isonim/core/private/record_refusals.nim';source.write_text(text)
 target=directory/'tests/fixtures'/fixture;target.parent.mkdir(parents=True);shutil.copy2(ROOT/'tests/fixtures'/fixture,target)
 differences=[]
 for p in sorted((directory/'src').rglob('*')):
  if p.is_file() and sha(p)!=sha(ROOT/'src'/p.relative_to(directory/'src')):differences.append(str(p.relative_to(directory/'src')))
 assert differences==([] if text==original else ['isonim/core/private/record_refusals.nim']),'exact actual production source inverse'
 (directory/'SOURCE-BEFORE.json').write_text(json.dumps(dict(differences=differences,fixture_sha256=sha(target),source_sha256=sha(source)),indent=2)+'\n')
 out=directory/'fixture.js';cmd=['nim','js','--skipParentCfg','--skipProjCfg','-d:nimOldCaseObjects',*FLAGS,*extra,'--path:'+str(directory/'src'),'--path:'+str(ROOT.parent/'nim-everywhere/src'),'--nimcache:'+str(directory/'nimcache'),'--out:'+str(out),str(target)]
 r=run(name+'-compile',cmd,candidate=source);return source,out,r
pairs={'omit-owner':('m.patchRefusals(c);','','semantic: exact first-use feature marker'),'remove-guard':('c.rec.guard(function(){m.patchRefusals(c);});','m.patchRefusals(c);','semantic: setup fault stays in actual Recorder.guard'),'double-owner':('m.patchRefusals(c);','m.patchRefusals(c);m.patchRefusals(c);','semantic: actual owner installer called once')}
for name,(old,new,expected) in pairs.items():
 assert original.count(old)==1,name
 source,js,r=isolated(name,original.replace(old,new));r.check_returncode()
 cp,cjs,r=isolated(name+'-companion',original);r.check_returncode()
 assert str(source) in js.read_text(),'actual compiled candidate filename required'
 emitted=js.read_text().split('function rfInstall(',1)[1].split('\nfunction rfSelected(',1)[0]
 companion=cjs.read_text().split('function rfInstall(',1)[1].split('\nfunction rfSelected(',1)[0]
 assert emitted.count('m.patchRefusals(c);')==({'omit-owner':0,'remove-guard':1,'double-owner':2}[name])
 assert companion.count('m.patchRefusals(c);')==1 and 'c.rec.guard(function(){' in companion
 assert ('c.rec.guard(function(){' in emitted)==(name!='remove-guard')
 (OUT/(name+'-EMISSION.json')).write_text(json.dumps(dict(candidate_filename=str(source),candidate_sha256=sha(source),compiled_sha256=sha(js),companion_sha256=sha(cjs),actual_install_calls=emitted.count('m.patchRefusals(c);')),indent=2)+'\n')
 # Both use exactly the same selected scenario and common assertions.
 browser(name+'-companion',cjs,name,cp).check_returncode()
 r=browser(name,js,name,source)
 assert r.returncode==1 and 'AssertionError [ERR_ASSERTION]: '+expected in r.stdout,'precise compiled semantic inverse '+name
cp,cjs,cr=isolated('tag-loss-companion',original,'record_refusals_effect.nim',['-d:refusalsReject'])
assert cr.returncode!=0 and 'RawNondet' in cr.stdout and 'unlisted effect' in cr.stdout and 'Error: installInternalRecordRefusals(' in cr.stdout,'equivalent original direct binding rejects'
source,js,r=isolated('tag-loss',original.replace(', tags: [RawNondet]',''),'record_refusals_effect.nim',['-d:refusalsReject']);r.check_returncode()
# The unchanged expected-rejection assertion must fail when the actual binding
# loses its annotation and the very same limited caller now compiles.
try:rejection('tag-loss-unchanged-rejection',OUT/'tag-loss/tests/fixtures/record_refusals_effect.nim',[*FLAGS,'--skipParentCfg','--skipProjCfg','--path:'+str(OUT/'tag-loss/src'),'--path:'+str(ROOT.parent/'nim-everywhere/src')],source)
except AssertionError as e:
 assert str(e)=='semantic: actual direct binding rejects RawNondet ceiling'
 assert json.loads((OUT/'tag-loss-unchanged-rejection-EXIT.json').read_text())['exit']==0,'tag-loss inverse requires actual successful compilation, not wrong diagnostic'
else:raise AssertionError('tag-loss inverse must falsify unchanged rejection assertion')
for row in inputs:assert sha(Path(row['path']))==row['sha256'],'selected input changed '+row['path']
(OUT/'INPUTS-AFTER.json').write_text(json.dumps(inputs,indent=2)+'\n')
print('Record refusal owner qualification PASS',flush=True)
