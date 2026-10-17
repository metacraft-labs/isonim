#!/usr/bin/env python3
"""Real REST output modes through IsoNim's owned sibling Harbor instance.

Only model responses use the official deterministic Rust scenario provider.
HTTP, the production launcher/REST executor, durable SQLite, kernel process
identity, loaded executable bytes and shutdown are real. This complementary
case covers omitted/explicit false persistence explicit true one-turn exit and legacy task default;
the original editor continuity scenario retains its independent context checks.
The stdio observer forwards actual bytes without editing or delaying them. It
records safe ACP request/response metadata and line hashes, never raw context or
tool payloads, because REST dispatch acknowledgements
and a paused session row do not establish completion of the current turn.
An official runCmd scenario blocks every first turn until real kernel identity
and actual first request metadata are captured, and blocks the false-mode second
turn on a real file barrier.
Its activity changes REST status, so this control proves request freshness and
rejects reuse of the actual first terminal; it does not reproduce the paused-row
race from the earlier weaker scenario. The barrier is released on all exits.
"""
import hashlib
import concurrent.futures
import json
import os
from pathlib import Path
import sqlite3
import re
import shlex
import sys
import time
import unittest
import urllib.request
import urllib.error
from helpers.editor_scenario_runtime import Runtime, wait, post, HARBOR
from helpers.editor_process_observer import optional_sibling_available, capture_owned


WIRE_OBSERVER = '''import hashlib,json,os,selectors,subprocess,sys
os.environ["MOCK_AGENT_PROMPT_TRACE"]=sys.argv[1]
child=subprocess.Popen([sys.argv[2],"--scenario",sys.argv[3],"--disable-follower"],
    stdin=subprocess.PIPE,stdout=subprocess.PIPE,bufsize=0)
selector=selectors.DefaultSelector()
selector.register(0,selectors.EVENT_READ,("client",child.stdin.fileno()))
selector.register(child.stdout.fileno(),selectors.EVENT_READ,("provider",1))
buffers={"client":b"","provider":b""}
with open(sys.argv[4],"a",buffering=1) as evidence:
    while True:
        for key,_ in selector.select():
            direction,destination=key.data
            data=os.read(key.fd,65536)
            if not data:
                selector.unregister(key.fd)
                if direction=="client":child.stdin.close()
                else:
                    assert not buffers[direction],"partial provider protocol frame"
                    sys.exit(child.wait())
                continue
            buffers[direction]+=data
            while b"\\n" in buffers[direction]:
                line,buffers[direction]=buffers[direction].split(b"\\n",1)
                if line:
                    frame=json.loads(line)
                    params=frame.get("params",{})
                    result=frame.get("result",{})
                    prompt=params.get("prompt",[])
                    record={"direction":direction,"id":frame.get("id"),
                        "method":frame.get("method"),"sessionId":params.get("sessionId"),
                        "hasResult":"result" in frame,"hasError":"error" in frame,
                        "stopReason":result.get("stopReason") if isinstance(result,dict) else None,
                        "lineSha256":hashlib.sha256(line).hexdigest()}
                    if frame.get("method")=="session/prompt":
                        record["promptBlocks"]=len(prompt)
                        record["textBlocks"]=sum(block.get("type")=="text" for block in prompt)
                        record["promptSha256"]=hashlib.sha256("\\n".join(
                            block.get("text","") for block in prompt).encode()).hexdigest()
                    evidence.write(json.dumps(record)+"\\n")
                    evidence.flush()
            while data:
                count=os.write(destination,data)
                data=data[count:]
'''


