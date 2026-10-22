"""Real CLI/socket/Repro producer tests for optional runtime preparation.

No process, filesystem, HTTP client or Repro calls are mocked. A temporary public
producer builds a deliberately limited HTTP health peer, rather than modifying
private Harbor sources or invoking a model. Its filesystem barrier holds the
actual producer action at a known cold boundary; it is latency injection, not a
replacement for preparation, ownership or admission. Real Harbor REST/provider
behavior remains covered by the official scenario native and full GUI suites.
Producer interfaces are first materialized through the actual CLI; their output
executable is then removed and the action barrier reset. Thus compiler/tool
prerequisites are separate from the bounded held-action assertions. Cold HTTP
readiness and responsiveness are also checked during that real materialization.
The handoff control pauses only its owned daemon with SIGSTOP and modifies the
actual private result file before admission; no metadata/process API is replaced.
Control snapshots here are explicit protocol fixtures for authority/registry
continuity; mounted editor catalog behavior is covered in the GUI suite.
"""
import concurrent.futures
import http.client
import json
import os
from pathlib import Path
import queue
import signal
import socket
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get('ISONIM_TEST_CLI', str(ROOT / 'build/bin/isonim')))


def request(port, path, data=None, token='', timeout=2):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=timeout)
    try:
        headers = {'Content-Type': 'application/json', 'X-IsoNim-Control': token}
        conn.request('GET' if data is None else 'POST', path,
                     None if data is None else json.dumps(data), headers)
        response = conn.getresponse()
        return response.status, json.loads(response.read())
    finally:
        conn.close()


