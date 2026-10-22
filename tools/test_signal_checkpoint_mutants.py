#!/usr/bin/env python3
"""Reject checkpoint bugs using isolated real-compiler/native/Chromium runs."""
from pathlib import Path
import subprocess
import tempfile
import shutil

root = Path(__file__).resolve().parent.parent

def reject(command, expected, log):
    result = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (root / 'build' / log).write_text(result.stdout)
    assert result.returncode != 0, f'mutation survived: {log}'
    assert expected in result.stdout, result.stdout[-4000:]
    print(f'{log}: rejected ({result.returncode})', flush=True)

with tempfile.TemporaryDirectory(prefix='signal-checkpoint-mutants-') as temporary:
    tmp = Path(temporary)
    core = tmp / 'isonim/core'
    shutil.copytree(root / 'src/isonim/core', core)
    (tmp / 'isonim/web').mkdir()
    shutil.copyfile(root / 'src/isonim/web/dom_api.nim', tmp / 'isonim/web/dom_api.nim')
    shutil.copytree(root / 'tests/fixtures', tmp / 'tests/fixtures')
    (tmp / 'tests/test_signal_checkpoints.nim').write_text(
        (root / 'tests/test_signal_checkpoints.nim').read_text())
    common = ['--hints:off', '-d:isonimRecordable', '--path:' + str(tmp),
              '--path:' + str(root.parent / 'nim-everywhere/src'),
              '--nimcache:' + str(root / '.nimcache/checkpoint-mutants')]
    path = core / 'signals.nim'
    original = path.read_text()
    old = '      GC_ref(signal)\n      defer: GC_unref(signal)\n'
    assert original.count(old) == 1
    path.write_text(original.replace(old, ''))
    reject(['nim', 'c', '-r', *common, '--out:' + str(tmp / 'current-lifetime'), str(tmp / 'tests/test_signal_checkpoints.nim')],
           '[FAILED] native current contribution owns value through last-reference release and errors', 'xr_m5_mutant_current_lifetime.log')
    path.write_text(original)
    path = core / 'checkpoints.nim'
    original = path.read_text()
    old = '  flushUpdates()\n  if not session.active: return\n  let checkpoint = SignalCheckpoint(afterSeq: clock.dispatchSequence,\n    hash: signalStateHash(clock.randomDrawCount))'
    new = '  let checkpoint = SignalCheckpoint(afterSeq: clock.dispatchSequence,\n    hash: signalStateHash(clock.randomDrawCount))\n  flushUpdates()\n  if not session.active: return'
    assert original.count(old) == 1
    path.write_text(original.replace(old, new))
    reject(['nim', 'c', '-r', *common, '--out:' + str(tmp / 'before-flush'), str(tmp / 'tests/test_signal_checkpoints.nim')],
           '[FAILED] maintenance flush observes genuinely pending batched graph updates', 'xr_m5_mutant_flush.log')
    path.write_text(original)
    old = '  flushUpdates()\n  if not session.active: return'
    assert original.count(old) == 1
    path.write_text(original.replace(old, '  flushUpdates()'))
    reject(['nim', 'c', '-r', *common, '--out:' + str(tmp / 'stop-flush'), str(tmp / 'tests/test_signal_checkpoints.nim')],
           '[FAILED] stop during graph flush cancels emission before contributors', 'xr_m5_mutant_stop_flush.log')
    path.write_text(original)
    # Remove only initial scheduling; dispatched idle observation still works.
    assert original.count('  try:\n    armIdle()\n') == 1
    path.write_text(original.replace('  try:\n    armIdle()\n', '  try:\n    discard\n'))
    reject(['nim', 'c', '-r', *common, '--out:' + str(tmp / 'no-initial-idle'), str(tmp / 'tests/test_signal_checkpoints.nim')],
           '[FAILED] initial idle observes startup signals once without a dispatch and can cancel', 'xr_m5_mutant_initial_idle.log')
    path.write_text(original)
    old = '  except:\n    session.stop()\n    raise\n'
    assert original.count(old) == 1
    path.write_text(original.replace(old, '  except:\n    raise\n'))
    reject(['nim', 'c', '-r', *common, '--out:' + str(tmp / 'failed-start'), str(tmp / 'tests/test_signal_checkpoints.nim')],
           '[FAILED] failed initial scheduling releases observer and permits a clean retry', 'xr_m5_mutant_failed_start.log')
    path.write_text(original)
    # Callback cancellation is exercised in an isolated process so a nil-hook
    # regression cannot prevent the remaining lifecycle controls from running.
    begin = original.index('proc emitCheckpoint(')
    end = original.index('proc startCheckpoints*(')
    emission = original[begin:end]
    old = '  if not session.active: return\n'
    assert emission.count(old) == 3
    path.write_text(original[:begin] + emission.replace(old, '') + original[end:])
    callback = tmp / 'callback'
    subprocess.run(['nim', 'c', *common, '--out:' + str(callback), str(tmp / 'tests/fixtures/checkpoint_callbacks.nim')], cwd=root, check=True)
    reject([str(callback), 'stop-contribution'], 'checkpoint callback probe: stop-contribution begin', 'xr_m5_mutant_stop.log')
    path.write_text(original)
    path = core / 'checkpoint_registry.nim'
    original = path.read_text()
    old = '    if lease.registration != nil and\n        lease.registration.leaseAddress == cast[pointer](addr lease):'
    assert original.count(old) == 1
    path.write_text(original.replace(old, '    if lease.registration != nil:'))
    reject(['nim', 'c', '-r', *common, '--out:' + str(tmp / 'lease-copy'), str(tmp / 'tests/test_signal_checkpoints.nim')],
           '[FAILED] native signal value copy destruction and overwrite preserve live originals', 'xr_m5_mutant_lease_copy.log')
    path.write_text(original)
    assert original.count('    if not entry.active: continue') == 2
    path.write_text(original.replace('    if not entry.active: continue', '    # mutated activity validation'))
    subprocess.run(['nim', 'c', *common, '--out:' + str(callback), str(tmp / 'tests/fixtures/checkpoint_callbacks.nim')], cwd=root, check=True)
    reject([str(callback), 'entry-validation'], 'disposed registration must not contribute', 'xr_m5_mutant_disposal.log')
    path.write_text(original)
    mutations = [
        ('snapshot', '  for entry in snapshot:', '  for entry in registrations:', '[FAILED] metadata snapshot', 'xr_m5_mutant_snapshot.log'),
        ('hash-source', 'source != standardSource', 'source.split("/")[^1] != standardSource.split("/")[^1]', '[FAILED] user hashes module keeps existing value hash semantics', 'xr_m5_mutant_hash_source.log'),
        ('standard-wrapper', 'source != standardSource and (not inStandardLibrary or not generic)', 'source != standardSource', '[FAILED] standard HashSet wrappers exclude identity and preserve scalar and user members', 'xr_m5_mutant_standard_wrapper.log'),
        ('case-fields', '  elif T is object:\n    stableObjectFields(T)\n  elif T is tuple:', '  elif T is tuple or T is object:', '[FAILED] case value types conservatively exclude identity-bearing alternatives', 'xr_m5_mutant_case_fields.log'),
        ('recursive', 'if identity in seen: return true', 'if identity in seen: return false', '[FAILED] recursive value hashes terminate while mutual identity cycles use write counts', 'xr_m5_mutant_recursive.log'),
    ]
    for name, old, new, expected, log in mutations:
        assert original.count(old) == 1
        path.write_text(original.replace(old, new))
        reject(['nim', 'c', '-r', *common, '--out:' + str(tmp / name), str(tmp / 'tests/test_signal_checkpoints.nim')], expected, log)
        path.write_text(original)
    assert original.count('new WeakRef(#)') == 1
    path.write_text(original.replace('new WeakRef(#)', '(function(value){return {deref:function(){return value;}};})(#)'))
    artifact = tmp / 'strong.js'
    subprocess.run(['nim','js',*common,'-d:isonimStrictNondet','--out:' + str(artifact),str(tmp / 'tests/fixtures/checkpoints_browser.nim')],cwd=root,check=True)
    reject(['bash','-c', 'export PLAYWRIGHT_CHROMIUM_EXECUTABLE=$(command -v chromium); node tests/test_signal_checkpoints_browser.mjs "$1"', 'checkpoint-mutant', str(artifact)],
           '11 !== 10', 'xr_m5_mutant_strong.log')
# Both production controls run against the unchanged working tree.
subprocess.run(['nim','c','--hints:off','-d:isonimRecordable','--out:build/checkpoint_callback_restored','tests/fixtures/checkpoint_callbacks.nim'],cwd=root,check=True)
for mode in ['stop-contribution', 'entry-validation']:
    subprocess.run([str(root / 'build/checkpoint_callback_restored'), mode],cwd=root,check=True)
subprocess.run(['nim','c','-r','--hints:off','-d:isonimRecordable','--out:build/checkpoint_restored','tests/test_signal_checkpoints.nim'],cwd=root,check=True)
subprocess.run(['bash','-c','export PLAYWRIGHT_CHROMIUM_EXECUTABLE=$(command -v chromium); node tests/test_signal_checkpoints_browser.mjs'],cwd=root,check=True)
print('checkpoint mutations rejected in isolation; production controls PASS')
