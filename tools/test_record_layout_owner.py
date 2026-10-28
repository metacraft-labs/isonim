#!/usr/bin/env python3
"""Actual private viewport/owner qualification; no artifact or semantic skips.

Source inverses compile the actual module and retain source/emission/logs under
build/record-layout-inverses. Raw ceiling fixtures include the real leaf solely
to expose the private raw binding; no production test hook is added.
"""
from pathlib import Path
import os
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
artifact = os.environ.get('CT_ARTIFACT')
if not artifact:
    raise SystemExit('CT_ARTIFACT required: actual installed owner integration cannot skip')
assert (Path(artifact) / 'packages/boundary-shim/dist/browser/recorder.js').is_file(), 'actual installed Recorder required'
env = dict(os.environ)
env.setdefault('PLAYWRIGHT_CHROMIUM_EXECUTABLE', shutil.which('chromium') or '')
base = ['-d:isonimInternalRecordLayout']

def compile_js(name, fixture, flags=(), source=None, reject=False):
    output = root / 'build' / (name + '.js')
    cmd = ['nim', 'js', *flags]
    if source:
        cmd += ['--path:' + str(source), '--path:' + str(root.parent / 'nim-everywhere/src')]
    cmd += ['--nimcache:' + str(root / 'build/nimcache' / name), '--out:' + str(output), str(fixture)]
    p = subprocess.run(cmd, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(p.stdout, flush=True)
    if reject:
        assert p.returncode != 0 and 'RawNondet' in p.stdout and 'unlisted effect' in p.stdout, 'exact RawNondet ceiling rejection'
    else:
        assert p.returncode == 0, 'actual source must compile before semantic qualification: ' + name
    return output

for boundary in [[], ['-d:recordLayoutRaw']]:
    compile_js('record-layout-effect', 'tests/fixtures/record_layout_effect.nim', [*base, *boundary])
    compile_js('record-layout-reject', 'tests/fixtures/record_layout_effect.nim', [*base, *boundary, '-d:recordLayoutReject'], reject=True)

lazy = compile_js('record-layout-import', 'tests/fixtures/record_layout_import.nim', base)
assert 'function rlUncalled(' in lazy.read_text() and 'boundary-shim/dist/browser/recorder.js' in lazy.read_text()
subprocess.run(['node', str(lazy)], cwd=root, check=True)
for name, flags in [('default', []), ('recordable', ['-d:isonimRecordable'])]:
    empty = compile_js('record-layout-omission-' + name, 'tests/fixtures/record_layout_omission.nim', flags)
    assert all(s not in empty.read_text() for s in ['RecordLayoutPrimitives', 'boundary-shim'])
    subprocess.run(['node', str(empty)], cwd=root, check=True)
    a = compile_js('record-layout-public-' + name, 'tests/test_nondet_seams.nim', flags)
    b = compile_js('record-layout-public-internal-' + name, 'tests/test_nondet_seams.nim', [*flags, *base])
    assert a.read_bytes() == b.read_bytes(), 'same fixture/compiler paths: exact unused-define public bytes'
    assert all(s not in a.read_text() for s in ['record_layout.nim', 'RecordLayoutPrimitives', 'boundary-shim'])
    subprocess.run(['python3', 'tools/run_nim_js_test.py', str(a)], cwd=root, check=True)
compile_js('replay-reads-context', 'tests/fixtures/replay_reads_context.nim')
replay = compile_js('record-layout-replay', 'tests/fixtures/record_layout_replay.nim', ['-d:isonimInternalReplayReads'])
for name, flags in [('default', []), ('recordable', ['-d:isonimRecordable']), ('release', ['-d:release']), ('both', ['-d:isonimInternalReplayReads', '-d:isonimInternalRecordClocks'])]:
    js = compile_js('record-layout-' + name, 'tests/fixtures/record_layout.nim', [*base, *flags])
    matching = compile_js('record-layout-replay-' + name, 'tests/fixtures/record_layout_replay.nim', ['-d:isonimInternalReplayReads', *flags])
    subprocess.run(['node', 'tests/test_record_layout_owner.mjs'], cwd=root, env={**env, 'RECORD_LAYOUT_BUNDLE': str(js), 'RECORD_LAYOUT_REPLAY': str(matching), 'RECORD_LAYOUT_RESULTS': str(root / 'build' / ('record-layout-results-' + name + '.jsonl'))}, check=True)

original = (root / 'src/isonim/core/private/record_layout.nim').read_text()
width = "var width=c.width.call(c.window);c.rec.guard(function(){c.rec.emit('LayoutRead',{target:'win',prop:'innerWidth',value:JSON.stringify(width===undefined?null:width)});});"
height = "var height=c.height.call(c.window);c.rec.guard(function(){c.rec.emit('LayoutRead',{target:'win',prop:'innerHeight',value:JSON.stringify(height===undefined?null:height)});});"
mutations = {
    'omit-width': (width, 'var width=c.width.call(c.window);', 'one nonempty record'),
    'omit-height': (height, 'var height=c.height.call(c.window);', 'one nonempty record'),
    'target': ("target:'win',prop:'innerWidth'", "target:'doc',prop:'innerWidth'", 'checked Window target'),
    'property': ("prop:'innerHeight'", "prop:'outerHeight'", 'width emission before height observation'),
    'order': (width + height, height + width, 'width emission before height observation'),
    'extra': ('var width=c.width.call(c.window);', 'var width=c.width.call(c.window);c.width.call(c.window);', 'exactly one width then height read'),
    'receiver': ('c.width.call(c.window)', 'c.width.call({})', 'original Window receiver'),
    'value': ('return {width:width,height:height}', 'return {width:width+1,height:height}', 'exact native returned values'),
    'fallback': ('var width=c.width.call(c.window);', 'var width=c.window.innerWidth;', 'captured getters bypass witnessed late raw traps'),
}

def source_copy(name, text):
    directory = root / 'build/record-layout-inverses' / name
    directory.mkdir(parents=True, exist_ok=True)
    source = directory / 'src'
    if not source.exists():
        shutil.copytree(root / 'src', source)
    (source / 'isonim/core/private/record_layout.nim').write_text(text)
    fixtures = directory / 'tests/fixtures'
    fixtures.mkdir(parents=True, exist_ok=True)
    for f in ['record_layout.nim', 'record_layout_effect.nim']:
        shutil.copyfile(root / 'tests/fixtures' / f, fixtures / f)
    return source, fixtures

for name, (old, new, assertion) in mutations.items():
    assert original.count(old) == 1, 'exact source inverse anchor ' + name
    source, fixtures = source_copy(name, original.replace(old, new, 1))
    js = compile_js('record-layout-inverse-' + name, fixtures / 'record_layout.nim', base, source)
    p = subprocess.run(['node', 'tests/test_record_layout_owner.mjs'], cwd=root, env={**env, 'RECORD_LAYOUT_BUNDLE': str(js), 'RECORD_LAYOUT_REPLAY': str(replay), 'RECORD_LAYOUT_INVERSE': name, 'RECORD_LAYOUT_RESULTS': str(source.parent / 'results.jsonl')}, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (source.parent / 'semantic.log').write_text(p.stdout)
    print(p.stdout, flush=True)
    assert p.returncode != 0 and 'layout semantic: ' + assertion in p.stdout, 'compiled inverse must fail its named semantic assertion: ' + name
    print('compiled viewport inverse ' + name + ': REJECTED at ' + assertion, flush=True)

# An inferred effect is equally real: dropping a redundant export annotation
# must retain rejection. Actual raw loss can be observed directly; combined loss
# must let both prohibited callers compile, proving negative tests discriminate.
export = ' {.tags: [RawNondet].}'
assert original.count(export) == 1 and original.count(', tags: [RawNondet]') == 1
for name, text, boundaries, reject in [
    ('inferred-export', original.replace(export, ''), [[], ['-d:recordLayoutRaw']], True),
    ('raw-loss', original.replace(', tags: [RawNondet]', ''), [['-d:recordLayoutRaw']], False),
    ('combined-loss', original.replace(export, '').replace(', tags: [RawNondet]', ''), [[], ['-d:recordLayoutRaw']], False),
]:
    source, fixtures = source_copy(name, text)
    for i, boundary in enumerate(boundaries):
        compile_js('record-layout-effect-' + name + str(i), fixtures / 'record_layout_effect.nim', [*base, *boundary, '-d:recordLayoutReject'], source, reject=reject)
    print('viewport effect control ' + name + ': PASS', flush=True)

missing_env = dict(env)
missing_env.pop('CT_ARTIFACT', None)
missing = subprocess.run(['python3', str(Path(__file__))], cwd=root, env=missing_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
print(missing.stdout, flush=True)
assert missing.returncode != 0 and 'CT_ARTIFACT required: actual installed owner integration cannot skip' in missing.stdout, 'missing artifact must fail rather than skip'
print('viewport missing-artifact negative: PASS', flush=True)
