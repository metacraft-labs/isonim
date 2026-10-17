"""Real native process/filesystem tests; no OS/process metadata is mocked.

Real children and argument paths containing spaces, punctuation and empty values
exercise both the portable ps enumeration and native identity boundary. Linux
runs both observers; Darwin's native APIs are exercised when run on that host.
Controlled Python children also exercise the original acceptance stderr reader
without starting Harbor or inference: real subprocess pipes, a real log file,
Linux /dev/full, and a live owned writer distinguish EOF, error and blocking.
No streams, log sinks or queue operations are mocked.
"""
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import time
import json
import queue
import signal
import threading
import unittest

from helpers.editor_process_observer import (
    LinuxProcessObserver, PosixProcessObserver, optional_sibling_available,
    capture_owned, reap_owned,
)
from test_editor_harbor_scenario import OwnedStderrReader


class ProcessObserverTests(unittest.TestCase):
    def test_original_stderr_reader_reaches_actual_eof_and_preserves_log_and_queue(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'stderr.log'
            with path.open('w') as log:
                child = subprocess.Popen([sys.executable, '-c',
                    'import sys; sys.stderr.write("first\\nsecond\\n"); sys.stderr.flush()'],
                    stderr=subprocess.PIPE, text=True)
                lines = queue.Queue()
                reader = OwnedStderrReader(child.stderr, log, lines)
                reader.start()
                try:
                    self.assertEqual(child.wait(timeout=5), 0)
                    reader.join(timeout=5)
                    self.assertFalse(reader.is_alive())
                    self.assertTrue(reader.eof)
                    self.assertEqual(reader.errors, [])
                    self.assertEqual(path.read_text(), 'first\nsecond\n')
                    self.assertEqual([lines.get_nowait(), lines.get_nowait()], ['first\n', 'second\n'])
                    self.assertTrue(lines.empty())
                finally:
                    if child.poll() is None: child.kill()
                    child.wait(timeout=5)
                    reader.join(timeout=5)
                    if not reader.is_alive(): child.stderr.close()

    @unittest.skipUnless(sys.platform == 'linux', 'real /dev/full failure boundary requires Linux')
    def test_original_stderr_reader_dead_after_real_log_failure_is_not_eof(self):
        log = open('/dev/full', 'w')
        child = subprocess.Popen([sys.executable, '-c',
            'import sys; sys.stderr.write("cannot persist this line\\n"); sys.stderr.flush()'],
            stderr=subprocess.PIPE, text=True)
        lines = queue.Queue()
        reader = OwnedStderrReader(child.stderr, log, lines)
        reader.start()
        try:
            self.assertEqual(child.wait(timeout=5), 0)
            reader.join(timeout=5)
            # The former not-is_alive predicate accepts this failed reader.
            self.assertFalse(reader.is_alive())
            self.assertFalse(reader.eof)
            self.assertEqual(len(reader.errors), 1)
            self.assertIn('OSError(28,', reader.errors[0])
            self.assertTrue(lines.empty(), 'unpersisted line must not become readiness evidence')
        finally:
            if child.poll() is None: child.kill()
            child.wait(timeout=5)
            reader.join(timeout=5)
            if not reader.is_alive(): child.stderr.close()
            try: log.close()
            except OSError as error:
                self.assertEqual(error.errno, 28)  # Actual buffered sink can fail again at close.

    def test_original_stderr_reader_waits_for_owned_writer_to_close_before_eof(self):
        with tempfile.TemporaryDirectory() as directory:
            gate = Path(directory) / 'close'
            with (Path(directory) / 'stderr.log').open('w') as log:
                child = subprocess.Popen([sys.executable, '-c',
                    'import sys,time; from pathlib import Path; '
                    'sys.stderr.write("writer ready\\n"); sys.stderr.flush(); '
                    'exec("while not Path(sys.argv[1]).exists(): time.sleep(.01)")', str(gate)],
                    stderr=subprocess.PIPE, text=True)
                lines = queue.Queue()
                reader = OwnedStderrReader(child.stderr, log, lines)
                reader.start()
                try:
                    self.assertEqual(lines.get(timeout=5), 'writer ready\n')
                    reader.join(timeout=.05)
                    self.assertTrue(reader.is_alive())
                    self.assertFalse(reader.eof)
                    self.assertEqual(reader.errors, [])
                    self.assertIsNone(child.poll())
                    gate.touch()
                    self.assertEqual(child.wait(timeout=5), 0)
                    reader.join(timeout=5)
                    self.assertFalse(reader.is_alive())
                    self.assertTrue(reader.eof)
                    self.assertEqual(reader.errors, [])
                finally:
                    if child.poll() is None: child.kill()
                    child.wait(timeout=5)
                    reader.join(timeout=5)
                    if not reader.is_alive(): child.stderr.close()

    def test_already_dead_reload_host_sigterm_is_not_normal_cleanup(self):
        # Isolate the real cleanup resource owner without producer/model setup.
        # Actual child signal, wait status, readers and filesystem are unchanged.
        from helpers.editor_scenario_runtime import Runtime
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); runtime=Runtime.__new__(Runtime)
            runtime.project=root/'project'; runtime.project.mkdir()
            runtime.source_file='stories.nim'; runtime.before='unchanged source\n'
            (runtime.project/runtime.source_file).write_text(runtime.before)
            runtime.artifacts=runtime.project/'.scenario'; runtime.artifacts.mkdir(mode=0o700)
            runtime.private=runtime.artifacts/'private'; runtime.private.mkdir(mode=0o700)
            runtime.observer=PosixProcessObserver(); runtime.handoffStop=threading.Event()
            runtime.handles=[]; runtime.children=[]; runtime.readers=[]; runtime.readerErrors=[]
            runtime.ownedProcesses={}; runtime.childRoles={}; runtime.lines=queue.Queue(); runtime.env=dict(os.environ)
            ready=root/'ready'
            child=runtime.spawn([sys.executable,'-c',
                'import sys,time; from pathlib import Path; Path(sys.argv[1]).write_text("ready"); time.sleep(60)',str(ready)],'reload-host')
            try:
                deadline=time.monotonic()+10
                while not ready.exists() and time.monotonic()<deadline:time.sleep(.01)
                self.assertTrue(ready.exists())
                runtime.ownedProcesses=capture_owned(runtime.observer.snapshot(),[child.pid])
                child.terminate(); self.assertEqual(child.wait(timeout=5),-signal.SIGTERM)
                with self.assertRaisesRegex(AssertionError,'reload-host native exit -15; expected \\[0\\]'):
                    runtime.close()
                proof=json.loads((runtime.artifacts/'native-exits.json').read_text())
                self.assertEqual(proof,[{'role':'reload-host','pid':child.pid,'returncode':-signal.SIGTERM,'allowed':[0]}])
                self.assertNotIn(child.pid,runtime.observer.snapshot())
                self.assertTrue(all(not reader.is_alive() for reader in runtime.readers))
                self.assertTrue(json.loads((runtime.artifacts/'cleanup.json').read_text())['reaped'])
            finally:
                if child.poll() is None:child.kill()
                child.wait(timeout=5)

    def test_owned_writer_cleanup_reaches_real_pipe_eof_after_native_death(self):
        # Three real children use the same interpreter. Only the two captured
        # fixture owners may be signalled; the third is an unrelated control.
        observer=PosixProcessObserver()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); gate=root/'exit'; ready=root/'ready'
            readfd,writefd=os.pipe(); reader=os.fdopen(readfd,'r')
            crashed=subprocess.Popen([sys.executable,'-c',
                'import os,resource,signal,sys,time; from pathlib import Path; '
                'resource.setrlimit(resource.RLIMIT_CORE,(0,0)); '
                'Path(sys.argv[1]).write_text("ready"); '
                'exec("while not Path(sys.argv[2]).exists(): time.sleep(.01)"); '
                'os.kill(os.getpid(),signal.SIGSEGV)',str(ready),str(gate)],
                stderr=writefd,start_new_session=True)
            helper=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'],
                stderr=writefd,start_new_session=True)
            unrelated=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'],start_new_session=True)
            os.close(writefd)
            thread=threading.Thread(target=reader.read,daemon=True);thread.start()
            try:
                deadline=time.monotonic()+10
                while not ready.exists() and time.monotonic()<deadline:time.sleep(.01)
                self.assertTrue(ready.exists())
                captured=capture_owned(observer.snapshot(),[crashed.pid,helper.pid])
                self.assertNotIn(unrelated.pid,captured)
                gate.touch();self.assertEqual(crashed.wait(timeout=5),-signal.SIGSEGV)
                self.assertTrue(thread.is_alive(),'real helper must hold the inherited pipe open')
                reap_owned(observer,captured,[crashed,helper],seconds=15)
                thread.join(timeout=5)
                self.assertFalse(thread.is_alive(),'physical owner reaping must release EOF')
                self.assertIsNone(unrelated.poll(),'cleanup must not signal another same-executable process')
                self.assertNotIn(helper.pid,observer.snapshot())
            finally:
                for child in (crashed,helper,unrelated):
                    if child.poll() is None:child.kill()
                    child.wait(timeout=5)
                thread.join(timeout=5)
                if not thread.is_alive():reader.close()

    def test_real_native_crash_is_reaped_but_never_accepted_as_normal_cleanup(self):
        # Construct the orchestration's resource owner without launching Harbor:
        # this isolates exceptional cleanup from paid inference and producer
        # builds. Its actual spawn/readers/close, filesystem and OS APIs run;
        # there are no fake Process objects or substituted native metadata.
        from helpers.editor_scenario_runtime import Runtime
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            runtime=Runtime.__new__(Runtime)
            runtime.project=root/'project'; runtime.project.mkdir()
            runtime.source_file='stories.nim'; runtime.before='unchanged source\n'
            (runtime.project/runtime.source_file).write_text(runtime.before)
            runtime.artifacts=runtime.project/'.scenario'; runtime.artifacts.mkdir(mode=0o700)
            runtime.private=runtime.artifacts/'private'; runtime.private.mkdir(mode=0o700)
            runtime.observer=PosixProcessObserver()
            runtime.handoffStop=threading.Event(); runtime.handles=[]
            runtime.children=[]; runtime.readers=[]; runtime.readerErrors=[]
            runtime.ownedProcesses={}; runtime.childRoles={}
            runtime.lines=queue.Queue(); runtime.env=dict(os.environ)
            gate=root/'crash'; ready=root/'ready'
            # A real signal death, with core dumps disabled only in this child.
            script=('import os,resource,signal,time,sys; from pathlib import Path; '
                    'resource.setrlimit(resource.RLIMIT_CORE,(0,0)); '
                    'Path(sys.argv[1]).write_text("ready"); '
                    'exec("while not Path(sys.argv[2]).exists(): time.sleep(.01)"); '
                    'os.kill(os.getpid(),signal.SIGSEGV)')
            crashed=runtime.spawn([sys.executable,'-c',script,str(ready),str(gate)],'host')
            other=runtime.spawn([sys.executable,'-c','import time; print("owned helper",flush=True); time.sleep(60)'],'host')
            try:
                deadline=time.monotonic()+10
                while not ready.exists() and time.monotonic()<deadline:time.sleep(.01)
                self.assertTrue(ready.exists())
                runtime.ownedProcesses=capture_owned(runtime.observer.snapshot(),[crashed.pid,other.pid])
                gate.touch(); self.assertEqual(crashed.wait(timeout=5),-signal.SIGSEGV)
                started=time.monotonic()
                with self.assertRaisesRegex(AssertionError,'host native exit -11'):
                    runtime.close()
                self.assertLess(time.monotonic()-started,20)
                proof=json.loads((runtime.artifacts/'native-exits.json').read_text())
                self.assertEqual(proof[0]['returncode'],-signal.SIGSEGV)
                self.assertEqual(proof[0]['allowed'],[0])
                self.assertTrue(json.loads((runtime.artifacts/'cleanup.json').read_text())['reaped'])
                self.assertTrue(all(not reader.is_alive() for reader in runtime.readers))
                self.assertNotIn(other.pid,runtime.observer.snapshot())
                self.assertNotIn(crashed.pid,runtime.observer.snapshot())
            finally:
                for child in runtime.children:
                    if child.poll() is None:child.kill()
                    child.wait(timeout=5)

    def test_unreaped_exited_child_remains_observed_until_wait(self):
        observer = PosixProcessObserver()
        with tempfile.TemporaryDirectory() as directory:
            gate = Path(directory) / 'exit-gate'
            ready = Path(directory) / 'ready'
            script = ('from pathlib import Path; import sys,time; '
                      'Path(sys.argv[1]).write_text("ready"); '
                      'exec("while not Path(sys.argv[2]).exists(): time.sleep(.01)")')
            child = subprocess.Popen([sys.executable, '-c', script, str(ready), str(gate)])
            try:
                deadline = time.monotonic() + 10
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(ready.exists())
                original = observer.snapshot()[child.pid]
                gate.touch()
                # Do not poll/wait the child: both would reap it. Read the real
                # native ps state until the known child is actually a zombie.
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    state = subprocess.check_output([observer.ps, '-p', str(child.pid), '-o', 'stat='],
                                                    text=True, timeout=5).strip()
                    if state.startswith('Z'):
                        break
                    time.sleep(.01)
                else:
                    self.fail('real exited child did not remain a zombie before wait')
                for _ in range(3):
                    current = observer.snapshot()
                    self.assertIn(child.pid, current, 'a zombie is not a reaped process')
                    self.assertEqual(current[child.pid][1], original[1])
                    if sys.platform == 'linux':
                        native = LinuxProcessObserver().snapshot()
                        self.assertIn(child.pid, native)
                        self.assertEqual(native[child.pid][1], original[1])
                        self.assertIsNone(native[child.pid][3], 'positive control must exercise unavailable zombie executable')
                self.assertEqual(child.wait(timeout=5), 0)
                self.assertNotIn(child.pid, observer.snapshot())
                if sys.platform == 'linux':
                    self.assertNotIn(child.pid, LinuxProcessObserver().snapshot())
            finally:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=5)

    def test_portable_observer_keeps_exact_real_process_identity_and_detects_closure(self):
        with tempfile.TemporaryDirectory(prefix='editor observer spaces ') as directory:
            root = Path(directory)
            executable = root / 'python (quoted executable)'
            executable.symlink_to(Path(sys.executable).resolve())
            script = 'from pathlib import Path; import sys,time; Path(sys.argv[1]).write_text("ready"); time.sleep(60)'
            children = []
            try:
                expected = {}
                for index in range(2):
                    ready = root / f'ready {index}'
                    argv = [str(executable), '-c', script, str(ready), 'space separated', '',
                            'a"b\'c;$()[]', 'newline\nargument', f'child-{index}']
                    child = subprocess.Popen(argv, start_new_session=True)
                    children.append(child)
                    deadline = time.monotonic() + 10
                    while not ready.exists() and time.monotonic() < deadline:
                        self.assertIsNone(child.poll())
                        time.sleep(.01)
                    self.assertTrue(ready.exists(), 'real child did not become ready')
                    expected[child.pid] = argv
                observer = PosixProcessObserver()
                first = observer.snapshot()
                for pid, argv in expected.items():
                    self.assertIn(pid, first)
                    self.assertEqual(first[pid][0], os.getpid())
                    self.assertTrue(first[pid][1])
                    self.assertEqual(first[pid][2], argv)
                    self.assertEqual(Path(first[pid][3]).resolve(), Path(sys.executable).resolve())
                self.assertNotEqual(children[0].pid, children[1].pid)
                for _ in range(3):
                    current = observer.snapshot()
                    for pid in expected:
                        self.assertEqual(current[pid], first[pid])
                    if sys.platform == 'linux':
                        native = LinuxProcessObserver().snapshot()
                        for pid in expected:
                            self.assertEqual(current[pid], native[pid], 'portable observation must equal actual kernel identity')
                children[0].terminate()
                self.assertEqual(children[0].wait(timeout=5), -15)
                current = observer.snapshot()
                self.assertNotIn(children[0].pid, current)
                self.assertEqual(current[children[1].pid], first[children[1].pid], 'closing one child must preserve the other')
                children[1].terminate()
                self.assertEqual(children[1].wait(timeout=5), -15)
                current = observer.snapshot()
                for pid in expected:
                    self.assertNotIn(pid, current)
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill()
                    child.wait(timeout=5)

    def test_only_truly_absent_private_sibling_is_optional(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertFalse(optional_sibling_available(root / 'absent'))
            sibling = root / 'agent-harbor'
            sibling.mkdir()
            with self.assertRaisesRegex(OSError, 'missing required Cargo.toml'):
                optional_sibling_available(sibling)
            (sibling / 'Cargo.toml').write_text('[workspace]\n')
            with self.assertRaisesRegex(OSError, 'missing required repro.nim'):
                optional_sibling_available(sibling)
            (sibling / 'repro.nim').write_text('# producer fixture\n')
            self.assertTrue(optional_sibling_available(sibling))
            broken = root / 'broken-link'
            broken.symlink_to(root / 'missing-target')
            with self.assertRaisesRegex(OSError, 'not a directory'):
                optional_sibling_available(broken)
            file = root / 'ordinary-file'
            file.write_text('present')
            with self.assertRaisesRegex(OSError, 'not a directory'):
                optional_sibling_available(file)

    def test_actual_acceptance_entrypoint_skips_absence_and_rejects_present_broken_checkout(self):
        # Run the actual script in a real minimal filesystem workspace. No
        # injected OS/platform metadata or fake subprocess response is involved.
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            tests = workspace / 'isonim/tests'
            (tests / 'helpers').mkdir(parents=True)
            source = Path(__file__).parent
            shutil.copyfile(source / 'test_editor_harbor_scenario.py', tests / 'test_editor_harbor_scenario.py')
            shutil.copyfile(source / 'helpers/editor_process_observer.py', tests / 'helpers/editor_process_observer.py')
            shutil.copyfile(source / 'helpers/editor_context_evidence.py', tests / 'helpers/editor_context_evidence.py')
            absent = subprocess.run([sys.executable, str(tests / 'test_editor_harbor_scenario.py'), '-v'],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(absent.returncode, 0, absent.stderr)
            self.assertIn('Ran 2 tests', absent.stderr)
            self.assertIn('OK (skipped=2)', absent.stderr)
            for name in ('test_parallel_native_shutdown_of_two_actual_backend_sessions',
                          'test_production_routes_keep_isolated_provider_sessions_alive_until_close'):
                self.assertRegex(absent.stderr, name + r'.*\.\.\. skipped')
            sibling = workspace / 'agent-harbor'
            sibling.mkdir()
            for expected in ('Cargo.toml', 'repro.nim'):
                invalid = subprocess.run([sys.executable, str(tests / 'test_editor_harbor_scenario.py'), '-v'],
                                          capture_output=True, text=True, timeout=10)
                self.assertNotEqual(invalid.returncode, 0)
                self.assertIn('Present Agent Harbor sibling is missing required ' + expected, invalid.stderr)
                self.assertIn('Ran 2 tests', invalid.stderr)
                self.assertIn('FAILED (errors=2)', invalid.stderr)
                for name in ('test_parallel_native_shutdown_of_two_actual_backend_sessions',
                              'test_production_routes_keep_isolated_provider_sessions_alive_until_close'):
                    self.assertRegex(invalid.stderr, name + r'.*\.\.\. ERROR')
                self.assertNotIn('skipped=', invalid.stderr)
                (sibling / expected).write_text('# required metadata boundary\n')


if __name__ == '__main__':
    unittest.main()
