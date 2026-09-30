"""Real native process/filesystem tests; no OS/process metadata is mocked.

Real children and argument paths containing spaces, punctuation and empty values
exercise both the portable ps enumeration and native identity boundary. Linux
runs both observers; Darwin's native APIs are exercised when run on that host.
"""
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import time
import unittest

from helpers.editor_process_observer import (
    LinuxProcessObserver, PosixProcessObserver, optional_sibling_available,
)


class ProcessObserverTests(unittest.TestCase):
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
            absent = subprocess.run([sys.executable, str(tests / 'test_editor_harbor_scenario.py')],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(absent.returncode, 0, absent.stderr)
            self.assertIn('OK (skipped=1)', absent.stderr)
            sibling = workspace / 'agent-harbor'
            sibling.mkdir()
            for expected in ('Cargo.toml', 'repro.nim'):
                invalid = subprocess.run([sys.executable, str(tests / 'test_editor_harbor_scenario.py')],
                                         capture_output=True, text=True, timeout=10)
                self.assertNotEqual(invalid.returncode, 0)
                self.assertIn('Present Agent Harbor sibling is missing required ' + expected, invalid.stderr)
                self.assertIn('FAILED (errors=1)', invalid.stderr)
                self.assertNotIn('skipped=', invalid.stderr)
                (sibling / expected).write_text('# required metadata boundary\n')


if __name__ == '__main__':
    unittest.main()
