#!/usr/bin/env python3
"""Actual captured-native frames; all current-source inverses retain full inputs.

Native browser, installed owner, codec, run-loop and checkpoints are genuine.
Only named native/owner fault controls inject failures. Missing inputs fail closed.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
artifact = os.environ.get('CT_ARTIFACT')
if not artifact:
    raise SystemExit('CT_ARTIFACT required: actual installed frame owner cannot skip')
assert (Path(artifact) / 'packages/boundary-shim/dist/browser/recorder.js').is_file()
parent = root / 'build/record-frames-inverses'
parent.mkdir(parents=True, exist_ok=True)
out = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
print('retained qualification directory: ' + str(out), flush=True)
env = dict(os.environ)
env.setdefault('PLAYWRIGHT_CHROMIUM_EXECUTABLE', shutil.which('chromium') or '')
base = ['-d:isonimInternalRecordFrames', '-d:isonimInternalRecordTimers', '-d:isonimInternalRecordClocks']

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
        assert p.returncode == 0, 'actual current source must compile: ' + name
    return output

for boundary in [[], ['-d:frameRaw'], ['-d:frameCancel'], ['-d:frameRaw', '-d:frameCancel']]:
    label = '-'.join(boundary) or 'export'
    compile_js('effect-' + label, 'tests/fixtures/record_frames_effect.nim', [*base, *boundary])
    compile_js('reject-' + label, 'tests/fixtures/record_frames_effect.nim', [*base, *boundary, '-d:frameReject'], reject=True)
for name, flags in [('default', []), ('recordable', ['-d:isonimRecordable'])]:
    js = compile_js('omission-' + name, 'tests/fixtures/record_frames_omission.nim', flags)
    assert 'RecordFramePrimitives' not in js.read_text() and 'boundary-shim' not in js.read_text()
    subprocess.run(['node', str(js)], check=True)
    for suffix, extra in [('ordinary', []), ('internal', base)]:
        cmd = ['nim', 'c', *flags, *extra, '--nimcache:' + str(out / 'nimcache' / ('c-' + name + suffix)), '--out:' + str(out / ('c-' + name + suffix)), 'tests/fixtures/record_frames_omission.nim']
        p = subprocess.run(cmd, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (out / ('c-' + name + suffix + '.log')).write_text(repr(cmd) + '\n' + p.stdout)
        assert p.returncode == 0
        subprocess.run([str(out / ('c-' + name + suffix))], check=True)
lazy = compile_js('import', 'tests/fixtures/record_frames_import.nim', base)
subprocess.run(['node', str(lazy)], check=True)
context = compile_js('context', 'tests/fixtures/replay_reads_context.nim')
env['FRAME_CONTEXT'] = str(context)
replay = compile_js('replay', 'tests/fixtures/record_frames_replay.nim', ['-d:isonimInternalReplayReads'])
companion = compile_js('companion', 'tests/fixtures/record_frames.nim', base)
env['FRAME_COMPANION'] = str(companion)

def browser(name, js, rp, inverse=None, assertion=None):
    e = {**env, 'FRAME_BUNDLE': str(js), 'FRAME_REPLAY': str(rp), 'FRAME_RESULTS': str(out / (name + '-results.jsonl'))}
    if inverse:
        e['FRAME_INVERSE'] = inverse
    p = subprocess.run(['node', 'tests/test_record_frames_owner.mjs'], cwd=root, env=e, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / (name + '-browser.log')).write_text(p.stdout)
    print(p.stdout, flush=True)
    if inverse:
        assert 'frame companion positive: real Record -> strict codec -> public Replay DONE' in p.stdout
        assert p.returncode == 1 and 'AssertionError [ERR_ASSERTION]: frame semantic: ' + assertion in p.stdout, 'precise compiled semantic inverse: ' + name
    else:
        p.check_returncode()

for name, flags in [('default', []), ('recordable', ['-d:isonimRecordable']), ('release', ['-d:release']), ('recordable-release', ['-d:isonimRecordable', '-d:release'])]:
    js = compile_js('frames-' + name, 'tests/fixtures/record_frames.nim', [*base, *flags])
    rp = compile_js('replay-' + name, 'tests/fixtures/record_frames_replay.nim', ['-d:isonimInternalReplayReads', *flags])
    browser(name, js, rp)
original = (root / 'src/isonim/core/private/record_frames.nim').read_text()
mutations = {
    'omit': ("c.rec.emit('TaskReg',{task_id:task,kind:3,delay_ms:0});", '', 'exact TaskReg count'),
    'task': ('c.rec.task(task,3);', '', 'task before callback'),
    'reg-kind': ('task_id:task,kind:3,delay_ms:0', 'task_id:task,kind:2,delay_ms:0', 'registration kind'),
    'delay': ('kind:3,delay_ms:0', 'kind:3,delay_ms:1', 'zero registration delay'),
    'task-kind': ('c.rec.task(task,3);', 'c.rec.task(task,2);', 'delivered Task kind'),
    'counter': ('var task=c.rec.nextTaskId();', 'var task=1n;', 'actual shared owner namespace'),
    'clock': ("c.rec.emit('Clock',{src:4,bits:c.bits(ts)});", '', 'delivered Clock4 count'),
    'source': ('return forward(ts);};var handle', 'return forward(-ts);};var handle', 'original native callback timestamp bits'),
    'bits': ('bits:c.bits(ts)', 'bits:c.bits(ts)^1n', 'delivered timestamp bits'),
    'order': ("c.rec.task(task,3);c.rec.emit('Clock',{src:4,bits:c.bits(ts)});});return forward(ts);", "c.rec.task(task,3);});var value=forward(ts);c.rec.guard(function(){c.rec.emit('Clock',{src:4,bits:c.bits(ts)});});return value;", 'immediate native Task Clock callback order'),
    'live': ('c.request.call(c.window,run)', 'c.window.requestAnimationFrame(run)', 'captured native scheduling'),
    'cancel': ('c.cancel.call(c.window,h)', 'c.cancel.call(c.window,0)', 'cancelled callback remains absent'),
    'guard': ('return forward(ts);};var handle', 'return c.rec.guard(function(){return forward(ts);});};var handle', 'callback error delivered outside guard'),
}

def source_copy(name, text):
    directory = out / name
    directory.mkdir()
    source = directory / 'src'
    shutil.copytree(root / 'src', source)
    (source / 'isonim/core/private/record_frames.nim').write_text(text)
    fixtures = directory / 'tests/fixtures'
    fixtures.mkdir(parents=True)
    for name in ['record_frames.nim', 'record_frames_effect.nim']:
        shutil.copyfile(root / 'tests/fixtures' / name, fixtures / name)
    return source, fixtures

for name, (old, new, assertion) in mutations.items():
    assert original.count(old) == 1, name
    source, fixtures = source_copy(name, original.replace(old, new, 1))
    js = compile_js('inverse-' + name, fixtures / 'record_frames.nim', base, source)
    browser('inverse-' + name, js, replay, name, assertion)
    if name == 'cancel':
        browser('inverse-cancel-lifecycle', js, replay, 'cancel-lifecycle', 'nested cancelled callback remains absent after native fence')
    print('compiled frame inverse ' + name + ': exact semantic rejection PASS', flush=True)
for name, text, reject in [('inferred', original.replace(' {.tags: [RawNondet].}', ''), True), ('combined', original.replace(' {.tags: [RawNondet].}', '').replace(', tags: [RawNondet]', ''), False)]:
    source, fixtures = source_copy('effect-' + name, text)
    for boundary in [[], ['-d:frameRaw'], ['-d:frameCancel'], ['-d:frameRaw', '-d:frameCancel']]:
        compile_js(name + '-'.join(boundary), fixtures / 'record_frames_effect.nim', [*base, *boundary, '-d:frameReject'], source, reject=reject)
missing = dict(env)
missing.pop('CT_ARTIFACT', None)
p = subprocess.run(['python3', str(Path(__file__))], cwd=root, env=missing, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(out / 'missing-artifact.log').write_text(p.stdout)
assert p.returncode != 0 and 'CT_ARTIFACT required' in p.stdout
missing = {**env, 'FRAME_BUNDLE': str(companion), 'FRAME_REPLAY': str(replay)}
missing.pop('FRAME_CONTEXT', None)
p = subprocess.run(['node', 'tests/test_record_frames_owner.mjs'], cwd=root, env=missing, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(out / 'missing-context.log').write_text(p.stdout)
assert p.returncode == 1 and 'FRAME_CONTEXT required' in p.stdout
print('frame missing-artifact/context fail closed PASS', flush=True)
