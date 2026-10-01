"""Production editor -> nim-agents -> sibling Harbor REST acceptance.

Only the model provider is substituted: Harbor's official scenario playback
scripts agent responses deterministically. HTTP, editor routes, producer build,
SQLite, filesystem and provider processes are real. This is a narrow native
route acceptance test; the larger ViewModel/GUI campaign has separate coverage.
Absence of the optional private sibling is the only automatic skip. When present,
ISONIM_HARBOR_SCENARIO_PROVIDER must name its already-built official mock-agent.
POSIX native PID/starttime/argv/executable checks prove continuity. Linux also
requires kernel start ticks and the provider's exact NSpid namespace mapping.
Execution inputs live in the bound project because supported isolation hides
host temporary/cache directories. The official provider is copied byte-for-byte
and both that copy and the actual executed process are checked against its
source SHA; no provider decisions or protocol behavior are replaced.
"""
import hashlib
import http.client
import json
import os
from pathlib import Path
import queue
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from helpers.editor_process_observer import process_observer, optional_sibling_available

ROOT = Path(__file__).resolve().parents[1]
HARBOR = ROOT.parent / 'agent-harbor'
SCENARIO = ROOT / 'tests/scenarios/agent-harbor/editor-session-continuity.yaml'
FIRST = 'Remember the token ISONIM_CONTEXT_7309 for this conversation. Reply only with that token.'
SECOND = ('What token did I ask you to remember? Reply with that token and the instruction sentinel '
          'from your system instructions. Do not read files or use tools.')


OBSERVER = None


def processes():
    return OBSERVER.snapshot()


def descendants(table, root):
    found = {root}
    while True:
        added = {pid for pid, info in table.items() if info[0] in found} - found
        if not added:
            return found
        found.update(added)


