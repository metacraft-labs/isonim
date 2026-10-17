#!/usr/bin/env python3
"""Actual owning wrapper/ACP/SDK/native ACK controls, no user/model/token calls.

Changed/missing instructions are real negative launch inputs, never fabricated
ACKs. Six authority values here are inert private fixture strings solely because
this standalone stdio initialization requests no editor tools; mounted authority
is separately covered by the actual launcher/Harbor/browser zero-turn gate.
Private genuine records copied and deliberately mutated test strict validator
rejection; these copies are synthetic negatives, never new runtime evidence.
"""
from pathlib import Path
import hashlib
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from helpers.editor_sdk_runtime import ROOT,materialize,authenticate,observe_environment

base=Path(tempfile.mkdtemp(prefix='isonim-native-controls-'));base.chmod(0o700)
authenticate(ROOT/'build/editor-sdk-runtime.json')
results=[]
# Actual original default SDK spawn, bare versus transparent preload, with the
# SAME nonempty inherited options. This is independent of synthetic flag tests.
equivalence=base/'equivalence';equivalence.mkdir(mode=0o700)
private=equivalence/'private';private.mkdir(mode=0o700)
guide=private/'instructions.md';guide.write_bytes((ROOT/'prompts/ai-assistant.md').read_bytes());guide.chmod(0o600)
manifest,runtime=materialize(private)
old_options=os.environ.get('NODE_OPTIONS');old_present='NODE_OPTIONS' in os.environ
os.environ['NODE_OPTIONS']='--trace-warnings'
try:
    observed_env=observe_environment(private,runtime)
    config=json.loads((private/'sdk-observer-config.json').read_text())
    config.update(sdk=runtime['paths']['sdk'],instructions=str(guide),command=runtime['paths']['nativeCommand'])
    for mode in ['baseline','observed']:
        configured={**config,'result':str(private/(mode+'.json'))}
        filename=private/(mode+'-driver.json');filename.write_text(json.dumps(configured));filename.chmod(0o600)
        with (private/(mode+'.log')).open('w') as output:
            os.chmod(output.name,0o600)
            subprocess.run([runtime['paths']['node'],str(ROOT/'tests/helpers/editor_sdk_native_initialization.mjs'),str(filename)],
                cwd=equivalence,env=dict(os.environ) if mode=='baseline' else observed_env,stdout=output,stderr=subprocess.STDOUT,check=True,timeout=45)
    bare=json.loads((private/'baseline.json').read_text());observed=json.loads((private/'observed.json').read_text())
    assert all(bare[key]==observed[key] for key in ['argvSha256','environmentSha256','cwdSha256'])
    assert bare['pidIdentity']['loadedSha256']==observed['pidIdentity']['loadedSha256']
    assert bare['nativeReaped'] and observed['nativeReaped'] and observed['parentNodeOptionsRestored'] and observed['parentObserverConfigAbsent']
    print(json.dumps({'actualBareObservedEqual':True,'nonemptyOriginalNodeOptions':True,'artifacts':str(equivalence)}),flush=True)
finally:
    if old_present:os.environ['NODE_OPTIONS']=old_options
    else:os.environ.pop('NODE_OPTIONS',None)