class EditorHarborOutputModes(unittest.TestCase):
    def test_real_rest_default_false_and_true_provider_lifetimes(self):
        if not optional_sibling_available(HARBOR):
            self.skipTest('optional private Agent Harbor sibling absent')
        runtime = Runtime('browser')  # Supported launcher-only host; no GUI driver is started.
        evidence = []
        release_files = []
        try:
            # A real API draft prepares the optional sibling service without
            # launching a provider, exactly as normal editor sessions do.
            # The first draft owns the original cold900 preparation bound,
            # independently observed by Runtime's kernel/handoff clock. Turn
            # APIs below retain post()'s70s bound. Probe unrelated native HTTP
            # concurrently, as the original continuity scenario does.
            daemon_origin = re.search(r'isonim-review serve: listening on (http://[^\s]+)',
                (runtime.artifacts/'launcher.log').read_text())[1]
            request = urllib.request.Request(runtime.origin+'/api/agent/sessions',
                data=json.dumps({'cwd':str(runtime.project)}).encode(),
                headers={'Content-Type':'application/json'})
            def cold_draft():
                with urllib.request.urlopen(request, timeout=900) as response:
                    self.assertEqual(response.status, 200)
                    return json.load(response)
            deadline = time.monotonic()+900
            health_samples = []
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pending = pool.submit(cold_draft)
                while not pending.done() or not hasattr(runtime, 'harborUrl'):
                    self.assertLess(time.monotonic(), deadline, 'original cold900 preparation bound')
                    self.assertIsNone(runtime.server.poll())
                    self.assertIn(runtime.daemonPid, runtime.observer.snapshot())
                    self.assertEqual(runtime.clockData['error'], None)
                    started = time.monotonic()
                    try:
                        response = urllib.request.urlopen(daemon_origin+'/health', timeout=1)
                    except urllib.error.HTTPError as error:
                        response = error
                    with response:
                        self.assertEqual(response.code, 503)  # Actual agent-only daemon has no PG.
                        health = json.load(response)
                        self.assertFalse(health['postgres_reachable'])
                        self.assertFalse(health['schema_version_current'])
                    health_samples.append(time.monotonic()-started)
                    self.assertLess(health_samples[-1], 1, 'preparation blocked unrelated HTTP')
                    time.sleep(.1)
                draft = pending.result()
            self.assertTrue(runtime.clockData['completed'])
            (runtime.controllerPrivate/'output-mode-preparation.json').write_text(json.dumps({
                'clock':runtime.clockData, 'healthSamples':health_samples}, indent=2))
            self.assertEqual(draft['sessionState'], 'draft')
            self.assertEqual(draft['backendSessionId'], '')
            self.assertEqual(self.sessions(runtime), [])
            for label, mode in (('omitted', None), ('false', False), ('true', True), ('task-default', None)):
                directory = runtime.artifacts / label
                directory.mkdir(mode=0o700)
                provider = directory/'mock-agent'
                provider.write_bytes(runtime.provider.read_bytes()); provider.chmod(0o755)
                expected_sha = hashlib.sha256(runtime.provider.read_bytes()).hexdigest()
                scenario = directory/'scenario.yaml'
                scenario_text = '''name: REST output mode lifetime
acp:
  capabilities:
    loadSession: true
timeline:
  - sessionStart:
      sessionId: rest-output-mode
  - userInputs:
      - relativeTime: 0
        input: FIRST_OUTPUT_MODE
        expectedResponse:
          sessionId: rest-output-mode
          stopReason: end_turn
  - llmResponse:
      - assistant:
          - relativeTime: 1000
            content: OUTPUT_MODE_REPLY
expect:
  stopReason: end_turn
'''
                trace = directory/'prompts.jsonl'
                protocol = directory/'protocol.jsonl'
                release_files.append(directory/'first-release')
                if label == 'false':
                    release_files.append(directory/'second-release')
                gate = directory/'turn-gate.py'
                gate.write_text('''import json,pathlib,sys,time
root=pathlib.Path(sys.argv[1])
prompts=[json.loads(line) for line in (root/'prompts.jsonl').read_text().splitlines()]
assert prompts in (['FIRST_OUTPUT_MODE'],['FIRST_OUTPUT_MODE','SECOND_OUTPUT_MODE'])
phase='first' if len(prompts)==1 else 'second'
if phase=='first' or sys.argv[2]=='false':
    (root/(phase+'-entered')).touch()
    deadline=time.monotonic()+70
    while not (root/(phase+'-release')).exists():
        assert time.monotonic()<deadline,'real '+phase+'-turn gate not released'
        time.sleep(.03)
''')
                tool = ('  - agentToolUse:\n      toolName: runCmd\n      args:\n'
                    +'        cwd: '+json.dumps(str(runtime.project))+'\n'
                    +'        cmd: '+json.dumps(shlex.join([sys.executable,str(gate),str(directory),label]))+'\n')
                scenario_text = scenario_text.replace('  - llmResponse:', tool+'  - llmResponse:')
                scenario.write_text(scenario_text)
                wrapper = directory/'provider.py'
                wrapper.write_text(WIRE_OBSERVER)
                request = {'prompt': 'FIRST_OUTPUT_MODE', 'workspace_path': str(runtime.project),
                    'sandbox': {'mode':'dynamic', 'debug':True, 'allow-network':True},
                    'agent': {'agent':{'software':'Acp','version':'latest'}, 'model':'', 'count':1,
                        'acp_stdio_launch_command':{'binary':sys.executable,
                            'args':[str(wrapper), str(trace), str(provider), str(scenario), str(protocol)]}}}
                if mode is not None:
                    request['output']={'format':'text','flavor':'native','nonInteractive':mode}
                one_turn = mode is True or label == 'task-default'
                if label == 'task-default':
                    task_request = {'prompt':request['prompt'], 'repo':{'mode':'none'},
                        'runtime':{'type':'local'}, 'workspace_path':str(runtime.project),
                        'working_copy_mode':'in_place',
                        'sandbox':request['sandbox'], 'agents':[request['agent']],
                        'output':{'format':'text','flavor':'native','nonInteractive':False}}
                    admission_path, admission_request = '/api/v1/tasks', task_request
                else:
                    admission_path, admission_request = '/api/v1/sessions', request
                observed = {}
                def capture_provider():
                    table = runtime.observer.snapshot()
                    runtime.ownedProcesses = capture_owned(table, [child.pid for child in runtime.children], runtime.ownedProcesses)
                    for pid, row in table.items():
                        if (pid in runtime.ownedProcesses and row[2] and row[2][0] == str(provider)
                                and str(scenario) in row[2]):
                            image = Path(f'/proc/{pid}/exe') if sys.platform == 'linux' else Path(row[3])
                            loaded = hashlib.sha256(image.read_bytes()).hexdigest()
                            self.assertEqual(loaded, expected_sha)
                            observed[pid] = {'identity':row, 'loadedSha256':loaded}
                    self.assertLessEqual(len(observed), 1)
                    return len(observed)==1
                def first_capture():
                    capture_provider()
                    if not protocol.exists() or not (directory/'first-entered').exists():
                        return None
                    messages=[json.loads(line) for line in protocol.read_bytes().splitlines(keepends=True)
                        if line.endswith(b'\n')]
                    requests=[(index,item) for index,item in enumerate(messages)
                        if item['direction']=='client' and item['method']=='session/prompt'
                        and item['promptSha256']==hashlib.sha256(b'FIRST_OUTPUT_MODE').hexdigest()]
                    self.assertEqual(len(requests), 1)
                    index, metadata=requests[0]
                    self.assertIsNotNone(metadata['id'])
                    self.assertTrue(metadata['sessionId'])
                    self.assertEqual(metadata['promptBlocks'], 1)
                    self.assertEqual(metadata['textBlocks'], 1)
                    self.assertFalse(self.current_turn_terminal(protocol, 'FIRST_OUTPUT_MODE'),
                        'first terminal must remain pending until real identity capture')
                    return len(observed)==1 and {'requestIndex':index, 'metadata':metadata}
                # Session admission queues work; task admission may also await
                # launch setup. Keep the actual POST's70s bound unchanged while
                # the controller observes the real first-turn tool barrier.
                with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                    pending=pool.submit(self.post_mode, runtime, admission_path, admission_request)
                    try:
                        captured=wait(first_capture, label+' actual first request/provider before release')
                        self.assertEqual(len(observed), 1, 'one actual official provider required')
                        pid, original = next(iter(observed.items()))
                        self.same_provider(runtime, pid, original, expected_sha)
                        (runtime.controllerPrivate/('first-capture-'+label+'.json')).write_text(json.dumps({
                            'label':label, 'providerPid':pid, **original, 'firstRequest':captured,
                            'firstReleaseExists':False, 'firstTerminal':None}, indent=2))
                    finally:
                        (directory/'first-release').touch()
                    created=pending.result()
                if label == 'task-default':
                    self.assertEqual(len(created['session_ids']), 1)
                    session = created['session_ids'][0]
                else:
                    session = created['session_id']
                def terminal():
                    capture_provider()
                    state = next(row for row in self.sessions(runtime) if row['id']==session)
                    terminal_states = ('completed','failed') if one_turn else ('paused','completed','failed')
                    return self.current_turn_terminal(protocol, 'FIRST_OUTPUT_MODE') and state['status'] in terminal_states and state
                state = wait(terminal, label+' first actual provider turn')
                self.assertEqual(len(observed), 1, 'one actual official provider required')
                pid, original = next(iter(observed.items()))
                self.assertEqual([json.loads(line) for line in trace.read_text().splitlines()], ['FIRST_OUTPUT_MODE'])
                with sqlite3.connect(runtime.harborState/'daemon.sqlite') as db:
                    durable=json.loads(db.execute('select runtime_config from sessions where id=?',(session,)).fetchone()[0])
                if label == 'task-default':
                    self.assertNotIn('output', durable, 'legacy task absence keeps one-turn fallback')
                else:
                    self.assertEqual(durable['output'], {'format':'text','flavor':'native','nonInteractive':mode is True})
                if one_turn:
                    self.assertEqual(state['status'], 'completed')
                    wait(lambda: pid not in runtime.observer.snapshot(), 'one-turn provider physically reaped')
                else:
                    self.assertEqual(state['status'], 'paused')
                    self.same_provider(runtime, pid, original, expected_sha)
                    first = self.current_turn_terminal(protocol, 'FIRST_OUTPUT_MODE')
                    operation = 'output-mode-'+label+'-second'
                    delivered=self.post_mode(runtime, f'/api/v1/sessions/{session}/prompt',
                        {'prompt':'SECOND_OUTPUT_MODE','operationId':operation})
                    self.assertTrue(delivered['accepted'])
                    self.assertEqual(delivered['operationId'], operation)
                    self.assertEqual(delivered['sessionId'], session)
                    wait(lambda: trace.exists() and len(trace.read_text().splitlines())==2, 'followup actually delivered')
                    if label == 'false':
                        wait(lambda: (directory/'second-entered').exists(), 'official second runCmd entered')
                        self.same_provider(runtime, pid, original, expected_sha)
                        rest_status = next(row for row in self.sessions(runtime) if row['id']==session)['status']
                        fresh = self.followup_terminal(runtime, session, protocol, first)
                        (runtime.controllerPrivate/'freshness-control.json').write_text(json.dumps({
                            'session':session, 'operation':delivered, 'firstTerminal':first,
                            'actualPrompts':[json.loads(line) for line in trace.read_text().splitlines()],
                            'restStatus':rest_status, 'currentTerminal':fresh, 'releaseExists':False,
                            'protocolSha256':hashlib.sha256(protocol.read_bytes()).hexdigest()}, indent=2))
                        self.assertFalse(fresh,
                            'a delivered second prompt must not inherit the first terminal')
                        (directory/'second-release').touch()
                    second = wait(lambda: self.followup_terminal(runtime, session, protocol, first),
                        'fresh second ACP request terminal end_turn')
                    wait(lambda: next(row for row in self.sessions(runtime) if row['id']==session)['status']=='paused', 'followup idle after actual current terminal')
                    self.assertEqual([json.loads(line) for line in trace.read_text().splitlines()], ['FIRST_OUTPUT_MODE','SECOND_OUTPUT_MODE'])
                    self.same_provider(runtime, pid, original, expected_sha)
                    self.post_mode(runtime, f'/api/v1/sessions/{session}/stop', {}, empty=True)
                    wait(lambda: pid not in runtime.observer.snapshot(), 'persistent provider physically reaped after close')
                evidence.append({'label':label, 'mode':mode, 'session':session, 'providerPid':pid, **original,
                    'durableOutput':durable.get('output'), 'actualPrompts':len(trace.read_text().splitlines()),
                    'firstTerminal':self.current_turn_terminal(protocol, 'FIRST_OUTPUT_MODE'),
                    'secondTerminal':second if not one_turn else None})
                (runtime.artifacts/'output-mode-results.json').write_text(json.dumps(evidence,indent=2))
        finally:
            # Unblock the real official tool even when the pending assertion or
            # an intentionally bad terminal-reuse mutant fails. Preserve that
            # failure while retaining ordinary owned shutdown and deadlines.
            for release in release_files:
                release.touch()
            runtime.close()  # Enforces the owned exit/reaping/reader/privacy policy.

    def current_turn_terminal(self, protocol, prompt, first=None):
        if not protocol.exists():
            return None
        # Ignore only an unfinished final write; all completed lines are real
        # safe metadata of unmodified frames on the provider's actual pipe.
        lines = protocol.read_bytes().splitlines(keepends=True)
        messages = [json.loads(line) for line in lines if line.endswith(b'\n')]
        requests = [(index, item) for index,item in enumerate(messages)
            if item['direction']=='client' and item['method']=='session/prompt'
            and item['promptSha256']==hashlib.sha256(prompt.encode()).hexdigest()]
        self.assertLessEqual(len(requests), 1, 'one actual ACP request per supplied prompt')
        if not requests:
            return None
        index, request = requests[0]
        self.assertIsNotNone(request['id'], 'actual ACP prompt request ID required')
        self.assertEqual(request['promptBlocks'], 1)
        self.assertEqual(request['textBlocks'], 1)
        if first:
            self.assertGreater(index, first['responseIndex'], 'second request after completed first highwater')
            self.assertNotEqual(request['id'], first['requestId'])
            self.assertEqual(request['sessionId'], first['acpSessionId'])
        responses = [(response_index, item) for response_index,item in enumerate(messages)
            if response_index>index and item['direction']=='provider'
            and item['id']==request['id'] and (item['hasResult'] or item['hasError'])]
        self.assertLessEqual(len(responses), 1, 'one actual terminal response for this request')
        if not responses:
            return None
        response_index, response = responses[0]
        self.assertFalse(response['hasError'], 'current ACP prompt failed')
        self.assertTrue(response['hasResult'])
        self.assertEqual(response['stopReason'], 'end_turn')
        return {'requestId':request['id'], 'acpSessionId':request['sessionId'],
            'requestIndex':index, 'responseIndex':response_index, 'response':response}

    def followup_terminal(self, runtime, session, protocol, first):
        return self.current_turn_terminal(protocol, 'SECOND_OUTPUT_MODE', first)

    def post_mode(self, runtime, path, data, empty=False):
        try:
            if empty:
                request = urllib.request.Request(runtime.harborUrl+path,
                    data=json.dumps(data).encode(), headers={'Content-Type':'application/json'})
                with urllib.request.urlopen(request, timeout=70) as response:
                    body = response.read()
                    (runtime.controllerPrivate/'output-mode-stop-response.json').write_text(json.dumps({
                        'path':path, 'status':response.status,
                        'body':body.decode('utf-8', errors='replace')}, indent=2))
                    # stop_session returns Ok(()) directly:200 with empty body,
                    # unlike participant leave's explicit204 response.
                    self.assertEqual(response.status, 200)
                    self.assertEqual(body, b'')
                return None
            return post(runtime.harborUrl+path, data)
        except urllib.error.HTTPError as error:
            # Keep actual failure diagnostics outside the agent's bound project,
            # then retain the original HTTP failure and all API deadlines.
            (runtime.controllerPrivate/'output-mode-http-error.json').write_text(json.dumps({
                'path':path, 'status':error.code,
                'body':error.read().decode('utf-8', errors='replace')}, indent=2))
            raise

    def sessions(self, runtime):
        with urllib.request.urlopen(runtime.harborUrl+'/api/v1/sessions', timeout=70) as response:
            payload = json.load(response)
            self.assertIsInstance(payload['items'], list)
            self.assertEqual(payload['total'], len(payload['items']))
            return payload['items']

    def same_provider(self, runtime, pid, original, expected_sha):
        row = runtime.observer.snapshot()[pid]
        self.assertEqual(row[1:], original['identity'][1:])
        image=Path(f'/proc/{pid}/exe') if sys.platform=='linux' else Path(row[3])
        self.assertEqual(hashlib.sha256(image.read_bytes()).hexdigest(), expected_sha)


if __name__ == '__main__':
    unittest.main()