class EditorHarborScenario(unittest.TestCase):
    def test_production_routes_keep_isolated_provider_sessions_alive_until_close(self):
        global OBSERVER
        if not optional_sibling_available(HARBOR):
            self.skipTest('optional private Agent Harbor sibling absent')
        OBSERVER = process_observer()
        provider_source = Path(os.environ.get('ISONIM_HARBOR_SCENARIO_PROVIDER', '/missing-provider')).resolve()
        self.assertTrue(provider_source.is_file() and os.access(provider_source, os.X_OK),
                        'Set ISONIM_HARBOR_SCENARIO_PROVIDER to the built official Harbor mock-agent')
        daemon = ROOT / 'build/bin/isonim-review'
        self.assertTrue(daemon.is_file(), 'Build with just isonim-review-build')
        artifacts = Path(tempfile.mkdtemp(prefix='isonim-editor-harbor-scenario-')).resolve()
        print('Acceptance artifacts:', artifacts, flush=True)
        self.artifacts = artifacts
        workspace = artifacts / 'workspace'
        workspace.mkdir()
        fixture = workspace / '.scenario'
        fixture.mkdir(mode=0o700)
        provider = fixture / 'mock-agent'
        shutil.copyfile(provider_source, provider)
        provider.chmod(0o755)
        provider_sha = hashlib.sha256(provider_source.read_bytes()).hexdigest()
        self.assertEqual(hashlib.sha256(provider.read_bytes()).hexdigest(), provider_sha,
                         'The sandbox-visible provider must be the exact official build')
        (workspace / 'isonim.nimble').write_text('# actual isolated project boundary\n')
        config = artifacts / 'empty.toml'
        config.write_text('')  # Defaults: no explicit backend, command or endpoint.
        bindir = fixture / 'bin'
        bindir.mkdir()
        scenario_paths = []
        for index in range(2):
            scenario = fixture / f'chat{index}.yaml'
            scenario.write_text(SCENARIO.read_text().replace('ISONIM_CONTEXT_7309', f'ISONIM_CONTEXT_7309_{index}')
                                .replace('isonim-persistent-session', f'isonim-persistent-session-{index}'))
            scenario_paths.append(str(scenario))
        chooser = fixture / 'choose_scenario.py'
        chooser.write_text('''import fcntl, json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
provider = sys.argv[2]
scenarios = json.loads(sys.argv[3])
with (root / 'provider-counter').open('a+') as counter:
    fcntl.flock(counter, fcntl.LOCK_EX)
    counter.seek(0)
    index = int(counter.read() or '0')
    if index >= len(scenarios):
        raise RuntimeError('Unexpected additional provider process launch')
    counter.seek(0)
    counter.truncate()
    counter.write(str(index + 1))
    counter.flush()
    (root / ('provider-launch-%s.json' % index)).write_text(json.dumps(
        {'pid': os.getpid(), 'scenario': scenarios[index]}))
os.environ['MOCK_AGENT_PROMPT_TRACE'] = str(root / ('provider-prompts-%s.jsonl' % index))
os.environ.pop('MOCK_AGENT_EXPECT_PROMPT_CONTAINS', None)
os.environ.pop('MOCK_AGENT_PROMPT_LOG', None)
os.execv(provider, [provider, '--scenario', scenarios[index], '--disable-follower'])
''')
        wrapper = bindir / 'claude-agent-acp'
        wrapper.write_text('#!/bin/sh\nexec ' + shlex.join([sys.executable, str(chooser), str(fixture),
                                                          str(provider), json.dumps(scenario_paths)]) + '\n')
        wrapper.chmod(0o755)
        env = dict(os.environ)
        # Exercise default sibling discovery, independent of operator overrides.
        for key in list(env):
            if key.startswith('ISONIM_') or key.startswith('FAKE_ACP_'):
                del env[key]
        env['PATH'] = str(bindir) + os.pathsep + env['PATH']
        inherited = artifacts / 'parent.sqlite'
        inherited.write_text('parent state must remain untouched')
        env['AH_DAEMON_DB_PATH'] = str(inherited)
        identities = {}
        for repo in (ROOT, HARBOR, ROOT.parent / 'nim-agents', ROOT.parent / 'nim-agent-harbor'):
            identities[repo.name] = {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
                                    'diff_sha256': hashlib.sha256(subprocess.check_output(['git', 'diff', 'HEAD'], cwd=repo)).hexdigest()}
        identities['daemon_sha256'] = hashlib.sha256(daemon.read_bytes()).hexdigest()
        identities['provider_sha256'] = hashlib.sha256(provider.read_bytes()).hexdigest()
        identities['provider_source_sha256'] = provider_sha
        identities['provider_source'] = str(provider_source)
        identities['provider_executed_path'] = str(provider)
        identities['scenario_sha256'] = hashlib.sha256(SCENARIO.read_bytes()).hexdigest()
        identities['acceptance_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        identities['observer_sha256'] = hashlib.sha256((ROOT / 'tests/helpers/editor_process_observer.py').read_bytes()).hexdigest()
        identities['observer_tests_sha256'] = hashlib.sha256((ROOT / 'tests/test_editor_process_observer.py').read_bytes()).hexdigest()
        identities['python_version'] = sys.version
        identities['platform'] = sys.platform
        identities['starttime_kind'] = OBSERVER.starttime_kind
        (artifacts / 'identities.json').write_text(json.dumps(identities, indent=2))
        lines = queue.Queue()
        log = (artifacts / 'daemon.log').open('w')
        child = subprocess.Popen([str(daemon), 'serve', '--agent-routes-only', '--config', str(config),
                                  '--bind', '127.0.0.1', '--port', '0', '--workspace', str(workspace),
                                  '--default-assistant-prompt', str(ROOT / 'prompts/ai-assistant.md')],
                                 cwd=workspace, env=env, stdout=log, stderr=subprocess.PIPE, text=True,
                                 start_new_session=True)
        def drain():
            for line in child.stderr:
                log.write(line)
                log.flush()
                lines.put(line)
        reader = threading.Thread(target=drain, daemon=True)
        reader.start()
        workers = {}
        try:
            harbor_url = None
            base = None
            deadline = time.monotonic() + 900
            while time.monotonic() < deadline:
                self.assertIsNone(child.poll(), 'daemon exited; inspect daemon.log')
                try:
                    line = lines.get(timeout=.2)
                except queue.Empty:
                    continue
                match = re.search(r'IsoNim: using (.+) via REST at (http://127\.0\.0\.1:\d+)', line)
                if match:
                    executable = Path(match[1]).resolve()
                    self.assertTrue(executable.is_relative_to(HARBOR.resolve()), 'must use this workspace producer export')
                    exported = (HARBOR / '.repro/isonim-runtime/harbor-executable').read_text().strip()
                    self.assertEqual(executable, Path(exported).resolve())
                    harbor_url = match[2]
                match = re.match(r'READY (\d+)\s*$', line)
                if match:
                    base = 'http://127.0.0.1:' + match[1]
                    break
            self.assertIsNotNone(base, 'bounded daemon readiness failed')
            self.assertIsNotNone(harbor_url, 'automatic local producer REST selection was not used')
            self.base = base
            self.harbor_url = harbor_url
            owned = processes()
            services = [owned[pid][2] for pid in descendants(owned, child.pid) if pid in owned
                        and owned[pid][2] and owned[pid][2][0] == str(executable)
                        and '--rest-port' in owned[pid][2] and '--pid-file' in owned[pid][2]]
            self.assertEqual(len(services), 1, 'exactly one owned Harbor service')
            state_dir = Path(services[0][services[0].index('--pid-file') + 1]).parent
            self.assertNotEqual(state_dir, inherited.parent)
            self.assertTrue((state_dir / 'daemon.sqlite').read_bytes().startswith(b'SQLite format 3\0'))
            (artifacts / 'owned-state.txt').write_text(str(state_dir) + '\n')
            self.assertEqual(self.sessions(), [])
            drafts = [self.post('/api/agent/sessions', {'cwd': str(workspace)}) for _ in range(2)]
            self.assertNotEqual(drafts[0]['sessionId'], drafts[1]['sessionId'])
            for draft in drafts:
                self.assertEqual(draft['sessionState'], 'draft')
                self.assertEqual(draft['backendSessionId'], '')
                self.assertEqual(draft['sessionCapabilities'], {'persistent': True, 'cancelTurn': False, 'closeSession': True})
            self.assertEqual(self.sessions(), [], 'draft creation must not launch provider')
            backend_ids = []
            chat_workers = []
            for index, draft in enumerate(drafts):
                before = set(workers)
                token = f'ISONIM_CONTEXT_7309_{index}'
                event_ids = self.turn(draft['sessionId'], FIRST.replace('ISONIM_CONTEXT_7309', token), token, f'chat{index}-first')
                sessions = self.sessions()
                self.assertEqual(len(sessions), index + 1)
                new = {s['id'] for s in sessions} - set(backend_ids)
                self.assertEqual(len(new), 1)
                backend_ids.append(new.pop())
                self.assertEqual(event_ids, {backend_ids[index]}, 'first stream must identify its real backend')
                self.assertEqual({s['status'] for s in sessions}, {'paused'}, 'turn end is idle, never session completion')
                table = processes()
                owned = descendants(table, child.pid)
                candidates = {pid: table[pid] for pid in owned if pid in table and table[pid][2]
                              and table[pid][2][0] == str(provider)}
                self.assertEqual(len(set(candidates) - before), 1, 'each chat needs its own actual playback process')
                chat_workers.append(next(iter(set(candidates) - before)))
                launched = json.loads((fixture / f'provider-launch-{index}.json').read_text())
                # Harbor may isolate the provider in a PID namespace. Ground
                # its exec-before-playback PID in our proc mount's kernel mapping.
                if sys.platform == 'linux':
                    namespace_lines = [line for line in Path(f'/proc/{chat_workers[index]}/status').read_text().splitlines()
                                       if line.startswith('NSpid:')]
                    self.assertEqual(len(namespace_lines), 1)
                    namespace_pids = [int(value) for value in namespace_lines[0].split()[1:]]
                    self.assertEqual(namespace_pids[0], chat_workers[index])
                    provider_pid = namespace_pids[-1]
                else:
                    namespace_pids = None  # Darwin has no Linux NSpid surface.
                    provider_pid = chat_workers[index]
                self.assertEqual(launched, {'pid': provider_pid, 'scenario': scenario_paths[index]})
                self.assertEqual(Path(candidates[chat_workers[index]][3]).resolve(), provider)
                actual_executable = (Path(f'/proc/{chat_workers[index]}/exe')
                                     if sys.platform == 'linux'
                                     else Path(candidates[chat_workers[index]][3]))
                loaded_sha = hashlib.sha256(actual_executable.read_bytes()).hexdigest()
                self.assertEqual(loaded_sha, provider_sha,
                                 'Actual running provider must load the exact official bytes')
                (artifacts / f'provider-identity-{index}.json').write_text(json.dumps(
                    {'backend_id': backend_ids[index], 'observer_pid': chat_workers[index],
                     'starttime': candidates[chat_workers[index]][1], 'starttime_kind': OBSERVER.starttime_kind,
                     'executable': candidates[chat_workers[index]][3], 'executable_sha256': loaded_sha,
                     'provider_source_sha256': provider_sha, 'namespace_pids': namespace_pids,
                     'scenario': scenario_paths[index]}, indent=2))
                self.assertIn(scenario_paths[index], candidates[chat_workers[index]][2])
                workers.update(candidates)
                self.observe_idle_workers(workers)
                self.assertEqual(self.post('/api/agent/cancel', {'sessionId': draft['sessionId']}, 409)['error'],
                                 'unsupported_capability')
                self.assert_workers(workers)
            (artifacts / 'workers.json').write_text(json.dumps(workers, indent=2))
            # Reuse conversation handles in reverse order: no backend restart.
            for index in (1, 0):
                self.assert_workers(workers)
                event_ids = self.turn(drafts[index]['sessionId'], SECOND, f'ISONIM_CONTEXT_7309_{index}', f'chat{index}-second')
                self.assertEqual(event_ids, {backend_ids[index]}, 'followup must reach this same backend session')
                self.assertEqual({s['id'] for s in self.sessions()}, set(backend_ids))
                self.observe_idle_workers(workers)
                trace = [json.loads(line) for line in (fixture / f'provider-prompts-{index}.jsonl').read_text().splitlines()]
                self.assertEqual(trace, [FIRST.replace('ISONIM_CONTEXT_7309', f'ISONIM_CONTEXT_7309_{index}'), SECOND],
                                 'exactly two actual provider requests in this conversation, without a hidden primer')
                # Accepted/acknowledged delivery can reach the provider before
                # canonical history projection. Harbor's production recovery
                # worker finalizes these records on its five-second cadence.
                # Observe the real API until exact cardinality is visible;
                # missing/lost projection still fails after this bounded wait.
                history_started = time.monotonic()
                deadline = history_started + 15
                observations = artifacts / f'chat{index}-history-observations.jsonl'
                while True:
                    try:
                        with urllib.request.urlopen(self.harbor_url + '/api/v1/sessions/' + backend_ids[index] +
                                                    '/events/history?limit=200',
                                                    timeout=min(10, max(.1, deadline - time.monotonic()))) as response:
                            history = json.load(response)
                    except Exception as error:
                        with observations.open('a') as observation_log:
                            observation_log.write(json.dumps({'elapsed_seconds': time.monotonic() - history_started,
                                                              'error': str(error)}) + '\n')
                        raise
                    with observations.open('a') as observation_log:
                        observation_log.write(json.dumps({'elapsed_seconds': time.monotonic() - history_started,
                                                          'history': history}) + '\n')
                    self.assert_workers(workers)
                    self.assertFalse(any(event['type'] == 'log' and event.get('message') == 'user: ' + SECOND
                                         for event in history['events']), 'followup cannot remain an ambiguous assistant log')
                    inputs = [event['content'] for event in reversed(history['events']) if event['type'] == 'user_input']
                    if len(inputs) >= len(trace) or time.monotonic() >= deadline:
                        break
                    time.sleep(.1)
                (artifacts / f'chat{index}-history.json').write_text(json.dumps(history, indent=2))
                self.assertFalse(history['has_more'], 'focused history must include all actual turns')
                self.assertEqual(history['total_count'], len(history['events']))
                self.assertEqual(inputs, trace, 'actual initial/followup input must have structured human authorship')
            # Close one actual conversation; the other must still be alive.
            self.assertEqual(self.post('/api/agent/close', {'sessionId': drafts[0]['sessionId']}), {'closed': True})
            remaining = self.wait_workers(workers, expected=1)
            self.assertEqual(set(remaining), {chat_workers[1]}, 'close must reap only the selected chat provider')
            self.assert_workers(remaining)
            self.assertEqual(self.post('/api/agent/prompts', {'sessionId': drafts[0]['sessionId'], 'text': FIRST}, 404)['error'], 'unknown_session')
            self.assertEqual(self.post('/api/agent/close', {'sessionId': drafts[1]['sessionId']}), {'closed': True})
            self.assertEqual(self.wait_workers(workers, expected=0), {})
            self.assertEqual(inherited.read_text(), 'parent state must remain untouched')
        finally:
            if child.poll() is None:
                child.send_signal(signal.SIGTERM)
                try:
                    child.wait(timeout=90)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)
                    self.fail('owned daemon shutdown exceeded its normal deadline')
            reader.join(timeout=5)
            child.stderr.close()
            log.close()
        self.assertEqual(child.returncode, 0, 'normal owned shutdown must succeed')
        self.assertEqual(inherited.read_text(), 'parent state must remain untouched')
        (artifacts / 'PASS').write_text('production editor routes: two drafts, two isolated persistent REST sessions, same workers/starttimes, explicit closure and normal shutdown\n')

    def post(self, path, payload, expected=200):
        request = urllib.request.Request(self.base + path, json.dumps(payload).encode(),
                                         {'Content-Type': 'application/json'})
        try:
            response = urllib.request.urlopen(request, timeout=60)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            body = response.read().decode()
            self.assertEqual(response.code, expected, body)
            return json.loads(body)

    def sessions(self):
        with urllib.request.urlopen(self.harbor_url + '/api/v1/sessions', timeout=10) as response:
            payload = json.load(response)
        self.assertIsInstance(payload['items'], list)
        self.assertEqual(payload['total'], len(payload['items']))
        return payload['items']

    def turn(self, draft, text, expected, name):
        host, port = self.base.removeprefix('http://').split(':')
        client = http.client.HTTPConnection(host, int(port), timeout=60)
        try:
            client.request('POST', '/api/agent/prompts', json.dumps({'sessionId': draft, 'text': text}),
                           {'Content-Type': 'application/json'})
            response = client.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.getheader('Content-Type'), 'text/event-stream; charset=utf-8')
            raw = response.read().decode()
        finally:
            client.close()
        (self.artifacts / (name + '.sse')).write_text(raw)
        events = []
        for frame in raw.replace('\r\n', '\n').split('\n\n'):
            event = None
            data = []
            for line in frame.splitlines():
                if line.startswith('event: '): event = line[7:]
                if line.startswith('data: '): data.append(line[6:])
            if data: events.append((event, json.loads('\n'.join(data))))
        self.assertTrue(events, 'empty stream is not a successful turn')
        self.assertFalse(any(kind == 'error' for kind, _ in events), events)
        terminals = [value for kind, value in events if kind == 'end']
        self.assertEqual(terminals, [{'stopReason': 'end_turn'}])
        self.assertEqual(events[-1][0], 'end')
        updates = [value for kind, value in events if kind == 'session/update']
        self.assertTrue(updates, 'must deliver actual common events')
        self.assertEqual(expected, ''.join(value['text'] for value in updates if value['kind'] == 'message_chunk'),
                         'assistant reply must be exact, without duplicate or cross-chat chunks')
        return {value['sessionId'] for value in updates}

    def assert_workers(self, workers):
        table = processes()
        for pid, original in workers.items():
            self.assertIn(pid, table, 'provider exited at a normal turn boundary')
            self.assertEqual(table[pid][1], original[1], 'provider restarted/PID reused')
            self.assertEqual(table[pid][2], original[2])
            self.assertEqual(table[pid][3], original[3], 'provider executable identity changed')

    def observe_idle_workers(self, workers):
        # Observe beyond the HTTP turn boundary before another prompt or close.
        for _ in range(5):
            self.assert_workers(workers)
            time.sleep(.05)

    def wait_workers(self, workers, expected):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            table = processes()
            remaining = {pid: original for pid, original in workers.items()
                         if pid in table and table[pid][1] == original[1]}
            if len(remaining) == expected:
                return remaining
            time.sleep(.05)
        self.fail(f'provider closure failed: expected {expected}, still alive {list(remaining)}')


if __name__ == '__main__':
    unittest.main()