def wait_for(predicate, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError('bounded real-process condition did not become true')


def process_exited(pid):
    state=subprocess.run(['ps','-o','stat=','-p',str(pid)],capture_output=True,text=True).stdout.strip()
    # Session-leader/process-group suffixes (e.g. Zs, Z+) still mean a zombie:
    # the owning parent must reap it when invalidating this completed generation.
    return state == '' or state.startswith('Z')


class Preparation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # One private fixture source path keeps the real Repro compiler interface
        # prerequisite stable across serial cases. Every case removes the built
        # executable and resets the producer action barrier independently.
        cls.temp = tempfile.TemporaryDirectory(prefix='isonim-runtime-readiness-')

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.root = Path(self.temp.name)
        self.repo = self.root / 'agent-harbor'
        self.repo.mkdir(exist_ok=True)
        for path in ['release','fail','starts','producer-port','runtime-port','runtime-pid','runtime-state','build/bin/ah']:
            (self.repo/path).unlink(missing_ok=True)
        (self.repo / 'Cargo.toml').write_text('# discovery marker\n')
        (self.repo / 'repro.nim').write_text('''import repro_project_dsl
import repro_dsl_stdlib/packages/python3
import repro_dsl_stdlib/packages/sh
package testHarbor:
  defaultToolProvisioning "path"
  uses:
    "python3 >=3.9"
    "sh"
  executable ah:
    name: "ah"
  build:
    discard shell(command = "python3 build.py", extraInputs = @["build.py", "peer.py"],
      extraOutputs = @["build/bin/ah"], cacheable = false)
''')
        (self.repo / 'build.py').write_text('''import json,os,pathlib,shutil,socket,time
root=pathlib.Path.cwd()
socket_=socket.socket();socket_.bind(('127.0.0.1',0));socket_.listen()
(root/'producer-port').write_text(str(socket_.getsockname()[1]))
with (root/'starts').open('a') as f:f.write(str(os.getpid())+'\\n')
(root/'authority.json').write_text(json.dumps({k:k in os.environ for k in ['ISONIM_EDITOR_BROWSER_BOOTSTRAP','ISONIM_INTERNAL_HARBOR_EPOCH']}))
while not (root/'release').exists():time.sleep(.02)
if (root/'fail').exists():raise SystemExit(19)
(root/'build/bin').mkdir(parents=True,exist_ok=True)
shutil.copyfile(root/'peer.py',root/'build/bin/ah');(root/'build/bin/ah').chmod(0o700)
''')
        (self.repo / 'peer.py').write_text('''#!/usr/bin/env python3
import http.server,json,os,pathlib,sys
if sys.argv[1:]==['--version']:
 print('ah readiness fixture 1.0.0');raise SystemExit(0)
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200);self.end_headers();self.wfile.write(b'{"ok":true}')
 def log_message(self,*args):pass
port=int(sys.argv[sys.argv.index('--rest-port')+1])
server=http.server.HTTPServer(('127.0.0.1',port),Handler)
root=pathlib.Path(__file__).resolve().parents[2]
root.joinpath('runtime-port').write_text(str(port))
root.joinpath('runtime-pid').write_text(str(os.getpid()))
root.joinpath('runtime-state').write_text(str(pathlib.Path(os.environ['AH_DAEMON_DB_PATH']).parent))
server.serve_forever()
''')
        self.environ = dict(os.environ)
        for key in ['ISONIM_ACP_AGENT_CMD', 'ISONIM_HARBOR_URL', 'ISONIM_LOCAL_HARBOR',
                    'ISONIM_AGENT_BACKEND', 'ISONIM_AGENT_COMMAND']:
            self.environ.pop(key, None)
        self.environ['ISONIM_AGENT_HARBOR_SIBLING'] = str(self.repo)
        # The editor keeps its Reprobuild consumer in the user cache. Keep this
        # fixture's consumer inside the temporary root so it is removed with it.
        self.environ['XDG_CACHE_HOME'] = str(self.root / 'cache')
        if self._testMethodName == 'test_cold_prepare_singleflight_responsive_scope_recheck_and_post_ready_retry':
            alias = self.root / 'linked-agent-harbor'
            if not alias.exists(): alias.symlink_to(self.repo, target_is_directory=True)
            self.assertEqual(alias.resolve(), self.repo)
            self.environ['ISONIM_AGENT_HARBOR_SIBLING'] = str(alias)
        self.environ['ISONIM_EDITOR_BROWSER_BOOTSTRAP'] = 'test-browser-authority'
        self.environ['ISONIM_REVIEW_PORT'] = '0'
        self.config = self.root / 'review.toml'
        self.config.write_text('[store]\npath = ' + json.dumps(str(self.root / 'store')) + '\n')
        self.daemons = []
        self.addCleanup(self.stop_all)
        if self._testMethodName != 'test_explicit_url_only_selects_rest_backend_without_local_helper':
            (self.repo/'release').touch()
            warm,port=self.start()
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pending=pool.submit(request,port,'/api/agent/sessions',{},'',300)
                deadline=time.monotonic()+300
                while not pending.done():
                    self.assertLess(time.monotonic(),deadline,'owning producer prerequisite failed to finish')
                    started=time.monotonic()
                    status,health=request(port,'/health',timeout=1)
                    self.assertEqual(status,503) # Agent-only fixture deliberately has no PG.
                    self.assertFalse(health['postgres_reachable'])
                    self.assertFalse(health['schema_version_current'])
                    self.assertLess(time.monotonic()-started,1)
                    time.sleep(.1)
                status,session=pending.result()
                self.assertEqual(status,200,repr(session)+' '+repr([line[:500] for line in warm._diagnostics if 'Error:' in line or 'failed' in line][-12:]))
                self.assertEqual(session['backend'],'harbor')
                self.assertEqual(request(port,'/api/agent/close',{'sessionId':session['sessionId']})[0],200)
                # The consumer landed in the redirected cache, not the user's.
                self.assertTrue(any((self.root/'cache/isonim/harbor-consumer').iterdir()))
            self.stop_all()
            self.daemons.clear()
            for path in ['release','starts','producer-port','runtime-port','runtime-pid','runtime-state','build/bin/ah']:
                (self.repo/path).unlink(missing_ok=True)

    def start(self, environ=None):
        process = subprocess.Popen([str(CLI), 'serve', '--agent-routes-only', '--config', str(self.config)],
                                   env=environ or self.environ, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.PIPE, text=True)
        self.daemons.append(process)
        lines = queue.Queue()
        process._diagnostics = []
        def drain():
            for line in process.stderr:
                process._diagnostics.append(line.rstrip("\n"))
                lines.put(line.rstrip('\n'))
        reader = threading.Thread(target=drain)
        reader.start()
        process._reader = reader
        start = time.monotonic()
        while time.monotonic() - start < 15:
            try:
                line = lines.get(timeout=.1)
            except queue.Empty:
                if process.poll() is not None:
                    self.fail('CLI exited before readiness')
                continue
            if line.startswith('READY ') and line[6:].isdigit() and 1 <= int(line[6:]) <= 65535:
                return process, int(line[6:])
        self.fail('CLI failed unchanged 15 second readiness deadline')

    def stop_all(self):
        for process in self.daemons:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                    raise AssertionError('owned preparation did not stop within 15 seconds')
            process._reader.join(timeout=1)
            self.assertFalse(process._reader.is_alive())
            process.stderr.close()

    def rpc(self, port, method, params, token):
        status, reply = request(port, '/api/editor/rpc', {'jsonrpc':'2.0', 'id':1,
                               'method':method, 'params':params}, token)
        self.assertEqual(status, 200)
        return reply

    def helper(self, daemon):
        output = subprocess.check_output(['ps', '-e', '-o', 'pid=', '-o', 'ppid=', '-o', 'args='], text=True)
        matches = []
        for line in output.splitlines():
            fields = line.split(None, 2)
            if len(fields) == 3 and int(fields[1]) == daemon.pid and '--internal-harbor-runtime' in fields[2]:
                matches.append((int(fields[0]), fields[2].split()[-1]))
        self.assertEqual(len(matches), 1)
        return matches[0]

    def assert_responsive(self, port, scope):
        for path, data, token in [('/health', None, ''), ('/api/editor/rpc',
                {'jsonrpc':'2.0','id':2,'method':'editor.stories','params':scope}, scope['controlToken'])]:
            start = time.monotonic()
            status, reply = request(port, path, data, token, timeout=1)
            self.assertEqual(status,200 if data else 503)
            self.assertLess(time.monotonic() - start, 1)
            if not data:
                self.assertFalse(reply['postgres_reachable'])
                self.assertFalse(reply['schema_version_current'])
            if data:
                self.assertEqual(reply['result'], [{'name':'Current story'}])

    def test_ready_handoff_rejects_escaping_and_prefix_lookalike_executable_aliases(self):
        for outside_directory in [self.root / 'installed', self.repo.with_name('agent-harbor-installed')]:
            outside_directory.mkdir(exist_ok=True)
            outside = outside_directory / 'ah'
            outside.write_text('#!/bin/sh\nprintf "outside source\\n"\n')
            outside.chmod(0o700)
            for path in ['release', 'producer-port', 'runtime-pid']:
                (self.repo / path).unlink(missing_ok=True)
            daemon, port = self.start()
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pending = pool.submit(request, port, '/api/agent/sessions', {}, '', 120)
                wait_for(lambda: (self.repo / 'producer-port').exists(), 90)
                helper_pid, directory = self.helper(daemon)
                metadata = Path(directory) / 'ready.json'
                os.kill(daemon.pid, signal.SIGSTOP)
                try:
                    (self.repo / 'release').touch()
                    wait_for(metadata.exists, 90)
                    original = json.loads(metadata.read_text())
                    self.assertEqual(original['pid'], helper_pid)
                    self.assertEqual(Path(original['executable']).resolve(), (self.repo / 'build/bin/ah').resolve())
                    self.assertEqual(metadata.stat().st_mode & 0o777, 0o600)
                    alias = self.repo / 'build/bin/handoff-alias'
                    alias.unlink(missing_ok=True)
                    alias.symlink_to(outside)
                    self.assertEqual(alias.resolve(), outside)
                    # Preserve the real generation authority and private-file
                    # metadata; only the producer identity claim is poisoned.
                    poisoned = {**original, 'executable': str(alias)}
                    metadata.write_text(json.dumps(poisoned))
                    self.assertEqual(metadata.stat().st_nlink, 1)
                    self.assertEqual(metadata.stat().st_mode & 0o777, 0o600)
                finally:
                    os.kill(daemon.pid, signal.SIGCONT)
                status, result = pending.result()
                self.assertEqual(status, 500)
                self.assertEqual(result['error'], 'agent_init_failed')
                self.assertEqual(result['reason'], 'Unexpected local Harbor executable')
                wait_for(lambda: process_exited(helper_pid), 15)
            self.stop_all()
            self.daemons.clear()

    def test_cold_prepare_singleflight_responsive_scope_recheck_and_post_ready_retry(self):
        daemon, port = self.start()
        self.assertFalse((self.repo / 'starts').exists())
        status, _ = request(port, '/api/agent/sessions', {'editor':{'instance':'missing'}})
        self.assertEqual(status, 403)
        self.assertFalse((self.repo / 'starts').exists())
        scope = self.rpc(port, 'editor.register', {'workspace':'fixture-workspace',
            'state':{'revision':1,'stories':[{'name':'Current story'}]}}, 'test-browser-authority')['result']
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            scoped = pool.submit(request, port, '/api/agent/sessions', {'editor':scope}, scope['browserToken'], 120)
            unscoped = pool.submit(request, port, '/api/agent/sessions', {}, '', 120)
            last_poll=[0]
            def producer_started():
                if time.monotonic()-last_poll[0]>1:
                    self.assertIn('result',self.rpc(port,'editor.poll',scope,scope['browserToken']))
                    self.assert_responsive(port,scope)
                    last_poll[0]=time.monotonic()
                if (self.repo / 'producer-port').exists():return True
                for pending in [scoped,unscoped]:
                    if pending.done():self.fail('session returned before producer barrier: '+repr(pending.result())+' diagnostics: '+repr([line[:500] for line in daemon._diagnostics if 'Error:' in line or 'failed' in line][-12:]))
                return False
            wait_for(producer_started, 90)
            helper_pid, directory = self.helper(daemon)
            self.assertEqual(Path(directory).stat().st_mode & 0o777, 0o700)
            for _ in range(4):
                self.assert_responsive(port, scope)
            self.assertEqual(len((self.repo / 'starts').read_text().splitlines()), 1)
            self.assertEqual(json.loads((self.repo / 'authority.json').read_text()),
                             {'ISONIM_EDITOR_BROWSER_BOOTSTRAP':False,'ISONIM_INTERNAL_HARBOR_EPOCH':False})
            aborted = socket.create_connection(('127.0.0.1',port),timeout=1)
            aborted.sendall(b'POST /api/agent/sessions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}')
            # The production handler emits this safe lifecycle diagnostic only
            # after validating admission and before awaiting shared preparation.
            # The two earlier requests are already waiting; the third record
            # proves this exact additional connection reached that boundary.
            wait_for(lambda: sum('agent session waiting for backend preparation' in line
                for line in daemon._diagnostics)==3,2)
            self.assert_responsive(port,scope)
            aborted.shutdown(socket.SHUT_RDWR)
            aborted.close()
            self.assertTrue(self.rpc(port,'editor.disconnect',scope,scope['browserToken'])['result']['disconnected'])
            (self.repo / 'release').touch()
            self.assertEqual(scoped.result()[0], 403)
            status, first = unscoped.result()
            self.assertEqual(status,200)
            self.assertEqual(first['backend'],'harbor')
            self.assertEqual(first['sessionState'],'draft')
            metadata = Path(directory) / 'ready.json'
            self.assertEqual(metadata.stat().st_mode & 0o777,0o600)
            result = json.loads(metadata.read_text())
            self.assertEqual(result['pid'],helper_pid)
            self.assertEqual(Path(result['executable']).resolve(),(self.repo/'build/bin/ah').resolve())
            os.kill(helper_pid,signal.SIGTERM)
            wait_for(lambda:process_exited(helper_pid),15)
            # Kill/retry preserves an existing draft's identity and only admits a
            # new session against the new owned runtime generation.
            status, second = request(port,'/api/agent/sessions',{},timeout=120)
            self.assertEqual(status,200)
            self.assertEqual(second['backend'],'harbor')
            self.assertNotEqual(first['sessionId'],second['sessionId'])
            self.assertEqual(len((self.repo/'starts').read_text().splitlines()),2)
            second_helper=self.helper(daemon)[0]
            self.assertNotEqual(second_helper,helper_pid)
            self.assertFalse(Path(directory).exists())
            service_pid=int((self.repo/'runtime-pid').read_text())
            self.assertEqual(os.getsid(service_pid),second_helper)
            state_directory=Path((self.repo/'runtime-state').read_text())
            self.assertEqual(state_directory.stat().st_mode & 0o777,0o700)
            os.kill(service_pid,signal.SIGTERM)
            wait_for(lambda:process_exited(second_helper),15)
            status,third=request(port,'/api/agent/sessions',{},timeout=120)
            self.assertEqual(status,200)
            self.assertEqual(third['backend'],'harbor')
            self.assertEqual(len((self.repo/'starts').read_text().splitlines()),3)
            self.assertNotEqual(self.helper(daemon)[0],second_helper)
            self.assertEqual(len({s['sessionId'] for s in [first,second,third]}),3)
            for session in [first,second,third]:
                self.assertEqual(request(port,'/api/agent/close',{'sessionId':session['sessionId']})[0],200)
            daemon.terminate()
            self.assertEqual(daemon.wait(timeout=15),0)
            daemon._reader.join(timeout=1)
            shutdowns=[line for line in daemon._diagnostics if 'agent client shutdown begin' in line]
            self.assertEqual(len(shutdowns),3, 'aborted admission created an orphan or unnecessary session')
            for session in [first,second,third]:
                self.assertEqual(sum(session['sessionId'] in line for line in shutdowns),1)

    def test_shutdown_cancels_real_blocked_producer_and_reclaims_its_listener(self):
        daemon,port = self.start()
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            pending=pool.submit(request,port,'/api/agent/sessions',{},'',120)
            wait_for(lambda:(self.repo/'producer-port').exists(),90)
            _,directory=self.helper(daemon)
            producer_port=int((self.repo/'producer-port').read_text())
            daemon.terminate()
            self.assertEqual(daemon.wait(timeout=15),0)
            self.assertFalse(Path(directory).exists())
            with self.assertRaises(OSError):
                conn=http.client.HTTPConnection('127.0.0.1',producer_port,timeout=1)
                try:conn.connect()
                finally:conn.close()
            try:pending.result()
            except (OSError,http.client.HTTPException):pass

    def test_failed_generation_can_retry_without_blocking_health(self):
        daemon,port=self.start()
        (self.repo/'fail').touch();(self.repo/'release').touch()
        status,reply=request(port,'/api/agent/sessions',{},timeout=120)
        self.assertEqual(status,503)
        health_status,health=request(port,'/health')
        self.assertEqual(health_status,503)
        self.assertFalse(health['postgres_reachable'])
        (self.repo/'fail').unlink()
        status,reply=request(port,'/api/agent/sessions',{},timeout=120)
        self.assertEqual(status,200)
        self.assertEqual(reply['backend'],'harbor')
        self.assertEqual(request(port,'/api/agent/close',{'sessionId':reply['sessionId']})[0],200)

    def test_explicit_url_only_selects_rest_backend_without_local_helper(self):
        environ=dict(self.environ)
        environ['ISONIM_HARBOR_URL']='http://127.0.0.1:1'
        environ['ISONIM_AGENT_HARBOR_SIBLING']=str(self.root/'invalid-sibling')
        daemon,port=self.start(environ)
        status,reply=request(port,'/api/agent/sessions',{})
        self.assertEqual(status,200)
        self.assertEqual(reply['backend'],'harbor')
        self.assertEqual(reply['sessionState'],'draft')
        self.assertFalse((self.repo/'starts').exists())
        self.assertEqual(request(port,'/api/agent/close',{'sessionId':reply['sessionId']})[0],200)


if __name__ == '__main__':
    unittest.main(verbosity=2)