for mode in ['positive','changed','missing']:
    artifacts=base/mode;artifacts.mkdir(mode=0o700);private=artifacts/'private';private.mkdir(mode=0o700)
    guide=private/'instructions.md';guide.write_bytes((ROOT/'prompts/ai-assistant.md').read_bytes());guide.chmod(0o600)
    manifest,runtime=materialize(private);provider=runtime['paths']['provider'];node=runtime['paths']['node']
    instruction=guide
    if mode=='changed':
        instruction=private/'changed.md';instruction.write_bytes(guide.read_bytes()+b'\nActual negative launch append.\n');instruction.chmod(0o600)
    argv=[sys.executable,str(ROOT/'tools/agent_session_launcher.py')]+(['--instructions',str(instruction)] if mode!='missing' else [])+['--',sys.executable,str(ROOT/'tests/helpers/editor_real_provider.py'),str(artifacts),provider,str(manifest)]
    env=dict(os.environ)
    for key in ('ENDPOINT','WORKSPACE','INSTANCE','EPOCH','TOKEN','CLI_DIR'):env['ISONIM_EDITOR_'+key]='inert-zero-tool-control'
    env['NODE_OPTIONS']='--trace-warnings'
    log=(private/'stderr.log').open('wb');os.chmod(log.name,0o600)
    child=subprocess.Popen(argv,cwd=artifacts,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log)
    responses=queue.Queue();errors=[];started=time.monotonic();native=None
    def drain():
        try:
            for line in child.stdout:responses.put(json.loads(line))
        except BaseException as error:errors.append(type(error).__name__)
    reader=threading.Thread(target=drain);reader.start()
    def request(index,method,params):
        child.stdin.write((json.dumps({'jsonrpc':'2.0','id':index,'method':method,'params':params})+'\n').encode());child.stdin.flush()
        deadline=time.monotonic()+30
        while time.monotonic()<deadline:
            try:value=responses.get(timeout=min(1,deadline-time.monotonic()))
            except queue.Empty:
                if child.poll() is not None:raise AssertionError('Provider exited before actual ACK')
                continue
            if value.get('id')==index and 'method' not in value:
                if 'error' in value:raise AssertionError('Actual ACP rejected '+method)
                return value['result']
        raise AssertionError('Original bounded30s actual ACP ACK expired')
    try:
        request(1,'initialize',{'protocolVersion':1,'clientCapabilities':{'fs':{'readTextFile':False,'writeTextFile':False},'terminal':False},'clientInfo':{'name':'isonim-zero-inference-control','version':'1'}})
        sid=request(2,'session/new',{'cwd':str(artifacts),'mcpServers':[]})['sessionId']
        files=list((private/'sdk-native').glob('sdk-native-*.json'));assert len(files)==1
        state=json.loads(files[0].read_text());native=state['nativePid'];assert state['identity']['loadedMatches'] is True
        request(3,'session/close',{'sessionId':sid})
        deadline=time.monotonic()+15
        while (Path('/proc')/str(native)).exists() and time.monotonic()<deadline:time.sleep(.02)
        assert not (Path('/proc')/str(native)).exists(),'Native must reap before finally'
    finally:
        child.stdin.close()
        try:child.wait(timeout=15)
        except subprocess.TimeoutExpired:child.terminate();child.wait(timeout=15)
        reader.join(5);assert not reader.is_alive();child.stdout.close();log.close();assert not errors,errors
        if native and (Path('/proc')/str(native)).exists():os.kill(native,15);raise AssertionError('Emergency native reap required')
    authenticate(manifest,provider)
    command=[node,str(ROOT/'tests/helpers/editor_sdk_delivery_evidence.mjs'),str(private/'sdk-native'),str(private/'real-provider-wire.jsonl'),str(guide),'/unused-zero-checkpoints',str(manifest),'0']
    def oracle(command,name):
        with (private/(name+'.log')).open('w') as output:
            os.chmod(output.name,0o600)
            return subprocess.run(command,stdout=output,stderr=subprocess.STDOUT,timeout=30).returncode
    exit=oracle(command,'oracle');assert (exit==0)==(mode=='positive'),'Actual changed/missing controls must reject exact append'
    if mode=='positive':
        state=json.loads(files[0].read_text());assert state['spawn']['parentNodeOptionsRestored'] is True
        assert state['spawn']['nodeOptionsRestored'] is True
        for group,key in [('spawn','parentNodeOptionsRestored'),('spawn','nodeOptionsRestored'),('spawn','observerEnvAbsent'),('identity','loadedMatches'),('identity','cwdMatches')]:
            for value in [False,None,'true',1,'missing']:
                negative=private/(group+'-'+key+'-'+str(value));negative.mkdir(mode=0o700)
                altered=json.loads(json.dumps(state))
                if value=='missing':del altered[group][key]
                else:altered[group][key]=value
                target=negative/files[0].name;target.write_text(json.dumps(altered));target.chmod(0o600)
                assert oracle([*command[:2],str(negative),*command[3:]],negative.name)!=0,'Synthetic invalid flag wrongly accepted'
    result={'kind':mode,'artifacts':str(artifacts),'oracleExit':exit,'setupSucceeded':True,'nativePid':native,'reapedBeforeFinally':True,'providerExit':child.returncode,'readerReaped':True,'seconds':time.monotonic()-started}
    results.append(result);(base/'results.json').write_text(json.dumps(results,indent=2));print(json.dumps(result),flush=True)
print('PASS actual zero-user native controls and strict private validator negatives',flush=True)
