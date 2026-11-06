#!/usr/bin/env python3
"""Real compiler/graph controls for the opt-in private flush observation leaf.

No queues/callbacks are mocked. Mutations temporarily change only the owning
batch source, restore it in finally, compile real test programs, then require a
specific semantic failure after its real-work witness. Compiler/setup/crash
failures cannot count as semantic inverse rejection. Optional admission limits
control only when a child starts, never what its outcome means.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
BATCH = ROOT / 'src/isonim/core/batch.nim'
BASE = 'b338890f6f44876384af64294831cf3cbf942931'


def main():
    if sys.flags.optimize:
        raise RuntimeError("qualification requires Python assertions enabled")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent', default=BASE)
    parser.add_argument('--minimum-available-mib', type=int, default=0)
    parser.add_argument('--minimum-free-mib', type=int, default=0)
    args = parser.parse_args()
    output = ROOT / 'build/internal-flush-observation'
    output.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix='run-', dir=output))
    print(f'flush observation evidence: {evidence}', flush=True)
    serial = 0

    def admit(name, argv):
        nonlocal serial
        while True:
            serial += 1
            available = None
            if Path('/proc/meminfo').exists():
                available = int(next(line.split()[1] for line in
                                     Path('/proc/meminfo').read_text().splitlines()
                                     if line.startswith('MemAvailable:'))) * 1024
            if args.minimum_available_mib and available is None:
                raise RuntimeError('requested memory admission cannot be measured')
            disk = shutil.disk_usage(ROOT).free
            permitted = ((not args.minimum_available_mib or
                          available >= args.minimum_available_mib * 1024**2) and
                         disk >= args.minimum_free_mib * 1024**2)
            record = dict(utc=time.time(), argv=argv, cwd=str(ROOT),
                          memAvailable=available, diskAvailable=disk,
                          admitted=permitted)
            (evidence / f'{serial:04d}-{name}.admission.json').write_text(
                json.dumps(record, indent=2) + '\n')
            if permitted:
                return
            print(f'{name}: awaiting pre-child admission', flush=True)
            time.sleep(20)

    def run(name, argv, *, failure=None, witness=None, required=None):
        admit(name, argv)
        with (evidence / (name + '.log')).open('wb') as stream:
            child = subprocess.Popen(argv, cwd=ROOT, stdout=stream,
                                     stderr=subprocess.STDOUT)
            (evidence / (name + '.child.json')).write_text(json.dumps(
                dict(pid=child.pid, argv=argv, cwd=str(ROOT)), indent=2) + '\n')
            code = child.wait()
        raw = (evidence / (name + '.log')).read_bytes()
        (evidence / (name + '.result.json')).write_text(json.dumps(
            dict(exit=code, bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest()),
            indent=2) + '\n')
        text = raw.decode(errors='replace')
        if failure is None:
            assert code == 0, f'{name} exit {code}: {text[-5000:]}'
        else:
            assert code == 1, f'{name} is not the expected semantic refusal: {code}'
            assert failure in text and witness in text, f'{name}: {text[-5000:]}'
            assert text.index(witness) < text.index(failure), name
        if required:
            assert required in text, f'{name}: missing {required!r}'
        print(f'{name}: verified exit {code}', flush=True)
        return raw

    def compile_case(name, backend, source, *, flags=()):
        artifact = evidence / (name + ('.js' if backend == 'js' else ''))
        argv = ['nim', backend, '--hints:off', '--out:' + str(artifact),
                '--nimcache:' + str(evidence / ('cache-' + name)), '--path:' + str(ROOT / 'src'),
                '--path:' + str(ROOT.parent / 'nim-everywhere/src'), *flags, str(source)]
        run(name + '-compile', argv)
        return artifact

    def execute(name, artifact, *, js=False, **kwargs):
        return run(name, ['node', str(artifact)] if js else [str(artifact)], **kwargs)

    original = BATCH.read_bytes()
    (evidence / 'candidate-batch.nim').write_bytes(original)
    named = ['src/isonim/core/batch.nim', 'src/isonim/core/graph.nim',
             'src/isonim/core/computation.nim', 'src/isonim/core/signals.nim',
             'src/isonim/core/owner.nim', 'tests/test_internal_flush_observation.nim',
             'tests/fixtures/internal_flush_observation_unused.nim',
             'tests/fixtures/internal_flush_observation_threads.nim',
             'tools/test_internal_flush_observation.py', 'Justfile',
             'tests/test_effects.nim', 'config.nims', 'tests/config.nims',
             'flake.lock', 'flake.nix', 'repro.lock', 'repro.nim']
    before = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
              for name in named}
    (evidence / 'inputs.json').write_text(json.dumps(before, indent=2) + '\n')
    admit('tool-bindings', ['read-real-tool-identities'])
    tools = {}
    for tool in ['nim', 'node', 'python3', 'cc']:
        selected = shutil.which(tool)
        assert selected, tool
        tools[tool] = dict(path=selected, resolved=str(Path(selected).resolve()),
                           sha256=hashlib.sha256(Path(selected).read_bytes()).hexdigest())
    tools['pythonOptimize'] = sys.flags.optimize
    (evidence / 'tools.json').write_text(json.dumps(tools, indent=2) + '\n')
    run('nim-version', ['nim', '--version'])

    # Identical absolute entry and OUTPUT path, fresh caches, literal output.
    # Only batch source changes during this owned restoration transaction.
    ordinary_out = output / 'ordinary.js'
    ordinary_entry = ROOT / 'tests/test_effects.nim'
    ordinary_flags = ['--hints:off', '-d:release', '--stackTrace:off', '--lineTrace:off']
    parent_source = subprocess.check_output(
        ['git', 'show', args.parent + ':src/isonim/core/batch.nim'], cwd=ROOT,
        env=dict(os.environ, GIT_OPTIONAL_LOCKS='0', GIT_NO_LAZY_FETCH='1'))
    (evidence / 'parent-batch.nim').write_bytes(parent_source)
    try:
        BATCH.write_bytes(parent_source)
        run('ordinary-parent-compile', ['nim', 'js', *ordinary_flags,
            '--out:' + str(ordinary_out), '--nimcache:' + str(evidence / 'cache-parent'),
            str(ordinary_entry)])
        parent = ordinary_out.read_bytes()
        (evidence / 'parent.js').write_bytes(parent)
    finally:
        BATCH.write_bytes(original)
    run('ordinary-candidate-compile', ['nim', 'js', *ordinary_flags,
        '--out:' + str(ordinary_out), '--nimcache:' + str(evidence / 'cache-candidate'),
        str(ordinary_entry)])
    candidate = ordinary_out.read_bytes()
    (evidence / 'candidate.js').write_bytes(candidate)
    assert candidate == parent, 'ordinary shipping release output changed (unnormalized)'
    run('ordinary-real-behavior', ['python3', 'tools/run_nim_js_test.py', str(ordinary_out)])

    # Debug ordinary real graph behavior is independent of release byte equality.
    for backend in ['c', 'js']:
        artifact = compile_case('ordinary-debug-' + backend, backend, ordinary_entry)
        if backend == 'js':
            run('ordinary-debug-js', ['python3', 'tools/run_nim_js_test.py', str(artifact)])
        else:
            execute('ordinary-debug-c', artifact)
    expected_scenarios = ['local', 'activity', 'nested', 'throw', 'reset', 'reuse',
                          'caught-inner', 'ambient-exception', 'open-batch-and-pure',
                          'direct-and-invalid', 'nested-first-query']

    def verify_scenarios(raw):
        lines = raw.decode().splitlines()
        assert [line[6:] for line in lines if line.startswith('BEGIN:')] == expected_scenarios
        assert [line[5:] for line in lines if line.startswith('PASS:')] == expected_scenarios
        assert lines.count('INTERNAL FLUSH OBSERVATION COMPLETE') == 1

    source = ROOT / 'tests/test_internal_flush_observation.nim'
    enabled = ['-d:isonimInternalFlushObservation']
    for backend in ['c', 'js']:
        artifact = compile_case('enabled-' + backend, backend, source, flags=enabled)
        verify_scenarios(execute('enabled-' + backend, artifact, js=backend == 'js',
                required='INTERNAL FLUSH OBSERVATION COMPLETE'))
        unused = compile_case('unused-' + backend, backend,
            ROOT / 'tests/fixtures/internal_flush_observation_unused.nim', flags=enabled)
        execute('unused-' + backend, unused, js=backend == 'js',
                required='UNUSED REAL GRAPH ZERO TOKEN CONSTRUCTIONS; OBSERVED POSITIVE ONE')
        combined = compile_case('recordable-enabled-' + backend, backend, source,
                                flags=[*enabled, '-d:isonimRecordable'])
        verify_scenarios(execute('recordable-enabled-' + backend, combined, js=backend == 'js',
                required='INTERNAL FLUSH OBSERVATION COMPLETE'))

    # Native compilation must retain actual TLS, including when the graph's
    # existing callback API prevents a GC-safe two-thread runtime caller.
    thread_source = ROOT / 'tests/fixtures/internal_flush_observation_threads.nim'
    thread_artifact = evidence / 'threads'
    command = ['nim', 'c', '--hints:off', '--threads:on', *enabled,
               '--path:' + str(ROOT / 'src'),
               '--path:' + str(ROOT.parent / 'nim-everywhere/src'),
               '--nimcache:' + str(evidence / 'cache-threads'),
               '--out:' + str(thread_artifact), str(thread_source)]
    admit('threads-compile', command)
    with (evidence / 'threads-compile.log').open('wb') as stream:
        child = subprocess.Popen(command, cwd=ROOT, stdout=stream,
                                 stderr=subprocess.STDOUT)
        thread_code = child.wait()
    thread_raw = (evidence / 'threads-compile.log').read_text()
    (evidence / 'threads-compile.result.json').write_text(json.dumps(dict(
        exit=thread_code, argv=command, pid=child.pid), indent=2) + '\n')
    thread_runtime = False
    if thread_code == 0:
        execute('threads-real-runtime', thread_artifact,
                required='TWO REAL THREAD GRAPH EPOCHS INDEPENDENT')
        thread_runtime = True
    else:
        assert thread_code == 1 and "not GC-safe" in thread_raw, thread_raw
        assert "'createRoot' is not GC-safe as it performs an indirect call via 'fn'" in thread_raw, thread_raw
        assert "Error: 'worker' is not GC-safe as it calls 'createRoot'" in thread_raw, thread_raw
        assert 'owner.nim' in thread_raw and thread_source.name in thread_raw, thread_raw
        assert thread_raw.count('Error:') == 1, thread_raw
        (evidence / 'THREAD-LIMIT.md').write_text(
            'The real two-thread graph caller is not GC-safe under the owning compiler. '
            'No casts or callback replacement were used. This is a measured compile '
            'limit, NOT runtime cross-thread qualification.\n')
    generated_c = [path for path in (evidence / 'cache-enabled-c').glob('*.nim.c')
                   if str(BATCH) in path.read_text() and any(
                       'NIM_THREADVAR' in line and 'activeFlushDepth__' in line
                       for line in path.read_text().splitlines())]
    assert len(generated_c) == 1, generated_c
    native_batch = generated_c[0].read_text()
    # Native compiler output, rather than a JS or fake-depth stand-in.
    for state_name in ['activeFlushDepth', 'activeFlushEpoch', 'flushEpochConstructions']:
        declarations = [line for line in native_batch.splitlines()
                        if state_name + '__' in line and 'NIM_THREADVAR' in line]
        assert declarations, (state_name, 'native TLS declaration missing')
    (evidence / 'native-batch.c').write_bytes(generated_c[0].read_bytes())
    (evidence / 'native-source.json').write_text(json.dumps(dict(
        path=str(generated_c[0]), bytes=generated_c[0].stat().st_size,
        sha256=hashlib.sha256(generated_c[0].read_bytes()).hexdigest()), indent=2) + '\n')

    # Every exported type, enum member and query is unavailable in ordinary mode.
    # The SAME source compiles/runs genuine graph work with the define enabled.
    symbols = {
        'InternalFlushState': 'var value: InternalFlushState\ndiscard value',
        'ifsActive': 'discard ifsActive', 'ifsReturned': 'discard ifsReturned',
        'ifsUnwound': 'discard ifsUnwound',
        'InternalFlushEpoch': 'var value: InternalFlushEpoch\ndiscard value',
        'InternalBatchActivity': 'var value: InternalBatchActivity\ndiscard value',
        'currentInternalFlushEpoch': 'discard currentInternalFlushEpoch()',
        'internalFlushState': 'let reader = internalFlushState\ndiscard reader(currentInternalFlushEpoch())',
        'internalBatchActivity': 'discard internalBatchActivity()',
        'internalFlushEpochConstructionCount': 'discard internalFlushEpochConstructionCount()',
    }
    fixture_dir = ROOT / 'tests/fixtures/internal-flush-generated'
    assert not fixture_dir.exists(), 'refuse to overwrite another fixture directory'
    fixture_dir.mkdir()
    try:
        symbol_map = []
        for ordinal, (symbol, statement) in enumerate(symbols.items()):
            case_id = f'{ordinal:02d}-' + symbol
            fixture = fixture_dir / (f'probe_{ordinal:02d}_' + symbol + '.nim')
            symbol_map.append(dict(ordinal=ordinal, symbol=symbol, fixture=fixture.name,
                                   evidenceStem='omission-' + case_id))
            # This actual callback runs inside a real flush on the positive route.
            indented = '\n'.join('      ' + line for line in statement.splitlines())
            fixture.write_text('import isonim/core/[batch, signals, computation, owner]\n'
                'let source = createSignal(0)\nvar calls = 0\n'
                'createRoot proc(dispose: proc()) =\n  defer: dispose()\n'
                '  createEffect proc() =\n    if source.val > 0:\n'
                '      inc calls\n' + indented + '\n'
                '  batch proc() = source.val = 1\n'
                'doAssert calls == 1\necho "OMISSION POSITIVE REAL FLUSH"\n')
            (evidence / ('omission-source-' + case_id + '.nim')).write_bytes(fixture.read_bytes())
            for backend in ['c', 'js']:
                name = 'omission-' + case_id + '-' + backend
                # Compile-negative diagnostic must name this absent symbol.
                command = ['nim', backend, '--hints:off', '--out:' + str(evidence / name),
                           '--nimcache:' + str(evidence / ('cache-' + name)),
                           '--path:' + str(ROOT / 'src'),
                           '--path:' + str(ROOT.parent / 'nim-everywhere/src'), str(fixture)]
                admit(name, command)
                with (evidence / (name + '.log')).open('wb') as stream:
                    child = subprocess.Popen(command, cwd=ROOT, stdout=stream,
                                             stderr=subprocess.STDOUT)
                    code = child.wait()
                raw = (evidence / (name + '.log')).read_text()
                assert code == 1 and ("undeclared identifier: '" + symbol + "'") in raw, raw
                (evidence / (name + '.result.json')).write_text(json.dumps(
                    dict(exit=code, argv=command, diagnosticSymbol=symbol, pid=child.pid)) + '\n')
                positive = compile_case(name + '-positive', backend, fixture, flags=enabled)
                execute(name + '-positive', positive, js=backend == 'js',
                        required='OMISSION POSITIVE REAL FLUSH')
            assert fixture.read_bytes() == (evidence / ('omission-source-' + case_id + '.nim')).read_bytes()
        for key in ['fixture', 'evidenceStem']:
            names = [row[key].casefold() for row in symbol_map]
            assert len(names) == len(set(names)), 'case-insensitive evidence collision'
        (evidence / 'omission-symbol-map.json').write_text(json.dumps(symbol_map, indent=2) + '\n')
    finally:
        shutil.rmtree(fixture_dir)

    mutations = [
        ('premature', 'local',
         '      inc flushEpochConstructions\n',
         '      inc flushEpochConstructions\n      activeFlushEpoch.state = ifsReturned\n',
         'FAIL:local-active', 'WITNESS:local:first-effect'),
        ('nested', 'nested', '      if activeFlushDepth == 0:\n',
         '      if true:\n', 'FAIL:nested-outer-still-active',
         'WITNESS:nested:inner-returned'),
        ('exception-returned', 'throw',
         'if internalFlushReturned: ifsReturned else: ifsUnwound',
         'if internalFlushReturned: ifsReturned else: ifsReturned',
         'FAIL:throw-unwound', 'WITNESS:throw:original-object-caught'),
        ('exception-reset', 'reset', '        activeFlushEpoch = nil\n',
         '        if internalFlushReturned: activeFlushEpoch = nil\n',
         'FAIL:reset-fresh-after-unwind', 'WITNESS:reset:subsequent-success-ran'),
        ('reuse', 'reuse', '        activeFlushEpoch = nil\n',
         '        discard # inverse retains one epoch across outer flushes\n',
         'FAIL:reuse-fresh-identities', 'WITNESS:reuse:two-successes-ran'),
        ('global-empty', 'activity', 'activeFlushDepth: activeFlushDepth,\n',
         'activeFlushDepth: (if Updates.len == 0 and Effects.len == 0: 0 else: activeFlushDepth),\n',
         'FAIL:activity-local-work-is-active', 'WITNESS:activity:first-effect'),
    ]
    # Freeze and execute the SAME selected-scenario compile path on unchanged
    # production source before applying any inverse. Exact single-case markers
    # ensure a misspelled string define cannot silently execute zero cases.
    for name, selected, _anchor, _replacement, _failure, _witness in mutations:
        companion = compile_case('companion-' + name, 'c', source,
            flags=[*enabled, '-d:observationScenario=' + selected])
        raw = execute('companion-' + name, companion,
                      required='INTERNAL FLUSH OBSERVATION COMPLETE')
        lines = raw.decode().splitlines()
        assert [line for line in lines if line.startswith('BEGIN:')] == ['BEGIN:' + selected]
        assert [line for line in lines if line.startswith('PASS:')] == ['PASS:' + selected]
        assert lines.count('INTERNAL FLUSH OBSERVATION COMPLETE') == 1

    try:
        text = original.decode()
        for name, selected, anchor, replacement, failure, witness in mutations:
            assert text.count(anchor) == 1, f'{name}: source anchor is not unique'
            mutant = text.replace(anchor, replacement)
            (evidence / (name + '-batch.nim')).write_text(mutant)
            BATCH.write_text(mutant)
            artifact = compile_case('inverse-' + name, 'c', source,
                flags=[*enabled, '-d:observationScenario=' + selected])
            execute('inverse-' + name, artifact, failure=failure, witness=witness)
    finally:
        BATCH.write_bytes(original)
    after = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
             for name in named}
    assert before == after, 'source/config drift during qualification'
    (evidence / 'COMPLETE.json').write_text(json.dumps(dict(
        parent=args.parent, sourceInputs=before, semanticInverses=len(mutations),
        ordinaryLiteralBytes=len(candidate), ordinarySha256=hashlib.sha256(candidate).hexdigest(),
        nativeCrossThreadRuntimeQualified=thread_runtime,
        limits='No stop/quiescence, event/microtask drainage, GC or privacy acceptance'),
        indent=2) + '\n')
    print('PRIVATE FLUSH OBSERVATION QUALIFICATION COMPLETE', flush=True)


if __name__ == '__main__':
    main()
