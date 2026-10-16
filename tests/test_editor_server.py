"""Shared launcher tests across real HTTP, process and filesystem boundaries.

A controlled upstream HTTP server supplies barriers to prove incremental forwarding,
errors, and disconnection without a provider/network timing dependency. The real
editor daemon is used for configuration/workspace checks. This is launcher proof;
Harbor/provider scenario E2E coverage is separate. A controlled native frontend also writes real temporary files and exchanges
upgrade bytes to verify preserved consumer routes. A tiny child process exercises
supervisor ownership, including descendants, without invoking a GUI compiler.
Copied real ps executables and actual missing/nonzero/hung replacements exercise
preflight and cleanup failure at real process/filesystem boundaries. The delayed
REST peer proves ownership and shutdown budgets, not provider behavior. A cache
fixture uses real foreign process identities to represent stale numeric IDs
without forcing kernel PID reuse; all ownership checks remain real.
"""
import importlib.util
import contextlib
import io
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / 'tools/editor_server.py'


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def request(port, path='/', method='GET', body=None):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
    connection.request(method, path, json.dumps(body) if body is not None else None,
                        {'Content-Type': 'application/json'})
    response = connection.getresponse()
    data = response.read()
    connection.close()
    return response.status, data


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        (self.directory / 'index.html').write_text('<html><head><meta name="isonim-review-api" content="http://127.0.0.1:9999"></head><body>Editor</body></html>')
        self.children = []
        self.allow_end = threading.Event()
        self.stream_started = threading.Event()
        self.created_payload = None
        self.created = threading.Event()
        self.allow_create = threading.Event(); self.allow_create.set()
        self.stopped = threading.Event()
        self.stop_delay = 0
        self.stop_times = []
        self.created_ids = []
        self.stopped_ids = []
        self.peer_lock = threading.Lock()
        owner = self
        class Peer(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
                if self.path == '/api/v1/sessions':
                    owner.created_payload = payload
                    with owner.peer_lock:
                        backend_id = 'backend-'+str(len(owner.created_ids)+1)
                        owner.created_ids.append(backend_id)
                    owner.created.set()
                    owner.allow_create.wait(28)
                    value = {'session_id': backend_id, 'status': 'queued'}
                elif self.path.endswith('/stop'):
                    with owner.peer_lock:
                        owner.stop_times.append(time.monotonic())
                    time.sleep(owner.stop_delay)
                    owner.allow_end.set()
                    value = {}
                else: value = {'accepted': True, 'sessionId': 'backend'}
                data = json.dumps(value).encode()
                self.send_response(200); self.send_header('Content-Length', str(len(data)))
                self.end_headers(); self.wfile.write(data); self.wfile.flush()
                if self.path.endswith("/stop"):
                    with owner.peer_lock:
                        owner.stopped_ids.append(self.path.split("/")[-2])
                    owner.stopped.set()
            def do_GET(self):
                if self.path == '/api/stream' or self.path.endswith('/events'):
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.end_headers()
                    self.wfile.write(b'data: first\n\n' if self.path == '/api/stream' else b'id: 1\ndata: {"type":"log","message":"started"}\n\n')
                    self.wfile.flush()
                    owner.stream_started.set()
                    owner.allow_end.wait(5)
                    try:
                        self.wfile.write(b'data: second\n\n')
                    except (BrokenPipeError, ConnectionResetError): pass
                else:
                    self.send_response(409)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Content-Length', '20')
                    self.end_headers()
                    self.wfile.write(b'{"error":"conflict"}')
        self.peer = ThreadingHTTPServer(('127.0.0.1', 0), Peer)
        self.peer.daemon_threads = True
        threading.Thread(target=self.peer.serve_forever, daemon=True).start()

    def tearDown(self):
        self.allow_create.set()
        self.allow_end.set()
        for child, output in reversed(self.children):
            if child.poll() is None:
                child.terminate()
                try: child.wait(10)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait()
            output.close()
        self.peer.shutdown()
        self.peer.server_close()
        self.temp.cleanup()

    def launch(self, extra=(), env=None):
        port = free_port()
        output = tempfile.TemporaryFile(mode='w+')
        child = subprocess.Popen([sys.executable, str(LAUNCHER),
            '--directory', str(self.directory), '--project-root', str(self.directory),
            '--port', str(port), *extra], stdout=output, stderr=output,
            env=dict(os.environ, **(env or {})))
        self.children.append((child, output))
        return child, port, output

    def wait_ready(self, child, port, output):
        for _ in range(100):
            if child.poll() is not None:
                output.seek(0)
                self.fail(output.read())
            try:
                if request(port)[0] == 200: return
            except OSError: pass
            time.sleep(.05)
        self.fail('editor did not become ready')

    def external(self, extra=()):
        child, port, output = self.launch(('--daemon-url', f'http://127.0.0.1:{self.peer.server_port}', *extra))
        self.wait_ready(child, port, output)
        return child, port, output

    def test_same_origin_and_incremental_sse(self):
        child, port, output = self.external()
        status, html = request(port)
        self.assertEqual(status, 200)
        self.assertIn(b'apiMeta.content=location.origin', html)
        self.assertNotIn(b'127.0.0.1', html)
        self.assertNotIn(str(self.peer.server_port).encode(), html)
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
        connection.request('GET', '/api/stream')
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.readline(), b'data: first\n')
        self.assertFalse(self.allow_end.is_set(), 'first event must arrive before upstream finishes')
        self.allow_end.set()
        self.assertIn(b'data: second', response.read())
        connection.close()
        self.assertEqual(request(port, '/api/failure'), (409, b'{"error":"conflict"}'))
        child.terminate(); self.assertEqual(child.wait(10), 143)
        # The explicitly external service remains usable.
        self.assertEqual(request(self.peer.server_port, '/api/failure')[0], 409)
        with self.assertRaises(OSError): request(port)

    def test_disconnected_stream_does_not_block_other_requests(self):
        _, port, _ = self.external()
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
        connection.request('GET', '/api/stream')
        response = connection.getresponse()
        self.assertEqual(response.readline(), b'data: first\n')
        response.close(); connection.close()
        self.assertEqual(request(port, '/api/failure')[0], 409)
        self.allow_end.set()

    def test_unreachable_upstream_is_502(self):
        child, port, output = self.launch(('--daemon-url', f'http://127.0.0.1:{free_port()}'))
        self.wait_ready(child, port, output)
        self.assertEqual(request(port, '/api/failure')[0], 502)

    def test_startup_and_bind_failures_are_errors(self):
        child, _, output = self.launch(('--daemon-binary', '/nonexistent/isonim-review'))
        self.assertEqual(child.wait(10), 1)
        output.seek(0); self.assertIn('No such file', output.read())
        with socket.socket() as occupied:
            occupied.bind(('127.0.0.1', 0)); occupied.listen()
            output2 = tempfile.TemporaryFile(mode='w+')
            bad = subprocess.Popen([sys.executable, str(LAUNCHER), '--directory', str(self.directory),
                '--project-root', str(self.directory), '--port', str(occupied.getsockname()[1]),
                '--daemon-url', f'http://127.0.0.1:{self.peer.server_port}'], stdout=output2, stderr=output2)
            self.children.append((bad, output2))
            self.assertEqual(bad.wait(10), 1)
            output2.seek(0); self.assertIn('Address already in use', output2.read())

    def test_command_descendants_are_owned_on_sigterm(self):
        other, other_port, _ = self.external()
        script = self.directory / 'child.py'
        pidfile = self.directory / 'pid'
        script.write_text('import subprocess,sys,time,signal\nfrom pathlib import Path\np=subprocess.Popen([sys.executable,"-c","import socket,time,os; os.setpgrp(); s=socket.socket(); s.bind((\\\"127.0.0.1\\\",0)); s.listen(); from pathlib import Path; Path(\\\"'+str(self.directory/'listener')+'\\\").write_text(str(s.getsockname()[1])); time.sleep(60)"])\nPath(sys.argv[1]).write_text(str(p.pid))\ndef stop(signum,frame):\n Path(sys.argv[1]+\".stopping\").write_text(\"yes\"); time.sleep(.3); raise SystemExit(0)\nsignal.signal(signal.SIGTERM,stop)\ntry: time.sleep(60)\nfinally: p.terminate(); p.wait()\n')
        child, _, _ = self.launch(('--daemon-url', f'http://127.0.0.1:{self.peer.server_port}',
            '--command', sys.executable, str(script), str(pidfile)))
        for _ in range(100):
            if pidfile.exists() and (self.directory/'listener').exists(): break
            time.sleep(.05)
        self.assertTrue(pidfile.exists())
        listener = int((self.directory/'listener').read_text())
        with socket.create_connection(('127.0.0.1', listener), timeout=1): pass
        child.terminate()
        for _ in range(100):
            if Path(str(pidfile)+'.stopping').exists(): break
            time.sleep(.005)
        self.assertTrue(Path(str(pidfile)+'.stopping').exists())
        child.send_signal(signal.SIGTERM)
        self.assertEqual(child.wait(10), 143)
        with self.assertRaises(OSError): socket.create_connection(('127.0.0.1', listener), timeout=1)
        self.assertIsNone(other.poll())
        self.assertEqual(request(other_port)[0], 200, 'another editor instance was stopped')

    def test_native_frontend_proxy_preserves_write_and_upgrade_routes(self):
        script = self.directory / 'frontend.py'
        script.write_text((
          'import http.server,json,os\n'
          'from pathlib import Path\n'
          'class Handler(http.server.BaseHTTPRequestHandler):\n'
          ' def do_GET(self):\n'
          "  if self.headers.get('Upgrade') == 'websocket':\n"
          "   self.send_response(101); self.send_header('Upgrade','websocket'); self.send_header('Connection','Upgrade'); self.end_headers()\n"
          '   self.wfile.write(self.rfile.read(4)); self.wfile.flush(); return\n'
          '  page=b\'<html><head><meta name="isonim-review-api" content="http://127.0.0.1:7777"></head><body>Native</body></html>\'\n'
          "  self.send_response(200); self.send_header('Content-Type','text/html'); self.send_header('Content-Length',str(len(page))); self.end_headers(); self.wfile.write(page)\n"
          ' def do_POST(self):\n'
          "  value=self.rfile.read(int(self.headers['Content-Length']))\n"
          "  Path('saved.json').write_bytes(value)\n"
          "  self.send_response(201); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(value))); self.end_headers(); self.wfile.write(value)\n"
          "server=http.server.ThreadingHTTPServer((os.environ['ISONIM_EDITOR_BIND'],int(os.environ['PORT'])),Handler)\n"
          "Path('frontend-port').write_text(str(server.server_port))\n"
          'server.serve_forever()\n'
        ))
        child, port, output = self.external(('--frontend-command', sys.executable, str(script)))
        status, html = request(port)
        self.assertEqual(status, 200)
        self.assertIn(b'Native', html)
        self.assertIn(b'apiMeta.content=location.origin', html)
        self.assertNotIn(b'127.0.0.1', html)
        value = {'token': 'edited'}
        status, saved = request(port, '/__isonim_save', 'POST', value)
        self.assertEqual(status, 201)
        self.assertEqual(json.loads(saved), value)
        self.assertEqual(json.loads((self.directory/'saved.json').read_text()), value)
        self.assertEqual(request(port, '/api/failure')[0], 409)
        with socket.create_connection(('127.0.0.1', port), timeout=2) as connection:
            connection.sendall(b'GET /__isonim_reload HTTP/1.1\r\nHost: remote.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n')
            head = b''
            while b'\r\n\r\n' not in head: head += connection.recv(4096)
            self.assertIn(b'101 Switching Protocols', head)
            connection.sendall(b'ping')
            self.assertEqual(connection.recv(4), b'ping')
        frontend_port = int((self.directory/'frontend-port').read_text())
        child.terminate(); self.assertEqual(child.wait(10), 143)
        with self.assertRaises(OSError): request(frontend_port)
        with self.assertRaises(OSError): request(port)

    def test_consumer_bridges_keep_agent_streams_and_existing_routes(self):
        node = shutil.which('node')
        self.assertIsNotNone(node, 'Node is required by the consumer bridge tests')
        for consumer, script in (
            ('isonim-examples', 'tools/editor-server.mjs'),
            ('metacraft-web', 'tools/serve_editor_dev_bridge.mjs')):
            with self.subTest(consumer=consumer):
                extra = ['--command', node, str(ROOT.parent / consumer / script)]
                if consumer == 'metacraft-web': extra += [str(self.directory), '0']
                # The consumer bridge's CLI port must be the same public port.
                if consumer == 'metacraft-web':
                    child, port, output = self.launch(('--daemon-url',
                        f'http://127.0.0.1:{self.peer.server_port}', *extra))
                    # Node bridge supports PORT when supervised; standalone CLI
                    # remains available for its existing tests and users.
                    self.wait_ready(child, port, output)
                else:
                    child, port, output = self.external(extra)
                status, html = request(port)
                self.assertEqual(status, 200)
                self.assertNotIn(str(self.peer.server_port).encode(), html)
                self.assertIn(b'isonim-review-api', html)
                self.assertEqual(request(port, '/api/failure'), (409, b'{"error":"conflict"}'))
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
                connection.request('GET', '/api/stream')
                response = connection.getresponse()
                self.assertEqual(response.readline(), b'data: first\n')
                self.assertFalse(self.allow_end.is_set())
                self.allow_end.set()
                self.assertIn(b'data: second', response.read())
                connection.close(); self.allow_end.clear()
                if consumer == 'metacraft-web':
                    status, health = request(port, '/__isonim-dev-bridge/health')
                    self.assertEqual(status, 200)
                    self.assertTrue(json.loads(health)['ok'])
                    status, state = request(port, '/__isonim-dev-bridge/status', 'POST', {})
                    self.assertEqual(status, 200)
                    self.assertEqual(json.loads(state)['workspaceRoot'], str(self.directory))
                else:
                    # Real upgrade byte forwarding to the established GPUI
                    # route, using a controlled TCP peer only for the bridge.
                    with socket.socket() as listener:
                        listener.bind(('127.0.0.1', 8103)); listener.listen()
                        captured = []
                        def upgrade_peer():
                            stream, _ = listener.accept()
                            with stream:
                                captured.append(stream.recv(4096))
                                stream.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n')
                        thread = threading.Thread(target=upgrade_peer, daemon=True); thread.start()
                        with socket.create_connection(('127.0.0.1', port), timeout=2) as client:
                            client.sendall(b'GET /bridge/gpui HTTP/1.1\r\nHost: remote.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n')
                            self.assertIn(b'101 Switching Protocols', client.recv(4096))
                        thread.join(2)
                        self.assertIn(b'GET / HTTP/1.1', captured[0])
                child.terminate(); self.assertEqual(child.wait(10), 143)
                with self.assertRaises(OSError): request(port)

    def test_real_daemon_uses_project_and_preserves_explicit_config(self):
        # External Harbor mode creates a local draft before contacting the peer.
        # Invalid sibling proves explicit backend config wins in the real daemon.
        config = self.directory / '.isonim' / 'config.toml'
        config.parent.mkdir()
        promptfile = self.directory / 'instructions.md'
        promptfile.write_text('Explicit authoring instructions')
        config.write_text('[agent]\nbackend="harbor"\nharbor_url="http://127.0.0.1:'+str(self.peer.server_port)+'"\nprimer_enabled=false\nassistant_prompt_path="'+str(promptfile)+'"\n')
        child, port, output = self.launch(('--daemon-binary', str(ROOT/'build/bin/isonim-review')) ,
            {'ISONIM_AGENT_HARBOR_SIBLING': '/nonexistent/harbor', 'HOME': str(self.directory)})
        self.wait_ready(child, port, output)
        status, body = request(port, '/api/agent/sessions', 'POST', {})
        self.assertEqual(status, 200, body)
        session = json.loads(body)
        self.assertTrue(session['sessionId'].startswith('draft-'))
        output.seek(0)
        lines = output.read()
        self.assertNotIn('building workspace Agent Harbor', lines)
        self.assertIn('assistantPromptPath='+str(promptfile), lines)
        # Deliver the first prompt through the real daemon and common library;
        # inspect the actual wire workspace, rather than a launcher argument.
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
        connection.request('POST', '/api/agent/prompts', json.dumps({'sessionId': session['sessionId'],
            'messages': [{'role': 'user', 'content': [{'type': 'text', 'text': 'hello'}]}]}))
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        arrived = self.stream_started.wait(5)
        output.seek(0)
        self.assertTrue(arrived, output.read())
        self.assertEqual(self.created_payload['workspace_path'], str(self.directory))
        ready = next(line for line in lines.splitlines() if line.startswith('READY '))
        daemon_port = int(ready.split()[1])
        self.assertEqual(request(daemon_port, '/api/agent/sessions', 'OPTIONS')[0], 204)
        child.terminate(); self.assertEqual(child.wait(10), 143)
        self.assertTrue(self.stopped.wait(2), 'active provider was not closed on launcher shutdown')
        response.close(); connection.close()
        with self.assertRaises(OSError): request(daemon_port)
    def test_shutdown_during_backend_creation_closes_late_session(self):
        config = self.directory / 'config.toml'
        config.write_text('[agent]\nbackend="harbor"\nharbor_url="http://127.0.0.1:'+str(self.peer.server_port)+'"\nprimer_enabled=false\n')
        child, port, output = self.launch(('--daemon-binary', str(ROOT/'build/bin/isonim-review'), '--config', str(config)))
        self.wait_ready(child, port, output)
        status, body = request(port, '/api/agent/sessions', 'POST', {})
        session = json.loads(body)['sessionId']
        self.allow_create.clear()
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
        connection.request('POST', '/api/agent/prompts', json.dumps({'sessionId':session, 'text':'hello'}))
        response = connection.getresponse()
        self.assertTrue(self.created.wait(5))
        self.stop_delay = 8
        child.terminate()
        # Hold first-session creation beyond daemon shutdown admission so a
        # removed draft cannot publish a provider after its owner exits.
        time.sleep(24)
        self.assertIsNone(child.poll(), 'owner exited before late backend could be closed')
        child.send_signal(signal.SIGTERM)
        self.allow_create.set()
        self.assertEqual(child.wait(10), 143)
        self.assertTrue(self.stopped.wait(2), 'late created provider was leaked')
        self.assertEqual(self.stopped_ids, self.created_ids)
        response.close(); connection.close()

    def test_shutdown_closes_multiple_slow_sessions_concurrently(self):
        # Two real REST stops each take 16s: serial shutdown would exceed the
        # old supervisor's 30s deadline. Both requests must arrive together.
        config = self.directory / 'parallel.toml'
        config.write_text('[agent]\nbackend="harbor"\nharbor_url="http://127.0.0.1:'+str(self.peer.server_port)+'"\nprimer_enabled=false\n')
        child, port, output = self.launch(('--daemon-binary', str(ROOT/'build/bin/isonim-review'), '--config', str(config)))
        self.wait_ready(child, port, output)
        connections = []
        try:
            for index in range(2):
                self.created.clear()
                self.stream_started.clear()
                status, body = request(port, '/api/agent/sessions', 'POST', {})
                self.assertEqual(status, 200)
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                connection.request('POST', '/api/agent/prompts', json.dumps({'sessionId':json.loads(body)['sessionId'], 'text':'hello'}))
                response = connection.getresponse()
                connections.append((connection,response))
                self.assertTrue(self.created.wait(5))
                self.assertTrue(self.stream_started.wait(5))
            self.stop_delay = 16
            child.terminate()
            self.assertEqual(child.wait(25), 143)
            self.assertEqual(len(self.created_ids), 2)
            self.assertEqual(len(set(self.created_ids)), 2)
            self.assertCountEqual(self.stopped_ids, self.created_ids)
            self.assertEqual(len(self.stop_times), 2)
            self.assertLess(max(self.stop_times)-min(self.stop_times), 2,
                            'independent provider stops were serialized')
            self.assertTrue(self.stopped.is_set())
        finally:
            for connection,response in connections:
                response.close(); connection.close()

    def test_cleanup_freezes_ps_and_signals_on_enumeration_failure(self):
        spec = importlib.util.spec_from_file_location('editor_launcher', LAUNCHER)
        launcher = importlib.util.module_from_spec(spec); spec.loader.exec_module(launcher)
        original = os.environ['PATH']
        ps = shutil.which('ps')
        python = sys.executable
        try:
            # PATH disappearance after a real child starts cannot alter the
            # executable used by cleanup. No mocked process API is involved.
            with launcher.owned_process([python, '-c', 'import time;time.sleep(60)']) as child:
                os.environ['PATH'] = str(self.directory)
            self.assertIsNotNone(child.poll())
            os.environ['PATH'] = original
            # A real executable that breaks after successful preflight must
            # diagnose enumeration failure and still terminate the known owner.
            controlled_ps = self.directory / 'ps'
            os.environ['PATH'] = str(self.directory)
            for failure in ('missing', 'nonzero', 'hung'):
                shutil.copyfile(ps, controlled_ps); controlled_ps.chmod(0o755)
                diagnostics = io.StringIO()
                with contextlib.redirect_stderr(diagnostics):
                    with launcher.owned_process([python, '-c', 'import time;time.sleep(60)']) as child:
                        controlled_ps.unlink()
                        if failure != 'missing':
                            controlled_ps.write_text('#!'+python+'\n'+
                                ('import sys;sys.exit(19)\n' if failure == 'nonzero' else 'import time;time.sleep(60)\n'))
                            controlled_ps.chmod(0o755)
                self.assertIsNotNone(child.poll())
                self.assertIn('enumeration failed', diagnostics.getvalue())
                self.assertIn('signalling known groups', diagnostics.getvalue())
                marker = self.directory / 'must-not-launch'
                with self.assertRaisesRegex(RuntimeError, 'ps'):
                    with launcher.owned_process([python, '-c',
                            'from pathlib import Path;Path('+repr(str(marker))+').touch()']):
                        self.fail('broken ps preflight launched a child')
                self.assertFalse(marker.exists())
                controlled_ps.unlink(missing_ok=True)
            with self.assertRaisesRegex(RuntimeError, 'require.*ps'):
                with launcher.owned_process([python, '-c', 'raise Exception("must not launch")']):
                    self.fail('missing dependency launched a child')
        finally:
            os.environ['PATH'] = original

    def test_cached_groups_revalidate_real_member_session_before_signalling(self):
        # Adversarial cached identity state represents a recycled group ID.
        # Both processes and all kernel identity calls are real; no PID reuse
        # or process API is mocked. The foreign session must remain running.
        spec = importlib.util.spec_from_file_location('editor_launcher', LAUNCHER)
        launcher = importlib.util.module_from_spec(spec); spec.loader.exec_module(launcher)
        bad_ps = self.directory / 'broken-ps'
        bad_ps.write_text('#!'+sys.executable+'\nimport sys;sys.exit(19)\n')
        bad_ps.chmod(0o755)
        with launcher.owned_process([sys.executable, '-c', 'import time;time.sleep(60)']) as owner:
            with launcher.owned_process([sys.executable, '-c', 'import time;time.sleep(60)']) as foreign:
                cache = {owner.pid: {owner.pid}, foreign.pid: {foreign.pid}}
                self.assertEqual(launcher.owned_session_groups(owner.pid, str(bad_ps), cache), {owner.pid})
                launcher.signal_owned_session(owner.pid, signal.SIGTERM, str(bad_ps), cache)
                owner.wait(2)
                self.assertIsNone(foreign.poll(), 'stale cached group killed another session')

    def test_daemon_cli_rejects_invalid_ports(self):
        for port in ('-1', '65536', 'abc'):
            result = subprocess.run([str(ROOT/'build/bin/isonim-review'), 'serve', '--port', port],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn('--port', result.stderr)


if __name__ == '__main__': unittest.main()
