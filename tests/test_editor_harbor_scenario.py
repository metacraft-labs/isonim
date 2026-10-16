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
import concurrent.futures
import http.client
import json
import os
from pathlib import Path
import queue
import re
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from helpers.editor_context_evidence import resolve_context, identity as context_identity
from helpers.editor_workspace_roles import source_role
import urllib.error
import urllib.request
from helpers.editor_process_observer import (
    process_observer, optional_sibling_available, capture_owned, reap_owned,
    require_exit,
)

ROOT = Path(__file__).resolve().parents[1]
HARBOR = source_role(ROOT, 'agent-harbor',
                      override=os.environ.get('ISONIM_AGENT_HARBOR_SIBLING'),
                      required=False)
SCENARIO = ROOT / 'tests/scenarios/agent-harbor/editor-session-continuity.yaml'
FIRST = 'Remember the token ISONIM_CONTEXT_7309 for this conversation. Reply only with that token.'
SECOND = ('What token did I ask you to remember? Reply with that token and the instruction sentinel '
          'from your system instructions. Do not read files or use tools.')


OBSERVER = None


class OwnedStderrReader(threading.Thread):
    """Keep actual iterator EOF separate from a reader that died on an error."""
    def __init__(self, stream, log, lines):
        super().__init__(daemon=True)
        self.stream, self.log, self.lines = stream, log, lines
        self.eof = False
        self.errors = []

    def run(self):
        try:
            for line in self.stream:
                self.log.write(line)
                self.log.flush()
                self.lines.put(line)
            self.eof = True
        except BaseException as error:
            self.errors.append(repr(error))


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
        self.exercise_production_routes()

    def test_parallel_native_shutdown_of_two_actual_backend_sessions(self):
        # A focused native-ownership gate, independent of provider continuity:
        # both actual REST conversations launch their first official scenario
        # turn, then the SAME loaded daemon shuts down with both still open.
        # The original persistent-session test above retains every assertion.
        self.exercise_production_routes(shutdown_only=True)

    def exercise_production_routes(self, shutdown_only=False):
        global OBSERVER
        if not optional_sibling_available(HARBOR):
            self.skipTest('optional private Agent Harbor sibling absent')
        OBSERVER = process_observer()
        provider_source = Path(os.environ.get('ISONIM_HARBOR_SCENARIO_PROVIDER', '/missing-provider')).resolve()
        self.assertTrue(provider_source.is_file() and os.access(provider_source, os.X_OK),
                        'Set ISONIM_HARBOR_SCENARIO_PROVIDER to the built official Harbor mock-agent')
        daemon = ROOT / 'build/bin/isonim-review'
        self.assertTrue(daemon.is_file(), 'Build with just isonim-review-build')
        artifact_parent=os.environ.get('ISONIM_SCENARIO_ARTIFACT_DIR')
        artifacts = Path(tempfile.mkdtemp(prefix='isonim-editor-harbor-scenario-', dir=artifact_parent)).resolve()
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
        (workspace / 'AGENTS.md').write_text('Current project guidance: first turn.\n')
        self.submitted_contexts = {}
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
        for repo in (ROOT, HARBOR, source_role(ROOT, 'nim-agents'),
                      source_role(ROOT, 'nim-agent-harbor')):
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
        reader = OwnedStderrReader(child.stderr, log, lines)
        reader.start()
        workers = {}
        cleanup_owned = capture_owned(processes(), [child.pid])
        try:
            harbor_url = None
            base = None
            deadline = time.monotonic() + 15
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
            self.base = base
            native = processes()[child.pid]
            self.assertEqual(native[2][0], str(daemon))
            loaded = Path(f'/proc/{child.pid}/exe') if sys.platform == 'linux' else Path(native[3])
            self.assertEqual(hashlib.sha256(loaded.read_bytes()).hexdigest(), identities['daemon_sha256'])
            (artifacts / 'native-loaded-identity.json').write_text(json.dumps({
                'pid': child.pid, 'starttime': native[1], 'starttime_kind': OBSERVER.starttime_kind,
                'kernelExecutable': native[3], 'loadedSha256': identities['daemon_sha256']}, indent=2))
            # HTTP is ready independently of the optional producer. Trigger its
            # actual owned preparation through the first validated session API.
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pending = pool.submit(self.post, '/api/agent/sessions', {'cwd':str(workspace)}, 200, 900)
                deadline = time.monotonic()+900 # Existing cold-producer bound.
                while not pending.done() or harbor_url is None:
                    self.assertLess(time.monotonic(),deadline,'bounded automatic producer preparation failed')
                    self.assertIsNone(child.poll(),'daemon exited during preparation')
                    started=time.monotonic()
                    try: response=urllib.request.urlopen(base+'/health',timeout=1)
                    except urllib.error.HTTPError as error: response=error
                    with response:
                        self.assertEqual(response.code,503) # Agent-only fixture has no PG.
                        health=json.load(response)
                        self.assertFalse(health['postgres_reachable'])
                        self.assertFalse(health['schema_version_current'])
                    self.assertLess(time.monotonic()-started,1,'owned preparation blocked unrelated HTTP')
                    try: line=lines.get(timeout=.1)
                    except queue.Empty:
                        if pending.done(): first_draft=pending.result()
                        continue
                    match=re.search(r'IsoNim: using (.+) via REST at (http://127\.0\.0\.1:\d+)',line)
                    if match:
                        executable=Path(match[1]).resolve()
                        self.assertTrue(executable.is_relative_to(HARBOR.resolve()))
                        exported=(HARBOR/'.repro/isonim-runtime/harbor-executable').read_text().strip()
                        self.assertEqual(executable,Path(exported).resolve())
                        harbor_url=match[2]
                first_draft=pending.result()
            self.assertIsNotNone(harbor_url,'automatic local producer REST selection was not used')
            self.harbor_url = harbor_url
            owned = processes()
            cleanup_owned = capture_owned(owned, [child.pid], cleanup_owned)
            services = [owned[pid][2] for pid in descendants(owned, child.pid) if pid in owned
                        and owned[pid][2] and owned[pid][2][0] == str(executable)
                        and '--rest-port' in owned[pid][2] and '--pid-file' in owned[pid][2]]
            self.assertEqual(len(services), 1, 'exactly one owned Harbor service')
            helpers=[pid for pid in descendants(owned,child.pid) if pid in owned
                      and owned[pid][2] and '--internal-harbor-runtime' in owned[pid][2]]
            self.assertEqual(len(helpers),1,'automatic selection owns one isolated preparation helper')
            helper_pid=helpers[0]
            helper_args=owned[helper_pid][2]
            helper_directory=Path(helper_args[-1])
            self.assertEqual(helper_directory.stat().st_mode & 0o777,0o700)
            ready_file=helper_directory/'ready.json'
            self.assertEqual(ready_file.stat().st_mode & 0o777,0o600)
            ready=json.loads(ready_file.read_text())
            self.assertEqual(ready['pid'],helper_pid)
            self.assertEqual(Path(ready['executable']).resolve(),executable)
            self.assertEqual(ready['url'],harbor_url)
            self.assertEqual(os.getsid(helper_pid),helper_pid)
            service_pids=[pid for pid in descendants(owned,child.pid) if pid in owned
                          and owned[pid][2] in services]
            self.assertEqual(len(service_pids),1)
            self.assertEqual(os.getsid(service_pids[0]),helper_pid)
            (artifacts/'owned-preparation-proof.json').write_text(json.dumps({
                'helperPid':helper_pid,'servicePid':service_pids[0],
                'helperDirectoryMode':0o700,'readyFileMode':0o600,
                'daemonSha256':identities['daemon_sha256'],
                'producerExecutable':str(executable),'sameOwnedSession':True},indent=2))
            state_dir = Path(services[0][services[0].index('--pid-file') + 1]).parent
            self.assertNotEqual(state_dir, inherited.parent)
            self.assertEqual(state_dir.stat().st_mode & 0o777,0o700)
            self.assertTrue((state_dir / 'daemon.sqlite').read_bytes().startswith(b'SQLite format 3\0'))
            (artifacts / 'owned-state.txt').write_text(str(state_dir) + '\n')
            self.assertEqual(self.sessions(), [])
            drafts = [first_draft,self.post('/api/agent/sessions', {'cwd':str(workspace)})]
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
                if shutdown_only:
                    actual_prompts = [json.loads(line) for line in
                                      (fixture / f'provider-prompts-{index}.jsonl').read_text().splitlines()]
                    self.assertEqual(len(actual_prompts), 1)
                    self.assertTrue(actual_prompts[0].startswith(FIRST.replace('ISONIM_CONTEXT_7309', token)))
                    continue
                self.assertEqual({s['status'] for s in sessions}, {'paused'}, 'turn end is idle, never session completion')
                table = processes()
                cleanup_owned = capture_owned(table, [child.pid], cleanup_owned)
                # Save all actually owned native metadata before any argv
                # predicate. A rejected predicate cannot erase its evidence.
                (artifacts / f'owned-processes-after-turn-{index}.json').write_text(
                    json.dumps({pid: row for pid, row in table.items()
                                if pid in cleanup_owned and row[1] == cleanup_owned[pid][1]}, indent=2))
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
            if shutdown_only:
                self.assertEqual(len(backend_ids), 2)
                self.assertEqual(len(set(backend_ids)), 2)
                self.assertEqual((fixture / 'provider-counter').read_text(), '2')
                self.assertEqual({s['id'] for s in self.sessions()}, set(backend_ids))
                return  # Finally still requires native0, owned reaping and EOF.
            # Reuse conversation handles in reverse order: no backend restart.
            for index in (1, 0):
                self.assert_workers(workers)
                (workspace / 'AGENTS.md').write_text(f'Current project guidance: followup chat {index}.\n')
                event_ids = self.turn(drafts[index]['sessionId'], SECOND, f'ISONIM_CONTEXT_7309_{index}', f'chat{index}-second')
                self.assertEqual(event_ids, {backend_ids[index]}, 'followup must reach this same backend session')
                self.assertEqual({s['id'] for s in self.sessions()}, set(backend_ids))
                self.observe_idle_workers(workers)
                trace = [json.loads(line) for line in (fixture / f'provider-prompts-{index}.jsonl').read_text().splitlines()]
                self.assertEqual(len(trace), 2, 'exactly two real user turns; no hidden primer')
                prior_delivered = None
                for turn_index, user in enumerate((FIRST.replace('ISONIM_CONTEXT_7309', f'ISONIM_CONTEXT_7309_{index}'), SECOND)):
                    editor_label = '\n\nEDITOR CONTEXT:\n'
                    user_text, context_and_project = trace[turn_index].split(editor_label, 1)
                    self.assertEqual(user_text, user)
                    editor_context, project_context = context_and_project.split('\n\nPROJECT CONTEXT:\n\n', 1)
                    wire_context = json.loads(editor_context)
                    if turn_index == 1 and 'fromContext' in wire_context:
                        self.assertEqual(wire_context['fromContext'], context_identity(prior_delivered),
                            'Reference must identify this exact prior provider transcript, not observer state')
                    delivered = resolve_context(wire_context, prior_delivered)
                    self.assertEqual(delivered, self.submitted_contexts[f'chat{index}-' + ('first' if turn_index == 0 else 'second')],
                        'Every original current context value must cross the actual provider transport')
                    prior_delivered = delivered
                    self.assertIn('Project root: ' + str(workspace), project_context)
                    guidance = 'first turn.' if turn_index == 0 else f'followup chat {index}.'
                    self.assertIn('Current project guidance: ' + guidance, project_context)
                    self.assertIn('Brief index (loaded from <project>/briefs/):', project_context)
                    self.assertIn('Active campaigns:', project_context)
                    self.assertNotIn((ROOT / 'prompts/ai-assistant.md').read_text(), trace[turn_index])
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
            original_error = sys.exc_info()[1]
            cleanup_errors = []
            cleanup_owned = capture_owned(processes(), [child.pid], cleanup_owned)
            if child.poll() is None:
                child.send_signal(signal.SIGTERM)
                try:
                    child.wait(timeout=90)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)
                    cleanup_errors.append('owned daemon shutdown exceeded its normal deadline')
            # The isolated preparation helper can outlive a crashed native
            # daemon and keep stderr open. Revalidate only captured identities,
            # even when the direct child was already reaped before finally.
            try:
                reap_owned(OBSERVER, cleanup_owned, [child], seconds=15)
            except AssertionError as error:
                cleanup_errors.append(str(error))
            reader.join(timeout=5)
            if reader.is_alive():
                cleanup_errors.append('owned stderr reader did not reach EOF')
            else:
                # Never block acquiring an active reader's lock. A buffered
                # failed log can raise again at close; retain that evidence too.
                for handle in (child.stderr, log):
                    try:
                        handle.close()
                    except BaseException as error:
                        cleanup_errors.append('owned stderr handle close failed: ' + repr(error))
            if reader.errors:
                cleanup_errors.append('owned stderr reader failed: ' + repr(reader.errors))
            elif not reader.eof and not reader.is_alive():
                cleanup_errors.append('owned stderr reader ended without EOF')
            try:
                require_exit(child, {0}, 'editor daemon')
            except AssertionError as error:
                cleanup_errors.append(str(error))
            (artifacts / 'native-exit.json').write_text(json.dumps({
                'pid': child.pid, 'returncode': child.returncode,
                'readerEof': reader.eof, 'readerAlive': reader.is_alive(),
                'readerErrors': reader.errors, 'cleanupErrors': cleanup_errors}, indent=2))
            if cleanup_errors:
                error = AssertionError('; '.join(cleanup_errors))
                if original_error is not None:
                    original_error.add_note(str(error))
                else:
                    raise error
            if shutdown_only and original_error is None:
                self.assertFalse(helper_directory.exists(), 'owned helper handoff must be removed')
                self.assertNotIn(helper_pid, processes(), 'owned helper must be physically reaped')
                self.assertNotIn(service_pids[0], processes(), 'owned service must be physically reaped')
                self.assertEqual(inherited.read_text(), 'parent state must remain untouched')
                with sqlite3.connect(state_dir / 'daemon.sqlite') as database:
                    status_events = [(sid, json.loads(payload)) for sid, payload in
                        database.execute("select session_id,payload from session_events where kind='status'")
                        if sid in backend_ids]
                stopping = {sid: min(event['timestamp'] for session, event in status_events
                                    if session == sid and event['status'] == 'stopping') for sid in backend_ids}
                stopped = {sid: min(event['timestamp'] for session, event in status_events
                                    if session == sid and event['status'] == 'stopped') for sid in backend_ids}
                self.assertLess(max(stopping.values()), min(stopped.values()),
                                'both real REST stops must begin before either completes')
                (artifacts / 'parallel-stop-proof.json').write_text(json.dumps({
                    'backendIds': backend_ids, 'stopping': stopping, 'stopped': stopped,
                    'normalNativeExit': child.returncode, 'readerEof': reader.eof}, indent=2))
                (artifacts / 'SHUTDOWN-PASS').write_text(
                    'two real backend sessions, two official first prompts; native0; owned helper/service reaping and stderr EOF\n')
        self.assertEqual(child.returncode, 0, 'normal owned shutdown must succeed')
        self.assertFalse(helper_directory.exists(),'owned helper handoff must be removed')
        self.assertNotIn(helper_pid,processes(),'owned helper must be reaped')
        self.assertNotIn(service_pids[0],processes(),'owned Harbor service must be reaped')
        self.assertEqual(inherited.read_text(), 'parent state must remain untouched')
        (artifacts / 'PASS').write_text('production editor routes: two drafts, two isolated persistent REST sessions, same workers/starttimes, explicit closure and normal shutdown\n')

    def post(self, path, payload, expected=200, timeout=60):
        request = urllib.request.Request(self.base + path, json.dumps(payload).encode(),
                                          {'Content-Type': 'application/json'})
        try:
            response = urllib.request.urlopen(request, timeout=timeout)
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
            context = {'backend': 'absAgentHarbor', 'selectedStoryName': name,
                        'themeTokens': [{'id': 'project.accent', 'value': '#123456' if name.endswith('first') else '#abcdef'}],
                        'renderedComponentTree': [{'id': name, 'parentId': '', 'depth': 0}],
                        'availableTailwindClasses': ['p-4'], 'tailwindClassTotal': 1}
            self.submitted_contexts[name] = context
            client.request('POST', '/api/agent/prompts', json.dumps({'sessionId': draft, 'text': text, 'context': context}),
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
