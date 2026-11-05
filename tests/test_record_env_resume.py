#!/usr/bin/env python3
"""Retained-command tests against the actual Record Env helper ASTs.

Real temporary files, a tiny real Python child and an independent invocation
counter exercise the filesystem/process boundary. AST isolation avoids unrelated
compiler/browser top-level qualification; sha, guard and run are not copied or
mocked. The old-discovery inverse changes only the new output-role exclusion in
an isolated AST. Every real helper resource guard remains active. This suite
claims helper bookkeeping coverage, never compiler/browser/Recorder coverage.
"""
from pathlib import Path
import ast
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'tools/test_record_env_owner.py'
SOURCE_BYTES = SOURCE.read_bytes()
TEST_BYTES = Path(__file__).read_bytes()
EXCLUSION = 'and Path(p).resolve()not in output_paths'
FUNCTION_NAMES = ['sha', 'guard', 'run']
EVIDENCE = Path(os.environ.get('RECORD_ENV_RESUME_TEST_EVIDENCE',
                             ROOT / 'build/record-env-resume-tests'))
EVIDENCE.mkdir(parents=True, exist_ok=True)
RUN = Path(tempfile.mkdtemp(prefix='run-', dir=EVIDENCE))
print('Record Env resume test evidence: ' + str(RUN), flush=True)


def helpers(inverse=False):
    text = SOURCE_BYTES.decode()
    if inverse:
        assert text.count(EXCLUSION) == 1, 'inverse must remove exactly one exclusion'
        text = text.replace(EXCLUSION, '')
    nodes = [n for n in ast.parse(text).body
             if isinstance(n, ast.FunctionDef) and n.name in FUNCTION_NAMES]
    assert [n.name for n in nodes] == FUNCTION_NAMES
    return text, nodes


