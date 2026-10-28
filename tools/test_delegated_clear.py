#!/usr/bin/env python3
"""Compile actual Nim and run native Chromium clear/removal qualification.

No DOM mock: the JS harness only observes forwarded native arguments. The
published baseline is obtained from git, not a handwritten implementation.
The compiled inverse restores that actual proc-conversion mismatch and must
reach the precise delivery AssertionError after its neutral controls pass.
All inverse source, emission and logs remain under build/delegated-clear.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
output_parent = root / 'build/delegated-clear'
output_parent.mkdir(parents=True, exist_ok=True)
# Each invocation must compile its own fresh dependency closure. Keep every
# prior run for review without reusing or overwriting its source snapshots.
out = Path(tempfile.mkdtemp(prefix='run-', dir=output_parent))
print('retained qualification directory: ' + str(out), flush=True)
env = dict(os.environ)
env.setdefault('PLAYWRIGHT_CHROMIUM_EXECUTABLE', shutil.which('chromium') or '')

def run(name, command, expected=0):
    p = subprocess.run(command, cwd=root, env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / (name + '.log')).write_text(p.stdout)
    print(p.stdout, flush=True)
    assert p.returncode == expected, f'{name}: exit {p.returncode}, expected {expected}'
    return p.stdout

def compile_js(name, fixture, flags=(), source=None):
    target = out / (name + '.js')
    paths = ['--path:' + str(source)] if source else []
    run(name + '-compile', ['nim', 'js', '--hints:off', *flags, *paths,
        '--path:' + str(root.parent / 'nim-everywhere/src'),
        '--nimcache:' + str(out / (name + '-cache')),
        '--out:' + str(target), str(fixture)])
    return target

original = (root / 'src/isonim/web/events.nim').read_text()
for name, flags in [('default', []), ('recordable', ['-d:isonimRecordable']),
        ('release', ['-d:release']), ('private', ['-d:isonimInternalReplayReads',
         '-d:isonimInternalRecordClocks', '-d:isonimInternalRecordLayout'])]:
    js = compile_js(name, root / 'tests/fixtures/delegated_clear.nim', flags)
    env['DELEGATED_CLEAR_BUNDLE'] = str(js)
    run(name + '-browser', ['node', 'tests/test_delegated_clear.mjs'])

# Import behavior is compared against the actual published events module.
# These isolated sources are retained even when a qualification fails.
baseline = out / 'published'
shutil.copytree(root / 'src', baseline / 'src')
published = subprocess.check_output(['git', 'show',
    '4215efad564c57648638e19c15cc3af41346dca8:src/isonim/web/events.nim'], cwd=root)
(baseline / 'src/isonim/web/events.nim').write_bytes(published)
fixtures = baseline / 'tests/fixtures'
fixtures.mkdir(parents=True, exist_ok=True)
shutil.copyfile(root / 'tests/fixtures/delegated_clear_import.nim', fixtures / 'delegated_clear_import.nim')
baseline_js = compile_js('published-import', fixtures / 'delegated_clear_import.nim', source=baseline / 'src')
for name, flags in [('default', []), ('recordable', ['-d:isonimRecordable']),
        ('release', ['-d:release']), ('private', ['-d:isonimInternalReplayReads',
         '-d:isonimInternalRecordClocks', '-d:isonimInternalRecordLayout'])]:
    js = compile_js(name + '-import', root / 'tests/fixtures/delegated_clear_import.nim', flags)
    run(name + '-windowless', ['node', '--input-type=module', '-e', '''
import assert from 'node:assert/strict';import vm from 'node:vm';import {readFileSync} from 'node:fs';
function observe(path){const accesses=[];const sandbox={console};for(const key of ['document','window'])Object.defineProperty(sandbox,key,{get(){accesses.push(key);if(key==='document')throw new Error('unexpected document access');return undefined;}});vm.runInNewContext(readFileSync(path,'utf8'),sandbox);assert.equal(typeof sandbox.dcClearLater,'function');return accesses;}
const baseline=observe(process.argv[1]),candidate=observe(process.argv[2]);assert.deepEqual(candidate,baseline,'windowless import preserves published platform behavior');assert(!candidate.includes('document'));console.log('windowless published import behavior preserved: PASS',JSON.stringify(candidate));
''', str(baseline_js), str(js)])

inverse = out / 'inverse'
shutil.copytree(root / 'src', inverse / 'src')
old = 'document.Node.addEventListener(name, delegatedHandler)'
old2 = 'document.Node.addEventListener(cs, delegatedHandler)'
assert original.count(old) == original.count(old2) == 1
text = original.replace(old, 'document.Node.addEventListener(name, eventHandler)').replace(old2, 'document.Node.addEventListener(cs, eventHandler)')
anchor = 'document, ".removeEventListener(name, ", delegatedHandler,'
assert text.count(anchor) == 1
text = text.replace(anchor, 'document, ".removeEventListener(name, ", eventHandler,')
(inverse / 'src/isonim/web/events.nim').write_text(text)
fixtures = inverse / 'tests/fixtures'
fixtures.mkdir(parents=True, exist_ok=True)
shutil.copyfile(root / 'tests/fixtures/delegated_clear.nim', fixtures / 'delegated_clear.nim')
js = compile_js('inverse', fixtures / 'delegated_clear.nim', source=inverse / 'src')
env['DELEGATED_CLEAR_BUNDLE'] = str(js)
log = run('inverse-browser', ['node', 'tests/test_delegated_clear.mjs'], expected=1)
assert 'clear neutral before/foreign/direct/nondet: PASS' in log
assert 'AssertionError [ERR_ASSERTION]: clear semantic: no delegated delivery after clear' in log
assert 'TypeError' not in log
print('compiled callback-identity inverse: REJECTED at precise post-clear delivery assertion', flush=True)
