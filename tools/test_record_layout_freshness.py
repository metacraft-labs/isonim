#!/usr/bin/env python3
"""Qualify changed non-leaf inputs through two complete real owner gates.

This deliberately changes only an isolated copy of the actual imported clock
module: static compiler output and an emitted JS comment witness which version
was compiled without changing runtime behavior. Both runs use the actual Nim
compiler, Chromium, installed Recorder/strict reader and public Replay harness.
No compiler, browser, writer, cursor or provider is mocked. Every copied source,
emission, log and previous run remains available for independent review.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
assert os.environ.get('CT_ARTIFACT'), 'CT_ARTIFACT required: freshness qualification cannot skip'
parent = root / 'build/record-layout-freshness'
parent.mkdir(parents=True, exist_ok=True)
out = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
print('retained freshness directory: ' + str(out), flush=True)
proof = out / 'isonim'
proof.mkdir()
# Copy the complete current framework source, rather than extracting HEAD and
# silently discarding a candidate's uncommitted changes. Other listed inputs
# are the real gate/fixture/config closure; dependency links retain real tools.
for directory in ['src', 'tests/fixtures']:
    shutil.copytree(root / directory, proof / directory)
for name in ['config.nims', 'tests/config.nims', 'tests/test_nondet_seams.nim',
             'tests/test_record_layout_owner.mjs', 'tools/run_nim_js_test.py',
             'tools/test_record_layout_owner.py']:
    target = proof / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(root / name, target)
(proof / 'tests/browser').mkdir()
(proof / 'tests/browser/node_modules').symlink_to((root / 'tests/browser/node_modules').resolve(), target_is_directory=True)
(proof / 'node_modules').symlink_to((root / 'node_modules').resolve(), target_is_directory=True)
(out / 'nim-everywhere').symlink_to((root.parent / 'nim-everywhere').resolve(), target_is_directory=True)

names = ['omit-width', 'omit-height', 'target', 'property', 'order', 'extra',
         'receiver', 'value', 'fallback']
copies = names + ['inferred-export', 'raw-loss', 'combined-loss']
leaf = 'isonim/core/private/record_layout.nim'
clock = proof / 'src/isonim/core/clock.nim'
original_clock = clock.read_text()

def hashes(directory):
    return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(directory.rglob('*')) if p.is_file()}

def save(name, value):
    (out / name).write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')

previous = None
previous_hashes = None
for arm in ['A', 'B']:
    marker = 'record_layout_freshness_' + out.name.replace('-', '_') + '_' + arm
    clock.write_text(original_clock + '\nstatic: echo "' + marker + '"\nwhen defined(js):\n  {.emit: "/* ' + marker + ' */".}\n')
    inputs = hashes(proof / 'src')
    save('inputs-' + arm + '.json', inputs)
    # This parent is the only writer of the probe input. subprocess.run reaps
    # the complete driver (which awaits every actual browser/compiler) before
    # any source change for B. No favorable-result retry or output deletion.
    p = subprocess.run(['python3', 'tools/test_record_layout_owner.py'], cwd=proof,
                       text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / ('gate-' + arm + '.log')).write_text(p.stdout)
    print(p.stdout, flush=True)
    assert p.returncode == 0, 'freshness: complete actual owner gate must pass ' + arm
    paths = [line.removeprefix('retained qualification directory: ')
             for line in p.stdout.splitlines() if line.startswith('retained qualification directory: ')]
    assert len(paths) == 1, 'freshness: exactly one exclusive qualification directory'
    run = Path(paths[0])
    assert run.is_dir() and run.parent == proof / 'build/record-layout-inverses'
    assert run != previous, 'freshness: separate invocations must use exclusive paths'
    for name in copies:
        actual = hashes(run / name / 'src')
        assert actual.keys() == inputs.keys(), 'freshness: complete current source path set ' + name
        assert all(actual[n] == h for n, h in inputs.items() if n != leaf), 'freshness: current non-leaf source bytes ' + name
        assert actual[leaf] != inputs[leaf], 'freshness: intended leaf inverse remains active ' + name
    for name in names:
        emitted = (run / ('record-layout-inverse-' + name + '.js')).read_text()
        compile_log = (run / ('record-layout-inverse-' + name + '-compile.log')).read_text()
        semantic = (run / name / 'semantic.log').read_text()
        command = (run / ('record-layout-inverse-' + name + '-command.txt')).read_text()
        assert 'exit: 0\n' in command, 'freshness: semantic inverse compilation must succeed ' + name
        assert '/* ' + marker + ' */' in emitted, 'freshness: current non-leaf actual emitted JS ' + name
        assert marker in compile_log, 'freshness: current non-leaf actual compiler output ' + name
        assert 'AssertionError' in semantic and 'layout semantic: ' in semantic and 'TypeError' not in semantic, 'freshness: actual semantic AssertionError ' + name
        if arm == 'B':
            assert previous_marker not in emitted and previous_marker not in compile_log, 'freshness: prior marker must not survive compilation ' + name
    assert p.stdout.count('compiled viewport inverse ') == 9, 'freshness: all nine semantic inverses'
    assert p.stdout.count('viewport effect control ') == 3, 'freshness: all original effect controls'
    assert 'viewport missing-artifact negative: PASS' in p.stdout
    for build in ['default', 'recordable', 'release', 'both']:
        records = [json.loads(line) for line in
                   (run / ('record-layout-results-' + build + '.jsonl')).read_text().splitlines()]
        assert len([r for r in records if r['stage'] == 'construction']) == 8, 'freshness: eight actual workflows ' + build
        replays = [r for r in records if r['stage'] == 'replay']
        assert len(replays) == 3 and all(r['done']['status']['state'] == 'done' for r in replays), 'freshness: three actual owned DONE sessions ' + build
    if previous is not None:
        assert hashes(previous) == previous_hashes, 'freshness: previous retained outputs must remain byte exact'
    save('outputs-' + arm + '.json', hashes(run))
    previous, previous_hashes, previous_marker = run, hashes(run), marker
print('actual changed non-leaf A/B qualification: PASS; all prior outputs retained', flush=True)
