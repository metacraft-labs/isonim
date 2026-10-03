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

    def test_terminal_wrapper_preserves_exact_tool_and_uses_filename_only(self):
        original = {"jsonrpc": "2.0", "id": 9, "method": "terminal/create", "params": {
            "command": "/bin/bash", "args": ["-c", "isonim editor state; printf 'α'"],
            "cwd": "/served project", "env": [{"name": "USER_SETTING", "value": "keep"}],
            "outputByteLimit": 4096}}
        environment = "/private/original/environment.json"
        actual = json.loads(launcher.inject_terminal_scope(json.dumps(original), environment))
        self.assertEqual(actual["id"], 9)
        self.assertEqual(actual["params"]["cwd"], original["params"]["cwd"])
        self.assertEqual(actual["params"]["env"], original["params"]["env"])
        self.assertEqual(actual["params"]["outputByteLimit"], 4096)
        self.assertEqual(actual["params"]["command"], sys.executable)
        self.assertEqual(actual["params"]["args"], [str(SCRIPT.parent / "editor_agent_env.py"),
            "--environment", environment, "--", "/bin/bash", "-c", "isonim editor state; printf 'α'"])
        self.assertNotIn("ISONIM_EDITOR_TOKEN", json.dumps(actual))
        for method in ("terminal/output", "session/update", "session/prompt"):
            raw = json.dumps({"method": method, "params": {"keep": 1}})
            self.assertEqual(launcher.inject_terminal_scope(raw, environment), raw)
        self.assertEqual(launcher.inject_terminal_scope(json.dumps(original), ""), json.dumps(original))

    def test_actual_provider_output_is_wrapped_over_real_pipes(self):
        with tempfile.TemporaryDirectory() as directory:
            child = "import json,sys; print(json.dumps({'id':42,'method':'terminal/create','params':{'command':'isonim','args':['editor','state'],'cwd':'/project'}}),flush=True); sys.stdin.readline(); sys.exit(7)"
            process = subprocess.Popen([sys.executable, str(SCRIPT), "--environment", "/original/environment.json",
                "--", sys.executable, "-c", child], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            try:
                result = json.loads(process.stdout.readline())
                self.assertEqual(result["id"], 42)
                self.assertEqual(result["params"]["cwd"], "/project")
                self.assertEqual(result["params"]["args"][-3:], ["isonim", "editor", "state"])
                self.assertEqual(result["params"]["args"][2], "/original/environment.json")
                process.stdin.write('{"jsonrpc":"2.0","id":42,"result":{"terminalId":"actual"}}\n')
                process.stdin.flush()
                self.assertEqual(process.wait(timeout=5), 7)
            finally:
                process.stdin.close(); process.stdout.close()
                if process.poll() is None: process.kill(); process.wait()

    def test_actual_model_selection_pipes_preserve_identity_and_reject_failure(self):
        for advertised, reject in ((True, False), (True, True), (False, True), ('malformed', True)):
            with self.subTest(advertised=advertised, reject=reject):
                options = [{'id': 'model', 'type': 'select', 'currentValue': 'default',
                            'options': [{'value': 'sonnet', 'name': 'Sonnet'}]}] if advertised is True else ([] if advertised is False else {'model': True})
                child = """import json,sys,time
new=json.loads(sys.stdin.readline())
print(json.dumps({'jsonrpc':'2.0','id':new['id'],'result':{'sessionId':'actual-session','configOptions':OPTIONS}}),flush=True)
selection=json.loads(sys.stdin.readline())
print(json.dumps({'method':'selection-observed','params':selection}),flush=True)
print(json.dumps({'jsonrpc':'2.0','id':selection['id'],REPLY}),flush=True)
if REJECT:
    next_input=sys.stdin.readline()
    if next_input:print(json.dumps({'method':'unexpected-provider-input'}),flush=True)
    time.sleep(60)
""".replace('OPTIONS', repr(options)).replace('REPLY', "'error':{'code':-32601,'message':'unsupported selection'}" if reject else "'result':{'configOptions':[]} ").replace('REJECT', repr(reject))
                process = subprocess.Popen([sys.executable, str(SCRIPT), '--', sys.executable, '-c', child],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    process.stdin.write(json.dumps({'jsonrpc':'2.0','id':7,'method':'session/new','params':{'cwd':'/project'}})+'\n');process.stdin.flush()
                    created=json.loads(process.stdout.readline());self.assertEqual(created['id'],7)
                    original={'jsonrpc':'2.0','id':11,'method':'session/set_model','params':{'sessionId':'actual-session','modelId':'sonnet','_meta':{'keep':1}}}
                    process.stdin.write(json.dumps(original)+'\n'+(json.dumps({'id':12,'method':'session/prompt','params':{'sessionId':'actual-session','prompt':[]}})+'\n' if reject else ''));process.stdin.flush()
                    observed=json.loads(process.stdout.readline())['params']
                    expected=json.loads(json.dumps(original))
                    if advertised is True:
                        expected['method']='session/set_config_option'
                        expected['params'].pop('modelId');expected['params'].update(configId='model',value='sonnet')
                    self.assertEqual(observed,expected)
                    reply=json.loads(process.stdout.readline());self.assertEqual(reply['id'],11)
                    self.assertEqual('error' in reply,reject)
                    self.assertEqual(process.wait(timeout=5),1 if reject else 0)
                    self.assertEqual(process.stdout.read(),'','Rejected selection cannot run default prompt')
                    if reject:self.assertIn('Explicit provider model selection rejected',process.stderr.read())
                finally:
                    if process.poll() is None:process.kill();process.wait()
                    process.stdin.close();process.stdout.close();process.stderr.close()

    def test_model_projection_requires_correlated_new_and_session_capability(self):
        bridge=launcher.ModelSelectionBridge()
        original=json.dumps({'id':20,'method':'session/set_model','params':{'sessionId':'new','modelId':'sonnet'}})
        self.assertEqual(bridge.request(original),original)
        self.assertFalse(bridge.response(json.dumps({'id':123,'result':{'sessionId':'new','configOptions':[{'id':'model','type':'select','options':[{'value':'sonnet'}]}]}})))
        self.assertEqual(bridge.request(original),original)
        self.assertFalse(bridge.response(json.dumps({'id':999,'error':{'message':'unrelated'}})))
        self.assertFalse(bridge.failed)
        bridge.request(json.dumps({'id':1,'method':'session/new','params':{}}))
        bridge.response(json.dumps({'id':1,'result':{'sessionId':'new','configOptions':[{'id':'model','type':'select','options':[{'value':'sonnet'}]}]}}))
        other=original.replace('"new"','"other"');self.assertEqual(bridge.request(other),other)
        actual=json.loads(bridge.request(original));self.assertEqual(actual['method'],'session/set_config_option')
        self.assertTrue(bridge.response(json.dumps({'id':20,'error':{'message':'invalid model'}})))
        with self.assertRaisesRegex(RuntimeError,'input blocked'):
            bridge.request(json.dumps({'method':'session/prompt','params':{}}))

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
