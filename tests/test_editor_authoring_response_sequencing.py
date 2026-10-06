#!/usr/bin/env python3
"""Official Rust scripted decisions, real browser/host/compiler/CLI/close.

Only the model response and prescribed tools are scenario playback. A fixed
scenario nonce exercises the actual shared mounted response predicates and host
failure ordering, not Claude memory/delivery. Both successful and false nonce or
HTML cases must execute two prompts/eight applied scoped operations, durable
compiler/DOM, two same actual Rust provider checkpoints and genuine close/reap
BEFORE the shared host response oracle can fail. No fabricated process/ACK/DOM.
"""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from helpers.editor_scenario_runtime import Runtime,ROOT,wait,authenticated_scripted_terminal_fence
from helpers.editor_authoring_operations import prove_operations
from helpers.editor_authoring_assistant_evidence import validate_assistant_evidence
from helpers.editor_authoring_responses import validate_responses
from helpers.editor_provider_closure import capture_writers,wait_completion

results=[]
for case,(mode,response) in enumerate([('contamination','memory-sequencing-fixture capture'),('success','memory-sequencing-fixture HTML capture'),('nonce','HTML capture'),('html','memory-sequencing-fixture capture')]):
    fixture=Path(tempfile.mkdtemp(prefix='isonim-response-scenario-'));fixture.chmod(0o700)
    scenario=fixture/'scenario.yaml'
    template=(ROOT/'tests/scenarios/agent-harbor/authoring-response-sequencing.yaml').read_text().replace('@RESPONSE@',response)
    if mode=='contamination':template=template.replace(' > "@PRIVATE@/sequence-result-$state-4.json"','')
    scenario.write_text(template)
    runtime=Runtime('authoring-sequence-case-'+str(case),project_source=ROOT.parent/'web-site-prototypes/grip/isonim',
        editor_directory=ROOT/'build/editor-authoring',source_file='src/editor/catalog.nim',scenario_path=scenario,observe_scenario_wire=True)
    observed={};proofs={};responses={1:{},2:{}};prior=set();started=time.monotonic_ns()
    try:
        context=json.loads(runtime.controllerContext.read_text());context['scriptedNonce']='memory-sequencing-fixture'
        runtime.controllerContext.write_text(json.dumps(context))
        child=runtime.spawn([os.environ.get('ISONIM_SCENARIO_NODE','node'),str(ROOT/'tests/test_editor_authoring_real_gui.mjs'),str(runtime.controllerContext)],'sequencing-browser')
        while child.poll() is None:
            if runtime.preparationClock.elapsed(started)>300:raise AssertionError('Original browser lifetime300s exceeded')
            phase=runtime.artifacts/'phase';value=phase.read_text() if phase.exists() else ''
            if value in ('first-awaiting-terminal','second-awaiting-terminal'):
                turn=1 if value.startswith('first') else 2
                fence_writers=capture_writers(runtime)
                proof=authenticated_scripted_terminal_fence(runtime.private,turn,fence_writers)
                if proof is not None:
                    filename=runtime.private/('scripted-turn-'+str(turn)+'-terminal-fence.json')
                    fd=os.open(filename,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
                    with os.fdopen(fd,'w') as output:json.dump(proof,output)
                    phase.write_text(value.replace('awaiting-terminal','terminal-fenced'))
            if value in ('first-complete','second-complete') and value not in observed:
                launches=[json.loads(row) for row in (runtime.artifacts/'provider-launch.jsonl').read_text().splitlines()]
                if len(launches)!=1:raise AssertionError('Exactly one real Rust playback kernel required')
                table=runtime.observer.snapshot();owned={runtime.server.pid,runtime.harborPid}
                while True:
                    added={pid for pid,row in table.items() if row[0] in owned}-owned
                    if not added:break
                    owned.update(added)
                matches=[(pid,row) for pid,row in table.items() if pid in owned and row[2] and
                    '--scenario' in row[2] and str(runtime.scenario) in row[2] and row[3]==str(runtime.provider)]
                if len(matches)!=1:raise AssertionError('Exactly one actual owned host Rust playback kernel required')
                pid,row=matches[0]
                loaded=hashlib.sha256((Path('/proc')/str(pid)/'exe').read_bytes()).hexdigest()
                if loaded!=hashlib.sha256(runtime.provider.read_bytes()).hexdigest():raise AssertionError('Actual loaded Rust provider bytes differ')
                namespaces=[int(value) for value in next(line for line in (Path('/proc')/str(pid)/'status').read_text().splitlines() if line.startswith('NSpid:')).split()[1:]]
                if namespaces[-1]!=json.loads((runtime.artifacts/'real-provider-launch.json').read_text())['provider_pid']:raise AssertionError('Original sandbox PID does not map to actual owned host kernel')
                observed[value]={'pid':pid,'namespacePids':namespaces,'starttime':row[1],'executable':row[3],'loadedSha256':loaded}
                writers=capture_writers(runtime)
                fenced=json.loads((runtime.private/('scripted-turn-'+str(1 if value.startswith('first') else 2)+'-terminal-fence.json')).read_text())
                if fenced['writers']!=writers:raise AssertionError('Actual fence writer identity changed before checkpoint')
                writer_file=runtime.artifacts/'wire-writer-checkpoints.json'
                writer_points=json.loads(writer_file.read_text()) if writer_file.exists() else {}
                if writer_points and writers!=writer_points['first-complete']:raise AssertionError('Original observer/provider writer identities changed')
                writer_points[value]=writers;writer_file.write_text(json.dumps(writer_points,indent=2))
                prove_operations(runtime,value,proofs,responses,prior)
                if value=='second-complete' and observed[value]!=observed['first-complete']:raise AssertionError('Real scripted provider reset')
                (runtime.artifacts/'sequencing-checkpoints.json').write_text(json.dumps({'kernels':observed,'operations':proofs},indent=2))
                phase.write_text(value.replace('complete','observed'))
            time.sleep(.03)
        if child.returncode:raise subprocess.CalledProcessError(child.returncode,child.args)
        if set(observed)!={'first-complete','second-complete'}:raise AssertionError('Both independent real checkpoints required')
        acknowledgement=json.loads((runtime.artifacts/'browser-close.json').read_text())
        if acknowledgement!={'httpStatus':200,'closed':True}:raise AssertionError('Genuine browser explicit close required')
        closed=observed['second-complete']
        wait_completion(runtime.private,writers,{'pid':closed['pid'],'starttime':closed['starttime'],'executable':closed['executable'],'loadedSha256':closed['loadedSha256'],'namespacePids':closed['namespacePids']},runtime.private/'close-lifetime-snapshots.json')
        assistant_failure=None
        try:validate_assistant_evidence(runtime.private,'memory-sequencing-fixture')
        except AssertionError as error:assistant_failure=str(error)
        failure=None
        try:validate_responses(runtime.private/'response-checks.json')
        except AssertionError as error:failure=str(error)
        expected={'success':None,'contamination':'actualHtmlDescription','nonce':'contextOnlyNonce','html':'actualHtmlDescription'}[mode]
        if expected is None and failure:raise AssertionError(failure)
        if expected is not None and (failure is None or expected not in failure):raise AssertionError('Expected substantive host rejection absent')
        checks=json.loads((runtime.private/'response-checks.json').read_text())
        assert checks=={'contextOnlyNonce':mode!='nonce','actualHtmlDescription':mode not in ('html','contamination')}
        assistant=json.loads((runtime.private/'assistant-response-checks.json').read_text())
        assert assistant['checks']=={'actualAssistantNonce':mode!='nonce','actualAssistantHtmlDescription':mode not in ('html','contamination')}
        if (assistant_failure is None)!=(mode=='success'):raise AssertionError('Actual assistant predicate failure not faithfully enforced')
        tool_html=False
        if mode=='contamination':
            wire=[json.loads(line) for line in (runtime.private/'real-provider-wire.jsonl').read_text().splitlines()]
            tool_html=any(row['direction']=='response' and row['message'].get('method')=='session/update' and
                row['message'].get('params',{}).get('update',{}).get('sessionUpdate')=='tool_call_update' and
                'html' in json.dumps(row['message'].get('params',{}).get('update',{}).get('content',[])).lower() for row in wire)
            if not tool_html or checks['actualHtmlDescription'] is not False or assistant['checks']['actualAssistantHtmlDescription'] is not False:raise AssertionError('Real tool HTML must not satisfy either assistant description check')
        subprocess.run([sys.executable,str(ROOT/'tests/test_editor_scripted_terminal_fence.py'),str(runtime.artifacts)],check=True)
        result={'mode':mode,'artifacts':str(runtime.artifacts),'eightAppliedOperations':True,'sameActualRustKernel':True,
            'genuineExplicitClose':True,'reapedBeforeFinally':True,'checks':checks,'hostFailure':failure,'assistantFailure':assistant_failure,'assistantChecks':assistant['checks'],'toolActivityContainsHtml':tool_html,'seconds':runtime.preparationClock.elapsed(started),'wallSeconds':(time.monotonic_ns()-started)/1_000_000_000,'excludedPreparationSeconds':runtime.preparationClock.excluded_ns(started)/1_000_000_000}
        results.append(result)
        (runtime.artifacts/'sequencing-result.json').write_text(json.dumps(result,indent=2))
        print(json.dumps(result),flush=True)
    finally:runtime.close()
print('PASS real deferred response sequencing: success, both substantive failures and tool activity separation after eight operations/close/reap',flush=True)
