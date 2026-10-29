#!/usr/bin/env python3
"""Actual fixed timers primitive qualification. No missing-artifact skips.

Every invocation retains exclusive compiler caches, current full inverse sources,
fixtures, generated JS and logs. Explicit contexts cannot reuse shared outputs.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
artifact = os.environ.get('CT_ARTIFACT')
if not artifact:
    raise SystemExit('CT_ARTIFACT required: actual installed owner integration cannot skip')
assert (Path(artifact) / 'packages/boundary-shim/dist/browser/recorder.js').is_file(), 'actual installed Recorder required'
parent = root / 'build/record-timers-inverses'
parent.mkdir(parents=True, exist_ok=True)
out = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
print('retained qualification directory: ' + str(out), flush=True)
env = dict(os.environ)
env.setdefault('PLAYWRIGHT_CHROMIUM_EXECUTABLE', shutil.which('chromium') or '')
base = ['-d:isonimInternalRecordTimers', '-d:isonimInternalRecordClocks']

def compile_js(name, fixture, flags=(), source=None, reject=False):
    output = out / (name + '.js')
    cmd = ['nim', 'js', *flags]
    if source:
        cmd += ['--path:' + str(source), '--path:' + str(root.parent / 'nim-everywhere/src')]
    cmd += ['--nimcache:' + str(out / 'nimcache' / name), '--out:' + str(output), str(fixture)]
    p = subprocess.run(cmd, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / (name + '-compile.log')).write_text(p.stdout)
    (out / (name + '-command.txt')).write_text(repr(cmd) + '\nexit: ' + str(p.returncode) + '\n')
    print(p.stdout, flush=True)
    if reject:
        assert p.returncode != 0 and 'RawNondet' in p.stdout and 'unlisted effect' in p.stdout, 'exact RawNondet ceiling rejection'
    else:
        assert p.returncode == 0, 'actual source must compile before semantic qualification: ' + name
    return output


for boundary in [[],['-d:timerRaw'],['-d:timerCancel'],['-d:timerRaw','-d:timerCancel']]:
    label='-'.join(boundary) or 'export'
    compile_js('effect-'+label,'tests/fixtures/record_timers_effect.nim',[*base,*boundary])
    compile_js('reject-'+label,'tests/fixtures/record_timers_effect.nim',[*base,*boundary,'-d:timerReject'],reject=True)
for name,flags in [('default',[]),('recordable',['-d:isonimRecordable'])]:
    empty=compile_js('omission-'+name,'tests/fixtures/record_timers_omission.nim',flags)
    assert 'RecordTimerPrimitives' not in empty.read_text() and 'boundary-shim' not in empty.read_text()
    subprocess.run(['node',str(empty)],check=True)
    for suffix,extra in [('ordinary',[]),('internal',base)]:
        cmd=['nim','c',*flags,*extra,'--nimcache:'+str(out/'nimcache'/('c-'+name+suffix)),'--out:'+str(out/('c-'+name+suffix)),'tests/fixtures/record_timers_omission.nim']
        p=subprocess.run(cmd,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        (out/('c-'+name+suffix+'.log')).write_text(repr(cmd)+'\n'+p.stdout)
        assert p.returncode==0
        subprocess.run([str(out/('c-'+name+suffix))],check=True)
lazy=compile_js('import','tests/fixtures/record_timers_import.nim',base)
subprocess.run(['node',str(lazy)],check=True)
context=compile_js('context','tests/fixtures/replay_reads_context.nim')
env['TIMER_CONTEXT']=str(context)
replay=compile_js('replay','tests/fixtures/record_timers_replay.nim',['-d:isonimInternalReplayReads'])
companion=compile_js('companion','tests/fixtures/record_timers.nim',base)
env['TIMER_COMPANION']=str(companion)
def browser(name,js,rp,inverse=None,assertion=None):
    e={**env,'TIMER_BUNDLE':str(js),'TIMER_REPLAY':str(rp),'TIMER_RESULTS':str(out/(name+'-results.jsonl'))}
    if inverse:e['TIMER_INVERSE']=inverse
    p=subprocess.run(['node','tests/test_record_timers_owner.mjs'],cwd=root,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (out/(name+'-browser.log')).write_text(p.stdout);print(p.stdout,flush=True)
    if inverse:
        assert 'timer companion positive: real Record -> strict codec -> public Replay DONE' in p.stdout
        assert p.returncode==1 and 'AssertionError [ERR_ASSERTION]: timer semantic: '+assertion in p.stdout,'precise compiled semantic inverse: '+name
    else:p.check_returncode()
for name,flags in [('default',[]),('recordable',['-d:isonimRecordable']),('release',['-d:release']),('recordable-release',['-d:isonimRecordable','-d:release'])]:
    js=compile_js('timers-'+name,'tests/fixtures/record_timers.nim',[*base,*flags])
    rp=compile_js('replay-'+name,'tests/fixtures/record_timers_replay.nim',['-d:isonimInternalReplayReads',*flags])
    browser(name,js,rp)
original=(root/'src/isonim/core/private/record_timers.nim').read_text()
mutations={
 'omit':("c.rec.emit('TaskReg',{task_id:task,kind:1,delay_ms:d});",'', 'exact TaskReg count'),
 'task':('c.rec.task(task,1);','', 'task before callback'),
 'kind':('task_id:task,kind:1,delay_ms:d','task_id:task,kind:2,delay_ms:d', 'timeout kind'),
 'counter':('var task=c.rec.nextTaskId();','var task=1n;', 'actual shared owner namespace'),
 'delay':('kind:1,delay_ms:d','kind:1,delay_ms:d+1', 'normalized delay'),
 'live':('c.set.call(c.window,run,d)','c.window.setTimeout(run,d)', 'captured scheduling'),
 'cancel':('c.clear.call(c.window,h)','c.clear.call(c.window,0)', 'cancelled callback remains absent'),
 'guard':('return forward();};var handle','return c.rec.guard(forward);};var handle','callback error delivered outside guard'),
}
def source_copy(name,text):
    d=out/name;d.mkdir();source=d/'src';shutil.copytree(root/'src',source)
    (source/'isonim/core/private/record_timers.nim').write_text(text)
    fixtures=d/'tests/fixtures';fixtures.mkdir(parents=True)
    for f in ['record_timers.nim','record_timers_effect.nim']:shutil.copyfile(root/'tests/fixtures'/f,fixtures/f)
    return source,fixtures
for name,(old,new,assertion) in mutations.items():
    assert original.count(old)==1,name
    source,fixtures=source_copy(name,original.replace(old,new,1))
    js=compile_js('inverse-'+name,fixtures/'record_timers.nim',base,source)
    browser('inverse-'+name,js,replay,name,assertion)
    if name=='cancel':browser('inverse-cancel-lifecycle',js,replay,'cancel-lifecycle','nested cancelled callback remains absent after native fence')
    print('compiled timer inverse '+name+': exact semantic rejection PASS',flush=True)
for name,text,reject in [('inferred',original.replace(' {.tags: [RawNondet].}',''),True),('combined',original.replace(' {.tags: [RawNondet].}','').replace(', tags: [RawNondet]',''),False)]:
    source,fixtures=source_copy('effect-'+name,text)
    for boundary in [[],['-d:timerRaw'],['-d:timerCancel'],['-d:timerRaw','-d:timerCancel']]:
        compile_js(name+'-'.join(boundary),fixtures/'record_timers_effect.nim',[*base,*boundary,'-d:timerReject'],source,reject=reject)
missing=dict(env);missing.pop('CT_ARTIFACT',None)
p=subprocess.run(['python3',str(Path(__file__))],cwd=root,env=missing,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
(out/'missing-artifact.log').write_text(p.stdout);assert p.returncode!=0 and 'CT_ARTIFACT required' in p.stdout
missing={**env,'TIMER_BUNDLE':str(companion),'TIMER_REPLAY':str(replay)};missing.pop('TIMER_CONTEXT',None)
p=subprocess.run(['node','tests/test_record_timers_owner.mjs'],cwd=root,env=missing,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
(out/'missing-context.log').write_text(p.stdout);assert p.returncode==1 and 'TIMER_CONTEXT required' in p.stdout
print('timer missing-artifact/context fail closed PASS',flush=True)
