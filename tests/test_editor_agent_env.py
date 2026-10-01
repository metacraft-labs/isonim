#!/usr/bin/env python3
"""Real process/file boundary for instance-scoped provider environment delivery.

No mocks: invoke the production wrapper, real Python child and actual private
files. Verify exact args/ordinary credentials, scoped control vars, CLI PATH,
browser-authority stripping and refusal of broad permissions or unknown values.
Route text fixtures exercise the pure recognizer without replacing OS APIs;
official Harbor scenarios separately prove the actual isolated network callback.
This proves launch delivery; model tool use is covered by the scenario suites.
"""
import json
import http.client
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import queue
import threading
import unittest
import importlib.util

REPO = Path(__file__).resolve().parents[1]
WRAPPER = REPO / "tools/editor_agent_env.py"
module_spec = importlib.util.spec_from_file_location("editor_agent_env", WRAPPER)
wrapper_module = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(wrapper_module)
SLIRP_ROUTES = ("Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT\n"
    "tap0 00000000 0202000A 0003 0 0 0 00000000 0 0 0\n"
    "tap0 0002000A 00000000 0001 0 0 0 00FFFFFF 0 0 0\n")

class ControlEnvironmentTests(unittest.TestCase):
    def test_only_observed_supported_slirp_loopback_is_translated(self):
        for host in ('127.0.0.1','localhost','[::1]'):
            endpoint='https://'+host+':4321/callback/path?preserve=yes#fragment'
            self.assertEqual(wrapper_module.endpoint_for_routes(endpoint,SLIRP_ROUTES,'linux'),
                'https://10.0.2.2:4321/callback/path?preserve=yes#fragment')
        literal='http://127.0.0.1:4321/path'
        for routes in ('', 'malformed', SLIRP_ROUTES.replace('Iface','invalid'),
                       SLIRP_ROUTES.replace('0202000A','0102000A'),
                       SLIRP_ROUTES.replace('tap0','eth0'), SLIRP_ROUTES.replace('0003','0001'),
                       SLIRP_ROUTES.replace('00FFFFFF','0000FFFF'),
                       SLIRP_ROUTES+SLIRP_ROUTES.splitlines()[1]+'\n'):
            self.assertEqual(wrapper_module.endpoint_for_routes(literal,routes,'linux'),literal)
        for endpoint in ('http://editor.example:4321/path', 'http://192.168.1.2:4321',
                         'http://10.0.2.2:4321', 'http://localhost:invalid',
                         'http://localhost', 'http://user@localhost:4321', 'broken['):
            self.assertEqual(wrapper_module.endpoint_for_routes(endpoint,SLIRP_ROUTES,'linux'),endpoint)
        self.assertEqual(wrapper_module.endpoint_for_routes(literal,SLIRP_ROUTES,'darwin'),literal)

    def test_failed_scoped_provider_creation_removes_private_handoff(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / 'editor.toml'
            config.write_text('[agent]\nbackend="custom"\ncommand="/definitely-missing-isonim-test-provider"\nprimer_enabled=false\n')
            env = {**os.environ, 'TMPDIR': temp, 'ISONIM_REVIEW_PORT': '0',
                   'ISONIM_EDITOR_BROWSER_BOOTSTRAP': 'test-browser-bootstrap'}
            env.pop('ISONIM_ACP_AGENT_CMD', None)
            daemon = subprocess.Popen([str(REPO / 'build/bin/isonim-review'), 'serve',
                '--agent-routes-only', '--config', str(config)], env=env,
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            ready = queue.Queue()
            reader_errors = queue.Queue()
            def drain():
                try:
                    for line in daemon.stderr:
                        if line.startswith('READY '): ready.put(int(line.split()[1]))
                except Exception as error:
                    reader_errors.put(error)
            reader = threading.Thread(target=drain)
            reader.start()
            try:
                port = ready.get(timeout=10)
                def post(path, body, token):
                    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                    try:
                        connection.request('POST', path, json.dumps(body),
                            {'Content-Type':'application/json','X-IsoNim-Control':token})
                        response = connection.getresponse()
                        return response.status, json.loads(response.read())
                    finally: connection.close()
                _, registration = post('/api/editor/rpc', {'jsonrpc':'2.0','id':1,
                    'method':'editor.register','params':{'workspace':'failure','state':{'revision':0}}},
                    'test-browser-bootstrap')
                browser = registration['result']
                scope = {key:browser[key] for key in ['workspace','instance','epoch']}
                status, failure = post('/api/agent/sessions', {'editor':scope}, browser['browserToken'])
                # The wrapper process starts, but its provider exec fails before
                # initialize. The existing handler classifies this as init failure.
                self.assertEqual(status, 500)
                self.assertEqual(failure['error'], 'agent_init_failed')
                self.assertEqual(list(Path(temp).glob('isonim-control-*')), [])
                _, response = post('/api/editor/rpc', {'jsonrpc':'2.0','id':2,
                    'method':'editor.state','params':scope}, browser['controlToken'])
                self.assertIn('result', response, 'Failed provider must not crash the daemon')
            finally:
                daemon.terminate()
                daemon.wait(timeout=10)
                reader.join(timeout=5)
                self.assertFalse(reader.is_alive(), 'Daemon stderr reader must drain and exit')
                daemon.stderr.close()
                self.assertTrue(reader_errors.empty(), 'Background reader failed: ' + repr(list(reader_errors.queue)))
                self.assertIsNotNone(daemon.returncode)

    def test_real_child_has_only_agent_scope_and_preserves_provider_arguments(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "private.json"
            values = {
                "ISONIM_EDITOR_ENDPOINT": "http://127.0.0.1:1234",
                "ISONIM_EDITOR_WORKSPACE": "workspace", "ISONIM_EDITOR_INSTANCE": "tab-one",
                "ISONIM_EDITOR_EPOCH": "epoch-one", "ISONIM_EDITOR_TOKEN": "scoped-agent-value",
                "ISONIM_EDITOR_CLI_DIR": str(REPO / "build/bin"),
            }
            path.write_text(json.dumps(values)); path.chmod(0o600)
            code = "import json,os,sys; print(json.dumps({'args':sys.argv[1:], 'env':dict(os.environ)}))"
            args = ["", "spaces and punctuation: ' \" $()", "unicode α", "line\nbreak"]
            env = {**os.environ, "ISONIM_EDITOR_BROWSER_BOOTSTRAP": "browser-only-marker",
                   "AH_HOME": str(Path(temp) / "real-ah-home"), "UNRELATED_PROVIDER_SETTING": "kept"}
            result = subprocess.run([sys.executable, str(WRAPPER), "--environment", str(path), "--",
                sys.executable, "-c", code, *args], env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(result.stdout)
            self.assertEqual(data["args"], args)
            for key, value in values.items(): self.assertEqual(data["env"][key], value)
            self.assertNotIn("ISONIM_EDITOR_BROWSER_BOOTSTRAP", data["env"])
            self.assertEqual(data["env"]["AH_HOME"], env["AH_HOME"])
            self.assertEqual(data["env"]["UNRELATED_PROVIDER_SETTING"], "kept")
            self.assertTrue(data["env"]["PATH"].startswith(values["ISONIM_EDITOR_CLI_DIR"] + os.pathsep))
            self.assertNotIn(values["ISONIM_EDITOR_TOKEN"], result.stderr)

    def test_broad_permissions_fail_before_child_execution(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "public.json"
            path.write_text("{}"); path.chmod(0o644)
            result = subprocess.run([sys.executable, str(WRAPPER), "--environment", str(path), "--",
                sys.executable, "-c", "raise SystemExit(37)"], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertIn("mode 0600", result.stderr)

    def test_unknown_environment_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "private.json"
            path.write_text('{"ISONIM_EDITOR_BROWSER_BOOTSTRAP":"must-not-copy"}'); path.chmod(0o600)
            result = subprocess.run([sys.executable, str(WRAPPER), "--environment", str(path), "--",
                sys.executable, "-c", "raise SystemExit(37)"], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertIn("invalid scoped environment", result.stderr)
            self.assertNotIn("must-not-copy", result.stderr)

if __name__ == "__main__": unittest.main()
