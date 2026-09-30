"""Real editor HTTP/worker lifetime tests with a controlled Harbor protocol peer.

Only Harbor is substituted to hold creation/streaming at exact barriers. This
proves editor races and HTTP responsiveness; live/scenario tests separately prove
Harbor/provider integration. No editor dispatcher or process is mocked.
"""
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.created = threading.Event()
        self.allow_create = threading.Event()
        self.streamed = threading.Event()
        self.allow_finish = threading.Event()
        self.stopped = threading.Event()
        self.fail_stop = False
        owner = self

        class Peer(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def respond(self, value, status=200):
                payload = json.dumps(value).encode()
                self.send_response(status)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
                if self.path == '/api/v1/sessions':
                    owner.created.set()
                    if not owner.allow_create.wait(10):
                        return
                    self.respond({'session_id': 'backend', 'status': 'queued'})
                elif self.path.endswith('/stop'):
                    if owner.fail_stop:
                        self.respond({'error': 'controlled close failure'}, 503)
                        return
                    owner.stopped.set()
                    owner.allow_finish.set()
                    self.respond({})
                else:
                    self.respond({'accepted': True, 'sessionId': 'backend'})

            def do_GET(self):
                if self.path.endswith('/events/history?limit=1'):
                    self.respond({'events': [], 'total_count': 0})
                    return
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                self.wfile.write(b'id: 1\ndata: {"type":"log","message":"started"}\n\n')
                self.wfile.flush()
                owner.streamed.set()
                owner.allow_finish.wait(10)
                self.wfile.write(b'id: 2\ndata: {"type":"turn_complete","stop_reason":"end_turn"}\n\n')
                self.wfile.flush()

        self.peer = ThreadingHTTPServer(('127.0.0.1', 0), Peer)
        threading.Thread(target=self.peer.serve_forever, daemon=True).start()
        config = Path(self.temp.name) / 'editor.toml'
        config.write_text('[agent]\nbackend = "harbor"\ncommand = "/bin/true"\nprimer_enabled = false\n')
        env = dict(os.environ, ISONIM_AGENT_BACKEND='harbor', ISONIM_LOCAL_HARBOR='0',
            ISONIM_HARBOR_URL=f'http://127.0.0.1:{self.peer.server_port}', ISONIM_REVIEW_PORT='0',
            ISONIM_EDITOR_BROWSER_BOOTSTRAP='lifecycle-browser-bootstrap')
        env.pop('ISONIM_ACP_AGENT_CMD', None)
        self.daemon = subprocess.Popen([str(ROOT / 'build/bin/isonim-review'), 'serve',
            '--agent-routes-only', '--config', str(config)], env=env, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, text=True)
        ready = queue.Queue()

        def drain():
            for line in self.daemon.stderr:
                if line.startswith('READY '):
                    ready.put(int(line.split()[1]))
        threading.Thread(target=drain, daemon=True).start()
        self.port = ready.get(timeout=20)
        status, body = self.post('/api/agent/sessions', {})
        self.assertEqual(status, 200, body)
        self.session = json.loads(body)['sessionId']
        self.assertEqual(json.loads(body)['backendSessionId'], '')
        self.assertEqual(json.loads(body)['sessionState'], 'draft')

    def tearDown(self):
        self.allow_create.set()
        self.allow_finish.set()
        self.daemon.terminate()
        self.daemon.wait(timeout=10)
        self.peer.shutdown()
        self.peer.server_close()
        self.temp.cleanup()

    def post(self, path, value, token=''):
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        try:
            connection.request('POST', path, json.dumps(value), {'Content-Type': 'application/json', 'X-IsoNim-Control': token})
            response = connection.getresponse()
            return response.status, response.read().decode()
        finally:
            connection.close()

    def prompt(self):
        return {'sessionId': self.session, 'messages': [{'role': 'user', 'content': [{'type': 'text', 'text': 'hello'}]}]}

    def start_scoped_turn(self):
        _, raw = self.post('/api/editor/rpc', {'jsonrpc': '2.0', 'id': 1, 'method': 'editor.register',
            'params': {'workspace': 'lifecycle', 'state': {'revision': 0}}}, 'lifecycle-browser-bootstrap')
        browser = json.loads(raw)['result']
        scope = {key: browser[key] for key in ['workspace', 'instance', 'epoch']}
        status, raw = self.post('/api/agent/sessions', {'editor': scope}, browser['browserToken'])
        self.assertEqual(status, 200)
        self.session = json.loads(raw)['sessionId']
        outcome = queue.Queue()
        threading.Thread(target=lambda: outcome.put(self.post('/api/agent/prompts', self.prompt())), daemon=True).start()
        self.assertTrue(self.created.wait(5))
        self.allow_create.set()
        self.assertTrue(self.streamed.wait(5))
        environment = Path(tempfile.gettempdir()) / ('isonim-control-' + self.session) / 'environment.json'
        self.assertTrue(environment.is_file())
        self.assertEqual(environment.stat().st_mode & 0o777, 0o600)
        token = json.loads(environment.read_text())['ISONIM_EDITOR_TOKEN']
        self.allow_finish.set()
        self.assertEqual(outcome.get(timeout=5)[0], 200)
        return scope, token, environment

    def test_backend_close_failure_retains_control_then_acknowledged_close_revokes_and_cleans(self):
        scope, token, environment = self.start_scoped_turn()
        self.fail_stop = True
        self.assertEqual(self.post('/api/agent/close', {'sessionId': self.session})[0], 502)
        self.assertTrue(environment.is_file())
        _, raw = self.post('/api/editor/rpc', {'jsonrpc': '2.0', 'id': 1, 'method': 'editor.state', 'params': scope}, token)
        self.assertIn('result', json.loads(raw))
        self.fail_stop = False
        self.assertEqual(self.post('/api/agent/close', {'sessionId': self.session})[0], 200)
        self.assertFalse(environment.exists())
        _, raw = self.post('/api/editor/rpc', {'jsonrpc': '2.0', 'id': 1, 'method': 'editor.state', 'params': scope}, token)
        self.assertEqual(json.loads(raw)['error']['message'], 'invalid_control_credential')

    def test_local_environment_cleanup_failure_cannot_resurrect_closed_backend(self):
        _, _, environment = self.start_scoped_turn()
        # Removing write permission from the owned directory makes the real
        # unlink boundary fail; no cleanup method or filesystem is mocked.
        environment.parent.chmod(0o500)
        try:
            self.assertEqual(self.post('/api/agent/close', {'sessionId': self.session})[0], 200)
            self.assertEqual(self.post('/api/agent/prompts', self.prompt())[0], 404)
        finally:
            environment.parent.chmod(0o700)
            environment.unlink()
            environment.parent.rmdir()

    def test_close_during_creation_closes_new_backend_without_resurrection(self):
        outcome = queue.Queue()
        threading.Thread(target=lambda: outcome.put(self.post('/api/agent/prompts', self.prompt())), daemon=True).start()
        self.assertTrue(self.created.wait(5))
        self.assertEqual(self.post('/api/agent/close', {'sessionId': self.session})[0], 200)
        self.allow_create.set()
        self.assertTrue(self.stopped.wait(5), 'new backend leaked after local draft closed')
        self.assertIn('Conversation closed', outcome.get(timeout=5)[1])
        self.assertEqual(self.post('/api/agent/prompts', self.prompt())[0], 404)

    def test_stream_disconnect_keeps_daemon_responsive_and_turn_exclusive(self):
        self.allow_create.set()
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        connection.request('POST', '/api/agent/prompts', json.dumps(self.prompt()))
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertTrue(self.streamed.wait(5))
        response.close()
        connection.close()
        self.assertEqual(self.post('/api/agent/prompts', self.prompt())[0], 409)
        self.assertEqual(self.post('/api/agent/cancel', {'sessionId': self.session})[0], 409)
        self.assertFalse(self.stopped.is_set())
        self.assertEqual(self.post('/api/agent/sessions', {})[0], 200)
        self.assertEqual(self.post('/api/agent/close', {'sessionId': self.session})[0], 200)
        self.assertTrue(self.stopped.wait(5))


if __name__ == '__main__':
    unittest.main()
