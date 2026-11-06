#!/usr/bin/env python3
"""Real checkpoint mutation controls with separately judged compile/run phases.

Each inverse uses actual copied production source, the real Nim compiler and
native graph or Chromium. A semantic rejection needs compilation0, runtime1
and the intended source assertion; crashes/setup/BEGIN alone never qualify.
Versioned source variants and physical images remain under build for review.
The optional recorded-runtime interface classifies external evidence only: it
cannot authenticate a historical binary or claim a fresh semantic execution.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parent.parent

# These witnesses name existing assertions in test_signal_checkpoints.nim or
# checkpoint_callbacks.nim. Failed unittest titles are scoped to their own
# preceding diagnostic block, so another case's assertion cannot satisfy them.
REQUIREMENTS = {'xr_m5_mutant_current_lifetime.log': {'test': 'native current contribution '
                                               'owns value through '
                                               'last-reference release and '
                                               'errors',
                                       'fragments': ['current contributor must '
                                                     'read the original '
                                                     'expected value',
                                                     '[AssertionDefect]']},
 'xr_m5_mutant_flush.log': {'test': 'maintenance flush observes genuinely '
                                    'pending batched graph updates',
                            'fragments': ['Check failed: seen[0].hash == '
                                          'expected']},
 'xr_m5_mutant_stop_flush.log': {'test': 'stop during graph flush cancels '
                                         'emission before contributors',
                                 'fragments': ['Check failed: contributions == '
                                               '0']},
 'xr_m5_mutant_initial_idle.log': {'test': 'initial idle observes startup '
                                           'signals once without a dispatch '
                                           'and can cancel',
                                   'fragments': ['Check failed: seen.len == '
                                                 '1']},
 'xr_m5_mutant_failed_start.log': {'test': 'failed initial scheduling releases '
                                           'observer and permits a clean retry',
                                   'fragments': ['Check failed: '
                                                 'backend.checkpointDispatch '
                                                 '== nil']},
 'xr_m5_mutant_stop.log': {'fragments': ['checkpoint callback probe: '
                                         'stop-contribution begin',
                                         'checkpoint callback probe: '
                                         'stop-contribution observed calls=1 '
                                         'contributions=1 value=1',
                                         '`calls == 0`',
                                         'stopped checkpoint session must not '
                                         'emit',
                                         '[AssertionDefect]']},
 'xr_m5_mutant_lease_copy.log': {'test': 'native signal value copy destruction '
                                         'and overwrite preserve live '
                                         'originals',
                                 'fragments': ['Check failed: '
                                               'signalStateHash(0) == before']},
 'xr_m5_mutant_disposal.log': {'fragments': ['checkpoint callback probe: '
                                             'entry-validation begin',
                                             '`observed == expected`',
                                             'disposed registration must not '
                                             'contribute',
                                             '[AssertionDefect]']},
 'xr_m5_mutant_snapshot.log': {'test': 'metadata snapshot bounds contributor '
                                       'creation and tolerates compaction',
                               'fragments': ['Check failed: signalStateHash(0) '
                                             '== expected']},
 'xr_m5_mutant_hash_source.log': {'test': 'user hashes module keeps existing '
                                          'value hash semantics',
                                  'fragments': ['Check failed: before != '
                                                'signalStateHash(0)']},
 'xr_m5_mutant_standard_wrapper.log': {'test': 'standard HashSet wrappers '
                                               'exclude identity and preserve '
                                               'scalar and user members',
                                       'fragments': ['Check failed: '
                                                     'stableContribution(toHashSet([address])) '
                                                     '== "writes"']},
 'xr_m5_mutant_case_fields.log': {'test': 'case value types conservatively '
                                          'exclude identity-bearing '
                                          'alternatives',
                                  'fragments': ['Check failed: '
                                                'stableContribution(VariantIdentity(kind: '
                                                'true,',
                                                '"writes"']},
 'xr_m5_mutant_recursive.log': {'test': 'recursive value hashes terminate '
                                        'while mutual identity cycles use '
                                        'write counts',
                                'fragments': ['Check failed: before != '
                                              'signalStateHash(0)']},
 'xr_m5_mutant_strong.log': {'fragments': ['AssertionError [ERR_ASSERTION]',
                                           '11 !== 10',
                                           'test_signal_checkpoints_browser.mjs']}}


class InvalidEvidence(RuntimeError):
    pass


class CompileFailure(InvalidEvidence):
    pass


def validate_runtime(code, output, requirement):
    if code != 1:
        raise InvalidEvidence(f'expected assertion exit1, received {code}')
    block = output
    if 'test' in requirement:
        title = requirement['test']
        match = re.search(r'^\s*\[FAILED\] ' + re.escape(title) + r'\s*$', output, re.M)
        if match is None:
            raise InvalidEvidence('intended failed test is missing: ' + title)
        earlier = list(re.finditer(r'^\s*\[(?:OK|FAILED)\] .+$', output[:match.start()], re.M))
        begin = earlier[-1].end() if earlier else 0
        block = output[begin:match.end()]
    for fragment in requirement['fragments']:
        if fragment not in block:
            raise InvalidEvidence('intended assertion witness is missing: ' + fragment)


def check_recorded_runtime(path):
    record = json.loads(path.read_text())
    raw_path = Path(record['stdoutPath'])
    raw = raw_path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != record['stdoutSha256']:
        raise InvalidEvidence('recorded raw bytes changed')
    try:
        validate_runtime(record['runtimeExit'], raw.decode(errors='replace'),
                         record['requirement'])
    except InvalidEvidence as error:
        print('recorded runtime evidence refused: ' + str(error), flush=True)
        print('classification only; no binary/image authentication or fresh execution', flush=True)
        return 2
    raise InvalidEvidence('record unexpectedly satisfied the semantic classifier')


def main():
    # An assert here would itself disappear under -O.
    if sys.flags.optimize:
        raise RuntimeError('checkpoint qualification requires Python assertions enabled')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--minimum-available-mib', type=int, default=0)
    parser.add_argument('--minimum-free-mib', type=int, default=0)
    parser.add_argument('--check-runtime-receipt', type=Path)
    args = parser.parse_args()
    if args.check_runtime_receipt:
        return check_recorded_runtime(args.check_runtime_receipt)
    build = root / 'build'
    build.mkdir(exist_ok=True)
    evidence_root = build / 'checkpoint-mutants'
    evidence_root.mkdir(exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix='run-', dir=evidence_root))
    print('checkpoint mutation evidence: ' + str(tmp), flush=True)
    records = []
    serial = 0

    def admit(label, argv):
        nonlocal serial
        while True:
            serial += 1
            available = None
            if Path('/proc/meminfo').exists():
                available = int(next(line.split()[1] for line in
                    Path('/proc/meminfo').read_text().splitlines()
                    if line.startswith('MemAvailable:'))) * 1024
            if args.minimum_available_mib and available is None:
                raise InvalidEvidence('requested memory admission cannot be measured')
            free = shutil.disk_usage(root).free
            permitted = ((not args.minimum_available_mib or
                available >= args.minimum_available_mib * 1024**2) and
                free >= args.minimum_free_mib * 1024**2)
            (tmp / f'{serial:04d}-{label}.admission.json').write_text(json.dumps(dict(
                utc=time.time(), argv=argv, memAvailable=available,
                diskAvailable=free, admitted=permitted), indent=2) + '\n')
            if permitted:
                return
            print(label + ': awaiting pre-child admission', flush=True)
            time.sleep(20)

    def run(label, argv, image=None, phase_inputs=()):
        admit(label, argv)
        binding = None
        if image is not None:
            data = image.read_bytes()
            binding = dict(path=str(image), bytes=len(data),
                           sha256=hashlib.sha256(data).hexdigest())
        inputs = []
        for path in phase_inputs:
            resolved = path.resolve()
            data = resolved.read_bytes()
            inputs.append(dict(path=str(path), resolved=str(resolved), bytes=len(data),
                               sha256=hashlib.sha256(data).hexdigest()))
        with (tmp / (label + '.log')).open('wb') as stream:
            child = subprocess.Popen(argv, cwd=root, stdout=stream,
                                     stderr=subprocess.STDOUT)
            (tmp / (label + '.child.json')).write_text(json.dumps(dict(
                argv=argv, cwd=str(root), pid=child.pid, image=binding, phaseInputs=inputs), indent=2) + '\n')
            code = child.wait()
        raw = (tmp / (label + '.log')).read_bytes()
        outcome = dict(label=label, argv=argv, pid=child.pid, exit=code,
                       stdoutBytes=len(raw), stdoutSha256=hashlib.sha256(raw).hexdigest(),
                       image=binding, phaseInputs=inputs)
        (tmp / (label + '.result.json')).write_text(json.dumps(outcome, indent=2) + '\n')
        records.append(outcome)
        return code, raw.decode(errors='replace')

    def compile_program(command, label):
        if command[:2] not in (['nim', 'c'], ['nim', 'js']):
            raise InvalidEvidence('unexpected compiler command')
        module = command[-1]
        if not module.endswith('.nim'):
            raise InvalidEvidence('compiler module must be explicit')
        target = tmp / 'bin' / (label + ('.js' if command[1] == 'js' else ''))
        target.parent.mkdir(exist_ok=True)
        flags = [x for x in command[2:-1] if x != '-r' and
                 not x.startswith('--out:') and not x.startswith('--nimcache:')]
        actual = [*command[:2], *flags, '--out:' + str(target),
                  '--nimcache:' + str(tmp / ('cache-' + label)), module]
        # Bind the actual import route. Restored programs resolve owning src;
        # copied fixtures use the explicit tmp path. Setup controls import no core.
        variant = tmp / 'variants' / label
        variant.mkdir(parents=True, exist_ok=True)
        source_core = None
        if Path(module).name != 'classifier_setup.nim':
            source_core = core if '--path:' + str(tmp) in flags else root / 'src/isonim/core'
        source_map = {}
        sources = [] if source_core is None else sorted(source_core.glob('*.nim'))
        for source in [*sources, Path(module)]:
            dest = variant / source.name
            data = source.read_bytes()
            dest.write_bytes(data)
            source_map[str(source)] = dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
        (variant / 'SOURCE-PROVENANCE.json').write_text(json.dumps(dict(
            module=module, sourceCore=None if source_core is None else str(source_core),
            coreScope='no core imports' if source_core is None else 'actual explicit import route',
            sources=source_map), indent=2) + '\n')
        code, output = run(label + '-compile', actual)
        if code != 0:
            raise CompileFailure(f'{label}: compiler exit {code}; not a semantic kill\n{output[-3000:]}')
        if not target.is_file():
            raise InvalidEvidence(label + ': compiled image missing')
        return target

    def reject(command, expected, log, browser_artifact=None):
        label = Path(log).stem
        if command[:2] == ['nim', 'c']:
            image = compile_program(command, label)
            actual = [str(image)]
        else:
            actual = command
            image = Path(command[0]) if Path(command[0]).is_file() else None
        phase_inputs = ()
        if browser_artifact is not None:
            image = browser_artifact
            phase_inputs = browser_inputs()
        code, output = run(label, actual, image=image, phase_inputs=phase_inputs)
        # Keep the original declared intent in addition to the precise oracle.
        if expected not in output:
            raise InvalidEvidence(label + ': original intended diagnostic absent')
        validate_runtime(code, output, REQUIREMENTS[log])
        (build / log).write_bytes((tmp / (label + '.log')).read_bytes())
        print(f'{log}: rejected semantic assertion (compile0/runtime1)', flush=True)

    def browser_inputs():
        # Selected PATH executables (and driver), not inferred kernel-exec images.
        return [root / 'tests/test_signal_checkpoints_browser.mjs',
                Path(shutil.which('node')), Path(shutil.which('chromium'))]

    def positive(image, mode, label, required):
        code, output = run(label, [str(image), mode], image=image)
        if code != 0 or required not in output:
            raise InvalidEvidence(label + ': genuine companion failed\n' + output[-3000:])
        return output

    core = tmp / 'isonim/core'
    shutil.copytree(root / 'src/isonim/core', core)
    (tmp / 'isonim/web').mkdir()
    shutil.copyfile(root / 'src/isonim/web/dom_api.nim', tmp / 'isonim/web/dom_api.nim')
    shutil.copytree(root / 'tests/fixtures', tmp / 'tests/fixtures')
    (tmp / 'tests/test_signal_checkpoints.nim').write_text(
        (root / 'tests/test_signal_checkpoints.nim').read_text())
    common = ['--hints:off', '-d:isonimRecordable', '--path:' + str(tmp),
              '--path:' + str(root.parent / 'nim-everywhere/src'),
              ]
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
    # Keep the actual hook alive across the contribution. The positive retains
    # the final activity guard; its otherwise identical inverse removes only
    # that guard. stop() and every earlier activity check remain genuine.
    old = '  let checkpoint = SignalCheckpoint(afterSeq: clock.dispatchSequence,'
    assert original.count(old) == 1
    captured = original.replace(old, '  let capturedHook = session.hook\n' + old)
    assert captured.count('  session.hook(checkpoint)') == 1
    captured = captured.replace('  session.hook(checkpoint)', '  capturedHook(checkpoint)')
    path.write_text(captured)
    callback = compile_program(['nim', 'c', *common,
        str(tmp / 'tests/fixtures/checkpoint_callbacks.nim')], 'stop-captured-guard')
    positive(callback, 'stop-contribution', 'stop-captured-guard-positive',
        'stop-contribution observed calls=0 contributions=1 value=1')
    old = '    hash: signalStateHash(clock.randomDrawCount))\n  if not session.active: return\n'
    assert captured.count(old) == 1
    path.write_text(captured.replace(old,
        '    hash: signalStateHash(clock.randomDrawCount))\n'))
    callback = compile_program(['nim', 'c', *common,
        str(tmp / 'tests/fixtures/checkpoint_callbacks.nim')], 'stop-captured-no-guard')
    reject([str(callback), 'stop-contribution'],
        'stopped checkpoint session must not emit', 'xr_m5_mutant_stop.log')
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
    callback = compile_program(['nim', 'c', *common, str(tmp / 'tests/fixtures/checkpoint_callbacks.nim')], 'entry-validation-mutant')
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
    artifact = compile_program(['nim', 'js', *common, '-d:isonimStrictNondet', str(tmp / 'tests/fixtures/checkpoints_browser.nim')], 'strong-browser-mutant')
    reject(['bash','-c', 'export PLAYWRIGHT_CHROMIUM_EXECUTABLE=$(command -v chromium); node tests/test_signal_checkpoints_browser.mjs "$1"', 'checkpoint-mutant', str(artifact)],
           '11 !== 10', 'xr_m5_mutant_strong.log', browser_artifact=artifact)
    path.write_text(original)

    # An actual compiler rejection must not enter the semantic runtime path.
    setup = tmp / 'classifier_setup.nim'
    setup.write_text('{.error: "intentional compiler-phase classifier control".}\n')
    try:
        compile_program(['nim', 'c', '--hints:off', str(setup)], 'classifier-bad-setup')
    except CompileFailure:
        raw = (tmp / 'classifier-bad-setup-compile.log').read_text()
        if records[-1]['exit'] != 1 or 'intentional compiler-phase classifier control' not in raw:
            raise InvalidEvidence('compiler control failed for an unrelated reason')
        print('actual compiler/setup failure refused; ZERO semantic credit', flush=True)
    else:
        raise InvalidEvidence('compiler rejection control unexpectedly compiled')
    setup.write_text('echo "classifier setup positive PASS"\n')
    setup_image = compile_program(['nim', 'c', '--hints:off', str(setup)], 'classifier-good-setup')
    positive(setup_image, '', 'classifier-good-setup-runtime', 'classifier setup positive PASS')

    # Restored controls use the unchanged owning working tree, not a mutant.
    callback = compile_program(['nim', 'c', '--hints:off', '-d:isonimRecordable',
        str(root / 'tests/fixtures/checkpoint_callbacks.nim')], 'callback-restored')
    for mode in ['stop-contribution', 'entry-validation']:
        positive(callback, mode, 'restored-' + mode, 'checkpoint callback probe: ' + mode + ' PASS')
    restored = compile_program(['nim', 'c', '--hints:off', '-d:isonimRecordable',
        str(root / 'tests/test_signal_checkpoints.nim')], 'native-restored')
    code, output = run('native-restored-runtime', [str(restored)], image=restored)
    catalog = re.findall(r'^\s*test "([^"]+)"', (root / 'tests/test_signal_checkpoints.nim').read_text(), re.M)
    observed = re.findall(r'^\s*\[OK\] (.+)$', output, re.M)
    if code != 0 or observed != catalog or '[FAILED]' in output:
        raise InvalidEvidence('restored native catalog failed')
    code, output = run('browser-restored', ['bash', '-c',
        'export PLAYWRIGHT_CHROMIUM_EXECUTABLE=$(command -v chromium); node tests/test_signal_checkpoints_browser.mjs'],
        image=root / 'build/checkpoints_browser.js', phase_inputs=browser_inputs())
    if code != 0 or 'checkpoint browser events/microtasks/timer/frame/network/idle/GC: PASS' not in output:
        raise InvalidEvidence('restored real browser failed')
    (tmp / 'COMPLETE.json').write_text(json.dumps(dict(
        semanticInverses=14, pythonOptimization=sys.flags.optimize,
        records=records, restoredCatalog=catalog, physicalArtifactsRetained=True), indent=2) + '\n')
    print('checkpoint mutations rejected in isolation; production controls PASS', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
