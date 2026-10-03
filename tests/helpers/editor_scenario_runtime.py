"""Real isolated launcher/Harbor/SQLite/compiler/provider orchestration.

Only official model playback replaces external inference. The wrapper serializes
actual launch scope privately because ACP terminal env is explicit. Public context
and artifacts contain no credentials. Failure logs, catalog/source diff and real
provider identity/prompt traces are retained. Cleanup targets owned descendants.
"""
import hashlib
from contextlib import closing
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
import urllib.request
from helpers.editor_sdk_runtime import materialize
from helpers.editor_process_observer import process_observer, optional_sibling_available

ROOT = Path(__file__).resolve().parents[2]
HARBOR = ROOT.parent / 'agent-harbor'

def wait(predicate, label, seconds=70):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value: return value
        time.sleep(.03)
    raise AssertionError('Observable barrier timed out: '+label)

def post(url, data, token=''):
    req = urllib.request.Request(url, data=json.dumps(data).encode(),headers={'Content-Type':'application/json','X-IsoNim-Control':token})
    with urllib.request.urlopen(req,timeout=70) as response: return json.load(response)

def private_credentials(data):
    """Find named credentials in mapping or array protocol evidence.

    Tool traces are arrays, while registrations and scope files are mappings.
    Scalars elsewhere are legitimate JSON; a named credential must be a string
    (or null/empty when absent), so malformed evidence fails explicitly.
    """
    if isinstance(data, dict):
        for key, value in data.items():
            if key in ('ISONIM_EDITOR_TOKEN', 'browserToken', 'controlToken'):
                if value is not None and not isinstance(value, str):
                    raise AssertionError('Malformed private credential: '+key)
                if value:
                    yield value
            else:
                yield from private_credentials(value)
    elif isinstance(data, list):
        for value in data:
            yield from private_credentials(value)

