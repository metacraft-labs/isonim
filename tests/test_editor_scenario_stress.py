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

def require_turn_identity(status, identity):
    if status['id'] != identity['id'] or status['backend'] != identity['backend']:
        raise AssertionError('Completion observer changed active chat or provider session')


def require_completed_chat(chat, identity):
    require_turn_identity(chat, identity)
    if chat['busy']:
        raise AssertionError('Full active-chat witness still has a provider turn in flight')


class EditorStreamOwnership(unittest.TestCase):
    def test_compact_completion_controls_use_actual_chat_and_provider_state(self):
        if not optional_sibling_available(HARBOR): self.skipTest('optional private Agent Harbor sibling absent')
        runtime = Runtime('native')
        try:
            prior_chat = runtime.activeStatus()
            runtime.action(action='new-chat')
            before_send = runtime.activeStatus()
            self.assertNotEqual(before_send['id'], prior_chat['id'])
            with self.assertRaisesRegex(AssertionError, 'changed active chat'):
                require_turn_identity(before_send, prior_chat)
            (runtime.artifacts/'ownership-turn').write_text('control')
            runtime.phase(17)
            runtime.action(action='send', text='Read actual editor state for completion observer controls.')
            runtime.preparationClock.wait(
                lambda:(runtime.artifacts/'ownership-entered-control').exists(),
                'actual provider entered completion control barrier')
            runtime.assertResourceVisibility()
            identity = runtime.activeStatus()
            self.assertEqual(identity['id'], before_send['id'])
            self.assertNotEqual(identity['backend'], before_send['backend'])
            self.assertTrue(identity['busy'])
            with self.assertRaisesRegex(AssertionError, 'provider session'):
                require_turn_identity(identity, before_send)
            busy_chat = runtime.active()
            self.assertEqual(busy_chat['id'], identity['id'])
            self.assertEqual(busy_chat['backend'], identity['backend'])
            with self.assertRaisesRegex(AssertionError, 'still has a provider turn'):
                require_completed_chat(busy_chat, identity)
            (runtime.artifacts/'ownership-release-control').touch()
            def completed():
                status = runtime.activeStatus()
                require_turn_identity(status, identity)
                return not status['busy']
            runtime.preparationClock.wait(completed, 'actual completion control turn ended')
            require_completed_chat(runtime.active(), identity)
            self.assertEqual(runtime.action()['errors'], [])
            print('PASS genuine wrong-chat, stale-provider and busy full-witness controls', flush=True)
        finally:
            runtime.close()

    def test_same_worker_streaming_and_concurrent_http_reads_release_cleanly(self):
        if not optional_sibling_available(HARBOR): self.skipTest('optional private Agent Harbor sibling absent')
        runtime = Runtime('native')
        wait = runtime.preparationClock.wait
        errors, observations = [], []
        try:
            initial = runtime.cli(['state'])
            self.assertEqual(initial['instance'], runtime.scope['instance'])
            begin = time.monotonic_ns()
            identity, session = None, None
            for number in range(24):
                self.assertLess(runtime.preparationClock.elapsed(begin), 180, 'Bounded real callback stress')
                (runtime.artifacts/'ownership-turn').write_text(str(number))
                runtime.phase(17)
                previous_messages = len(runtime.active()['messages'])
                runtime.action(action='send',text='Execute the real readonly editor tool for ownership turn '+str(number))
                wait(lambda:(runtime.artifacts/('ownership-entered-'+str(number))).exists(),
                      'actual terminal entered ownership barrier')
                runtime.assertResourceVisibility()
                wait(lambda:any('ISONIM_M5_STREAM_BEGIN' in message['text'] for message in runtime.active()['messages'][previous_messages:]),
                      'real streaming callback reaches production VM')
                active_chat = runtime.active()
                self.assertTrue(active_chat['busy'])
                active_identity = runtime.activeStatus()
                self.assertEqual(active_identity['id'], active_chat['id'])
                self.assertEqual(active_identity['backend'], active_chat['backend'])
                self.assertEqual(active_identity['busy'], active_chat['busy'])
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
                def terminal_completed():
                    # The host exposes the same active VM flag without copying
                    # its growing transcript on every completion poll. Identity
                    # is checked each time; full history and all editor.state
                    # reads retain their original independent assertions.
                    status = runtime.activeStatus()
                    require_turn_identity(status, active_identity)
                    return not status['busy']
                wait(terminal_completed,'terminal completion after overlap reads')
                completed_chat = runtime.active()
                require_completed_chat(completed_chat, active_identity)
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
                      'backendSession':session, 'seconds':runtime.preparationClock.elapsed(begin),
                      'wallSeconds':(time.monotonic_ns()-begin)/1_000_000_000,
                      'excludedPreparationSeconds':runtime.preparationClock.excluded_ns(begin)/1_000_000_000}
            (runtime.artifacts/'ownership-result.json').write_text(json.dumps(result,indent=2))
        finally:
            (runtime.artifacts/'ownership-observations.json').write_text(json.dumps(
                {'reads':observations,'errors':errors},indent=2))
            runtime.close()

if __name__ == '__main__': unittest.main(verbosity=2)
