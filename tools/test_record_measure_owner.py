#!/usr/bin/env python3
"""Actual fixed measure primitive qualification. No missing-artifact skips.

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
parent = root / 'build/record-measure-inverses'
parent.mkdir(parents=True, exist_ok=True)
out = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
print('retained qualification directory: ' + str(out), flush=True)
env = dict(os.environ)
env.setdefault('PLAYWRIGHT_CHROMIUM_EXECUTABLE', shutil.which('chromium') or '')
base = ['-d:isonimInternalRecordLayout', '-d:isonimInternalRecordClocks', '-d:isonimStableIds']

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

for i, raw in enumerate([[], ['-d:recordMeasureRaw'], ['-d:recordMeasureIid']]):
    compile_js('effect-' + str(i), 'tests/fixtures/record_measure_effect.nim', [*base, *raw])
    compile_js('reject-' + str(i), 'tests/fixtures/record_measure_effect.nim', [*base, *raw, '-d:recordMeasureReject'], reject=True)
lazy = compile_js('import', 'tests/fixtures/record_measure_import.nim', base)
assert 'function rqUncalled(' in lazy.read_text() and 'boundary-shim/dist/browser/recorder.js' in lazy.read_text()
subprocess.run(['node', str(lazy)], cwd=root, check=True)
for name, flags in [('default', []), ('recordable', ['-d:isonimRecordable'])]:
    empty = compile_js('omission-' + name, 'tests/fixtures/record_measure_omission.nim', flags)
    assert all(s not in empty.read_text() for s in ['RecordMeasurePrimitives', 'boundary-shim'])
    subprocess.run(['node', str(empty)], cwd=root, check=True)
    # C import stays empty even with the deliberate JS-only preparation flag.
    for suffix, extra in [('ordinary', []), ('internal', base)]:
        cmd = ['nim', 'c', *flags, *extra, '--nimcache:' + str(out / 'nimcache' / ('c-' + name + suffix)), '--out:' + str(out / ('c-' + name + suffix)), 'tests/fixtures/record_measure_omission.nim']
        p = subprocess.run(cmd, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (out / ('c-' + name + suffix + '.log')).write_text(repr(cmd) + '\n' + p.stdout)
        assert p.returncode == 0, 'native omission must compile'
        subprocess.run([str(out / ('c-' + name + suffix))], check=True)
empty = compile_js('omission-no-stable', 'tests/fixtures/record_measure_omission.nim', ['-d:isonimInternalRecordLayout'])
assert 'boundary-shim' not in empty.read_text()
subprocess.run(['node', str(empty)], check=True)
context = compile_js('context', 'tests/fixtures/replay_reads_context.nim')
env['RECORD_MEASURE_CONTEXT'] = str(context)
env['RECORD_MEASURE_IMPORT'] = str(lazy)
replay = compile_js('replay', 'tests/fixtures/record_measure_replay.nim', ['-d:isonimInternalReplayReads', '-d:isonimStableIds'])
companion = compile_js('companion', 'tests/fixtures/record_measure.nim', base)
env['RECORD_MEASURE_COMPANION'] = str(companion)

def browser(name, js, replay_js, inverse=None, assertion=None):
    run_env = {**env, 'RECORD_MEASURE_BUNDLE': str(js), 'RECORD_MEASURE_REPLAY': str(replay_js), 'RECORD_MEASURE_RESULTS': str(out / (name + '-results.jsonl'))}
    if inverse:
        run_env['RECORD_MEASURE_INVERSE'] = inverse
    p = subprocess.run(['node', 'tests/test_record_measure_owner.mjs'], cwd=root, env=run_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / (name + '-browser.log')).write_text(p.stdout)
    print(p.stdout, flush=True)
    if inverse:
        assert 'measure companion positive owner 0: actual compiled Record -> strict reader -> public/private Replay DONE' in p.stdout, 'companion must reach actual owner DONE before inverse'
        assert p.returncode == 1 and 'AssertionError [ERR_ASSERTION]: measure semantic: ' + assertion in p.stdout and 'TypeError' not in p.stdout, 'compiled inverse must reach its exact named AssertionError: ' + name
    else:
        p.check_returncode()

for name, flags in [('default', []), ('recordable', ['-d:isonimRecordable']), ('release', ['-d:release']), ('recordable-release', ['-d:isonimRecordable', '-d:release'])]:
    js = compile_js('measure-' + name, 'tests/fixtures/record_measure.nim', [*base, *flags])
    matching = compile_js('replay-' + name, 'tests/fixtures/record_measure_replay.nim', ['-d:isonimInternalReplayReads', '-d:isonimStableIds', *flags])
    browser(name, js, matching)

original = (root / 'src/isonim/core/private/record_measure.nim').read_text()
mutations = {
    'omit': ("c.rec.emit('LayoutRead',{target:'iid:'+iid,prop:'getBoundingClientRect',value:JSON.stringify(value)});", '', 'exactly one layout emission per read'),
    'live': ('c.rect.call(e)', 'c.window.Element.prototype.getBoundingClientRect.call(e)', 'captured original bypasses late replacement'),
    'identity': ('if not sameElement(el, resolveIidLookup(iid)):', 'if false and not sameElement(el, resolveIidLookup(iid)):', 'require exact registered object'),
    'early': ('    let iid = elementIid(measurement.linkage, el)', '    discard rectRaw(measurement.linkage, el, cstring"early")\n    let iid = elementIid(measurement.linkage, el)', 'validate identity before native read'),
    'field': ('JSON.stringify(value)', 'JSON.stringify({...value,left:undefined})', 'exact eight wire fields'),
    'clone': ('return r;})(#,#,#)', 'return value;})(#,#,#)', 'original native DOMRect identity'),
    'order': ('{x:r.x,y:r.y,width:r.width', '{y:r.y,x:r.x,width:r.width', 'exact snapshot field order'),
}

def source_copy(name, text):
    directory = out / name
    directory.mkdir()
    source = directory / 'src'
    shutil.copytree(root / 'src', source)
    (source / 'isonim/core/private/record_measure.nim').write_text(text)
    fixtures = directory / 'tests/fixtures'
    fixtures.mkdir(parents=True)
    for f in ['record_measure.nim', 'record_measure_effect.nim', 'record_measure_nodes.nim']:
        shutil.copyfile(root / 'tests/fixtures' / f, fixtures / f)
    return source, fixtures

for name, (old, new, assertion) in mutations.items():
    assert original.count(old) == 1, 'exact source inverse anchor ' + name
    source, fixtures = source_copy(name, original.replace(old, new, 1))
    js = compile_js('inverse-' + name, fixtures / 'record_measure.nim', base, source)
    browser('inverse-' + name, js, replay, name, assertion)
    print('compiled measure inverse ' + name + ': REJECTED at ' + assertion, flush=True)
export = ' {.tags: [RawNondet].}'
assert original.count(export) == 1 and original.count(', tags: [RawNondet]') == 2
for name, text, boundaries, reject in [
    ('inferred-export', original.replace(export, ''), [[], ['-d:recordMeasureRaw'], ['-d:recordMeasureIid']], True),
    ('raw-loss', original.replace(', tags: [RawNondet]', ''), [['-d:recordMeasureRaw'], ['-d:recordMeasureIid']], False),
    ('combined-loss', original.replace(export, '').replace(', tags: [RawNondet]', ''), [[], ['-d:recordMeasureRaw'], ['-d:recordMeasureIid']], False),
]:
    source, fixtures = source_copy(name, text)
    for i, boundary in enumerate(boundaries):
        compile_js('effect-' + name + str(i), fixtures / 'record_measure_effect.nim', [*base, *boundary, '-d:recordMeasureReject'], source, reject=reject)
    print('measure effect control ' + name + ': PASS', flush=True)
missing_env = dict(env)
missing_env.pop('CT_ARTIFACT', None)
p = subprocess.run(['python3', str(Path(__file__))], cwd=root, env=missing_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(out / 'missing-artifact.log').write_text(p.stdout)
assert p.returncode != 0 and 'CT_ARTIFACT required: actual installed owner integration cannot skip' in p.stdout
for key in ['RECORD_MEASURE_CONTEXT']:
    no_context = {**env, 'RECORD_MEASURE_BUNDLE': str(companion), 'RECORD_MEASURE_REPLAY': str(replay)}
    no_context.pop(key)
    p = subprocess.run(['node', 'tests/test_record_measure_owner.mjs'], cwd=root, env=no_context, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / 'missing-context.log').write_text(p.stdout)
    assert p.returncode == 1 and key + ' required: explicit current compiled input' in p.stdout
print('measure missing-artifact/context negatives: PASS', flush=True)