class Runtime:
    def __init__(self, host, *, real_provider=None, project_source=None,
                 editor_directory=None, source_file="stories.nim", instructions_path=None, real_model=None, scenario_path=None, observe_scenario_wire=False):
        self.source_file = source_file
        if not optional_sibling_available(HARBOR): raise FileNotFoundError('optional private Agent Harbor sibling absent')
        self.observer = process_observer()
        self.daemon = (ROOT/'build/bin/isonim-review').resolve()
        if self.daemon.parent!=(ROOT/'build/bin').resolve() or not self.daemon.is_file() or not os.access(self.daemon,os.X_OK):
            raise AssertionError('Scenario daemon must be an executable in this workspace build/bin')
        self.provider = Path(real_provider or os.environ.get('ISONIM_HARBOR_SCENARIO_PROVIDER','/missing-provider')).resolve()
        if not self.provider.is_file() or not os.access(self.provider,os.X_OK): raise AssertionError('Set ISONIM_HARBOR_SCENARIO_PROVIDER to the built official Rust mock-agent')
        root = Path(tempfile.mkdtemp(prefix='eac-m5-'+host+'-')).resolve()
        root.chmod(0o700)
        self.project = root/'project'
        shutil.copytree(project_source or ROOT/'examples/source_project',self.project,ignore=shutil.ignore_patterns('catalog-producer*','catalog.json','build','node_modules','.git'))
        # Only the bound workspace crosses Harbor's private /tmp. Keep fixture
        # execution, barriers and artifacts apart from source/catalog inputs.
        self.artifacts = self.project/'.scenario'
        self.artifacts.mkdir(mode=0o700)
        self.private = self.artifacts/'private'; self.private.mkdir(mode=0o700)
        self.before = (self.project/self.source_file).read_text()
        self.env = dict(os.environ)
        for key in list(self.env):
            if key.startswith('ISONIM_') or key.startswith('MOCK_AGENT_'): del self.env[key]
        self.env['ISONIM_SOURCE_FRAMEWORK'] = str(ROOT)
        build_argv = [sys.executable,str(ROOT/'tools/build_source_catalog.py'),str(self.project)]
        build = subprocess.run(build_argv,cwd=self.project,env=self.env,text=True,capture_output=True,timeout=120)
        (self.artifacts/'initial-build.log').write_text(build.stdout+build.stderr)
        if build.returncode: raise AssertionError('Real initial source build failed: '+str(self.artifacts))
        scenario = Path(scenario_path or ROOT/'tests/scenarios/agent-harbor/editor-workflows.yaml').read_text()
        values = {'PROJECT':self.project,'ARTIFACTS':self.artifacts,'PYTHON':Path(sys.executable),
                  'WRAPPER':ROOT/'tools/editor_agent_env.py','PRIVATE':self.private,'CLI':ROOT/'build/bin/isonim',
                  'BARRIER':ROOT/'tests/helpers/editor_scenario_barrier.py','NETPROBE':ROOT/'tests/helpers/editor_scenario_network_probe.py'}
        for key,value in values.items(): scenario=scenario.replace('@'+key+'@',str(value))
        self.scenario = self.artifacts/'scenario.yaml'; self.scenario.write_text(scenario)
        if real_provider:
            self.sdk_manifest,self.sdk_runtime=materialize(self.private,self.provider)
        bindir=self.artifacts/'bin'; bindir.mkdir()
        wrapper=bindir/'claude-agent-acp'
        wrapper_args = ([sys.executable,str(ROOT/'tests/helpers/editor_real_provider.py'),str(self.artifacts),str(self.provider),str(self.sdk_manifest)] if real_provider else
                        [sys.executable,str(ROOT/'tests/helpers/editor_scenario_provider.py'),str(self.artifacts),str(self.provider),str(self.scenario)]+(['--observe-wire'] if observe_scenario_wire else []))
        wrapper.write_text('#!/bin/sh\nexec '+shlex.join(wrapper_args)+'\n')
        wrapper.chmod(0o755)
        self.env['PATH']=str(bindir)+os.pathsep+self.env['PATH']
        config=self.artifacts/'empty.toml'
        scoped_instructions = self.private/'instructions.md'
        if real_provider:
            shutil.copyfile(instructions_path or ROOT/'prompts/ai-assistant.md', scoped_instructions)
            scoped_instructions.chmod(0o600)
        config.write_text(('[agent]\nassistant_prompt_path='+json.dumps(str(scoped_instructions))+'\n'+
            ('model='+json.dumps(real_model)+'\n' if real_model is not None else '')) if real_provider else '')
        self.handles=[]; self.children=[]; self.readers=[]; self.readerErrors=[]
        self.handoffStop=threading.Event()
        self.lines=queue.Queue()
        self.harborBefore=set(Path(tempfile.gettempdir()).glob('isonim-harbor-*'))
        self.server=self.spawn([sys.executable,str(ROOT/'tools/editor_server.py'),'--directory',str(editor_directory or ROOT/'build/editor-source'),
            '--project-root',str(self.project),'--port','0','--bind','127.0.0.1','--config',str(config),
            '--daemon-binary',str(self.daemon)],'launcher')
        def ready():
            if self.server.poll() is not None: raise AssertionError('Real launcher exited')
            while not self.lines.empty():
                line=self.lines.get_nowait()
                match=re.search(r'Editor listening on (http://[^\s]+)',line)
                if match: return match[1].rstrip('/')
        try:self.origin=wait(ready,'launcher ready',900)
        except BaseException:
            self.close()
            raise
        try:
            owned = self.observer.snapshot()
            pids = {self.server.pid}
            while True:
                added = {pid for pid,row in owned.items() if row[0] in pids} - pids
                if not added:break
                pids.update(added)
            # Harbor's server-start command may detach its service. Its actual
            # newly created private pid file identifies that owned service even
            # after reparenting; no unrelated pre-existing service is eligible.
            states=set(Path(tempfile.gettempdir()).glob('isonim-harbor-*'))-self.harborBefore
            candidates=[]
            observations=[]
            for state in states:
                pidfile=state/'server.pid'
                if not pidfile.exists():continue
                declaration=json.loads(pidfile.read_text())
                pid=declaration['pid']
                identity=owned.get(pid)
                observations.append({'state':str(state),'pidfile':declaration,'identity':identity})
                if identity is None:continue
                argv=identity[2] or []
                executable=(identity[3] or '').removesuffix(' (deleted)')
                if (executable==str((HARBOR/'build/bin/ah').resolve()) and
                    len(argv)>1 and argv[0]==str(HARBOR/'build/bin/ah') and
                    '--pid-file' in argv and argv[argv.index('--pid-file')+1]==str(pidfile) and
                    '--rest-port' in argv and int(argv[argv.index('--rest-port')+1])==declaration['rest']['port'] and
                    declaration['rest']['host']=='127.0.0.1'):
                    candidates.append((state,pid,owned[pid]))
            (self.artifacts/'harbor-service-observations.json').write_text(json.dumps(observations,indent=2))
            if len(candidates)!=1:raise AssertionError('Exactly one actual private Harbor pid-file service required: '+repr([(str(s),p) for s,p,r in candidates]))
            self.harborState,self.harborPid,self.harborIdentity=candidates[0]
            if not (self.harborState/'daemon.sqlite').read_bytes().startswith(b'SQLite format 3\0'):
                raise AssertionError('Actual private Harbor SQLite required')
            match = re.search(r'via REST at (http://127\.0\.0\.1:\d+)',(self.artifacts/'launcher.log').read_text())
            if not match:raise AssertionError('Production local Harbor REST selection required')
            self.harborUrl = match[1]
            actual_binary=Path('/proc')/str(self.harborPid)/'exe' if sys.platform=='linux' else Path(self.harborIdentity[3])
            (self.artifacts/'owned-harbor.json').write_text(json.dumps({'state':str(self.harborState),'pid':self.harborPid,'identity':self.harborIdentity,'executable_sha256':hashlib.sha256(actual_binary.read_bytes()).hexdigest(),'rest':self.harborUrl}))
            self.recordOriginalHandoff()
            self.host=None;self.hostOrigin=None;self.scope=None
            if host=='native':
                html=urllib.request.urlopen(self.origin).read().decode()
                bootstrap=json.loads(re.search(r'controlMeta.content=("[^"]+")',html)[1])
                self.bootstrap=bootstrap
                nativeenv=dict(self.env); nativeenv['ISONIM_EDITOR_BROWSER_BOOTSTRAP']=bootstrap
                self.host=self.spawn([str(ROOT/'build/bin/editor-scenario-host'),self.origin,str(self.private/'registration.json')],'host',nativeenv)
                def nativeReady():
                    if self.host.poll() is not None: raise AssertionError('Native production host exited')
                    while not self.lines.empty():
                        match=re.search(r'HOST_READY (\d+)',self.lines.get_nowait())
                        if match:return 'http://127.0.0.1:'+match[1]
                try:self.hostOrigin=wait(nativeReady,'native production VM ready')
                except BaseException:
                    self.close()
                    raise
                self.scope=json.loads((self.private/'registration.json').read_text())
            identity={repo.name:{'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),
                 'diff_sha256':hashlib.sha256(subprocess.check_output(['git','diff','HEAD'],cwd=repo)).hexdigest()} for repo in (ROOT,HARBOR,ROOT.parent/'nim-agents')}
            daemonPids=[pid for pid,row in owned.items() if pid in pids and row[2] and row[2][0]==str(self.daemon)]
            if len(daemonPids)!=1:raise AssertionError('Exactly one actual selected daemon required')
            daemonPid=daemonPids[0]
            loaded=Path('/proc')/str(daemonPid)/'exe' if sys.platform=='linux' else self.daemon
            identity['daemon']={'pid':daemonPid,'identity':owned[daemonPid],'binary':str(self.daemon),'loaded_sha256':hashlib.sha256(loaded.read_bytes()).hexdigest()}
            identity['provider_sha256']=hashlib.sha256(self.provider.read_bytes()).hexdigest()
            (self.artifacts/'identities.json').write_text(json.dumps(identity,indent=2))
            (self.artifacts/'context.json').write_text(json.dumps({'origin':self.origin,'project':str(self.project),'repo':str(ROOT),'artifacts':str(self.artifacts)}))
            print('M5 artifacts:',self.artifacts,flush=True)
        except BaseException:
            self.close()
            raise
    def recordOriginalHandoff(self):
        # Read only THIS owned service's actual persisted launch configuration.
        # Match the exact bound project and provider wrapper, never host file
        # globs or an older successful session. Publish a non-secret filepath
        # privately so real ACP terminals can consume the original handoff.
        def observe():
            try:
                while not self.handoffStop.is_set():
                    with closing(sqlite3.connect(self.harborState/'daemon.sqlite')) as database:
                        rows=database.execute('select id, workspace_path, agent_config from sessions').fetchall()
                    snapshot=self.private/'provider-scope.json'
                    if not snapshot.exists():
                        self.handoffStop.wait(.03);continue
                    current=json.loads(snapshot.read_text())
                    matches=[]
                    for sid,workspace,configuration in rows:
                        if workspace!=str(self.project):continue
                        launch=json.loads(configuration or '{}').get('acp_stdio_launch_command',{})
                        args=launch.get('args',[])
                        if str(self.artifacts/'bin/claude-agent-acp') not in args:continue
                        positions=[index for index,arg in enumerate(args) if arg=='--environment']
                        if len(positions)!=2 or any(index+1>=len(args) for index in positions):raise AssertionError('Provider and terminal launcher scoped boundaries required')
                        filenames=[args[index+1] for index in positions]
                        if len(set(filenames))!=1:raise AssertionError('Provider and real terminals must use the SAME original private handoff')
                        filename=Path(filenames[0])
                        if not filename.is_absolute() or filename.name!='environment.json':
                            raise AssertionError('Actual absolute production handoff required')
                        try: original=json.loads(filename.read_text())
                        except FileNotFoundError:continue
                        # The exact current provider's private scope selects its
                        # session even when this project has other chat rows.
                        if {key:value for key,value in original.items() if key!='ISONIM_EDITOR_ENDPOINT'} != {
                            key:value for key,value in current.items() if key!='ISONIM_EDITOR_ENDPOINT'}:continue
                        matches.append({'session':sid,'environment':str(filename),'current_provider_scope_matches':True})
                    if len(matches)>1:raise AssertionError('Exactly one current actual provider launch required')
                    if matches:
                        filename=self.private/'.original-handoff.pending'
                        fd=os.open(filename,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
                        with os.fdopen(fd,'w') as output:json.dump(matches[0],output)
                        os.replace(filename,self.private/'original-handoff.json')
                        return
                    self.handoffStop.wait(.03)
            except BaseException as error:self.readerErrors.append(repr(error))
        reader=threading.Thread(target=observe,daemon=True)
        self.readers.append(reader);reader.start()

    def spawn(self,args,name,env=None):
        log=(self.artifacts/(name+'.log')).open('w');self.handles.append(log)
        child=subprocess.Popen(args,env=env or self.env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,start_new_session=True)
        self.children.append(child)
        def drain():
            try:
                for line in child.stdout:
                    log.write(line);log.flush();self.lines.put(line)
            except BaseException as error:self.readerErrors.append(repr(error))
        reader=threading.Thread(target=drain,daemon=True);self.readers.append(reader);reader.start()
        return child
    def freshNative(self):
        filename=self.private/'reload-registration.json'
        environment={**self.env,'ISONIM_EDITOR_BROWSER_BOOTSTRAP':self.bootstrap}
        child=self.spawn([str(ROOT/'build/bin/editor-scenario-host'),self.origin,str(filename)],'reload-host',environment)
        def ready():
            if child.poll() is not None:raise AssertionError('Fresh native VM exited')
            while not self.lines.empty():
                match=re.search(r'HOST_READY (\d+)',self.lines.get_nowait())
                if match:return 'http://127.0.0.1:'+match[1]
        host=wait(ready,'fresh native production VM from actual persisted catalog')
        return post(host,{}),json.loads(filename.read_text())
    def action(self,**data): return post(self.hostOrigin,data)
    def active(self):
        state=self.action()
        return next(row for row in state['chats'] if row['id']==state['active'])
    def activeStatus(self): return self.action(action='active-status')
    def phase(self,number): (self.artifacts/'phase').write_text(str(number))
    def rpc(self,method,params,token=None):
        data={key:self.scope[key] for key in ('workspace','instance','epoch')};data.update(params)
        return post(self.origin+'/api/editor/rpc',{'jsonrpc':'2.0','id':1,'method':method,'params':data},token or self.scope['browserToken'])
    def cli(self,args,expected=0):
        scope=self.scope
        token=scope['controlToken']
        # Tool operations are conversation-bound. Observation uses the actual
        # live provider credential, never the broader browser registration's
        # empty-conversation token. The host proxy resolves the same callback.
        if args[0]=='wait':token=json.loads((self.private/'provider-scope.json').read_text())['ISONIM_EDITOR_TOKEN']
        env={**self.env,'ISONIM_EDITOR_ENDPOINT':self.origin,'ISONIM_EDITOR_WORKSPACE':scope['workspace'],
          'ISONIM_EDITOR_INSTANCE':scope['instance'],'ISONIM_EDITOR_EPOCH':scope['epoch'],'ISONIM_EDITOR_TOKEN':token}
        run=subprocess.run([str(ROOT/'build/bin/isonim'),'editor',*args],env=env,capture_output=True,text=True,timeout=70)
        if run.returncode!=expected:raise AssertionError(f'CLI exit {run.returncode} expected {expected}: {run.stdout} {run.stderr}')
        return json.loads(run.stdout)
    def turn(self,phase,text):
        self.phase(phase); self.action(action='send',text=text)
        wait(lambda:not self.active()['busy'],'native turn '+str(phase))
        if self.action()['errors']: raise AssertionError(self.action()['errors'])
    def providerIdentity(self):
        table=self.observer.snapshot()
        candidates={pid:row for pid,row in table.items() if row[2] and row[2][0]==str(self.provider) and str(self.scenario) in row[2]}
        if len(candidates)!=1:raise AssertionError('Expected one exact real provider: '+str(candidates))
        result={str(pid):list(row) for pid,row in candidates.items()}
        (self.artifacts/'provider-identity.json').write_text(json.dumps(result,indent=2))
        return result
    def close(self):
        self.handoffStop.set()
        # Save actual final source/catalog even on a failed assertion.
        if self.project.exists():
            import difflib
            (self.artifacts/'source.diff').write_text(''.join(difflib.unified_diff(self.before.splitlines(True),(self.project/self.source_file).read_text().splitlines(True))))
        owned=set()
        table=self.observer.snapshot()
        for child in self.children: owned.add(child.pid)
        if hasattr(self,'harborPid') and self.harborPid in table and table[self.harborPid][1]==self.harborIdentity[1]:owned.add(self.harborPid)
        while True:
            added={pid for pid,row in table.items() if row[0] in owned}-owned
            if not added:break
            owned.update(added)
        if hasattr(self,'harborState'):
            import sqlite3
            with closing(sqlite3.connect(self.harborState/'daemon.sqlite')) as database:
                events=[{'session':sid,'kind':kind,'payload':json.loads(payload)}
                        for sid,kind,payload in database.execute('select session_id,kind,payload from session_events')]
            (self.artifacts/'harbor-events.json').write_text(json.dumps(events,indent=2))
            log=(self.harborState/'harbor.log').read_text()
            private=self.private/'provider-scope.json'
            if private.exists():
                for value in json.loads(private.read_text()).values():
                    if value:log=log.replace(value,'[private-scope]')
            (self.artifacts/'harbor.log').write_text(log)
        for child in reversed(self.children):
            if child.poll() is None:
                os.killpg(child.pid,signal.SIGTERM)
                try:child.wait(timeout=10)
                except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait(timeout=5)
        # Launcher can leave a producer service in its own session. Only captured
        # owned descendants with unchanged kernel identity are eligible here.
        remaining=self.observer.snapshot()
        for pid in owned:
            if pid in remaining and pid in table and remaining[pid][1]==table[pid][1]:
                try:os.kill(pid,signal.SIGTERM)
                except ProcessLookupError:pass
        def reaped():
            current=self.observer.snapshot()
            return not any(pid in current and current[pid][1]==table[pid][1] for pid in owned if pid in table)
        wait(reaped,'owned cleanup',15)
        for reader in self.readers:
            reader.join(timeout=5)
            if reader.is_alive():raise AssertionError('Owned stdout reader did not reach EOF')
        for child in self.children:
            if child.stdout:child.stdout.close()
        for handle in self.handles:handle.close()
        if self.readerErrors:raise AssertionError('Owned log reader failed: '+repr(self.readerErrors))
        secrets=[]
        if hasattr(self,'bootstrap'):secrets.append(self.bootstrap)
        for filename in self.private.glob('*.json'):
            data=json.loads(filename.read_text())
            secrets.extend(private_credentials(data))
        scanned=[]
        for filename in self.artifacts.iterdir():
            if filename.is_file() and filename.suffix in ('.json','.jsonl','.yaml','.log','.txt'):
                contents=filename.read_text()
                if any(secret in contents for secret in secrets):raise AssertionError('Credential leaked into public artifact: '+filename.name)
                scanned.append(filename.name)
        (self.artifacts/'cleanup.json').write_text(json.dumps({'owned_processes':len(owned),'readers':len(self.readers),'reaped':True,'public_secret_scan':scanned},indent=2))


def scripted_terminal_fence(wire, turn):
    """Actual per-turn runCmd completion; None means the producer is still busy.

    This parser never supplies RPC replies or invents terminal completion. Its
    caller authenticates the current fully forwarded, zero-inflight ACP journal.
    Official playback currently emits no release request; every emitted release
    is nevertheless required to have its original successful response.
    """
    sha=lambda value:hashlib.sha256(json.dumps(value,sort_keys=True).encode()).hexdigest()
    prompts=[(i,row['message']) for i,row in enumerate(wire) if row['direction']=='request' and row['message'].get('method')=='session/prompt']
    if len(prompts)>turn:raise AssertionError('Later turn cannot satisfy a scripted terminal fence')
    if len(prompts)<turn:return None
    start,prompt=prompts[-1];sid=prompt.get('params',{}).get('sessionId')
    if type(sid) is not str or not sid or any(message.get('params',{}).get('sessionId')!=sid for _,message in prompts):raise AssertionError('Same actual scripted session required')
    def reply(index,request,direction):
        identity=request.get('id')
        if type(identity) not in (int,str) or identity=='':raise AssertionError('Typed actual RPC request ID required')
        found=[(i,row['message']) for i,row in enumerate(wire) if i>index and row['direction']==direction and 'method' not in row['message'] and 'id' in row['message'] and type(row['message']['id']) is type(identity) and row['message']['id']==identity]
        if len(found)>1:raise AssertionError('Duplicate actual scripted RPC reply')
        if not found:return None
        if 'error' in found[0][1] or type(found[0][1].get('result')) is not dict:raise AssertionError('Actual scripted RPC failed')
        return found[0]
    new=[(i,row['message']) for i,row in enumerate(wire) if row['direction']=='request' and row['message'].get('method')=='session/new']
    if len(new)!=1:raise AssertionError('One actual scripted session creation required')
    new_reply=reply(new[0][0],new[0][1],'response')
    if new_reply is None:return None
    if new_reply[1]['result'].get('sessionId')!=sid:raise AssertionError('Scripted terminal must use actual created session')
    prompt_reply=reply(start,prompt,'response')
    if prompt_reply is None:return None
    if prompt_reply[1]['result'].get('stopReason')!='end_turn':raise AssertionError('Actual scripted prompt did not end successfully')
    declarations=[];creates=[];updates=[]
    for i,row in enumerate(wire[start+1:],start+1):
        message=row['message'];params=message.get('params',{})
        if row['direction']!='response':continue
        method=message.get('method')
        if method=='terminal/create':
            if params.get('sessionId')!=sid:raise AssertionError('Terminal create targets another session')
            creates.append((i,message))
        elif method=='session/update':
            update=params.get('update',{})
            if update.get('sessionUpdate') in ('tool_call','tool_call_update'):
                if params.get('sessionId')!=sid:raise AssertionError('Scripted tool targets another session')
                if update.get('sessionUpdate')=='tool_call' and any(item.get('type')=='terminal' for item in update.get('content',[])):declarations.append((i,update))
                elif update.get('sessionUpdate')=='tool_call_update':updates.append((i,update))
    if not declarations or not creates:return None
    if len(declarations)!=1 or len(creates)!=1:raise AssertionError('Exactly one actual scripted terminal per turn required')
    declaration_order,declaration=declarations[0];create_order,create=creates[0]
    if declaration_order>=create_order:raise AssertionError('Actual terminal declaration must precede create')
    created=reply(create_order,create,'request')
    if created is None:return None
    terminal=created[1]['result'].get('terminalId');tool=declaration.get('toolCallId')
    if any(type(value) is not str or not value for value in (terminal,tool)):raise AssertionError('Actual terminal and tool identities required')
    raw=declaration.get('rawInput');params=create.get('params');content=declaration.get('content')
    if type(raw) is not dict or type(params) is not dict or type(content) is not list:raise AssertionError('Typed actual terminal declaration required')
    terminals=[item for item in content if type(item) is dict and item.get('type')=='terminal']
    args=params.get('args')
    if declaration.get('kind')!='execute' or declaration.get('title')!='runCmd' or len(terminals)!=1 or terminals[0].get('terminalId')!=tool:raise AssertionError('Actual declared runCmd tool identity required')
    if type(args) is not list or not args or any(type(value) is not str for value in args) or type(raw.get('cmd')) is not str or raw['cmd']!=args[-1] or type(raw.get('cwd')) is not str or raw['cwd']!=params.get('cwd'):raise AssertionError('Actual declared command/cwd must match terminal create')
    for i,row in enumerate(wire[:start]):
        message=row['message']
        if row['direction']=='response' and message.get('method')=='terminal/create':
            previous=reply(i,message,'request')
            if previous and previous[1]['result'].get('terminalId')==terminal:raise AssertionError('Previous turn terminal cannot satisfy current turn')
    output=[];release=[];successful_exits=[]
    for i,row in enumerate(wire[start+1:],start+1):
        message=row['message'];method=message.get('method')
        if row['direction']!='response' or method not in ('terminal/output','terminal/release'):continue
        params=message.get('params',{})
        if params.get('sessionId')!=sid or params.get('terminalId')!=terminal:raise AssertionError('Actual RPC targets wrong scripted terminal/session')
        result=reply(i,message,'request')
        if result is None:return None
        (output if method=='terminal/output' else release).append({'requestOrder':i,'replyOrder':result[0],'requestIdSha256':sha(message['id'])})
        if method=='terminal/output':
            value=result[1]['result'];status=value.get('exitStatus')
            if status is not None:
                if type(status) is not dict or type(status.get('exitCode')) is not int or status['exitCode']!=0 or value.get('isComplete') is not True:raise AssertionError('Actual scripted terminal did not exit successfully')
                successful_exits.append(result[0])
    if not output or not successful_exits:return None
    completed=[i for i,update in updates if update.get('toolCallId')==tool and update.get('status')=='completed']
    if any(update.get('toolCallId')==tool and update.get('status') in ('failed','cancelled') for _,update in updates):raise AssertionError('Actual scripted tool failed')
    if not completed:return None
    if len(completed)!=1 or completed[0]<=successful_exits[-1]:raise AssertionError('Actual completed tool update must follow successful terminal reply')
    return {'complete':True,'turn':turn,'sessionIdSha256':sha(sid),'promptRequestIdSha256':sha(prompt['id']),
        'toolCallIdSha256':sha(tool),'terminalIdSha256':sha(terminal),'promptRequestOrder':start,'promptReplyOrder':prompt_reply[0],
        'createRequestOrder':create_order,'createReplyOrder':created[0],'successfulExitReplyOrder':successful_exits[-1],
        'completedToolOrder':completed[0],'outputReplies':output,'releaseReplies':release}


def authenticated_scripted_terminal_fence(private, turn, writers):
    """Live actual journal authentication, not an unjournaled JSON snapshot."""
    from helpers.editor_provider_closure import authenticate_progress
    try:
        progress=authenticate_progress(private,writers['observer'])
    except (AssertionError,FileNotFoundError,json.JSONDecodeError):
        # A concurrently growing journal or still-unforwarded observation is
        # not ready. The existing absolute turn deadline bounds this polling;
        # final close independently requires strict complete authentication.
        return None
    data=(private/'real-provider-wire.jsonl').read_bytes()
    if hashlib.sha256(data).hexdigest()!=progress['traceSha256']:return None
    proof=scripted_terminal_fence([json.loads(line) for line in data.splitlines()],turn)
    if proof is None:return None
    proof.update(frames=progress['frames'],traceSha256=progress['traceSha256'],progressChain=progress['chain'],
        ingressChain=progress['ingress']['chain'],writers=writers,
        sourceSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    return proof
