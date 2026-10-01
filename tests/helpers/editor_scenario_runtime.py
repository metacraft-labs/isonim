"""Real isolated launcher/Harbor/SQLite/compiler/provider orchestration.

Only official model playback replaces external inference. The wrapper serializes
actual launch scope privately because ACP terminal env is explicit. Public context
and artifacts contain no credentials. Failure logs, catalog/source diff and real
provider identity/prompt traces are retained. Cleanup targets owned descendants.
"""
import hashlib
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
import urllib.request
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

class Runtime:
    def __init__(self, host):
        if not optional_sibling_available(HARBOR): raise FileNotFoundError('optional private Agent Harbor sibling absent')
        self.observer = process_observer()
        self.provider = Path(os.environ.get('ISONIM_HARBOR_SCENARIO_PROVIDER','/missing-provider')).resolve()
        if not self.provider.is_file() or not os.access(self.provider,os.X_OK): raise AssertionError('Set ISONIM_HARBOR_SCENARIO_PROVIDER to the built official Rust mock-agent')
        self.artifacts = Path(tempfile.mkdtemp(prefix='eac-m5-'+host+'-'))
        self.artifacts.chmod(0o700)
        self.private = self.artifacts/'private'; self.private.mkdir(mode=0o700)
        self.project = self.artifacts/'project'
        shutil.copytree(ROOT/'examples/source_project',self.project,ignore=shutil.ignore_patterns('catalog-producer*','catalog.json'))
        self.before = (self.project/'stories.nim').read_text()
        self.env = dict(os.environ)
        for key in list(self.env):
            if key.startswith('ISONIM_') or key.startswith('MOCK_AGENT_'): del self.env[key]
        self.env['ISONIM_SOURCE_FRAMEWORK'] = str(ROOT)
        build = subprocess.run([sys.executable,str(ROOT/'tools/build_source_catalog.py'),str(self.project)],env=self.env,text=True,capture_output=True,timeout=120)
        (self.artifacts/'initial-build.log').write_text(build.stdout+build.stderr)
        if build.returncode: raise AssertionError('Real initial source build failed: '+str(self.artifacts))
        scenario = (ROOT/'tests/scenarios/agent-harbor/editor-workflows.yaml').read_text()
        values = {'PROJECT':self.project,'ARTIFACTS':self.artifacts,'PYTHON':Path(sys.executable),
                  'WRAPPER':ROOT/'tools/editor_agent_env.py','PRIVATE':self.private,'CLI':ROOT/'build/bin/isonim',
                  'BARRIER':ROOT/'tests/helpers/editor_scenario_barrier.py','NETPROBE':ROOT/'tests/helpers/editor_scenario_network_probe.py'}
        for key,value in values.items(): scenario=scenario.replace('@'+key+'@',str(value))
        self.scenario = self.artifacts/'scenario.yaml'; self.scenario.write_text(scenario)
        bindir=self.artifacts/'bin'; bindir.mkdir()
        wrapper=bindir/'claude-agent-acp'
        wrapper.write_text('#!/bin/sh\nexec '+shlex.join([sys.executable,str(ROOT/'tests/helpers/editor_scenario_provider.py'),str(self.artifacts),str(self.provider),str(self.scenario)])+'\n')
        wrapper.chmod(0o755)
        self.env['PATH']=str(bindir)+os.pathsep+self.env['PATH']
        config=self.artifacts/'empty.toml'; config.write_text('')
        self.handles=[]; self.children=[]; self.readers=[]; self.readerErrors=[]
        self.lines=queue.Queue()
        self.harborBefore=set(Path(tempfile.gettempdir()).glob('isonim-harbor-*'))
        self.server=self.spawn([sys.executable,str(ROOT/'tools/editor_server.py'),'--directory',str(ROOT/'build/editor-source'),
            '--project-root',str(self.project),'--port','0','--bind','127.0.0.1','--config',str(config),
            '--daemon-binary',str(ROOT/'build/bin/isonim-review')],'launcher')
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
            identity['provider_sha256']=hashlib.sha256(self.provider.read_bytes()).hexdigest()
            (self.artifacts/'identities.json').write_text(json.dumps(identity,indent=2))
            (self.artifacts/'context.json').write_text(json.dumps({'origin':self.origin,'project':str(self.project),'repo':str(ROOT),'artifacts':str(self.artifacts)}))
            print('M5 artifacts:',self.artifacts,flush=True)
        except BaseException:
            self.close()
            raise
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
        # Save actual final source/catalog even on a failed assertion.
        if self.project.exists():
            import difflib
            (self.artifacts/'source.diff').write_text(''.join(difflib.unified_diff(self.before.splitlines(True),(self.project/'stories.nim').read_text().splitlines(True))))
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
            with sqlite3.connect(self.harborState/'daemon.sqlite') as database:
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
            secrets.extend(value for key,value in data.items() if key in ('ISONIM_EDITOR_TOKEN','browserToken','controlToken') and value)
        scanned=[]
        for filename in self.artifacts.iterdir():
            if filename.is_file() and filename.suffix in ('.json','.jsonl','.yaml','.log','.txt'):
                contents=filename.read_text()
                if any(secret in contents for secret in secrets):raise AssertionError('Credential leaked into public artifact: '+filename.name)
                scanned.append(filename.name)
        (self.artifacts/'cleanup.json').write_text(json.dumps({'owned_processes':len(owned),'readers':len(self.readers),'reaped':True,'public_secret_scan':scanned},indent=2))
