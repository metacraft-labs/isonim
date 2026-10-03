#!/usr/bin/env python3
"""Required opt-in real Claude authoring gate, never playback or skipped inference.

Owns the ordinary launcher/Harbor/SQLite/provider/SDK/compiler and a real browser.
The existing lifecycle runtime preserves scoped handoff and owned cleanup. A thin
observer records unchanged actual ACP bytes privately; model/tool/REST/CLI results
are real. First/follow-up checkpoints bind kernel PID/starttime/executable hashes
of the same live Claude stream-json process. The nonce exists only in first-turn
context and private transport evidence, never in later input or project sources.
"""
from html.parser import HTMLParser
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import re
import time
from helpers.editor_scenario_runtime import Runtime, ROOT, wait
from helpers.editor_authoring_operations import prove_operations
from helpers.editor_authoring_assistant_evidence import validate_assistant_evidence
from helpers.editor_authoring_responses import validate_responses
from helpers.editor_provider_closure import capture_writers,wait_completion
from helpers.editor_sdk_runtime import authenticate
from helpers.editor_authoring_evidence import correlated_responses, verify_tool_inputs

provider_command=os.environ.get('ISONIM_REAL_CLAUDE_ACP') or shutil.which('claude-agent-acp')
if not provider_command:
 raise AssertionError('Actual supported Claude ACP provider required: set ISONIM_REAL_CLAUDE_ACP or expose claude-agent-acp on PATH')
provider=Path(provider_command)
authenticate(ROOT/'build/editor-sdk-runtime.json',provider)
if not provider.is_file() or not os.access(provider,os.X_OK):
 raise AssertionError('ISONIM_REAL_CLAUDE_ACP must select an executable supported Claude ACP provider')
private=Path(tempfile.mkdtemp(prefix='eac-m6-instructions-'));private.chmod(0o700)
instructions=private/'instructions.md'
instructions.write_bytes((ROOT/'prompts/ai-assistant.md').read_bytes())
instructions.chmod(0o600)
provision_started=time.monotonic()
runtime=Runtime('real-gui',real_provider=provider,project_source=ROOT.parent/'web-site-prototypes/grip/isonim',
 editor_directory=ROOT/'build/editor-authoring',source_file='src/editor/catalog.nim',instructions_path=instructions,real_model='sonnet')
provision_seconds=time.monotonic()-provision_started
browser_started=time.monotonic()
observed={}
terminal_observations={}
cli_observations={}
operation_proofs={}
operation_responses={1:{},2:{}}
prior_operation_ids=set()
def model_identity():
 table=runtime.observer.snapshot()
 descendants={runtime.server.pid,runtime.harborPid}
 while True:
  added={pid for pid,row in table.items() if row[0] in descendants}-descendants
  if not added:break
  descendants.update(added)
 matches={pid:row for pid,row in table.items() if pid in descendants and row[2] and '--input-format' in row[2] and 'stream-json' in row[2]}
 if len(matches)!=1:raise AssertionError('Exactly one actual continuously running Claude SDK stream-json process required')
 pid,row=next(iter(matches.items()))
 actual=Path('/proc')/str(pid)/'exe'
 namespaces=[int(value) for value in next(line for line in (Path('/proc')/str(pid)/'status').read_text().splitlines() if line.startswith('NSpid:')).split()[1:]]
 return {'pid':pid,'namespace_pids':namespaces,'starttime':row[1],'executable':row[3],'loaded_sha256':hashlib.sha256(actual.read_bytes()).hexdigest()}
