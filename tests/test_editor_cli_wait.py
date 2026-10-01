"""Real native CLI waits over TCP and HTTP, including partial observation.

Only the JSON-RPC server is substituted with a controlled wire peer: it returns
genuine pending snapshots then holds a later response to reach the CLI's actual
deadline deterministically. This isolates CLI result ownership without browser
timing. The executable, HTTP client, sockets, deadline and subprocess are real.
Full registered control GUI coverage separately exercises the production server.
No command dispatcher, clock, CLI result or process is mocked.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CliWaitTests(unittest.TestCase):
    def exercise(self, mode, timeout):
        requests = []
        disconnected = threading.Event()
        problems = []
        owner = self

        class Peer(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                try:
                    body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    owner.assertEqual(self.path, '/api/editor/rpc')
                    owner.assertEqual(self.headers['X-IsoNim-Control'], 'fixture-scoped-authority')
                    owner.assertEqual(body['method'], 'editor.wait')
                    owner.assertEqual(body['params'], {'workspace': 'fixture-workspace',
                        'instance': 'fixture-instance', 'epoch': 'fixture-epoch', 'operationId': 'approve1'})
                    requests.append(body)
                    number = len(requests)
                    if mode == 'first_timeout' or (mode == 'latest_timeout' and number == 3):
                        # No response is produced. Observe the real client closing
                        # its connection at the deadline; never manufacture EOF.
                        self.connection.settimeout(3)
                        owner.assertEqual(self.connection.recv(1), b'')
                        disconnected.set()
                        return
                    if mode == 'rpc_failure' and number == 2:
                        reply = {'jsonrpc': '2.0', 'id': body['id'],
                                 'error': {'code': -32000, 'message': 'fixture_rpc_failure'}}
                    else:
                        snapshot = {'operationId': 'approve1', 'status':
                            'applied' if mode == 'completion' and number == 2 else 'pending',
                            'revision': 6 + number}
                        reply = {'jsonrpc': '2.0', 'id': body['id'], 'result': snapshot}
                    data = json.dumps(reply).encode()
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                except Exception as error:
                    problems.append(error)

        server = ThreadingHTTPServer(('127.0.0.1', 0), Peer)
        server.daemon_threads = False  # server_close joins every owned request reader.
        thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=.02))
        thread.start()
        try:
            env = dict(os.environ)
            env.update(ISONIM_EDITOR_ENDPOINT='http://127.0.0.1:' + str(server.server_port),
                       ISONIM_EDITOR_WORKSPACE='fixture-workspace', ISONIM_EDITOR_INSTANCE='fixture-instance',
                       ISONIM_EDITOR_EPOCH='fixture-epoch', ISONIM_EDITOR_TOKEN='fixture-scoped-authority')
            child = subprocess.run([str(ROOT / 'build/bin/isonim'), 'editor', 'wait', 'approve1',
                                    '--timeout-ms', str(timeout)], env=env, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=4)
            if mode.endswith('timeout'):
                self.assertTrue(disconnected.wait(3), 'Actual deadline must disconnect the held HTTP exchange')
        finally:
            server.shutdown()
            thread.join(timeout=3)
            server.server_close()
        self.assertFalse(thread.is_alive())
        self.assertEqual(problems, [])
        self.assertNotIn('fixture-scoped-authority', child.stdout + child.stderr)
        self.assertEqual(child.stderr, '')
        return child.returncode, json.loads(child.stdout), requests

    def test_first_exchange_timeout_has_no_invented_operation(self):
        code, result, requests = self.exercise('first_timeout', 120)
        self.assertEqual(len(requests), 1)
        self.assertEqual(code, 5)
        self.assertEqual(result, {'error': 'control_timeout'})

    def test_later_exchange_timeout_keeps_latest_real_snapshot(self):
        code, result, requests = self.exercise('latest_timeout', 500)
        self.assertEqual(len(requests), 3, 'Two real observations must precede the held exchange')
        self.assertEqual(code, 5)
        self.assertEqual(result, {'error': 'control_timeout', 'operation':
            {'operationId': 'approve1', 'status': 'pending', 'revision': 8}})

    def test_rpc_failure_is_not_disguised_as_observed_timeout(self):
        code, result, requests = self.exercise('rpc_failure', 500)
        self.assertEqual(len(requests), 2)
        self.assertEqual(code, 3)
        self.assertEqual(result, {'error': 'fixture_rpc_failure'})

    def test_real_terminal_reply_completes_wait(self):
        code, result, requests = self.exercise('completion', 500)
        self.assertEqual(len(requests), 2)
        self.assertEqual(code, 0)
        self.assertEqual(result, {'operationId': 'approve1', 'status': 'applied', 'revision': 8})


if __name__ == '__main__':
    unittest.main()
