#!/usr/bin/env python3
"""Real compiler/Node controls for the Nim JS unittest process guard.

No mocks: each case compiles a temporary Nim module with std/unittest and runs
both the actual Node executable and production guard. Temporary files isolate
outputs; they do not replace compiler results or synthesize unittest diagnostics.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NODE = os.environ.get("ISONIM_SCENARIO_NODE", "node")


class NimJsGuardTests(unittest.TestCase):
    def run_control(self, body, *, nodejs=False):
        with tempfile.TemporaryDirectory(prefix="isonim-js-guard-") as directory:
            source = Path(directory) / "guard_control.nim"
            output = Path(directory) / "guard_control.js"
            source.write_text("import std/unittest\n" + body)
            command = ["nim", "js", "--out:" + str(output)]
            if nodejs:
                command.append("-d:nodejs")
            compile_result = subprocess.run(command + [str(source)], cwd=ROOT,
                capture_output=True, text=True, timeout=60)
            self.assertEqual(compile_result.returncode, 0,
                compile_result.stdout + compile_result.stderr)
            raw = subprocess.run([NODE, str(output)], cwd=ROOT,
                capture_output=True, text=True, timeout=15)
            guarded = subprocess.run([sys.executable,
                str(ROOT / "tools/run_nim_js_test.py"), str(output)], cwd=ROOT,
                capture_output=True, text=True, timeout=15)
            self.assertEqual(guarded.stdout, raw.stdout)
            return raw, guarded

    def test_zero_exit_helper_check_with_ok_is_rejected(self):
        raw, guarded = self.run_control('''proc helper() =
  check false
suite "helper":
  test "outer prints OK":
    helper()
''')
        self.assertEqual(raw.returncode, 0)
        self.assertIn("Check failed:", raw.stdout)
        self.assertIn("[OK]", raw.stdout)
        self.assertNotIn("[FAILED]", raw.stdout)
        self.assertNotEqual(guarded.returncode, 0)

    def test_nodejs_helper_failure_is_rejected(self):
        raw, guarded = self.run_control('''proc helper() =
  check false
suite "helper":
  test "outer prints OK":
    helper()
''', nodejs=True)
        self.assertNotEqual(raw.returncode, 0)
        self.assertIn("Check failed:", raw.stdout)
        self.assertNotEqual(guarded.returncode, 0)

    def test_helper_expect_failure_is_rejected_in_both_targets(self):
        for nodejs in [False, True]:
            with self.subTest(nodejs=nodejs):
                raw, guarded = self.run_control('proc helper() =\n  expect ValueError:\n    discard\nsuite "helper expect":\n  test "outer prints OK":\n    helper()\n', nodejs=nodejs)
                self.assertEqual(raw.returncode, 1 if nodejs else 0)
                self.assertIn("Expect Failed", raw.stdout)
                self.assertIn("[OK]", raw.stdout)
                self.assertNotEqual(guarded.returncode, 0)

    def test_zero_exit_direct_failure_is_rejected(self):
        raw, guarded = self.run_control('''suite "direct":
  test "fails":
    check false
''')
        self.assertEqual(raw.returncode, 0)
        self.assertIn("[FAILED]", raw.stdout)
        self.assertNotEqual(guarded.returncode, 0)

    def test_skip_is_rejected(self):
        raw, guarded = self.run_control('''suite "skipped":
  test "unexecuted":
    skip()
''')
        self.assertEqual(raw.returncode, 0)
        self.assertIn("[SKIPPED]", raw.stdout)
        self.assertNotEqual(guarded.returncode, 0)

    def test_actual_passing_case_is_accepted(self):
        raw, guarded = self.run_control('''suite "passing":
  test "executed":
    check 2 + 2 == 4
''')
        self.assertEqual(raw.returncode, 0)
        self.assertIn("[OK]", raw.stdout)
        self.assertEqual(guarded.returncode, 0)

    def test_missing_unittest_body_is_rejected(self):
        raw, guarded = self.run_control("discard\n")
        self.assertEqual(raw.returncode, 0)
        self.assertNotIn("[OK]", raw.stdout)
        self.assertNotEqual(guarded.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