class RetainedCommandTests(unittest.TestCase):
    def setUp(self):
        self.base = RUN / self.id().split('.')[-1]
        self.base.mkdir()
        self.previous_cwd = Path.cwd()
        os.chdir(self.base)
        self.addCleanup(os.chdir, self.previous_cwd)
        self.out = self.base / 'evidence'
        self.out.mkdir()
        self.counter = self.base / 'counter'
        self.receipt = self.base / 'receipt.json'
        self.neighbor = self.base / 'receipt.json.input'
        self.neighbor.write_text('genuine environment input\n')
        self.global_input = self.base / 'global-input'
        self.global_input.write_text('explicit generation input\n')
        self.script = self.base / 'child.py'
        self.script.write_text(
            'from pathlib import Path\nimport json, os, sys\n'
            f'counter = Path({str(self.counter)!r})\n'
            'n = int(counter.read_text()) if counter.exists() else 0\n'
            'counter.write_text(str(n + 1))\n'
            "if os.environ.get('FAIL') == '1':\n"
            " print('ENV_ASSERT:fixture-exit', flush=True)\n sys.exit(7)\n"
            "for key in ['RECORD_ENV_RECEIPT', 'RECORD_ENV_UNUSED_RECEIPT']:\n"
            ' if key in os.environ:\n'
            "  Path(os.environ[key]).write_text(json.dumps({'receipt': key}))\n"
            "print('child completed', flush=True)\n")
        self.argv = [sys.executable, '-I', '-B', str(self.script)]
        self.env = {'RECORD_ENV_RECEIPT': str(self.receipt),
                    'GENUINE_INPUT': str(self.neighbor)}
        self.outputs = [self.receipt]
        self.cwd = self.base
        self.expected = 0
        self.oracle = None
        self.ns = self.namespace()

    def namespace(self, inverse=False):
        text, nodes = helpers(inverse)
        ns = dict(Path=Path, hashlib=hashlib, json=json, os=os, shutil=shutil,
                  subprocess=subprocess, time=time, ROOT=ROOT, OUT=self.out,
                  LEDGER=[], inputs=[SOURCE, Path(__file__), self.global_input])
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(SOURCE), 'exec'), ns)
        (self.base / ('inverse-functions.json' if inverse else 'functions.json')).write_text(
            json.dumps({n.name: ast.get_source_segment(text, n) for n in nodes}, indent=2))
        return ns

    def invoke(self, **changes):
        args = dict(env=self.env, cwd=self.cwd, expected=self.expected,
                    oracle=self.oracle, outputs=self.outputs)
        args.update(changes)
        argv = args.pop('argv', self.argv)
        return self.ns['run']('command', argv, **args)

    def count(self):
        return int(self.counter.read_text()) if self.counter.exists() else 0

    def retained_bytes(self):
        return {p.name: p.read_bytes() for p in self.out.iterdir()
                if p.name != 'RESOURCE.jsonl'}

    def first(self):
        self.invoke()
        self.assertEqual(self.count(), 1)
        self.assertEqual(len(self.ns['LEDGER']), 1)
        row = self.ns['LEDGER'][0]
        self.assertEqual(row['exit'], self.expected)
        self.assertEqual(row['expectedExit'], self.expected)
        self.assertEqual(row['oracle'], self.oracle)
        self.assertEqual(json.loads((self.out / 'LEDGER.json').read_text()), [row])
        self.assertEqual(json.loads((self.out / 'command-RESULT.json').read_text()), row)
        self.assertEqual(row['logSha256'], hashlib.sha256(
            (self.out / 'command.log').read_bytes()).hexdigest())
        for path, digest in row['outputs'].items():
            self.assertEqual(hashlib.sha256(Path(path).read_bytes()).hexdigest(), digest)
        return row

    def resume(self):
        before = self.retained_bytes()
        body = self.invoke()
        self.assertEqual(self.count(), 1)
        self.assertEqual(before, self.retained_bytes())
        self.assertEqual(body, (self.out / 'command.log').read_text())

    def refusal(self, message, source_assertion, **changes):
        counter = self.count()
        retained = self.retained_bytes()
        try:
            self.invoke(**changes)
        except AssertionError as error:
            self.assertEqual(str(error), message)
            tb = error.__traceback__
            while tb.tb_next:
                tb = tb.tb_next
            self.assertEqual(tb.tb_frame.f_code.co_name, 'run')
            line = helpers(self.ns.get('inverse', False))[0].splitlines()[tb.tb_lineno - 1]
            self.assertIn(source_assertion, line)
        else:
            self.fail('retained command did not refuse: ' + source_assertion)
        self.assertEqual(self.count(), counter, 'refusal replayed the child')
        self.assertEqual(retained, self.retained_bytes(), 'refusal rewrote retained evidence')

    def test_generated_receipt_retained(self):
        row = self.first()
        self.assertNotIn(str(self.receipt), row['beforeInputs'])
        self.assertEqual(set(row['outputs']), {str(self.receipt)})
        self.resume()

    def test_omission_receipt_retained(self):
        self.env['RECORD_ENV_UNUSED_RECEIPT'] = self.env.pop('RECORD_ENV_RECEIPT')
        self.first()
        self.resume()

    def test_relative_output_absolute_environment(self):
        self.outputs = [Path('receipt.json')]
        self.first()
        self.resume()

    def test_absolute_output_relative_environment_uses_current_base(self):
        self.env['RECORD_ENV_RECEIPT'] = 'receipt.json'
        # The child creates the output using its cwd; a separate preexisting
        # output proves discovery uses current-base exactly like the old helper.
        other = self.base / 'other-cwd'
        other.mkdir()
        self.cwd = other
        self.receipt.write_text('current-base output')
        self.first()
        self.resume()
        self.assertTrue((other / 'receipt.json').is_file())

    def test_existing_symlink_output_alias(self):
        self.receipt.write_text('initial output')
        alias = self.base / 'receipt-alias'
        alias.symlink_to(self.receipt)
        self.env['RECORD_ENV_RECEIPT'] = str(alias)
        row = self.first()
        self.assertNotIn(str(alias), row['beforeInputs'])
        self.resume()

    def test_symlink_declared_output_alias(self):
        alias = self.base / 'receipt-alias'
        alias.symlink_to(self.receipt)
        self.outputs = [alias]
        self.first()
        self.resume()

    def test_output_generator_retained(self):
        self.outputs = iter([self.receipt])
        self.first()
        self.outputs = iter([self.receipt])
        self.resume()

    def test_genuine_environment_neighbor_drift(self):
        row = self.first()
        self.assertIn(str(self.neighbor), row['beforeInputs'])
        self.assertNotIn(self.neighbor, self.ns['inputs'])
        self.neighbor.write_text('changed genuine input')
        self.refusal('frozen command/input drift command', "row['beforeInputs']==before")

    def test_genuine_argv_neighbor_drift(self):
        del self.env['GENUINE_INPUT']
        self.argv.append(str(self.neighbor))
        row = self.first()
        self.assertIn(str(self.neighbor), row['beforeInputs'])
        self.neighbor.write_text('changed argv input')
        self.refusal('frozen command/input drift command', "row['beforeInputs']==before")

    def test_argv_script_drift(self):
        row = self.first()
        self.assertIn(str(self.script), row['beforeInputs'])
        self.script.write_text(self.script.read_text() + '\n# changed script\n')
        self.refusal('frozen command/input drift command', "row['beforeInputs']==before")

    def test_explicit_global_output_dual_role_drift(self):
        self.outputs.append(self.global_input)
        row = self.first()
        self.assertIn(str(self.global_input), row['beforeInputs'])
        self.assertIn(str(self.global_input), row['outputs'])
        self.global_input.write_text('changed explicit generation input')
        self.refusal('frozen command/input drift command', "row['beforeInputs']==before")

    def test_native_executable_output_dual_role_drift(self):
        # Actual executable selection, not a mocked Python subprocess. A symlink
        # also requires both selected and resolved executable bytes to be bound.
        executable = self.base / 'binary'
        executable.write_text('#!' + sys.executable + '\n' + self.script.read_text())
        executable.chmod(0o700)
        selected = self.base / 'selected-binary'
        selected.symlink_to(executable)
        self.argv = [str(selected)]
        self.outputs = [selected, self.receipt]
        row = self.first()
        for path in (selected, executable):
            self.assertIn(str(path), row['beforeInputs'])
        self.resume()
        executable.write_text(executable.read_text() + '\n# changed executable\n')
        self.refusal('frozen command/input drift command', "row['beforeInputs']==before")

    def test_retained_output_drift(self):
        self.first()
        self.receipt.write_text('changed receipt')
        self.refusal('', "row['outputs'].items()")

    def test_retained_output_missing(self):
        self.first()
        self.receipt.unlink()
        self.refusal('', "row['outputs'].items()")

    def test_retained_log_drift(self):
        self.first()
        (self.out / 'command.log').write_text('changed log')
        self.refusal('', "row['logSha256']")

    def test_command_drift(self):
        self.first()
        self.refusal('frozen command/input drift command', "row['argv']==argv",
                     argv=self.argv + ['changed-argument'])

    def test_environment_drift(self):
        self.first()
        self.refusal('frozen command/input drift command', "row['env']==env",
                     env=self.env | {'NEW_VALUE': 'changed'})

    def test_cwd_drift(self):
        self.first()
        self.refusal('frozen command/input drift command', "row['cwd']==str(cwd)", cwd=ROOT)

    def test_expected_exit_drift(self):
        self.first()
        self.refusal('retained command expectation drift command', "row['expectedExit']==expected",
                     expected=7)

    def test_semantic_oracle_drift(self):
        self.first()
        self.refusal('retained command expectation drift command', "row['oracle']==oracle",
                     oracle='fixture-exit')

    def test_expected_semantic_error_without_final_receipt(self):
        self.env['FAIL'] = '1'
        self.expected = 7
        self.oracle = 'fixture-exit'
        row = self.first()
        self.assertFalse(self.receipt.exists())
        self.assertEqual(row['outputs'], {})
        self.assertIn('ENV_ASSERT:fixture-exit', (self.out / 'command.log').read_text())
        self.resume()

    def test_missing_semantic_marker_is_not_accepted(self):
        # The child genuinely exits7, but an unrelated oracle is not a kill.
        self.env['FAIL'] = '1'
        self.expected = 7
        self.oracle = 'different-marker'
        try:
            self.invoke()
        except AssertionError as error:
            self.assertEqual(str(error), 'wrong semantic failure command')
        else:
            self.fail('wrong semantic marker was accepted')
        self.assertEqual(self.count(), 1)
        self.assertEqual(self.ns['LEDGER'][0]['exit'], 7)

    def test_unreceipted_start_refuses_before_child(self):
        (self.out / 'command-START.json').write_text('{}')
        self.refusal('unreceipted invocation: inspect before resume command',
                     'unreceipted invocation: inspect before resume')
        self.assertEqual(self.count(), 0)

    def test_duplicate_ledger_refuses(self):
        self.first()
        self.ns['LEDGER'].append(dict(self.ns['LEDGER'][0]))
        self.refusal('', 'assert len(old)==1')

    def test_old_generation_source_binding_refuses(self):
        # An explicit source-generation file is retained even if declared as
        # output; no ledger migration/relabel is permitted after code changes.
        source_copy = self.base / 'generation-source.py'
        source_copy.write_bytes(SOURCE_BYTES)
        self.ns['inputs'].append(source_copy)
        self.first()
        source_copy.write_bytes(SOURCE_BYTES + b'\n# new generation\n')
        self.refusal('frozen command/input drift command', "row['beforeInputs']==before")

    def test_old_discovery_inverse_exact_failure(self):
        self.ns = self.namespace(inverse=True)
        self.ns['inverse'] = True
        row = self.first()
        original_inputs = dict(row['beforeInputs'])
        self.assertNotIn(str(self.receipt), original_inputs)
        observed = {}

        def trace(frame, event, arg):
            if (event == 'exception' and frame.f_code.co_name == 'run'
                    and isinstance(arg[1], AssertionError)):
                observed.update(frame.f_locals['before'])
            return trace

        sys.settrace(trace)
        try:
            self.refusal('frozen command/input drift command', "row['beforeInputs']==before")
        finally:
            sys.settrace(None)
        self.assertEqual(set(observed) - set(original_inputs), {str(self.receipt)})
        self.assertEqual({k: observed[k] for k in original_inputs}, original_inputs)
        self.assertEqual(observed[str(self.receipt)], self.ns['sha'](self.receipt))
        (self.base / 'inverse-result.json').write_text(json.dumps(dict(
            exactRefusal='frozen command/input drift command',
            addedInputKeys=[str(self.receipt)], childInvocations=self.count()), indent=2))

    def tearDown(self):
        self.assertEqual(SOURCE.read_bytes(), SOURCE_BYTES)
        self.assertEqual(Path(__file__).read_bytes(), TEST_BYTES)
        rows = [json.loads(x) for x in (self.out / 'RESOURCE.jsonl').read_text().splitlines()]
        self.assertGreater(len(rows), 0)
        self.assertTrue(all(r['admitted'] for r in rows), 'resource refusal is not a test pass')


if __name__ == '__main__':
    (RUN / 'SOURCE-BINDINGS.json').write_text(json.dumps(dict(
        source=str(SOURCE), sourceSha256=hashlib.sha256(SOURCE_BYTES).hexdigest(),
        test=str(Path(__file__)), testSha256=hashlib.sha256(TEST_BYTES).hexdigest(),
        python=sys.executable, pythonSha256=hashlib.sha256(Path(sys.executable).read_bytes()).hexdigest(),
        scope='real helper AST/process retained-result controls; no full Env qualification'), indent=2))
    unittest.main(verbosity=2)
