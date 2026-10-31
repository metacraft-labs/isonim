"""Synthetic ACP event fixtures test only exact second-turn text correlation.

Explicit JSON frames are necessary to exhaust tool/thought/path contamination,
wrong sessions, missing ACKs/chunks and malformed text without fake Claude/native
processes or inference. Real official-provider/browser sequencing and the live
native gate remain independent required boundaries; no fixture is delivery proof.
"""
import copy
import unittest
import json
import tempfile
from pathlib import Path
from helpers.editor_authoring_responses import validate_responses
from helpers.editor_authoring_assistant_evidence import second_turn_assistant_checks, validate_assistant_checks

def row(direction,message):return {'direction':direction,'message':message}
def chunk(text,kind='agent_message_chunk',sid='actual-fixture-session'):
    return row('response',{'method':'session/update','params':{'sessionId':sid,'update':{'sessionUpdate':kind,'content':{'type':'text','text':text}}}})
def transcript():
    sid='actual-fixture-session'
    return [row('request',{'id':1,'method':'session/new','params':{}}),
      row('response',{'id':1,'result':{'sessionId':sid}}),
      row('request',{'id':2,'method':'session/prompt','params':{'sessionId':sid,'prompt':[]}}),
      chunk('fixture-nonce HTML only in FIRST turn'),row('response',{'id':2,'result':{}}),
      row('request',{'id':3,'method':'session/prompt','params':{'sessionId':sid,'prompt':[]}}),
      chunk('fixture-nonce HT'),chunk('ML observed'),row('response',{'id':3,'result':{}})]
class AssistantEvidence(unittest.TestCase):
    def test_actual_kind_session_turn_and_fragmented_text(self):
        checks,count=second_turn_assistant_checks(transcript(),'fixture-nonce')
        self.assertEqual(count,2);self.assertEqual(checks,{'actualAssistantNonce':True,'actualAssistantHtmlDescription':True})
    def test_tool_thought_path_and_first_turn_cannot_describe_second_result(self):
        wire=transcript();wire[6:8]=[chunk('fixture-nonce observed'),chunk('HTML output/path','tool_call_update'),chunk('HTML thought','agent_thought_chunk')]
        checks,_=second_turn_assistant_checks(wire,'fixture-nonce')
        self.assertEqual(checks,{'actualAssistantNonce':True,'actualAssistantHtmlDescription':False})
        wire[6]['message']['params']['update']['content']['text']='observed'
        checks,_=second_turn_assistant_checks(wire,'fixture-nonce')
        self.assertEqual(checks,{'actualAssistantNonce':False,'actualAssistantHtmlDescription':False})
    def test_synthetic_true_aggregate_cannot_override_false_actual_assistant(self):
        # This dictionary is a codec negative, not a claim about the real DOM.
        with tempfile.TemporaryDirectory() as directory:
            filename=Path(directory)/'response-checks.json'
            filename.write_text(json.dumps({'contextOnlyNonce':True,'actualHtmlDescription':True}))
            self.assertTrue(validate_responses(filename)['actualHtmlDescription'])
            wire=transcript();wire[6:8]=[chunk('fixture-nonce observed'),chunk('HTML tool output','tool_call_update')]
            checks,_=second_turn_assistant_checks(wire,'fixture-nonce')
            with self.assertRaisesRegex(AssertionError,'actualAssistantHtmlDescription'):validate_assistant_checks(checks)
        for malformed in ({}, {'actualAssistantNonce':True,'actualAssistantHtmlDescription':1}, {'actualAssistantNonce':True,'actualAssistantHtmlDescription':True,'extra':True}):
            with self.subTest(malformed=malformed),self.assertRaises(AssertionError):validate_assistant_checks(malformed)
    def test_correlation_and_text_schema_fail_closed(self):
        cases=[]
        wire=transcript();wire[6]['message']['params']['sessionId']='other';cases.append(wire)
        wire=transcript();wire.pop();cases.append(wire)
        wire=transcript();wire[-1]={'direction':'response','message':{'id':3,'error':{'message':'fixture error'}}};cases.append(wire)
        wire=transcript();wire[6:8]=[chunk('HTML fixture-nonce','tool_call_update')];cases.append(wire)
        wire=transcript();wire[6]['message']['params']['update']['content']['text']=1;cases.append(wire)
        wire=transcript();wire[5]['message']['params']['sessionId']='other';cases.append(wire)
        wire=transcript();wire.append(row('request',{'id':4,'method':'session/prompt','params':{'sessionId':'actual-fixture-session'}}));cases.append(wire)
        wire=transcript();wire.append(row('response',{'id':3,'result':{}}));cases.append(wire)
        wire=transcript();wire[1]['message']['result']['sessionId']='other';cases.append(wire)
        for wire in cases:
            with self.subTest(wire=wire),self.assertRaises(AssertionError):second_turn_assistant_checks(wire,'fixture-nonce')
if __name__=='__main__':unittest.main()
