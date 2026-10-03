#!/usr/bin/env python3
"""Exercise actual Runtime.close with real files, children, readers and OS identity.

No processes, observer, scanner or filesystem are mocked. Minimal runtime state
deliberately bypasses unrelated Harbor/compiler provisioning: these controls test
cleanup after protocol evidence has been written, including malformed/leaked
credentials. The separate mandatory real-provider gate tests full provisioning.
"""
import json
import os
from pathlib import Path
import queue
import sys
import tempfile
import threading
import unittest

from helpers.editor_scenario_runtime import Runtime, process_observer, wait


class ScenarioCleanup(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        runtime = self.runtime = Runtime.__new__(Runtime)
        runtime.project = Path(self.directory.name)/'project'
        runtime.project.mkdir()
        runtime.source_file = 'stories.nim'
        runtime.before = 'original story\n'
        (runtime.project/runtime.source_file).write_text('edited story\n')
        runtime.artifacts = runtime.project/'.scenario'
        runtime.artifacts.mkdir(mode=0o700)
        runtime.private = runtime.artifacts/'private'
        runtime.private.mkdir(mode=0o700)
        runtime.bootstrap = 'bootstrap-secret-for-cleanup-control'
        runtime.observer = process_observer()
        runtime.env = dict(os.environ)
        runtime.handoffStop = threading.Event()
        runtime.handles, runtime.children, runtime.readers, runtime.readerErrors = [], [], [], []
        runtime.lines = queue.Queue()
        # The actual trace shape that previously crashed cleanup, alongside
        # genuine mapping-shaped registration and provider-scope evidence.
        self.writePrivate('actual-tools.json', [
            {'tool':'Bash','input':{'command':'isonim editor state'}},
            {'nested':[{'controlToken':'nested-array-control-secret'}]},
            None, 12, 'ordinary scalar trace data',
            {'browserToken':None, 'controlToken':''},
        ])
        self.writePrivate('registration.json', {
            'browserToken':'mapping-browser-secret', 'controlToken':'mapping-control-secret',
            'nested':{'scope':{'ISONIM_EDITOR_TOKEN':'nested-mapping-secret'}},
        })
        self.writePrivate('provider-scope.json', {'ISONIM_EDITOR_TOKEN':'mapping-provider-secret'})
        self.child = runtime.spawn([
            sys.executable, '-u', '-c',
            'import time; print("CLEANUP_CHILD_READY", flush=True); time.sleep(60)',
        ], 'owned-cleanup-child')
        self.addCleanup(self.emergencyReap)
        wait(lambda: not runtime.lines.empty(), 'real cleanup control child ready', 5)
        self.identity = runtime.observer.snapshot()[self.child.pid][1]

    def writePrivate(self, name, data):
        filename = self.runtime.private/name
        filename.write_text(json.dumps(data))
        filename.chmod(0o600)

    def emergencyReap(self):
        if self.child.poll() is None:
            self.child.kill()
            self.child.wait(timeout=5)

    def assertOwnedCleanup(self):
        runtime = self.runtime
        self.assertIsNotNone(self.child.poll())
        current = runtime.observer.snapshot()
        self.assertFalse(self.child.pid in current and current[self.child.pid][1] == self.identity)
        self.assertTrue(runtime.handoffStop.is_set())
        self.assertTrue(all(not reader.is_alive() for reader in runtime.readers))
        self.assertTrue(self.child.stdout.closed)
        self.assertTrue(all(handle.closed for handle in runtime.handles))
        self.assertEqual(runtime.readerErrors, [])

    def test_array_trace_and_mapping_credentials_complete_actual_cleanup(self):
        runtime = self.runtime
        public = ['public.json','public.jsonl','public.yaml','public.log','public.txt']
        for name in public:
            (runtime.artifacts/name).write_text('clean public evidence')
        runtime.close()
        self.assertOwnedCleanup()
        result = json.loads((runtime.artifacts/'cleanup.json').read_text())
        self.assertEqual(result['owned_processes'], 1)
        self.assertEqual(result['readers'], 1)
        self.assertIs(result['reaped'], True)
        self.assertEqual(set(result['public_secret_scan']), set(public+['owned-cleanup-child.log']))
        # The private array remains available as evidence after cleanup.
        self.assertIsInstance(json.loads((runtime.private/'actual-tools.json').read_text()), list)

    def test_actual_public_scan_rejects_each_known_mapping_and_nested_credential(self):
        for secret in [self.runtime.bootstrap, 'mapping-browser-secret', 'mapping-control-secret',
                       'mapping-provider-secret', 'nested-array-control-secret', 'nested-mapping-secret']:
            with self.subTest(credential=secret):
                (self.runtime.artifacts/'deliberate-leak.json').write_text(json.dumps({'leak':secret}))
                with self.assertRaisesRegex(AssertionError, 'Credential leaked into public artifact: deliberate-leak.json'):
                    self.runtime.close()
                self.assertOwnedCleanup()
                self.assertFalse((self.runtime.artifacts/'cleanup.json').exists())

    def test_malformed_named_credential_fails_deliberately_after_owned_cleanup(self):
        for malformed in [True, 123, [], {}]:
            with self.subTest(credential_type=type(malformed).__name__):
                self.writePrivate('malformed.json', [{'ISONIM_EDITOR_TOKEN':malformed}])
                with self.assertRaisesRegex(AssertionError, 'Malformed private credential: ISONIM_EDITOR_TOKEN'):
                    self.runtime.close()
                self.assertOwnedCleanup()
                self.assertFalse((self.runtime.artifacts/'cleanup.json').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
