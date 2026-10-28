#!/usr/bin/env python3
"""Actual synchronous Nim queue / owner Clock2 integration and source inverses.

RealClock and native timer/frame instrumentation delegate to original operations;
actual owner Recorder, codec, run loop and DOM checkpoint are mandatory. Each
inverse builds its OWN copied fixture/source, never a substitute scheduler.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
if not os.environ.get('CT_ARTIFACT'):
    raise SystemExit('CT_ARTIFACT required: actual owner scheduler integration cannot skip')
env = dict(os.environ)
env.setdefault('PLAYWRIGHT_CHROMIUM_EXECUTABLE', shutil.which('chromium') or '')


def compile_js(name, flags=(), source=None, fixture=None):
    output = root / 'build' / (name + '.js')
    command = ['nim', 'js', '-d:isonimInternalReplayReads', *flags]
    if source:
        command += ['--path:' + str(source), '--path:' + str(root.parent / 'nim-everywhere/src')]
    command += ['--nimcache:' + str(root / 'build/nimcache' / name),
                '--out:' + str(output), str(fixture or 'tests/fixtures/replay_scheduler.nim')]
    subprocess.run(command, cwd=root, check=True)
    return output


# Importing the scheduler alone must not drag private module frames/state into
# ordinary or dormant output. The queue's native compatibility test is real.
for name, flags in [('ordinary', []), ('dormant', ['-d:isonimRecordable'])]:
    output = root / 'build' / ('scheduler-omission-' + name + '.js')
    subprocess.run(['nim', 'js', *flags, '--out:' + str(output),
                    'tests/test_scheduler_queue.nim'], cwd=root, check=True)
    text = output.read_text()
    for marker in ['replay_reads.nim', 'ReadReplayClock', 'timerNamespaces',
                   'navigationStates', '__isonimInternalReadReplaySelected']:
        assert marker not in text, (name, marker)
    subprocess.run(['node', str(output)], cwd=root, check=True)
    print(name + ' scheduler actual queue/private module omission PASS', flush=True)

native = compile_js('replay-scheduler-native')
for name, flags in [('default', []), ('recordable', ['-d:isonimRecordable']),
                    ('release', ['-d:release']), ('early', ['-d:replayTimersEarly'])]:
    bundle = compile_js('replay-scheduler-' + name, flags)
    subprocess.run(['node', 'tests/test_replay_scheduler_owner.mjs'], cwd=root,
                   env={**env, 'REPLAY_SCHEDULER_BUNDLE': str(bundle),
                        'REPLAY_SCHEDULER_NATIVE': str(native)}, check=True)

for mutation in ['refusal', 'read', 'inline', 'cancel', 'sort']:
    with tempfile.TemporaryDirectory(prefix='isonim-scheduler-' + mutation + '-') as directory:
        temporary = Path(directory)
        source = temporary / 'src'
        shutil.copytree(root / 'src', source)
        path = source / 'isonim/core/scheduler.nim'
        original = path.read_text()
        if mutation in ('refusal', 'read'):
            original = original.replace('import clock\n', 'import clock\nimport ./private/replay_reads\n')
        if mutation == 'refusal':
            old = '  let clock = currentClock'
            new = '  refuseReadReplay(currentClock, "requestCallback")\n' + old
        elif mutation == 'read':
            old = '  let startTime = if clock != nil: clock.now() else: 0.0'
            new = '  let startTime = if clock.isReadReplay: 0.0 elif clock != nil: clock.now() else: 0.0'
        elif mutation == 'inline':
            old = '  taskQueue.add(task)'
            new = '  fn(false)\n' + old
        elif mutation == 'cancel':
            old = '  task.cancelled = true\n  task.fn = nil'
            new = '  discard # inverse: leave actual callback active'
        else:
            old = '  taskQueue.sort(proc(a, b: Task): int = cmp(a.expirationTime, b.expirationTime))'
            new = '  discard # inverse: leave queue unsorted'
        assert original.count(old) == 1, mutation + ' exact source anchor changed'
        path.write_text(original.replace(old, new))
        fixtures = temporary / 'tests/fixtures'
        fixtures.mkdir(parents=True)
        for name in ['replay_scheduler.nim', 'replay_frames.nim', 'replay_timers.nim', 'replay_reads_bootstrap.nim']:
            shutil.copyfile(root / 'tests/fixtures' / name, fixtures / name)
        bundle = compile_js('replay-scheduler-inverse-' + mutation, source=source,
                            fixture=fixtures / 'replay_scheduler.nim')
        subprocess.run(['node', 'tests/test_replay_scheduler_owner.mjs'], cwd=root,
                       env={**env, 'REPLAY_SCHEDULER_BUNDLE': str(bundle),
                            'REPLAY_SCHEDULER_NATIVE': str(native),
                            'REPLAY_SCHEDULER_INVERSE': mutation}, check=True)
