"""Correlate actual second-turn assistant chunks, excluding tools/thoughts.

No provider/output rewriting. Mounted aggregate response predicates stay intact;
this strengthens them at the original ACP event boundary after close/reap.
"""
import hashlib
import json
import os
from pathlib import Path
import re
from helpers.editor_authoring_evidence import correlated_responses

def second_turn_assistant_checks(wire,nonce):
    requests=[row['message'] for row in wire if row['direction']=='request']
    new=[row for row in requests if row.get('method')=='session/new']
    prompts=[row for row in requests if row.get('method')=='session/prompt']
    if len(new)!=1 or len(prompts)!=2:raise AssertionError('Exactly one actual new and two user turns required for assistant evidence')
    result=correlated_responses(wire,new[0])
    if len(result)!=1 or result[0].get('error'):raise AssertionError('Successful actual session creation required')
    sid=result[0].get('result',{}).get('sessionId')
    if not sid or any(row['params'].get('sessionId')!=sid for row in prompts):raise AssertionError('Actual assistant evidence must use same created session')
    start=next(index for index,row in enumerate(wire) if row['direction']=='request' and row['message']==prompts[1])
    terminal=[index for index,row in enumerate(wire) if index>start and row['direction']=='response' and row['message'].get('id')==prompts[1]['id'] and 'method' not in row['message']]
    if len(terminal)!=1 or wire[terminal[0]]['message'].get('error') or 'result' not in wire[terminal[0]]['message']:raise AssertionError('Actual correlated second prompt completion required')
    chunks=[]
    for row in wire[start+1:terminal[0]]:
        message=row['message']
        if row['direction']!='response' or message.get('method')!='session/update':continue
        params=message.get('params',{});update=params.get('update',{})
        if update.get('sessionUpdate')!='agent_message_chunk':continue
        if params.get('sessionId')!=sid:raise AssertionError('Assistant chunk targets another actual session')
        content=update.get('content',{})
        if content.get('type')!='text' or type(content.get('text')) is not str:raise AssertionError('Actual textual assistant chunk required')
        chunks.append(content['text'])
    if not chunks:raise AssertionError('Actual second-turn assistant text required')
    text=''.join(chunks)
    return {'actualAssistantNonce':nonce in text,'actualAssistantHtmlDescription':bool(re.search('HTML',text,re.I))},len(chunks)

def validate_assistant_checks(checks):
    if type(checks) is not dict or set(checks)!={'actualAssistantNonce','actualAssistantHtmlDescription'} or any(type(value) is not bool for value in checks.values()):
        raise AssertionError('Exact literal boolean assistant checks required')
    failed=[key for key,value in checks.items() if value is not True]
    if failed:raise AssertionError('Actual assistant response checks failed: '+', '.join(failed))
    return checks

def validate_assistant_evidence(private,nonce):
    private=Path(private);filename=private/'real-provider-wire.jsonl'
    state=json.loads((private/'provider-wire-state.json').read_text())
    if state.get('origin') not in ('child-finally','host-quiescence') or state.get('complete') is not True or state['errors'] or state['traceSha256']!=hashlib.sha256(filename.read_bytes()).hexdigest():raise AssertionError('Actual wire recorder failed or trace changed')
    wire=[json.loads(line) for line in filename.read_text().splitlines()]
    checks,count=second_turn_assistant_checks(wire,nonce)
    proof={'checks':checks,'actualSecondAssistantChunks':count,'scope':'Actual second-prompt correlated ACP agent_message_chunk text only'}
    fd=os.open(private/'assistant-response-checks.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as output:json.dump(proof,output)
    validate_assistant_checks(checks)
    return proof