try:
 child=runtime.spawn([os.environ.get('ISONIM_SCENARIO_NODE','node'),str(ROOT/'tests/test_editor_authoring_real_gui.mjs'),str(runtime.artifacts/'context.json')],'real-browser')
 deadline=time.monotonic()+300
 while child.poll() is None:
  if time.monotonic()>=deadline:raise AssertionError('Actual model/browser workflow exceeded bounded 300 second lifetime')
  phase=runtime.artifacts/'phase'
  value=phase.read_text() if phase.exists() else ''
  if value in ('first-start','second-start'):
   original_file=runtime.private/'original-handoff.json'
   if original_file.exists():
    original=json.loads(original_file.read_text())['environment']
    # Endpoint is resolved by the production wrapper inside the actual
    # sandbox. This snapshot is independently matched to its original file.
    expected=json.loads((runtime.private/'provider-scope.json').read_text())
    table=runtime.observer.snapshot()
    owned={runtime.harborPid}
    while True:
     added={pid for pid,row in table.items() if row[0] in owned}-owned
     if not added:break
     owned.update(added)
    for pid,row in table.items():
     if pid not in owned:continue
     argv=row[2] or []
     if row[3]==str((ROOT/'build/bin/isonim').resolve()) and 'editor' in argv:
      try:
       actual=dict(item.split('=',1) for item in (Path('/proc')/str(pid)/'environ').read_bytes().decode().split('\0') if '=' in item)
       matches=all(actual.get(key)==value for key,value in expected.items())
      except (OSError,UnicodeError):continue
      if not matches:raise AssertionError('Actual model CLI process does not inherit original-file resolved six-key provider scope')
      cli_observations[str(pid)+':'+row[1]]={'pid':pid,'starttime':row[1],
       'phase':value,'executable':row[3],'original_handoff_matches':True,'operation':argv[argv.index('editor')+1]}
     if (str(ROOT/'tools/editor_agent_env.py') in argv and '--environment' in argv and original in argv
         and str(ROOT/'tools/agent_session_launcher.py') not in argv):
      terminal_observations[str(pid)+':'+row[1]]={'pid':pid,'starttime':row[1],
        'original_handoff':original,'phase':value,'wrapper':str(ROOT/'tools/editor_agent_env.py')}
  if value in ('first-complete','second-complete') and value not in observed:
   observed[value]=model_identity()
   writers=capture_writers(runtime)
   writer_file=runtime.artifacts/'wire-writer-checkpoints.json'
   writer_points=json.loads(writer_file.read_text()) if writer_file.exists() else {}
   if writer_points and writers!=writer_points['first-complete']:raise AssertionError('Original observer/ACP writer identities changed')
   writer_points[value]=writers;writer_file.write_text(json.dumps(writer_points,indent=2))
   prove_operations(runtime,value,operation_proofs,operation_responses,prior_operation_ids)
   (runtime.artifacts/'real-operation-checkpoints.json').write_text(json.dumps(operation_proofs,indent=2))
   (runtime.artifacts/'real-kernel-checkpoints.json').write_text(json.dumps(observed,indent=2))
   if value=='second-complete' and observed[value]!=observed['first-complete']:raise AssertionError('Model PID/starttime/executable changed across follow-up')
   phase.write_text(value.replace('complete','observed'))
  time.sleep(.03)
 if child.returncode:raise subprocess.CalledProcessError(child.returncode,child.args)
 if set(observed)!={'first-complete','second-complete'}:raise AssertionError('Both actual model checkpoints required')
 closed=observed['second-complete']
 if json.loads((runtime.artifacts/'browser-close.json').read_text())!={'httpStatus':200,'closed':True}:raise AssertionError('Actual HTTP200 literalclosed:true required')
 native={'pid':closed['pid'],'starttime':closed['starttime'],'executable':closed['executable'],'loadedSha256':closed['loaded_sha256'],'namespacePids':closed['namespace_pids']}
 wait_completion(runtime.private,writers,native,runtime.private/'close-lifetime-snapshots.json')
 wire=[json.loads(line) for line in (runtime.private/'real-provider-wire.jsonl').read_text().splitlines()]
 new=[row['message'] for row in wire if row['direction']=='request' and row['message'].get('method')=='session/new']
 turns=[row['message'] for row in wire if row['direction']=='request' and row['message'].get('method')=='session/prompt']
 if len(new)!=1 or len(turns)!=2:raise AssertionError('One actual session/new and exactly two real user turns required')
 new_results=correlated_responses(wire,new[0])
 if len(new_results)!=1 or new_results[0].get('error') or not new_results[0].get('result',{}).get('sessionId'):raise AssertionError('Actual session/new must succeed')
 actual_session=new_results[0]['result']['sessionId']
 if any(turn['params'].get('sessionId')!=actual_session for turn in turns):raise AssertionError('Both actual model prompts must target the same created provider session')
 model_requests=[row['message'] for row in wire if row['direction']=='request' and row['message'].get('method')=='session/set_config_option']
 if len(model_requests)!=1 or model_requests[0]['params'].get('configId')!='model' or model_requests[0]['params'].get('value')!='sonnet':raise AssertionError('Explicit supported Sonnet selection must use actual provider model API')
 model_results=correlated_responses(wire,model_requests[0])
 if len(model_results)!=1 or model_results[0].get('error') or 'result' not in model_results[0]:raise AssertionError('Actual provider rejected explicit Sonnet selection')
 model_options=[option for option in model_results[0]['result'].get('configOptions',[]) if option.get('id')=='model']
 if len(model_options)!=1 or 'sonnet' not in model_options[0].get('currentValue','').lower():raise AssertionError('Provider must report the actually selected Sonnet model')
 if new[0]['params']['_meta']['systemPrompt']['append']!=instructions.read_text():raise AssertionError('Exact substantive role guidance not delivered')
 nonce=json.loads((runtime.private/'context-nonce.json').read_text())['nonce']
 if nonce in json.dumps(new) or nonce in json.dumps(turns[1]):raise AssertionError('Nonce was repeated in system/follow-up input')
 requests=[row['message'] for row in wire if row['direction']=='response' and row['message'].get('method')=='terminal/create']
 commands=[row['params'].get('command','')+' '+' '.join(row['params'].get('args',[])) for row in requests]
 # Claude's real SDK Bash tool runs inside the scoped provider process; this
 # adapter reports its actual command as tool_call_update.rawInput, rather than
 # issuing ACP terminal/create. Keep the genuine route and require real results.
 updates=[row['message']['params'].get('update',{}) for row in wire
          if row['direction']=='response' and row['message'].get('method')=='session/update']
 bash_inputs={update['toolCallId']:update['rawInput']['command'] for update in updates
              if update.get('rawInput',{}).get('command') and update.get('_meta',{}).get('claudeCode',{}).get('toolName')=='Bash'}
 completed={update['toolCallId'] for update in updates if update.get('status')=='completed' and update.get('content')}
 commands.extend(command for tool,command in bash_inputs.items() if tool in completed)
 if not bash_inputs and not requests:raise AssertionError('Actual provider tool commands required')
 if not cli_observations:raise AssertionError('Actual kernel CLI execution with exact original scoped handoff required')
 # Observer sees the provider's original request, before the production launcher
 # wraps it. Persisted Harbor tool launch evidence must show the original file.
 original=json.loads((runtime.private/'original-handoff.json').read_text())
 if not original['current_provider_scope_matches']:raise AssertionError('Original scoped handoff required')
 tool_inputs=[update.get('rawInput',{}) for update in updates if update.get('rawInput')]
 offload_proofs=verify_tool_inputs(wire,nonce,operation_responses,actual_session)
 tool_trace=runtime.private/'actual-tools.json'
 tool_trace.write_text(json.dumps([{'id':update.get('toolCallId'),'event':update.get('sessionUpdate'),
   'tool':update.get('_meta',{}).get('claudeCode',{}).get('toolName'),'input':update.get('rawInput'),
   'status':update.get('status')} for update in updates if update.get('toolCallId')],indent=2));tool_trace.chmod(0o600)
 authenticate(runtime.sdk_manifest,provider)
 subprocess.run([runtime.sdk_runtime['paths']['node'],str(ROOT/'tests/helpers/editor_sdk_delivery_evidence.mjs'),
  str(runtime.private/'sdk-native'),str(runtime.private/'real-provider-wire.jsonl'),str(runtime.private/'instructions.md'),
  str(runtime.artifacts/'real-kernel-checkpoints.json'),str(runtime.sdk_manifest),'2'],check=True,timeout=30)
 validate_assistant_evidence(runtime.private,nonce)
 validate_responses(runtime.private/'response-checks.json')
 # Exact actual syscall identity, and loaded adapter/model inputs, are public proof.
 (runtime.artifacts/'real-model-continuity.json').write_text(json.dumps({'observed':observed,'provider':str(provider),
  'provider_sha256':hashlib.sha256(provider.read_bytes()).hexdigest(),'instructions_sha256':hashlib.sha256(instructions.read_bytes()).hexdigest(),
  'session_new_count':len(new),'actual_provider_requests':sum(row['direction']=='response' and 'id' in row['message'] and 'method' in row['message'] for row in wire),'actual_user_turns':len(turns),'actual_terminal_operations':len(commands),'observed_original_file_tools':list(terminal_observations.values()),'actual_kernel_cli':list(cli_observations.values()),'explicit_model':'sonnet','actual_applied_operations':operation_proofs,'verified_current_operation_offloads':offload_proofs},indent=2))
 print('PASS real model identity, genuine role instructions, actual tools and native retained context',flush=True)
finally:
 (runtime.artifacts/'real-gate-timing.json').write_text(json.dumps({
   'runtimeProvisionSeconds':provision_seconds,'browserAndProofSeconds':time.monotonic()-browser_started,
   'startupBoundSeconds':900,'browserBoundSeconds':300,'terminalWaitBoundSeconds':120,
   'mountedWaitBoundSeconds':30},indent=2))
 runtime.close()
