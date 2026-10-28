#!/usr/bin/env python3
"""Mandatory genuine native-storage owner gate; dependencies cannot be skipped.

All falsifiers compile their own copied source/fixture. No synthetic storage
provider, cursor, wire log or generated bundle is committed.
"""
from pathlib import Path
import os, shutil, subprocess, tempfile
root = Path(__file__).resolve().parent.parent
if not os.environ.get('CT_ARTIFACT'):
    raise SystemExit('CT_ARTIFACT required: storage output owner gate cannot skip')
env = dict(os.environ)
env.setdefault('PLAYWRIGHT_CHROMIUM_EXECUTABLE', shutil.which('chromium') or '')

def compile(name, flags=(), source=None, fixture=None):
    out = root / 'build' / (name + '.js')
    cmd = ['nim', 'js', '-d:isonimInternalReplayReads', *flags]
    if source:
        cmd += ['--path:' + str(source), '--path:' + str(root.parent / 'nim-everywhere/src')]
    cmd += ['--nimcache:' + str(root / 'build/nimcache' / name), '--out:' + str(out), str(fixture or 'tests/fixtures/replay_storage_output.nim')]
    subprocess.run(cmd, cwd=root, check=True)
    return out

def run(bundle, native, **extra):
    subprocess.run(['node', 'tests/test_replay_storage_output_owner.mjs'], cwd=root,
                   env={**env, 'REPLAY_STORAGE_BUNDLE': str(bundle), 'REPLAY_STORAGE_NATIVE': str(native), **extra}, check=True)

for name, flags in [('ordinary', []), ('dormant', ['-d:isonimRecordable'])]:
    out = root / 'build' / ('storage-output-omission-' + name + '.js')
    subprocess.run(['nim', 'js', '-d:nodejs', *flags, '--out:' + str(out), 'tests/test_replay_read_guards.nim'], cwd=root, check=True)
    text = out.read_text()
    for marker in ['requireReadReplayStorageOutput', 'requireStorageOutputLevel', 'internal storage output Replay']:
        assert marker not in text, (name, marker)
    subprocess.run(['node', str(out)], cwd=root, check=True)
    print(name + ' storage output helper/module omission PASS')

native = compile('replay-storage-native')
for name, flags in [('default', []), ('recordable', ['-d:isonimRecordable']), ('release', ['-d:release']), ('early', ['-d:replayStorageEarly'])]:
    output = compile('replay-storage-' + name, flags)
    run(output, native, REPLAY_STORAGE_RECEIPT=str(root / 'build' / ('replay-storage-' + name + '.json')))

for mutation in ['omit', 'value', 'area']:
    with tempfile.TemporaryDirectory(prefix='isonim-storage-output-' + mutation + '-') as directory:
        tmp = Path(directory)
        shutil.copytree(root / 'src', tmp / 'src')
        fixtures = tmp / 'tests/fixtures'
        fixtures.mkdir(parents=True)
        for name in ['replay_storage_output.nim', 'replay_storage_output_bootstrap.nim']:
            shutil.copyfile(root / 'tests/fixtures' / name, fixtures / name)
        path = tmp / 'src/isonim/core/nondet.nim'
        code = path.read_text()
        old = '      when defined(js): rawStorageWrite(key.cstring, value.cstring)'
        assert code.count(old) == 1
        selected = {'omit': 'discard', 'value': 'rawStorageWrite(key.cstring, cstring"wrong-output")', 'area': 'rawSessionStorageWrite(key.cstring, value.cstring)'}[mutation]
        code = code.replace(old, '      when defined(js):\n        when defined(isonimInternalReplayReads):\n          if currentClock.isReadReplay: ' + selected + '\n          else: rawStorageWrite(key.cstring, value.cstring)\n        else: rawStorageWrite(key.cstring, value.cstring)')
        if mutation == 'area':
            old = '  proc rawStorageWrite(key, value: cstring)'
            assert code.count(old) == 1
            code = code.replace(old, '  proc rawSessionStorageWrite(key, value: cstring) {.importjs: "sessionStorage.setItem(#,#)", tags: [RawNondet].}\n' + old)
        path.write_text(code)
        output = compile('replay-storage-inverse-' + mutation, source=tmp / 'src', fixture=fixtures / 'replay_storage_output.nim')
        run(output, native, REPLAY_STORAGE_INVERSE=mutation, REPLAY_STORAGE_RECEIPT=str(root / 'build' / ('replay-storage-inverse-' + mutation + '.json')))
