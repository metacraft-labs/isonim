#!/usr/bin/env python3
"""Real HTTP/SSE worker ownership regression with the official Rust provider.

Only model decisions/text use shared YAML phase 17. Every turn executes the actual
scoped editor CLI, while a phase-coordinated reader sends real authenticated HTTP
state requests. No HTTP client/daemon, dispatcher, filesystem/compiler or tool
result is mocked. The native production VM consumes actual streaming callbacks.
Each batch runs while the actual provider terminal waits at an observable file
barrier; every response asserts the production VM still reports an active turn.
The fixed batches and synchronous bounded requests bound workload and cleanup.
"""
import json
import time
import unittest
from helpers.editor_scenario_runtime import Runtime, post, wait, HARBOR
from helpers.editor_process_observer import optional_sibling_available

class EditorStreamOwnership(unittest.TestCase):
    def test_same_worker_streaming_and_concurrent_http_reads_release_cleanly(self):
        if not optional_sibling_available(HARBOR): self.skipTest('optional private Agent Harbor sibling absent')
        runtime = Runtime('native')
        errors, observations = [], []
        try:
            initial = runtime.cli(['state'])
            self.assertEqual(initial['instance'], runtime.scope['instance'])
            begin = time.monotonic()
            identity, session = None, None
            for number in range(24):
                self.assertLess(time.monotonic()-begin, 180, 'Bounded real callback stress')
                (runtime.artifacts/'ownership-turn').write_text(str(number))
                runtime.phase(17)
                previous_messages = len(runtime.active()['messages'])
                runtime.action(action='send',text='Execute the real readonly editor tool for ownership turn '+str(number))
                wait(lambda:(runtime.artifacts/('ownership-entered-'+str(number))).exists(),
                     'actual terminal entered ownership barrier')
                wait(lambda:any('ISONIM_M5_STREAM_BEGIN' in message['text'] for message in runtime.active()['messages'][previous_messages:]),
                     'real streaming callback reaches production VM')
                self.assertTrue(runtime.active()['busy'])
                active_identity = runtime.activeStatus()
                for request in range(64):
                    reply = runtime.rpc('editor.state', {}, token=runtime.scope['controlToken'])
                    self.assertIn('result',reply)
                    self.assertEqual(reply['result']['instance'],initial['instance'])
                    status = runtime.activeStatus()
                    self.assertEqual(status['id'],active_identity['id'])
                    self.assertEqual(status['backend'],active_identity['backend'])
                    self.assertTrue(status['busy'], 'Read must overlap real active provider turn')
                    observations.append({'turn':number,'request':request,'providerTurnActive':True,
                                         'streamedMessageAfterIndex':previous_messages})
                (runtime.artifacts/('ownership-release-'+str(number))).touch()
                wait(lambda:not runtime.active()['busy'],'terminal completion after overlap reads')
                self.assertEqual(runtime.action()['errors'],[])
                actual = runtime.providerIdentity()
                if identity is None:
                    identity, session = actual, runtime.active()['backend']
                    self.assertTrue(session)
                else:
                    self.assertEqual(actual, identity)
                    self.assertEqual(runtime.active()['backend'], session)
                self.assertEqual(errors, [])
                print('PASS real ownership turn '+str(number), flush=True)
            # All synchronous responses have drained before session close.
            self.assertEqual(errors, [])
            self.assertEqual(len(observations), 24*64)
            self.assertEqual(post(runtime.origin+'/api/agent/close', {'sessionId':session})['closed'], True)
            wait(lambda: not any(str(pid) in identity for pid in runtime.observer.snapshot()),
                 'actual ownership-regression provider reaped')
            result = {'turns':24, 'httpStateReads':len(observations), 'providerIdentity':identity,
                      'backendSession':session, 'seconds':time.monotonic()-begin}
            (runtime.artifacts/'ownership-result.json').write_text(json.dumps(result,indent=2))
        finally:
            (runtime.artifacts/'ownership-observations.json').write_text(json.dumps(
                {'reads':observations,'errors':errors},indent=2))
            runtime.close()

if __name__ == '__main__': unittest.main(verbosity=2)
