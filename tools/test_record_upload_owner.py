#!/usr/bin/env python3
"""Real owner upload bridge qualification; no optional artifact/context skips.

Supported compiler metadata discovery is retained; every semantic compiler and
browser invocation retains command, exit, output and its prebound source hash. The actual local server is the permitted ingest
stub; no owner codec, batching, scheduler or runtime is mocked.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
artifact = os.environ.get('CT_ARTIFACT')
if not artifact:
    raise SystemExit('CT_ARTIFACT required: actual installed owner integration cannot skip')
assert (Path(artifact) / 'packages/runtime-browser/dist/batch-transport.js').is_file()
parent = root / 'build/record-upload-inverses'
parent.mkdir(parents=True, exist_ok=True)
out = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
print('retained qualification directory: ' + str(out), flush=True)
env = dict(os.environ)
# Only this driver chooses bounded inverse modes; inherited overrides cannot
# silently narrow the mandatory baseline gate.
env.pop('UPLOAD_MODE', None)
env.pop('UPLOAD_COMPANION', None)
env['PLAYWRIGHT_CHROMIUM_EXECUTABLE'] = env.get('PLAYWRIGHT_CHROMIUM_EXECUTABLE') or shutil.which('chromium') or ''
assert Path(env['PLAYWRIGHT_CHROMIUM_EXECUTABLE']).is_file(), 'actual Chromium required'
base = ['-d:isonimInternalRecordUpload', '-d:isonimInternalRecordClocks']
module = root / 'src/isonim/core/private/record_upload.nim'
original = module.read_text()

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

# Retain supported compiler metadata discovery separately. Its selected engine,
# standard library and reported configuration files are bound before semantic
# compilation; campaign/host-specific extra bindings belong outside this gate.
nim_path = Path(shutil.which('nim') or '')
assert nim_path.is_file(), 'actual Nim required'
dump_command = [str(nim_path), 'dump', '--dump.format:json', '--hint:Conf:on',
                'tests/fixtures/record_upload.nim']
(out/'NIM-DUMP-BEFORE.json').write_text(json.dumps({
    'command': dump_command, 'tool': str(nim_path.resolve()),
    'sha256': sha(nim_path.resolve())}, indent=2)+'\n')
dump = subprocess.run(dump_command, cwd=root, env=env, text=True,
                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
(out/'nim-dump.stdout').write_text(dump.stdout)
(out/'nim-dump.stderr').write_text(dump.stderr)
(out/'NIM-DUMP-EXIT.json').write_text(json.dumps({'exit':dump.returncode})+'\n')
assert dump.returncode == 0, 'supported Nim metadata discovery must succeed'
nim_metadata = json.loads(dump.stdout)
nim_engine = Path(nim_metadata['nimExe'])
nim_library = Path(nim_metadata['libpath'])
assert nim_engine.is_file() and nim_library.is_dir(), 'selected Nim inputs required'
config_files = [Path(name) for name in re.findall(
    r"used config file '([^']+)'", dump.stderr)]

# Full selected source/dependency inputs. Package roots are selected by the
# supplied supported artifact; optional esbuild platforms are enumerated rather
# than naming a host architecture or a fixed store location.
inputs = []
directories = [root/'src', root.parent/'nim-everywhere/src', root/'tests/fixtures',
               Path(artifact)/'packages', root/'tests/browser/node_modules',
               Path(artifact)/'node_modules/esbuild',
               Path(artifact)/'node_modules/@esbuild', nim_library]
for directory in directories:
    assert directory.is_dir(), 'required selected input directory: '+str(directory)
    for p in sorted(directory.resolve().rglob('*')):
        if p.is_file() and (directory.name != 'packages' or
                            ('dist' in p.parts and p.suffix in ['.js','.json'])):
            inputs.append({'path':str(p),'sha256':sha(p),'size':p.stat().st_size})
for p in [Path(__file__), root/'tests/test_record_upload_owner.mjs', root/'Justfile',
          nim_engine, *config_files]:
    assert p.is_file(), 'required selected input file: '+str(p)
    inputs.append({'path':str(p),'sha256':sha(p),'size':p.stat().st_size})
for tool in ['nim','node','python3','chromium']:
    found=env['PLAYWRIGHT_CHROMIUM_EXECUTABLE'] if tool=='chromium' else shutil.which(tool)
    assert found, tool+' required'
    p=Path(found).resolve()
    inputs.append({'tool':tool,'path':str(p),'sha256':sha(p)})
(out/'INPUTS-BEFORE.json').write_text(json.dumps(inputs,indent=2)+'\n')

def invoke(name,cmd,e=None,candidate=module):
    (out/(name+'-BEFORE.json')).write_text(json.dumps({'command':cmd,'cwd':str(root),'candidate':str(candidate),'sha256':sha(candidate),'inputs_sha256':sha(out/'INPUTS-BEFORE.json')},indent=2)+'\n')
    p=subprocess.run(cmd,cwd=root,env=e or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (out/(name+'.log')).write_text(p.stdout)
    (out/(name+'-EXIT.json')).write_text(json.dumps({'exit':p.returncode})+'\n')
    print(p.stdout,flush=True)
    return p

def compile_js(name,fixture,flags=(),source=None,reject=False):
    output=out/(name+'.js')
    cmd=['nim','js',*flags]
    candidate=module
    if source:
        cmd+=['--path:'+str(source),'--path:'+str(root.parent/'nim-everywhere/src')]
        candidate=source/'isonim/core/private/record_upload.nim'
    cmd+=['--nimcache:'+str(out/'nimcache'/name),'--out:'+str(output),str(fixture)]
    p=invoke(name+'-compile',cmd,candidate=candidate)
    if reject:
        boundary=int(next((f.split('=')[1] for f in flags if f.startswith('-d:uploadBoundary=')), '0'))
        names=[('newInternalRecordUpload','prepare'),('recordUploadSink','sinkRaw'),('attachRecordUploadRecorder','attachRaw'),('recordUploadCompletion','completionRaw'),('recordUploadConsent','consentRaw'),('recordUploadFlush','flushRaw'),('recordUploadStatus','statusRaw')]
        expected=names[boundary][1 if '-d:uploadRaw' in flags else 0]
        assert p.returncode!=0 and 'RawNondet' in p.stdout and 'unlisted effect' in p.stdout and ('Error: '+expected+'(') in p.stdout, 'exact named RawNondet ceiling rejection: '+expected
    else: assert p.returncode==0,'actual source must compile before semantics: '+name
    return output

context=compile_js('context','tests/fixtures/replay_reads_context.nim')
env['UPLOAD_CONTEXT']=str(context)

def browser(name,js,mode=None,assertion=None,candidate=module):
    e={**env,'UPLOAD_BUNDLE':str(js),'UPLOAD_RESULTS':str(out/(name+'-results.json'))}
    if mode:e['UPLOAD_MODE']=mode
    if assertion:e['UPLOAD_COMPANION']=str(baseline)
    p=invoke(name+'-browser',['node','tests/test_record_upload_owner.mjs'],e,candidate)
    if assertion:
        assert 'upload inverse actual baseline companion PASS' in p.stdout
        assert p.returncode==1 and 'AssertionError [ERR_ASSERTION]: upload semantic: '+assertion in p.stdout,'precise compiled semantic inverse: '+name
    else: p.check_returncode()

for name,flags in [('default',[]),('recordable',['-d:isonimRecordable']),('release',['-d:release']),('recordable-release',['-d:isonimRecordable','-d:release'])]:
    js=compile_js('upload-'+name,'tests/fixtures/record_upload.nim',[*base,*flags])
    browser(name,js)
    if name=='default':baseline=js

for name,flags in [('ordinary',[]),('recordable',['-d:isonimRecordable'])]:
    js=compile_js('omission-'+name,'tests/fixtures/record_upload_omission.nim',flags)
    assert 'RecordUploadPrimitives' not in js.read_text() and 'runtime-browser' not in js.read_text()
    invoke('omission-'+name+'-node',['node',str(js)]).check_returncode()
    for label,internal in [('normal',[]),('internal',base)]:
        output=out/('native-'+name+'-'+label)
        invoke('native-'+name+'-'+label,['nim','c',*flags,*internal,'--nimcache:'+str(out/'nimcache'/output.name),'--out:'+str(output),'tests/fixtures/record_upload_omission.nim']).check_returncode()
        invoke(output.name+'-run',[str(output)]).check_returncode()
lazy=compile_js('lazy','tests/fixtures/record_upload_import.nim',base)
invoke('lazy-node',['node',str(lazy)]).check_returncode()
for boundary in range(7):
    for raw in [[],['-d:uploadRaw']]:
        label=('raw' if raw else 'export')+'-'+str(boundary)
        flags=[*base,*raw,'-d:uploadBoundary='+str(boundary)]
        compile_js('effect-'+label,'tests/fixtures/record_upload_effect.nim',flags)
        compile_js('reject-'+label,'tests/fixtures/record_upload_effect.nim',[*flags,'-d:uploadReject'],reject=True)

mutations={
 'config-rewriter':('Object.assign({},options,{window:w','Object.assign({},options,{onConfig:undefined,window:w','scrub','held frame owner scrubbing'),
 'duplicate-end':('c.completion=c.transport.end(unloading,frame);','c.transport.append(frame,undefined);c.completion=c.transport.end(unloading,frame);','basic','exact forwarding order'),
 'live-fetch':('originals:o,onDisabled:','originals:Object.assign({},o,{fetch:w.fetch}),onDisabled:','basic','captured transport originals'),
 'fallback':('originals:o,onDisabled:','originals:{},onDisabled:','basic','supplied native originals used'),
 'unloading':('c.transport.end(unloading,frame)','c.transport.end(false,frame)','unloading','exact End unloading forwarding'),
 'seq':('c.transport.append(frame,seq);','c.transport.append(frame,undefined);','basic','exact native sequence identity'),
 'append':('c.transport.append(frame,seq);','if(seq===undefined)c.transport.append(frame,seq);','basic','exact forwarding order'),
 'endframe':('c.transport.end(unloading,frame)','c.transport.end(unloading)','basic','exact native frame identity'),
 'completion':('c.completion=c.transport.end(unloading,frame);','c.transport.end(unloading,frame);c.completion=Promise.resolve();','delayed','actual stable completion promise'),
 'halt':('c.transport.halt();','void 0;','fault','fault sink halt forwarding'),
 'sync-off':("if(c.transport.status().state==='off')r.halt();",'','invalid-id','disabled recorder halted'),
 'async-off':('if(c.rec)c.rec.halt();','', 'disabled','disabled recorder halted'),
 'receiver':('callback.call(this,reason)','callback(reason)','disabled','disabled callback receiver/count'),
}
for name,(old,new,mode,assertion) in mutations.items():
    assert original.count(old)==1,name
    d=out/('inverse-'+name);source=d/'src';shutil.copytree(root/'src',source)
    candidate=source/'isonim/core/private/record_upload.nim';candidate.write_text(original.replace(old,new,1))
    fixtures=d/'tests/fixtures';fixtures.mkdir(parents=True)
    for f in ['record_upload.nim','record_upload_effect.nim']:shutil.copyfile(root/'tests/fixtures'/f,fixtures/f)
    js=compile_js('inverse-'+name,fixtures/'record_upload.nim',base,source)
    browser('inverse-'+name,js,mode,assertion,candidate)
    print('compiled upload inverse '+name+': exact semantic rejection PASS',flush=True)
pairs=[('newInternalRecordUpload','prepare'),('recordUploadSink','sinkRaw'),('attachRecordUploadRecorder','attachRaw'),('recordUploadCompletion','completionRaw'),('recordUploadConsent','consentRaw'),('recordUploadFlush','flushRaw'),('recordUploadStatus','statusRaw')]

def remove_tag(text, name, raw=False):
    start=text.index('  proc '+name)
    end=text.find('\n  proc ',start+1)
    if end<0:end=len(text)
    body=text[start:end]
    old=', tags: [RawNondet]' if raw else ' {.tags: [RawNondet].}'
    assert body.count(old)==1,(name,old)
    return text[:start]+body.replace(old,'',1)+text[end:]

for boundary,(export,helper) in enumerate(pairs):
    inferred=remove_tag(original,export)
    for name,text,reject in [('inferred',inferred,True),('combined',remove_tag(inferred,helper,True),False)]:
        d=out/('effect-'+name+'-'+str(boundary));source=d/'src';shutil.copytree(root/'src',source)
        (source/'isonim/core/private/record_upload.nim').write_text(text)
        fixtures=d/'tests/fixtures';fixtures.mkdir(parents=True)
        shutil.copyfile(root/'tests/fixtures/record_upload_effect.nim',fixtures/'record_upload_effect.nim')
        compile_js(name+'-'+str(boundary),fixtures/'record_upload_effect.nim',[*base,'-d:uploadReject','-d:uploadBoundary='+str(boundary)],source,reject=reject)

missing=dict(env);missing.pop('CT_ARTIFACT',None)
p=invoke('missing-artifact',['python3',str(Path(__file__))],missing)
assert p.returncode!=0 and 'CT_ARTIFACT required' in p.stdout
missing={**env,'UPLOAD_BUNDLE':str(js),'UPLOAD_RESULTS':str(out/'missing-results.json')};missing.pop('UPLOAD_CONTEXT',None)
p=invoke('missing-context',['node','tests/test_record_upload_owner.mjs'],missing)
assert p.returncode==1 and 'UPLOAD_CONTEXT required' in p.stdout
final=compile_js('final-baseline','tests/fixtures/record_upload.nim',base)
browser('final-baseline',final)
assert module.read_text()==original
for item in inputs:
    assert sha(Path(item['path']))==item['sha256'], 'input changed during qualification: '+item['path']
(out/'INPUTS-AFTER.json').write_text(json.dumps(inputs,indent=2)+'\n')
print('upload full qualification PASS',flush=True)
