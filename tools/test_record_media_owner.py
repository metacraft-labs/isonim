#!/usr/bin/env python3
"""Actual fixed media primitive qualification. No missing-artifact skips.

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
parent = root / 'build/record-media-inverses'
parent.mkdir(parents=True, exist_ok=True)
out = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
print('retained qualification directory: ' + str(out), flush=True)
env = dict(os.environ)
env.setdefault('PLAYWRIGHT_CHROMIUM_EXECUTABLE', shutil.which('chromium') or '')
base = ['-d:isonimInternalRecordLayout', '-d:isonimInternalRecordClocks']

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

for i, raw in enumerate([[], ['-d:recordMediaRaw']]):
    compile_js('effect-' + str(i), 'tests/fixtures/record_media_effect.nim', [*base, *raw])
    compile_js('reject-' + str(i), 'tests/fixtures/record_media_effect.nim', [*base, *raw, '-d:recordMediaReject'], reject=True)
lazy = compile_js('import', 'tests/fixtures/record_media_import.nim', base)
assert 'function rmUncalled(' in lazy.read_text() and 'boundary-shim/dist/browser/recorder.js' in lazy.read_text()
subprocess.run(['node', str(lazy)], cwd=root, check=True)
for name, flags in [('default', []), ('recordable', ['-d:isonimRecordable'])]:
    empty = compile_js('omission-' + name, 'tests/fixtures/record_media_omission.nim', flags)
    assert all(s not in empty.read_text() for s in ['RecordMediaPrimitives', 'boundary-shim'])
    subprocess.run(['node', str(empty)], cwd=root, check=True)
    # C import stays empty even with the deliberate JS-only preparation flag.
    for suffix, extra in [('ordinary', []), ('internal', base)]:
        cmd = ['nim', 'c', *flags, *extra, '--nimcache:' + str(out / 'nimcache' / ('c-' + name + suffix)), '--out:' + str(out / ('c-' + name + suffix)), 'tests/fixtures/record_media_omission.nim']
        p = subprocess.run(cmd, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (out / ('c-' + name + suffix + '.log')).write_text(repr(cmd) + '\n' + p.stdout)
        assert p.returncode == 0, 'native omission must compile'
        subprocess.run([str(out / ('c-' + name + suffix))], check=True)
context = compile_js('context', 'tests/fixtures/replay_reads_context.nim')
env['RECORD_MEDIA_CONTEXT'] = str(context)
replay = compile_js('replay', 'tests/fixtures/record_media_replay.nim', ['-d:isonimInternalReplayReads'])
companion = compile_js('companion', 'tests/fixtures/record_media.nim', base)
env['RECORD_MEDIA_COMPANION'] = str(companion)

def browser(name, js, replay_js, inverse=None, assertion=None):
    run_env = {**env, 'RECORD_MEDIA_BUNDLE': str(js), 'RECORD_MEDIA_REPLAY': str(replay_js), 'RECORD_MEDIA_RESULTS': str(out / (name + '-results.jsonl'))}
    if inverse:
        run_env['RECORD_MEDIA_INVERSE'] = inverse
    p = subprocess.run(['node', 'tests/test_record_media_owner.mjs'], cwd=root, env=run_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / (name + '-browser.log')).write_text(p.stdout)
    print(p.stdout, flush=True)
    if inverse:
        assert 'media companion positive owner 0: actual compiled Record -> strict reader -> public Replay DONE' in p.stdout, 'companion must reach actual owner DONE before inverse'
        assert p.returncode == 1 and 'AssertionError [ERR_ASSERTION]: media semantic: ' + assertion in p.stdout and 'TypeError' not in p.stdout, 'compiled inverse must reach its exact named AssertionError: ' + name
    else:
        p.check_returncode()

for name, flags in [('default', []), ('recordable', ['-d:isonimRecordable']), ('release', ['-d:release']), ('recordable-release', ['-d:isonimRecordable', '-d:release'])]:
    js = compile_js('media-' + name, 'tests/fixtures/record_media.nim', [*base, *flags])
    matching = compile_js('replay-' + name, 'tests/fixtures/record_media_replay.nim', ['-d:isonimInternalReplayReads', *flags])
    browser(name, js, matching)

original = (root / 'src/isonim/core/private/record_media.nim').read_text()
mutations = {
    'omit': ("c.rec.emit('LayoutRead',{target:'win',prop:'matchMedia:'+media,value:JSON.stringify({matches:value})});", '', 'native getter before guarded serialization and wire'),
    'key': ("prop:'matchMedia:'+media", "prop:'matchMedia:'+q", 'exact native serialized media key'),
    'value': ('JSON.stringify({matches:value})', 'JSON.stringify({matches:!value})', 'exact native boolean wire'),
    'live': ('c.match.call(c.window,q)', 'c.window.matchMedia(q)', 'captured originals bypass witnessed late replacements'),
}

def source_copy(name, text):
    directory = out / name
    directory.mkdir()
    source = directory / 'src'
    shutil.copytree(root / 'src', source)
    (source / 'isonim/core/private/record_media.nim').write_text(text)
    fixtures = directory / 'tests/fixtures'
    fixtures.mkdir(parents=True)
    for f in ['record_media.nim', 'record_media_effect.nim']:
        shutil.copyfile(root / 'tests/fixtures' / f, fixtures / f)
    return source, fixtures

for name, (old, new, assertion) in mutations.items():
    assert original.count(old) == 1, 'exact source inverse anchor ' + name
    source, fixtures = source_copy(name, original.replace(old, new, 1))
    js = compile_js('inverse-' + name, fixtures / 'record_media.nim', base, source)
    browser('inverse-' + name, js, replay, name, assertion)
    print('compiled media inverse ' + name + ': REJECTED at ' + assertion, flush=True)
export = ' {.tags: [RawNondet].}'
assert original.count(export) == 1 and original.count(', tags: [RawNondet]') == 1
for name, text, boundaries, reject in [
    ('inferred-export', original.replace(export, ''), [[], ['-d:recordMediaRaw']], True),
    ('raw-loss', original.replace(', tags: [RawNondet]', ''), [['-d:recordMediaRaw']], False),
    ('combined-loss', original.replace(export, '').replace(', tags: [RawNondet]', ''), [[], ['-d:recordMediaRaw']], False),
]:
    source, fixtures = source_copy(name, text)
    for i, boundary in enumerate(boundaries):
        compile_js('effect-' + name + str(i), fixtures / 'record_media_effect.nim', [*base, *boundary, '-d:recordMediaReject'], source, reject=reject)
    print('media effect control ' + name + ': PASS', flush=True)
missing_env = dict(env)
missing_env.pop('CT_ARTIFACT', None)
p = subprocess.run(['python3', str(Path(__file__))], cwd=root, env=missing_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(out / 'missing-artifact.log').write_text(p.stdout)
assert p.returncode != 0 and 'CT_ARTIFACT required: actual installed owner integration cannot skip' in p.stdout
for key in ['RECORD_MEDIA_CONTEXT']:
    no_context = {**env, 'RECORD_MEDIA_BUNDLE': str(companion), 'RECORD_MEDIA_REPLAY': str(replay)}
    no_context.pop(key)
    p = subprocess.run(['node', 'tests/test_record_media_owner.mjs'], cwd=root, env=no_context, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / 'missing-context.log').write_text(p.stdout)
    assert p.returncode == 1 and key + ' required: explicit current compiled input' in p.stdout
print('media missing-artifact/context negatives: PASS', flush=True)
