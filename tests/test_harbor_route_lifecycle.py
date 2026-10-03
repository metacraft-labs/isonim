"""Real editor HTTP/worker lifetime tests with a controlled Harbor protocol peer.

Only Harbor is substituted to hold creation/streaming at exact barriers. This
proves editor races and HTTP responsiveness; live/scenario tests separately prove
Harbor/provider integration. No editor dispatcher or process is mocked.
The multiclass quota case compiles an actual temporary Tailwind stylesheet and
real typed EditorVM context. Only repeated optional diagnostic protocol records
and Harbor inference/quota replies are controlled; compaction, serialization,
HTTP workers, compiler and project/filesystem boundaries remain production.
"""
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import unittest
from helpers.editor_context_evidence import resolve_context, identity

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
        self.fail_completion = False
        self.received = None
        self.followups = []
        self.budget_limit = None
        self.omit_operation = False
        self.rejections = []
        self.history_events = []
        self.stream_restart = False
        self.rejection_delivery_state = None
        self.current_chars = 0
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
                    owner.current_chars = len(payload["prompt"])
                    owner.received = payload
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
                    owner.followups.append(payload)
                    used = owner.current_chars + len(payload['prompt'])
                    if owner.budget_limit is not None and used > owner.budget_limit:
                        rejection={'accepted':False, 'sessionId':'backend',
                            'stopReason':'context_limit', 'limitChars':owner.budget_limit,
                            'currentChars':owner.current_chars, 'remainingChars':max(0,owner.budget_limit-owner.current_chars),
                            'usedChars':used, 'overLimitBy':used-owner.budget_limit}
                        if not owner.omit_operation:rejection['operationId']=None
                        if owner.rejection_delivery_state is not None:rejection['deliveryState']=owner.rejection_delivery_state
                        owner.rejections.append(rejection)
                        self.respond(rejection)
                        return
                    owner.current_chars = used
                    self.respond({'accepted': True, 'sessionId': 'backend'})

            def do_GET(self):
                if '/events/history' in self.path:
                    limit=int(self.path.split('limit=',1)[1]) if 'limit=' in self.path else 50
                    self.respond({'events': list(reversed(owner.history_events[-limit:])), 'total_count': len(owner.history_events)})
                    return
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                self.wfile.write(b'id: 0\ndata: {"type":"status","status":"running"}\n\n')
                self.wfile.write(b'id: 1\ndata: {"type":"user_input","content":"durably reserved input"}\n\nid: 2\ndata: {"type":"log","message":"startup log, not provider admission"}\n\n')
                self.wfile.flush()
                owner.streamed.set()
                if owner.stream_restart:
                    owner.stream_restart=False
                    event={'type':'dispatcher_restarted','restartSeq':1}
                    owner.history_events.append(event)
                    self.wfile.write(('id: 2\ndata: '+json.dumps(event)+'\n\n').encode());self.wfile.flush()
                owner.allow_finish.wait(10)
                reason = 'error' if owner.fail_completion else 'end_turn'
                self.wfile.write(('id: 3\ndata: '+json.dumps({'type':'turn_complete','stop_reason':reason})+'\n\n').encode())
                if not owner.fail_completion:
                    self.wfile.write(b'id: 4\ndata: {"type":"status","status":"paused"}\n\n')
                self.wfile.flush()

        self.peer = ThreadingHTTPServer(('127.0.0.1', 0), Peer)
        threading.Thread(target=self.peer.serve_forever, daemon=True).start()
        config = Path(self.temp.name) / 'editor.toml'
        config.write_text('[agent]\nbackend = "harbor"\ncommand = "/bin/true"\nprimer_enabled = false\nmodel = "sonnet"\n')
        env = dict(os.environ, HOME=str(Path(self.temp.name).resolve()), ISONIM_AGENT_BACKEND='harbor', ISONIM_LOCAL_HARBOR='0',
            ISONIM_HARBOR_URL=f'http://127.0.0.1:{self.peer.server_port}', ISONIM_REVIEW_PORT='0',
            ISONIM_EDITOR_BROWSER_BOOTSTRAP='lifecycle-browser-bootstrap')
        env.pop('ISONIM_ACP_AGENT_CMD', None)
        self.daemon = subprocess.Popen([str(ROOT / 'build/bin/isonim-review'), 'serve',
            '--agent-routes-only', '--config', str(config)], env=env, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, text=True)
        ready = queue.Queue()
        self.daemon_lines = []

        def drain():
            for line in self.daemon.stderr:
                self.daemon_lines.append(line)
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
        if self.daemon.poll() is not None:
            sys.stderr.write("".join(self.daemon_lines))
            sys.stderr.write(json.dumps({"followupChars":[len(p["prompt"]) for p in self.followups],"rejections":self.rejections})+"\n")
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
        environment = Path(self.temp.name).resolve() / ('Library/Application Support' if sys.platform == 'darwin' else '.local/share') / 'isonim/editor-control' / ('isonim-control-' + self.session) / 'environment.json'
        self.assertTrue(environment.is_file())
        self.assertEqual(environment.stat().st_mode & 0o777, 0o600)
        token = json.loads(environment.read_text())['ISONIM_EDITOR_TOKEN']
        self.allow_finish.set()
        self.assertEqual(outcome.get(timeout=5)[0], 200)
        return scope, token, environment

    def test_unicode_cumulative_context_budget_preserves_exact_user_input_and_rejection_metadata(self):
        self.allow_create.set();self.allow_finish.set()
        first=self.prompt();first['messages'][0]['content'][0]['text']='Пример😀保持'
        first['context']={'designSystemConstraints':['first genuine context']}
        status,raw=self.post('/api/agent/prompts',first)
        self.assertEqual(status,200);self.assertIn('event: admitted',raw)
        launch=self.received['agent']['acpStdioLaunchCommand']
        self.assertEqual(self.received['agent']['settings']['model'],'sonnet')
        self.assertTrue(any(value.endswith('/tools/agent_session_launcher.py') for value in launch['args']))
        self.assertNotIn('--instructions',launch['args'],'Intentional instruction disabling remains exact')
        initial=self.current_chars
        next_turn=self.prompt();next_turn['messages'][0]['content'][0]['text']='保持😀'
        full_project='PROJECT CONTEXT:'+self.received['prompt'].split('\n\nPROJECT CONTEXT:',1)[1]
        project='\n\nPROJECT CONTEXT: same '+hashlib.sha1(full_project.encode()).hexdigest().upper()
        next_envelope='保持😀'+project
        # Reserve one Unicode user character plus the actual mandatory project
        # guidance for the final short turn, using measured envelope lengths.
        self.budget_limit=initial+len(next_envelope)+len(project)+1
        status,raw=self.post('/api/agent/prompts',next_turn)
        self.assertEqual(status,200);self.assertIn('event: admitted',raw)
        self.assertEqual(self.followups[-1]['prompt'],next_envelope)
        rejected=self.prompt();rejected['messages'][0]['content'][0]['text']='😀😀'
        status,raw=self.post('/api/agent/prompts',rejected)
        self.assertEqual(status,200)
        self.assertNotIn('event: admitted',raw)
        errors=[json.loads(frame.split('data: ',1)[1]) for frame in raw.strip().split('\n\n') if frame.startswith('event: error\n')]
        self.assertEqual(len(errors),1)
        details=errors[0]['rejection']
        self.assertEqual(details,{'stopReason':'context_limit','operationId':None,'noOperation':True,
            'limitChars':self.budget_limit,'usedChars':initial+len(next_envelope)+len(project)+2,
            'currentChars':initial+len(next_envelope),'remainingChars':len(project)+1,'overLimitBy':1})
        self.assertIn('start a new conversation',errors[0]['reason'])
        self.assertEqual(self.followups[-1]['prompt'],'😀😀'+project)
        self.assertEqual(self.current_chars,initial+len(next_envelope),'Rejected input has no durable/provider effect')
        # Explicit no-operation quota rejection keeps the SAME session available
        # for a deliberate exact shorter retry; it is never automatically resent.
        retry=self.prompt();retry['messages'][0]['content'][0]['text']='😀'
        status,raw=self.post('/api/agent/prompts',retry)
        self.assertEqual(status,200);self.assertIn('event: admitted',raw)
        self.assertEqual(self.current_chars,self.budget_limit)
        self.assertEqual(len(self.followups),3)

    def test_official_omitted_operation_quota_compacts_once_each_turn_and_preserves_protected_snapshot(self):
        self.omit_operation=True
        self.allow_create.set();self.allow_finish.set()
        self.assertIn('event: admitted',self.post('/api/agent/prompts',self.prompt())[1])
        identity=self.received['agent']['acpStdioLaunchCommand']
        # Advance the same actual conversation before bounded turn three/four.
        self.assertIn('event: admitted',self.post('/api/agent/prompts',self.prompt())[1])
        full_project='PROJECT CONTEXT:'+self.received['prompt'].split('\n\nPROJECT CONTEXT:',1)[1]
        project='\n\nPROJECT CONTEXT: same '+hashlib.sha1(full_project.encode()).hexdigest().upper()
        prior_context={}
        for turn in (3,4):
            submitted=self.prompt()
            text='  exact user 保持😀 turn '+str(turn)+'  '
            submitted['messages'][0]['content'][0]['text']=text
            protected={'accumulatedEdits':['exact edit😀 '+str(turn)],
                'pendingSourceEdits':[{'path':'src/catalog.nim','value':'  exact 保持  '}],
                'designSystemConstraints':['must remain exact'], 'currentFileDiffs':['exact diff']}
            context=dict(protected,selectedStory={'group':'Hero','name':'example'},
                contextAvailability=['sourceMap: unavailable'],
                diagnostics=[{'file':'src/catalog.nim','line':i,'message':'保持😀 turn '+str(turn)+' '+str(i)} for i in range(80)],
                renderedComponentTree=[{'id':str(i),'parentId':'root','depth':1} for i in range(80)])
            submitted['context']=context
            self.budget_limit=self.current_chars+len(project)+len(text)+1800
            before=len(self.followups)
            status,raw=self.post('/api/agent/prompts',submitted)
            self.assertEqual(status,200);self.assertIn('event: admitted',raw,''.join(self.daemon_lines))
            self.assertIn('editor_context_budget',raw)
            self.assertEqual(len(self.followups),before+2,'Exactly one rejected attempt and one actual retry')
            first,second=self.followups[-2:]
            self.assertTrue(first['prompt'].startswith(text+'\n\nEDITOR CONTEXT'))
            self.assertTrue(second['prompt'].startswith(text+'\n\nEDITOR CONTEXT'))
            self.assertTrue(second['prompt'].endswith(project))
            wire=json.loads(second['prompt'].split('EDITOR CONTEXT:\n',1)[1].split('\n\nPROJECT CONTEXT:',1)[0]);actual=resolve_context(wire,prior_context);prior_context=actual
            self.assertEqual(set(actual),set(context))
            for key,value in protected.items():self.assertEqual(actual[key],value)
            self.assertGreaterEqual(len(actual['diagnostics']),1)
            self.assertGreaterEqual(len(actual['renderedComponentTree']),1)
            self.assertLess(len(actual['diagnostics']),80)
            self.assertIn('quota truncated',json.dumps(actual['contextAvailability']))
            self.assertNotIn('operationId',self.rejections[-1],'Matches actual public REST serializer omission')
            self.assertLessEqual(self.current_chars,self.budget_limit)
            self.assertEqual(self.received['agent']['acpStdioLaunchCommand'],identity)
        # Nothing optional can make a large exact edit fit: no retry or ACK.
        protected=self.prompt();protected['context']={'accumulatedEdits':['保持😀'*3000],
            'diagnostics':[{'message':'one complete diagnostic'}]}
        self.budget_limit=self.current_chars+len(project)+300
        before=len(self.followups)
        _,raw=self.post('/api/agent/prompts',protected)
        self.assertNotIn('event: admitted',raw)
        self.assertEqual(len(self.followups),before+1)
        detail=json.loads(next(frame.split('data: ',1)[1] for frame in raw.split('\n\n') if frame.startswith('event: error\n')))['rejection']
        self.assertTrue(detail['noOperation']);self.assertNotIn('operationId',detail)

    def test_actual_multiclass_quota_retry_preserves_producer_minimum_and_relevance(self):
        self.allow_create.set(); self.allow_finish.set(); self.omit_operation = True
        # The extract input must be inside this repo for normal Tailwind module
        # resolution. Its output and all binaries remain owned temporary files;
        # the shared build/tailwind-styles.json is never changed.
        compiled_fixture = tempfile.TemporaryDirectory(prefix='class-quota-', dir=ROOT / 'build')
        self.addCleanup(compiled_fixture.cleanup)
        fixture = Path(compiled_fixture.name)
        names = ['p-' + str(i) for i in range(1, 141)]
        (fixture / 'classes.html').write_text('<main class="' + ' '.join(names) + '"></main>')
        css = fixture / 'input.css'
        css.write_text('@import "tailwindcss" source(none);\n@source "./classes.html";\n')
        extract = subprocess.run(['node', 'tools/tailwind-extract.mjs', '--input', str(css),
            '--out-dir', str(fixture)], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(extract.returncode, 0, extract.stdout + extract.stderr)
        styles = json.loads((fixture / 'tailwind-styles.json').read_text())
        self.assertTrue(set(names) <= set(styles), 'Every selected utility is genuinely compiled')
        binary = fixture / 'actual-context-snapshot'
        build = subprocess.run(['nim', 'c', '--path:src', '--path:../nim-everywhere/src',
            '--path:../nim-acp/src', '--path:../nim-agent-harbor/src', '--path:../nim-agents/src',
            '--path:../isonim-render-serve/src', '-d:tailwindStylesPathOverride=' + str(fixture / 'tailwind-styles.json'),
            '--out:' + str(binary), 'tests/helpers/editor_context_snapshot.nim'],
            cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(build.returncode, 0, build.stderr)
        ordinary = json.loads(subprocess.check_output([str(binary)], text=True))
        selected = json.loads(subprocess.check_output([str(binary), '--all-compiled-classes'], text=True))
        optional = json.loads(subprocess.check_output([str(binary), '--optional-compiled-classes'], text=True))
        self.assertGreater(len(optional['availableTailwindClasses']), 128)
        self.assertFalse(any('required minimum' in marker for marker in optional['contextAvailability']))
        self.assertEqual(len(ordinary['availableTailwindClasses']), 128)
        self.assertGreater(len(selected['availableTailwindClasses']), 128)
        self.assertEqual(set(selected['availableTailwindClasses']), set(styles))
        self.assertEqual(selected['availableTailwindClasses'], sorted(styles))
        # The same real compiled inventory must prioritize actual rendered
        # attributes, never genuinely compiled utility names in inactive text.
        # Build from HTML through the real producer; no injected context ordering.
        preview_html = '''<!doctype html><!-- <i class="p-1"> -->
          <script>const fake="<i class='p-2'>";</script>
          <style>body::before{content:"<i class='p-3'>"}</style>
          <title><i class='p-4'></title><textarea><i class='p-5'></textarea>
          <noscript><i class='p-6'></noscript>
          <template><i class='p-7'></i></template>
          <main title="1 > 0" =class="p-9" class="p&#45;140&Tab;p&#x2d;139" class="p-8"></main>'''
        rendered = json.loads(subprocess.check_output([str(binary), '--preview-html'],
            input=preview_html, text=True))
        self.assertEqual(rendered['availableTailwindClasses'][:2], ['p-140', 'p-139'])
        self.assertEqual(len(rendered['availableTailwindClasses']), 128)
        self.assertEqual(rendered['tailwindClassTotal'], len(styles))
        # Relevance itself can exceed 128 through published real element classes.
        rendered_all_html = preview_html + '<section class="' + ' '.join(sorted(styles)) + '"></section>'
        rendered_all = json.loads(subprocess.check_output([str(binary), '--preview-html'],
            input=rendered_all_html, text=True))
        self.assertEqual(rendered_all['availableTailwindClasses'][:2], ['p-140', 'p-139'])
        self.assertEqual(set(rendered_all['availableTailwindClasses']), set(styles))
        self.assertEqual(rendered_all['tailwindClassTotal'], len(styles))
        self.assertTrue(any('required minimum' in marker for marker in rendered_all['contextAvailability']))
        # Run the SAME pure registered class oracle on this >128 real
        # compiler output, including exact Unicode wire/rejection tests.
        pure = fixture / 'class-quota'
        check = subprocess.run(['nim', 'c', '-r', '--path:src',
            '-d:tailwindStylesPathOverride=' + str(fixture / 'tailwind-styles.json'),
            '--out:' + str(pure), 'tests/test_design_review_class_quota.nim'], cwd=ROOT,
            env=dict(os.environ, ISONIM_TEST_LARGE_COMPILED_CLASSES='1'), capture_output=True, text=True)
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        wire_binary = fixture / 'actual-context-wire'
        build = subprocess.run(['nim', 'c', '--path:src', '--out:' + str(wire_binary),
            'tests/helpers/editor_context_wire.nim'], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(build.returncode, 0, build.stderr)
        payload = self.prompt(); payload['context'] = ordinary
        self.assertIn('event: admitted', self.post('/api/agent/prompts', payload)[1])
        local_session = self.session
        launch = self.received['agent']['acpStdioLaunchCommand']
        full_project = 'PROJECT CONTEXT:' + self.received['prompt'].split('\n\nPROJECT CONTEXT:', 1)[1]
        project = '\n\nPROJECT CONTEXT: same ' + hashlib.sha1(full_project.encode()).hexdigest().upper()
        prior = ordinary
        # New inventory and a changed current relevance ordering both traverse
        # prior-admitted reference encoding and one proven no-operation retry.
        reversed_html = '<main title="2 > 1" class="' + ' '.join(reversed(sorted(styles))) + '"></main>'
        rendered_followup = json.loads(subprocess.check_output([str(binary), '--preview-html'],
            input=reversed_html, text=True))
        self.assertEqual(rendered_followup['availableTailwindClasses'], list(reversed(sorted(styles))))
        for turn, produced in enumerate((rendered_all, rendered_followup)):
            context = json.loads(json.dumps(produced))
            classes = context['availableTailwindClasses']
            context['contextAvailability'].append('current compiled inventory turn ' + str(turn))
            context['diagnostics'] = [{'source':'compiler', 'category':'same',
                'message':'actionable 保持😀 current turn ' + str(turn) + ' ' + ('x' * 450), 'index':i} for i in range(3)]
            feasible = json.loads(json.dumps(context))
            feasible['diagnostics'] = [context['diagnostics'][0]]
            feasible['contextAvailability'] = list(dict.fromkeys(
                marker.split(':', 1)[0] + ': previously truncated'
                if ('budget' in marker or 'truncated' in marker) else marker
                for marker in context['contextAvailability']))
            feasible['contextAvailability'].append('diagnostics: 1/3 records; quota truncated')
            # Measure production reference encoding of an independently chosen
            # feasible meaningful minimum, rather than budgeting raw arrays.
            text = '  exact user 保持😀  '
            payload = self.prompt(); payload['context'] = context
            payload['messages'][0]['content'][0]['text'] = text
            minimum_wire = subprocess.check_output([str(wire_binary)], text=True,
                input=json.dumps({'current':feasible, 'base':prior}, ensure_ascii=False)).strip()
            minimum_chars = len(minimum_wire)
            fixed = len(text + '\n\nEDITOR CONTEXT:\n' + project)
            before_chars = self.current_chars
            self.budget_limit = before_chars + fixed + minimum_chars
            before = len(self.followups); rejections = len(self.rejections)
            status, raw = self.post('/api/agent/prompts', payload)
            self.assertEqual(status, 200)
            self.assertIn('event: admitted', raw, ''.join(self.daemon_lines))
            self.assertIn('editor_context_budget', raw, 'current class quota case ' + str(turn))
            self.assertEqual(len(self.followups), before + 2, 'One rejected attempt and exactly one retry')
            self.assertEqual(len(self.rejections), rejections + 1)
            rejected, retried = self.followups[-2:]
            for attempt in (rejected, retried):
                self.assertTrue(attempt['prompt'].startswith(text + '\n\nEDITOR CONTEXT:\n'))
                self.assertTrue(attempt['prompt'].endswith(project))
            wire = json.loads(retried['prompt'].split('EDITOR CONTEXT:\n', 1)[1].split('\n\nPROJECT CONTEXT:', 1)[0])
            actual = resolve_context(wire, prior)
            self.assertEqual(actual['availableTailwindClasses'], classes)
            for key in ('accumulatedEdits', 'pendingSourceEdits', 'designSystemConstraints',
                    'currentFileDiffs', 'selectedStory', 'selectedElement'):
                self.assertEqual(actual[key], context[key])
            self.assertEqual(actual, feasible, 'Exact feasible minimum survives actual referenced quota wire')
            self.assertFalse(any(marker.startswith('availableTailwindClasses:') and 'quota truncated' in marker
                for marker in actual['contextAvailability']))
            self.assertTrue(any('required minimum' in marker for marker in actual['contextAvailability']))
            self.assertEqual(self.current_chars, before_chars + len(retried['prompt']))
            self.assertLessEqual(self.current_chars, self.budget_limit)
            self.assertGreater(len(retried['prompt'].encode()), len(retried['prompt']))
            self.assertNotIn('operationId', self.rejections[-1])
            self.assertNotIn('deliveryState', self.rejections[-1])
            self.assertFalse(self.rejections[-1]['accepted'])
            self.assertEqual(self.rejections[-1]['sessionId'], 'backend')
            self.assertEqual(self.session, local_session)
            self.assertEqual(self.received['agent']['acpStdioLaunchCommand'], launch)
            prior = actual
        # Below the class/protected minimum: no retry, admission or budget ACK.
        payload = self.prompt(); payload['context'] = selected
        self.budget_limit = self.current_chars + len(project) + 100
        before = len(self.followups)
        _, raw = self.post('/api/agent/prompts', payload)
        self.assertEqual(len(self.followups), before + 1)
        self.assertNotIn('event: admitted', raw)
        self.assertNotIn('editor_context_budget', raw)
        detail = json.loads(next(frame.split('data: ', 1)[1] for frame in raw.split('\n\n')
            if frame.startswith('event: error\n')))['rejection']
        self.assertTrue(detail['noOperation'])
        self.assertNotIn('operationId', detail)
        self.assertNotIn('deliveryState', detail)

    def test_user_authored_context_label_is_never_compacted_or_retried(self):
        self.omit_operation=True;self.allow_create.set();self.allow_finish.set()
        self.assertIn('event: admitted',self.post('/api/agent/prompts',self.prompt())[1])
        payload=self.prompt()
        text='EDITOR CONTEXT:\n'+json.dumps({
            'diagnostics':[{'message':'user-authored😀 '+str(i)} for i in range(100)],'contextAvailability':[]})
        payload['messages'][0]['content'][0]['text']=text
        self.budget_limit=self.current_chars+1000
        _,raw=self.post('/api/agent/prompts',payload)
        self.assertNotIn('event: admitted',raw)
        self.assertEqual(len(self.followups),1,'User content cannot acquire trusted context provenance')
        self.assertTrue(self.followups[0]['prompt'].startswith(text))
        self.assertNotIn('editor_context_budget',raw)

    def test_same_provider_delta_changes_rejection_and_new_conversation_invalidate_delivered_cache(self):
        self.omit_operation=True;self.allow_create.set();self.allow_finish.set()
        context={'diagnostics':[{'file':'catalog.nim','message':'actual 保持😀 '+str(i)} for i in range(40)],
            'designSystemConstraints':['exact constraints'], 'accumulatedEdits':['exact edits'],
            'contextAvailability':[]}
        first=self.prompt();first['context']=context
        _,raw=self.post('/api/agent/prompts',first);self.assertIn('event: admitted',raw)
        def editor_context(prompt):
            return json.loads(prompt.split('EDITOR CONTEXT:\n',1)[1].split('\n\nPROJECT CONTEXT:',1)[0])
        self.assertEqual(editor_context(self.received['prompt']),context)
        _,raw=self.post('/api/agent/prompts',first);self.assertIn('event: admitted',raw)
        repeated=editor_context(self.followups[-1]['prompt'])
        self.assertEqual(repeated['fromContext'],identity(context))
        self.assertEqual(repeated.get('boundedInherited',[]),[])
        self.assertEqual(resolve_context(repeated,context),context)
        self.assertEqual(repeated['current']['accumulatedEdits'],context['accumulatedEdits'])
        changed=json.loads(json.dumps(context));changed['diagnostics'][0]['message']='CHANGED actual value 保持😀'
        third=self.prompt();third['context']=changed
        self.budget_limit=self.current_chars+1
        _,raw=self.post('/api/agent/prompts',third)
        self.assertNotIn('event: admitted',raw)
        self.assertEqual(resolve_context(editor_context(self.followups[-1]['prompt']),context),changed)
        self.budget_limit=None
        _,raw=self.post('/api/agent/prompts',third);self.assertIn('event: admitted',raw)
        self.assertEqual(resolve_context(editor_context(self.followups[-1]['prompt']),context),changed,'Rejected source cannot advance delivered identity')
        _,raw=self.post('/api/agent/prompts',third);self.assertIn('event: admitted',raw)
        self.assertEqual(editor_context(self.followups[-1]['prompt'])['fromContext'],identity(changed))
        self.assertEqual(self.post('/api/agent/close',{'sessionId':self.session})[0],200)
        _,raw=self.post('/api/agent/sessions',{})
        self.session=json.loads(raw)['sessionId']
        third['sessionId']=self.session
        _,raw=self.post('/api/agent/prompts',third);self.assertIn('event: admitted',raw)
        self.assertEqual(editor_context(self.received['prompt']),changed,'A fresh provider cannot reference prior conversation data')
        self.assertIn('Project root:',self.received['prompt'])

    def test_same_backend_provider_restart_invalidates_references_and_stale_turn_publication(self):
        self.allow_create.set();self.allow_finish.set()
        context={'diagnostics':[{'message':'actual context 保持😀 '+str(i)} for i in range(40)],'contextAvailability':[]}
        payload=self.prompt();payload['context']=context
        def context_of(prompt):return json.loads(prompt.split('EDITOR CONTEXT:\n',1)[1].split('\n\nPROJECT CONTEXT:',1)[0])
        self.assertIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
        self.assertIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
        self.assertEqual(context_of(self.followups[-1]['prompt'])['fromContext'],identity(context))
        self.history_events.append({'type':'session_started','timestamp':1})
        self.assertIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
        self.assertEqual(context_of(self.followups[-1]['prompt']),context,'Actual restart keeps backend ID but requires full current context')
        self.assertIn('Project root:',self.followups[-1]['prompt'])
        self.stream_restart=True
        _,raw=self.post('/api/agent/prompts',payload)
        self.assertNotIn('event: admitted',raw)
        self.assertIn('Provider restarted during context-reference delivery',raw)
        self.assertNotIn('event: admitted',self.post('/api/agent/prompts',payload)[1],'Uncertain delivery cannot be automatically retried')
        self.assertEqual(self.post('/api/agent/close',{'sessionId':self.session})[0],200)
        _,raw=self.post('/api/agent/sessions',{})
        self.session=json.loads(raw)['sessionId'];payload['sessionId']=self.session
        self.assertIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
        self.assertEqual(context_of(self.received['prompt']),context,'A fresh owner cannot publish or reuse the interrupted cache')

    def test_actual_http_array_delta_preserves_changes_removals_order_duplicates_and_rejected_basis(self):
        self.allow_create.set();self.allow_finish.set();self.omit_operation=True
        records=[{'source':'compiler','category':'generic','message':'actual diagnostic 保持😀 '+str(i)+' '+('detail '*20)} for i in range(20)]
        records[4]=dict(records[2]);records[8]=dict(records[2])
        first={'diagnostics':records,'contextAvailability':['sourceMap: unavailable'],
            'designSystemConstraints':['exact constraints'],'pendingSourceEdits':[{'value':'exact edit'}]}
        payload=self.prompt();payload['context']=first
        def context_of(prompt):return json.loads(prompt.split('EDITOR CONTEXT:\n',1)[1].split('\n\nPROJECT CONTEXT:',1)[0])
        self.assertIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
        changed=json.loads(json.dumps(first))
        changed['diagnostics']=list(reversed(records[1:]))
        changed['diagnostics'].insert(3,dict(records[2]))
        changed['diagnostics'][0]={'source':'review','category':'accessibility','message':'CHANGED meaningful current diagnostic 保持😀'}
        payload['context']=changed
        self.budget_limit=self.current_chars+1
        _,raw=self.post('/api/agent/prompts',payload);self.assertNotIn('event: admitted',raw)
        rejected=context_of(self.followups[-1]['prompt'])
        self.assertEqual(rejected['fromContext'],identity(first));self.assertIn('fromPreviousItems',rejected['current']['diagnostics'])
        self.assertEqual(resolve_context(rejected,first),changed)
        self.budget_limit=None
        self.assertIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
        retry=context_of(self.followups[-1]['prompt'])
        self.assertEqual(retry,rejected,'Rejected representation must not become a new reference basis')
        self.assertEqual(resolve_context(retry,first),changed)
        self.assertEqual(resolve_context(retry,first)['diagnostics'].count(records[2]),4,'Current duplicate multiplicity and order are exact')
        self.assertIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
        repeated=context_of(self.followups[-1]['prompt'])
        self.assertEqual(resolve_context(repeated,changed),changed)
        self.assertEqual(repeated['fromContext'],identity(changed))

    def test_actual_typed_snapshot_protected_tuple_crosses_http_and_round_trips_every_value(self):
        self.allow_create.set();self.allow_finish.set()
        binary=Path(self.temp.name)/'actual-context-snapshot'
        build=subprocess.run(['nim','c','--path:src','--path:../nim-everywhere/src',
            '--path:../nim-acp/src','--path:../nim-agent-harbor/src','--path:../nim-agents/src',
            '--path:../isonim-render-serve/src','--out:'+str(binary),
            'tests/helpers/editor_context_snapshot.nim'],cwd=ROOT,capture_output=True,text=True)
        self.assertEqual(build.returncode,0,build.stderr)
        context=json.loads(subprocess.check_output([str(binary)],text=True))
        self.assertEqual([(row['id'],row['parentId'],row['depth']) for row in context['renderedComponentTree']],
            [('root','',0),('branch','root',1),('actual-target','branch',2)])
        payload=self.prompt();payload['context']=context
        def context_of(prompt):return json.loads(prompt.split('EDITOR CONTEXT:\n',1)[1].split('\n\nPROJECT CONTEXT:',1)[0])
        self.assertIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
        delivered=context_of(self.received['prompt']);self.assertEqual(delivered,context)
        self.assertIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
        repeated=context_of(self.followups[-1]['prompt'])
        self.assertEqual(repeated['fromContext'],identity(delivered));self.assertIn('protectedV1',repeated)
        self.assertEqual(resolve_context(repeated,delivered),context)
        changed=json.loads(json.dumps(context));changed['selectedStory']['index']=7
        changed['selectedElement']['sourceLine']=84
        changed['accumulatedEdits'][0]['newValue']='  changed 保持😀 exact  '
        changed['pendingSourceEdits'][0]['newValue']='  changed 保持😀 exact  '
        changed['designSystemConstraints'].append('new exact constraint')
        changed['currentFileDiffs'][0]['afterText']='  changed 保持😀 exact  '
        payload['context']=changed
        self.assertIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
        wire=context_of(self.followups[-1]['prompt']);self.assertIn('protectedV1',wire)
        self.assertEqual(resolve_context(wire,delivered),changed,'Every new protected value crosses actual worker/HTTP/provider bytes')
        self.assertIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
        self.assertEqual(resolve_context(context_of(self.followups[-1]['prompt']),changed),changed)
        for malformed in [dict(repeated,boundedInherited={}),
            dict(repeated,current={'diagnostics':{'fromPreviousItems':{}}}),
            dict(repeated,current={'diagnostics':{'fromPreviousItems':'bad'}})]:
            with self.assertRaises(AssertionError):resolve_context(malformed,delivered)

    def test_actual_quota_retry_preserves_selected_hierarchy_beyond_512_with_real_ancestor_closure(self):
        self.allow_create.set();self.allow_finish.set();self.omit_operation=True
        self.assertIn('event: admitted',self.post('/api/agent/prompts',self.prompt())[1])
        full_project='PROJECT CONTEXT:'+self.received['prompt'].split('\n\nPROJECT CONTEXT:',1)[1]
        project='\n\nPROJECT CONTEXT: same '+hashlib.sha1(full_project.encode()).hexdigest().upper()
        rows=[{'id':'root','parentId':'','depth':0}]+[
            {'id':'unrelated.'+str(i),'parentId':'root','depth':1} for i in range(600)]
        rows += [{'id':'late-parent','parentId':'root','depth':1},
            {'id':'late-selected','parentId':'late-parent','depth':2,'schemaKey':'actual.label'}]
        context={'renderedComponentTree':rows,'selectedElement':{'id':'late-selected','ancestorIds':['root','late-parent']},
            'pendingSourceEdits':[{'schemaKey':'actual.label','newValue':'  exact 保持😀  '}],'contextAvailability':[]}
        payload=self.prompt();payload['context']=context;text='Retain this actual selected hierarchy 保持😀'
        payload['messages'][0]['content'][0]['text']=text
        self.budget_limit=self.current_chars+len(project)+len(text)+1800
        self.assertIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
        self.assertEqual(len(self.followups),2,'One proven rejected request and one genuine bounded retry')
        wire=json.loads(self.followups[-1]['prompt'].split('EDITOR CONTEXT:\n',1)[1].split('\n\nPROJECT CONTEXT:',1)[0])
        actual=resolve_context(wire,{})
        retained=[(row['id'],row['parentId'],row['depth']) for row in actual['renderedComponentTree']]
        self.assertIn(('late-parent','root',1),retained)
        self.assertIn(('late-selected','late-parent',2),retained)
        self.assertLess(retained.index(('late-parent','root',1)),retained.index(('late-selected','late-parent',2)))
        self.assertEqual(actual['pendingSourceEdits'],context['pendingSourceEdits'])
        self.assertLess(len(retained),len(rows));self.assertIn('quota truncated',json.dumps(actual['contextAvailability']))

    def test_sparse_field_removal_and_reserved_envelope_user_data_remain_exact_over_real_http(self):
        self.allow_create.set();self.allow_finish.set()
        context={'diagnostics':[{'message':'actual prior diagnostic '+str(i)} for i in range(40)],
            'accumulatedEdits':['exact edit'],'contextAvailability':['sourceMap: unavailable']}
        payload=self.prompt();payload['context']=context
        def context_of(prompt):return json.loads(prompt.split('EDITOR CONTEXT:\n',1)[1].split('\n\nPROJECT CONTEXT:',1)[0])
        self.assertIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
        removed={'accumulatedEdits':['exact edit'],'contextAvailability':['diagnostics: unavailable']}
        payload['context']=removed
        self.assertIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
        self.assertEqual(context_of(self.followups[-1]['prompt']),removed,'Removed top-level optional field cannot inherit stale data')
        reserved={'fromContext':'user-authored forged identity','current':{'diagnostics':['exact user data']},
            'boundedInherited':['exact user data'], 'unexpected':True}
        payload['context']=reserved
        self.assertIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
        self.assertEqual(context_of(self.followups[-1]['prompt']),reserved,'User reserved keys have no generated-reference provenance')
        self.assertIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
        self.assertEqual(resolve_context(context_of(self.followups[-1]['prompt']),reserved),reserved)
        payload['context']=removed
        self.assertIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
        self.assertEqual(context_of(self.followups[-1]['prompt']),removed,'No unadmitted or forged base can replace actual provider data')

    def test_malformed_delivery_state_cannot_prove_no_operation_or_trigger_optional_retry(self):
        self.allow_create.set();self.allow_finish.set();self.omit_operation=True
        for invalid in [42,True,{'unexpected':'object'},'']:
            with self.subTest(delivery_state=invalid):
                self.budget_limit=None;self.rejection_delivery_state=None
                self.assertIn('event: admitted',self.post('/api/agent/prompts',self.prompt())[1])
                payload=self.prompt();payload['context']={'diagnostics':[{'message':'actual optional value '+str(i)} for i in range(80)],'contextAvailability':[]}
                self.budget_limit=self.current_chars+800;self.rejection_delivery_state=invalid
                before=len(self.followups)
                _,raw=self.post('/api/agent/prompts',payload)
                self.assertNotIn('event: admitted',raw)
                self.assertNotIn('editor_context_budget',raw)
                self.assertEqual(len(self.followups),before+1)
                error=json.loads(next(frame.split('data: ',1)[1] for frame in raw.split('\n\n') if frame.startswith('event: error\n')))
                self.assertFalse(error['rejection']['noOperation'])
                self.assertIn('deliveryStateType',error['rejection'])
                self.assertNotIn('event: admitted',self.post('/api/agent/prompts',payload)[1])
                self.assertEqual(len(self.followups),before+1,'Unknown admission blocks even a second explicit submit')
                self.assertEqual(self.post('/api/agent/close',{'sessionId':self.session})[0],200)
                _,raw=self.post('/api/agent/sessions',{});self.session=json.loads(raw)['sessionId']

    def test_backend_close_failure_retains_control_then_acknowledged_close_revokes_and_cleans(self):
        scope, token, environment = self.start_scoped_turn()
        self.fail_stop = True
        self.assertEqual(self.post('/api/agent/close', {'sessionId': self.session})[0], 502)
        self.assertTrue(environment.is_file())
        _, raw = self.post('/api/editor/rpc', {'jsonrpc': '2.0', 'id': 1, 'method': 'editor.state', 'params': scope}, token)
        self.assertIn('result', json.loads(raw))
        self.fail_stop = False
        self.fail_completion = False
        self.received = None
        self.followups = []
        self.budget_limit = None
        self.omit_operation = False
        self.rejections = []
        self.history_events = []
        self.stream_restart = False
        self.rejection_delivery_state = None
        self.current_chars = 0
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

    def test_error_completion_after_durable_input_and_startup_log_never_admits(self):
        self.fail_completion = True
        self.allow_create.set()
        self.allow_finish.set()
        status, raw = self.post('/api/agent/prompts', self.prompt())
        self.assertEqual(status, 200)
        self.assertIn('durably reserved input', raw)
        self.assertIn('startup log', raw)
        self.assertIn('"stopReason":"error"', raw)
        self.assertNotIn('event: admitted', raw)

    def test_context_is_delivered_on_actual_first_and_followup_rest_inputs(self):
        self.allow_create.set()
        self.allow_finish.set()
        first = self.prompt()
        first['context'] = {'themeTokens': [{'key': 'surface', 'value': '#123456'}],
                            'renderedComponentTree': [{'id': 'title', 'parentId': 'root'}],
                            'availableTailwindClasses': ['p-4'], 'backend': 'absAgentHarbor'}
        status, raw = self.post('/api/agent/prompts', first)
        self.assertEqual(status, 200)
        self.assertIn('event: admitted', raw)
        encoded = json.dumps(self.received)
        self.assertIn('#123456', encoded)
        self.assertIn('renderedComponentTree', encoded)
        self.assertIn('p-4', encoded)
        followup = self.prompt()
        followup['context'] = {'themeTokens': [{'key': 'surface', 'value': '#abcdef'}],
                               'renderedComponentTree': [{'id': 'changed', 'parentId': 'root'}]}
        status, raw = self.post('/api/agent/prompts', followup)
        self.assertEqual(status, 200)
        self.assertIn('event: admitted', raw)
        self.assertEqual(len(self.followups), 1)
        actual = json.dumps(self.followups[0])
        self.assertIn('#abcdef', actual)
        self.assertIn('changed', actual)
        self.assertNotIn('#123456', actual)

    def test_malformed_editor_context_rejects_before_backend_delivery(self):
        malformed = self.prompt()
        malformed['context'] = ['invalid context']
        status, raw = self.post('/api/agent/prompts', malformed)
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(raw)['error'], 'invalid_editor_context')
        self.assertFalse(self.created.is_set())
        self.assertIsNone(self.received)
        self.assertEqual(self.followups, [])

    def test_close_after_terminal_completion_is_not_repeated(self):
        self.allow_create.set()
        self.allow_finish.set()
        status, raw = self.post('/api/agent/prompts', self.prompt())
        self.assertEqual(status, 200)
        self.assertIn('event: end', raw)
        self.assertEqual(self.post('/api/agent/close', {'sessionId': self.session})[0], 200)
        self.assertTrue(self.stopped.wait(5))
        self.assertEqual(self.post('/api/agent/close', {'sessionId': self.session})[0], 404)
        self.assertEqual(self.post('/api/agent/sessions', {})[0], 200)

    def test_shutdown_drains_disconnected_active_http_worker(self):
        self.allow_create.set()
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        connection.request('POST', '/api/agent/prompts', json.dumps(self.prompt()))
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertTrue(self.streamed.wait(5))
        response.close()
        connection.close()
        self.assertEqual(self.post('/api/agent/prompts', self.prompt())[0], 409)
        self.daemon.terminate()
        self.assertEqual(self.daemon.wait(timeout=10), 0)
        self.assertTrue(self.stopped.is_set(), 'Shutdown did not close admitted backend')


if __name__ == '__main__':
    unittest.main()
