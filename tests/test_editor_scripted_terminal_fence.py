#!/usr/bin/env python3
"""Oracle controls derived from authenticated actual Rust/Harbor wire evidence.

No fake process, RPC/ACK source or model output. The required artifact argument
is an actual owning mounted scenario run. Prefixes are real recorded bytes;
missing/wrong/failed metadata copies deliberately test the validation oracle
and are NOT evidence of new provider behavior. Fresh actual four-case execution
supplies independent production-host/browser/terminal integration positives.
"""
import copy
import hashlib
import json
from pathlib import Path
import sys
from helpers.editor_scenario_runtime import scripted_terminal_fence
from helpers.editor_provider_closure import authenticate_progress

root=Path(sys.argv[1]);private=root/'private'
wire=[json.loads(line) for line in (private/'real-provider-wire.jsonl').read_text().splitlines()]
proofs=[json.loads((private/('scripted-turn-'+str(turn)+'-terminal-fence.json')).read_text()) for turn in (1,2)]
progress=authenticate_progress(private,proofs[0]['writers']['observer'])
controls=[]
for turn,proof in enumerate(proofs,1):
    prefix=wire[:proof['frames']]
    assert hashlib.sha256((''.join(json.dumps(row)+'\n' for row in prefix)).encode()).hexdigest()==proof['traceSha256']
    expected=scripted_terminal_fence(prefix,turn);assert expected is not None and expected['complete'] is True
    for key,value in expected.items():assert proof[key]==value
    controls.append({'turn':turn,'control':'actual authenticated complete terminal','accepted':True})
    def reject(name,mutate):
        rows=copy.deepcopy(prefix);mutate(rows)
        try:answer=scripted_terminal_fence(rows,turn)
        except AssertionError:answer=None
        assert answer is None,'Invalid actual-derived fence accepted: '+name
        controls.append({'turn':turn,'control':name,'accepted':False})
    done=proof['completedToolOrder'];exit_reply=proof['successfulExitReplyOrder'];create_reply=proof['createReplyOrder'];last=proof['outputReplies'][-1]['replyOrder']
    reject('missing completion',lambda rows:rows.pop(done))
    reject('missing successful exit status',lambda rows:rows[exit_reply]['message']['result'].update(exitStatus=None))
    reject('unanswered original output',lambda rows:rows.pop(last))
    reject('wrong actual terminal',lambda rows:rows[create_reply]['message']['result'].update(terminalId='validation-copy-wrong-terminal'))
    reject('terminal failure',lambda rows:rows[exit_reply]['message']['result']['exitStatus'].update(exitCode=1))
    reject('tool failure',lambda rows:rows[done]['message']['params']['update'].update(status='failed'))
    reject('wrong completed tool',lambda rows:rows[done]['message']['params']['update'].update(toolCallId='validation-copy-wrong-tool'))
    reject('false complete field',lambda rows:rows[exit_reply]['message']['result'].update(isComplete=False))
    reject('RPC error',lambda rows:rows[last]['message'].update(error={'code':-1}))
    prompt=proof['promptRequestOrder'];prompt_reply=proof['promptReplyOrder'];create=proof['createRequestOrder']
    declaration=next(i for i in range(prompt+1,create) if prefix[i]['message'].get('params',{}).get('update',{}).get('sessionUpdate')=='tool_call')
    reject('missing request ID',lambda rows:rows[prompt]['message'].pop('id'))
    reject('missing reply ID',lambda rows:rows[prompt_reply]['message'].pop('id'))
    reject('wrong reply ID',lambda rows:rows[prompt_reply]['message'].update(id='validation-copy-unsolicited'))
    def bool_collision(rows):
        rows[prompt]['message']['id']=1;rows[prompt_reply]['message']['id']=True
    reject('bool/int ID collision',bool_collision)
    reject('malformed prompt result',lambda rows:rows[prompt_reply]['message'].update(result=[]))
    reject('unsuccessful prompt stop reason',lambda rows:rows[prompt_reply]['message']['result'].update(stopReason='cancelled'))
    reject('malformed output result',lambda rows:rows[exit_reply]['message'].update(result=False))
    reject('malformed exit status',lambda rows:rows[exit_reply]['message']['result'].update(exitStatus=[]))
    reject('bool exit code',lambda rows:rows[exit_reply]['message']['result']['exitStatus'].update(exitCode=False))
    reject('wrong declared command',lambda rows:rows[declaration]['message']['params']['update']['rawInput'].update(cmd='validation-copy-wrong-command'))
    reject('wrong declared cwd',lambda rows:rows[declaration]['message']['params']['update']['rawInput'].update(cwd='validation-copy-wrong-cwd'))
    reject('wrong declared terminal placeholder',lambda rows:rows[declaration]['message']['params']['update']['content'][0].update(terminalId='validation-copy-wrong-tool'))
    reject('duplicate original output reply',lambda rows:rows.append(copy.deepcopy(rows[last])))
    def premature_completion(rows):
        event=rows.pop(done);rows.insert(exit_reply,event)
    reject('completion before exit reply',premature_completion)

    if proof['promptReplyOrder']<done:
        polling=prefix[:proof['promptReplyOrder']+1]
        assert scripted_terminal_fence(polling,turn) is None
        controls.append({'turn':turn,'control':'actual prompt returned while terminal unfinished','accepted':False})
    if turn==2:
        first_create=proofs[0]['createReplyOrder'];old=wire[first_create]['message']['result']['terminalId']
        reject('previous turn terminal',lambda rows:rows[create_reply]['message']['result'].update(terminalId=old))
assert scripted_terminal_fence(wire,2) is not None
try:scripted_terminal_fence(wire,1)
except AssertionError:controls.append({'turn':1,'control':'later turn cannot satisfy prior fence','accepted':False})
else:raise AssertionError('Later turn accepted as first fence')
print(json.dumps({'actualScenarioFenceControls':controls,'actualForwardedFrames':progress['frames'],'source':'Actual captured provider traffic with explicit validation-copy negatives'}),flush=True)
