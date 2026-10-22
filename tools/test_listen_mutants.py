#!/usr/bin/env python3
"""Isolated actual-source mutations must fail the original browser assertions."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
mutations = [
    ("disabled input scrubber",
     "el.getAttribute('data-isonim-record') === 'true' ? value : '*'.repeat(value.length)",
     'value', 'scrub.slice(0,6).every'),
    ('strong target ownership', 'const isonimListeners = new WeakMap();',
     'const isonimListeners = new Map();', 'weakNode.deref()'),
]
with tempfile.TemporaryDirectory(prefix='listen-mutants-') as directory:
    tmp = Path(directory)
    shutil.copytree(root / 'src', tmp / 'src', symlinks=True)
    (tmp / 'build').mkdir()
    shutil.copyfile(root / 'build/tailwind-styles.json', tmp / 'build/tailwind-styles.json')
    fixture = tmp / 'tests/fixtures/listen'
    shutil.copytree(root / 'tests/fixtures/listen', fixture)
    path = tmp / 'src/isonim/core/nondet.nim'
    original = path.read_text()
    output = root / 'build/listen.js'
    saved = output.read_bytes()
    try:
        for name, before, after, assertion in mutations:
            assert original.count(before) == 1
            path.write_text(original.replace(before, after))
            subprocess.run([
                'nim', 'js', '--hints:off', '--path:' + str(tmp / 'src'),
                '--path:' + str(root.parent / 'nim-everywhere/src'),
                '-d:isonimStableIds', '-d:iidProjectRoot=' + str(tmp),
                '--out:' + str(output), str(fixture / 'task_app.nim')
            ], cwd=root, check=True)
            run = subprocess.run(['node', 'tests/test_listen_browser.mjs'], cwd=root,
                                 text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            assert run.returncode != 0, run.stdout
            assert assertion in run.stdout, run.stdout
            print(name + ' mutant: REJECTED')
    finally:
        output.write_bytes(saved)
