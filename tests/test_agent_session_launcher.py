"""Protocol adapter tests use a tiny child to isolate byte forwarding and lifetime.

The child replaces only the paid provider; real pipes/processes are exercised.
Live Harbor/provider tests separately establish E2E session continuity.
"""
import importlib.util
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "tools/agent_session_launcher.py"
spec = importlib.util.spec_from_file_location("launcher", SCRIPT)
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


class LaunchTests(unittest.TestCase):
    def test_preserves_other_frames_and_existing_configuration(self):
        frame = '{ "method": "session/prompt", "params": {"prompt": "user"} }\n'
        self.assertEqual(launcher.inject_instructions(frame, "rules"), frame)
        frame = json.dumps({"id": 7, "method": "session/new", "params": {
            "cwd": "/work", "_meta": {"sessionId": "harbor", "custom": 1,
            "systemPrompt": {"type": "preset", "preset": "claude_code", "append": "user config"}}}})
        result = json.loads(launcher.inject_instructions(frame, "rules"))
        self.assertEqual(result["id"], 7)
        self.assertEqual(result["params"]["cwd"], "/work")
        meta = result["params"]["_meta"]
        self.assertEqual(meta["sessionId"], "harbor")
        self.assertEqual(meta["custom"], 1)
        self.assertEqual(meta["systemPrompt"], {"type": "preset", "preset": "claude_code", "append": "user config\n\nrules"})

    def test_preserves_string_system_prompt(self):
        line = json.dumps({"method": "session/new", "params": {"_meta": {"systemPrompt": "existing"}}})
        value = json.loads(launcher.inject_instructions(line, "rules"))
        self.assertEqual(value["params"]["_meta"]["systemPrompt"], "existing\n\nrules")

    def test_real_child_terminates_on_signal_and_input_eof(self):
        for close_input in (False, True):
            with self.subTest(close_input=close_input), tempfile.TemporaryDirectory() as directory:
                instructions = Path(directory) / "instructions"
                instructions.write_text("rules")
                child = "import os,time; print(os.getpid(), flush=True); time.sleep(60)"
                process = subprocess.Popen([sys.executable, str(SCRIPT), "--instructions", str(instructions),
                    "--", sys.executable, "-c", child], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
                pid = int(process.stdout.readline())
                try:
                    if close_input:
                        process.stdin.close()
                    else:
                        process.send_signal(signal.SIGTERM)
                    self.assertEqual(process.wait(timeout=5), 143)
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)
                finally:
                    if not process.stdin.closed:
                        process.stdin.close()
                    process.stdout.close()
                    if process.poll() is None:
                        process.kill()
                        process.wait()

    def test_real_child_receives_metadata_and_exit_status_survives(self):
        with tempfile.TemporaryDirectory() as directory:
            instructions = Path(directory) / "instructions"
            instructions.write_text("editor rules")
            child = "import sys; print(sys.stdin.readline(), end='', flush=True); sys.exit(7)"
            process = subprocess.Popen([sys.executable, str(SCRIPT), "--instructions", str(instructions),
                "--", sys.executable, "-c", child], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            try:
                process.stdin.write(json.dumps({"id": 1, "method": "session/new", "params": {}}) + "\n")
                process.stdin.flush()
                response = json.loads(process.stdout.readline())
                self.assertEqual(response["params"]["_meta"]["systemPrompt"]["append"], "editor rules")
                self.assertEqual(process.wait(timeout=5), 7)
            finally:
                process.stdin.close()
                process.stdout.close()
                if process.poll() is None:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    unittest.main()
