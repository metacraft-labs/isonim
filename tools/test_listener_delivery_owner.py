#!/usr/bin/env python3
"""Mandatory installed-owner/native-event proof and precise compiled inverses.

Each invocation owns an exclusive retained source/output/cache/log directory.
No private-class, provider, cursor or event-dispatch mock is accepted.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
artifact = os.environ.get('CT_ARTIFACT')
if not artifact:
    raise SystemExit('CT_ARTIFACT required: actual installed owner integration cannot skip')
assert (Path(artifact) / 'packages/boundary-shim/dist/browser/recorder.js').is_file(), 'actual installed Recorder required'
parent = Path(os.environ.get('DELIVERY_EVIDENCE', str(root / 'build/listener-delivery-evidence')))
parent.mkdir(parents=True, exist_ok=True)
out = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
print('retained listener qualification directory: ' + str(out), flush=True)
env = dict(os.environ)
env.setdefault('PLAYWRIGHT_CHROMIUM_EXECUTABLE', shutil.which('chromium') or '')

def run(name, command, overrides=None):
    completed = subprocess.run(command, cwd=root, env={**env, **(overrides or {})},
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (out / (name + '.log')).write_text(completed.stdout)
    (out / (name + '-command.json')).write_text(json.dumps({'argv': command, 'exit': completed.returncode}, indent=2) + '\n')
    print(completed.stdout, end='', flush=True)
    return completed

def compile_fixture(name, flags=(), source=None, fixture=None, private=True):
    command = ['nim', 'js', *(['-d:isonimInternalReplayReads'] if private else []), *flags]
    if source:
        command += ['--path:' + str(source), '--path:' + str(root.parent / 'nim-everywhere/src')]
    output = out / (name + '.js')
    command += ['--nimcache:' + str(out / 'nimcache' / name), '--out:' + str(output),
                str(fixture or root / 'tests/fixtures/listener_delivery_guards.nim')]
    result = run(name + '-compile', command)
    assert result.returncode == 0, 'actual source must compile before semantic qualification: ' + name
    return output

# Retain exact positive source and fixtures, not a path into a historical run.
shutil.copytree(root / 'src', out / 'positive-source')
fixtures = out / 'positive-fixtures'
fixtures.mkdir()
for name in ['listener_delivery_guards.nim', 'replay_reads_context.nim']:
    shutil.copyfile(root / 'tests/fixtures' / name, fixtures / name)
context = compile_fixture('delivery-context', source=out / 'positive-source',
                          fixture=fixtures / 'replay_reads_context.nim', private=False)
for label, flags in [('default', []), ('recordable', ['-d:isonimRecordable']),
                     ('release', ['-d:release']), ('recordable-release', ['-d:isonimRecordable', '-d:release'])]:
    bundle = compile_fixture('listener-delivery-' + label, flags, out / 'positive-source', fixtures / 'listener_delivery_guards.nim')
    result = run(label + '-browser', ['node', 'tests/test_listener_delivery_owner.mjs'],
                 {'DELIVERY_BUNDLE': str(bundle), 'DELIVERY_CONTEXT': str(context),
                  'DELIVERY_RECEIPTS': str(out / (label + '-results.jsonl'))})
    result.check_returncode()

for path, guard, reason in [
    ('listen', '        refuseReadReplay(currentClock, "listen")\n', 'listener-delivery-before-dispatch'),
    ('delegate', '  refuseReadReplay(currentClock, "delegateEvents")\n', 'delegated-delivery-before-metadata'),
]:
    directory = out / (path + '-inverse')
    directory.mkdir()
    source = directory / 'src'
    # Always copy the entire CURRENT source again, never a previous proof tree.
    shutil.copytree(root / 'src', source)
    target = source / ('isonim/core/nondet.nim' if path == 'listen' else 'isonim/web/events.nim')
    text = target.read_text()
    if path == 'delegate':
        anchor = '  # Registration may predate selection; refuse before inspecting the event.\n' + guard
        assert text.count(anchor) == 1
        text = text.replace(anchor, anchor.replace(guard, ''), 1)
    else:
        assert text.count(guard) == 1
        text = text.replace(guard, '', 1)
    target.write_text(text)
    inverse_fixtures = directory / 'tests/fixtures'
    inverse_fixtures.mkdir(parents=True)
    fixture = inverse_fixtures / 'listener_delivery_guards.nim'
    shutil.copyfile(root / 'tests/fixtures/listener_delivery_guards.nim', fixture)
    bundle = compile_fixture('listener-delivery-' + path + '-inverse', [], source, fixture)
    completed = run(path + '-inverse-semantic', ['node', 'tests/test_listener_delivery_owner.mjs'],
                    {'DELIVERY_BUNDLE': str(bundle), 'DELIVERY_CONTEXT': str(context), 'DELIVERY_MUTANT': path,
                     'DELIVERY_RECEIPTS': str(directory / 'results.jsonl')})
    assert completed.returncode != 0, 'compiled inverse unexpectedly passed'
    assert 'AssertionError' in completed.stdout and reason in completed.stdout, completed.stdout
    assert completed.returncode == 1 and 'AssertionError [ERR_ASSERTION]: ' + reason in completed.stdout and 'TypeError' not in completed.stdout, 'exact named semantic AssertionError required: ' + path
    companion = 'delegate' if path == 'listen' else 'listen'
    assert companion + ': native refusal before effects, actual public Clock2 and owner DONE PASS' in completed.stdout
    assert 'native delivery witness' not in completed.stdout, 'native delivery witness must pass before intended inverse assertion'
    print(path + ' delivery guard inverse: precise semantic assertion REJECTED', flush=True)

for name, original, replacement, reason in [
    ('timestamp', 'proc(): float64 = backend().now(),', 'proc(): float64 = 0.0,', 'retained-resume timestamp: test'),
    ('receiver', 'handler.call(this, ev)', 'handler.call(null, ev)', 'retained-resume receiver identity'),
]:
    directory = out / (name + '-inverse')
    directory.mkdir()
    source = directory / 'src'
    shutil.copytree(root / 'src', source)
    target = source / 'isonim/core/nondet.nim'
    text = target.read_text()
    assert text.count(original) == 1, 'exact retained-listener falsifier anchor: ' + name
    target.write_text(text.replace(original, replacement, 1))
    inverse_fixtures = directory / 'tests/fixtures'
    inverse_fixtures.mkdir(parents=True)
    fixture = inverse_fixtures / 'listener_delivery_guards.nim'
    shutil.copyfile(root / 'tests/fixtures/listener_delivery_guards.nim', fixture)
    bundle = compile_fixture('listener-delivery-' + name + '-inverse', [], source, fixture)
    completed = run(name + '-inverse-semantic', ['node', 'tests/test_listener_delivery_owner.mjs'],
                    {'DELIVERY_BUNDLE': str(bundle), 'DELIVERY_CONTEXT': str(context), 'DELIVERY_MUTANT': name,
                     'DELIVERY_RECEIPTS': str(directory / 'results.jsonl')})
    assert completed.returncode == 1 and 'AssertionError [ERR_ASSERTION]: ' + reason in completed.stdout and 'TypeError' not in completed.stdout, 'exact retained-listener semantic assertion required: ' + name
    assert 'delegate: native refusal before effects, actual public Clock2 and owner DONE PASS' in completed.stdout
    assert 'listen: native refusal before effects, actual public Clock2 and owner DONE PASS' in completed.stdout
    assert 'native delivery witness' not in completed.stdout and 'retained-resume genuine native delivery' not in completed.stdout
    print(name + ' retained-listener inverse: precise semantic assertion REJECTED', flush=True)

missing_context = dict(env)
missing_context.pop('DELIVERY_CONTEXT', None)
negative = subprocess.run(['node', 'tests/test_listener_delivery_owner.mjs'], cwd=root, env=missing_context,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
(out / 'missing-context.log').write_text(negative.stdout)
assert negative.returncode == 1 and 'DELIVERY_CONTEXT required: just-compiled context must be explicit' in negative.stdout
missing_artifact = dict(env)
missing_artifact.pop('CT_ARTIFACT', None)
negative = subprocess.run(['python3', str(Path(__file__))], cwd=root, env=missing_artifact,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
(out / 'missing-artifact.log').write_text(negative.stdout)
assert negative.returncode != 0 and 'CT_ARTIFACT required: actual installed owner integration cannot skip' in negative.stdout
print('listener missing-context and missing-artifact controls: PASS', flush=True)
