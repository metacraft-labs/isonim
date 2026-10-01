#!/usr/bin/env python3
"""Official Rust playback through the real native production EditorVM host.

Only model decisions/responses are scripted. No mock dispatcher, RPC, filesystem,
compiler, successful tool output or BrowserAgentClient shim participates. Real
launcher/source-worker/CLI/nim-agents/Harbor/SQLite/provider and incremental SSE
feed the actual VM. The shared YAML also drives the browser subset. Browser-only
keyboard/layout/focus/highlight/capture assertions are deliberately in that runner.
"""
import json
import hashlib
from pathlib import Path
import subprocess
import sys
import unittest
from helpers.editor_scenario_runtime import Runtime, wait, post, ROOT, HARBOR
from helpers.editor_process_observer import optional_sibling_available

class EditorScenarios(unittest.TestCase):
    def test_native_real_authoring_sessions_streaming_conflicts_and_denial(self):
        if not optional_sibling_available(HARBOR):self.skipTest('optional private Agent Harbor sibling absent')
        runtime=Runtime('native')
        evidence=[]
        try:
            def checked(number,label):
                evidence.append({'scenario':number,'host':'native','outcome':label})
                (runtime.artifacts/'outcomes.json').write_text(json.dumps(evidence,indent=2))
                print('PASS native workflow '+str(number)+': '+label,flush=True)
            runtime.phase(1)
            runtime.action(action='send',text='Create the busy Card story, compile it, open it and capture its HTML.')
            wait(lambda:(runtime.artifacts/'entered-1').exists(),'actual provider tool entered')
            wait(lambda:any('ISONIM_M5_STREAM_BEGIN' in message['text'] for message in runtime.active()['messages']),'incremental real SSE reaches VM')
            self.assertTrue(runtime.active()['busy'])
            runtime.action(action='draft',text='Compose my next request while actual tools run')
            sid=runtime.active()['backend']; self.assertTrue(sid)
            identity=runtime.providerIdentity()
            # REST cancellation is truthfully unsupported, not a stop-session alias.
            import urllib.error
            with self.assertRaises(urllib.error.HTTPError) as cancellation:
                post(runtime.origin+'/api/agent/cancel',{'sessionId':sid})
            self.assertEqual(cancellation.exception.code,409)
            self.assertEqual(json.load(cancellation.exception)['error'],'unsupported_capability')
            self.assertEqual(runtime.providerIdentity(),identity)
            self.assertTrue(runtime.active()['busy'])
            (runtime.artifacts/'release-1').touch()
            wait(lambda:runtime.cli(['state'])['storyId']=='Card / default busy','native compiled view selected')
            (runtime.artifacts/'capture-ready-1').touch()
            wait(lambda:not runtime.active()['busy'],'first terminal after actual tools')
            self.assertEqual(runtime.action()['errors'],[])
            self.assertEqual(runtime.active()['draft'],'Compose my next request while actual tools run')
            self.assertTrue(runtime.active()['tools'])
            capture=json.loads((runtime.artifacts/'capture-busy.json').read_text())
            self.assertEqual(capture['status'],'applied');self.assertIn('Busy card',capture['result']['documentHtml'])
            self.assertEqual(capture['result']['captureBoundary'],'compiled-SSR')
            self.assertIn('card("Busy card")',(runtime.project/'stories.nim').read_text())
            checked(1,'created/compiled/opened/captured real SSR')
            checked(3,'incremental SSE and tool activity preserve next draft')
            (runtime.artifacts/'capture-ready-2').touch()
            runtime.turn(2,'Change Busy card to Followup card in the same conversation and compile it.')
            self.assertEqual(runtime.active()['backend'],sid);self.assertEqual(runtime.providerIdentity(),identity)
            self.assertIn('Followup card',json.loads((runtime.artifacts/'capture-followup.json').read_text())['result']['documentHtml'])
            checked(2,'follow-up same provider and conversation; second real source build')
            checked(4,'unsupported cancellation preserves provider; later prompt succeeds')
            catalog=(runtime.project/'.isonim/catalog.json').read_bytes()
            source=(runtime.project/'stories.nim').read_text()
            runtime.turn(3,'Attempt the invalid error fixture; report actual compiler diagnostics.')
            failed=runtime.cli(['wait','fail-compile'],4)
            self.assertIn('type mismatch',failed['diagnostic']);self.assertEqual(failed['status'],'failed')
            self.assertEqual((runtime.project/'.isonim/catalog.json').read_bytes(),catalog)
            self.assertEqual((runtime.project/'stories.nim').read_text(),source)
            self.assertEqual(runtime.cli(['state'])['storyId'],'Card / default busy')
            checked(5,'actual compiler failure retains prior source/catalog/selection')
            first=runtime.action()['active']; history=runtime.active()['messages']
            runtime.action(action='draft',text='first independent draft')
            runtime.action(action='new-chat'); second=runtime.action()['active']
            self.assertNotEqual(first,second)
            self.assertEqual(runtime.active()['messages'],[])
            runtime.action(action='draft',text='second independent draft')
            runtime.action(action='switch',id=first)
            self.assertEqual(runtime.active()['draft'],'first independent draft');self.assertEqual(runtime.active()['messages'],history)
            runtime.action(action='switch',id=second);self.assertEqual(runtime.active()['draft'],'second independent draft')
            runtime.action(action='switch',id=first)
            checked(6,'independent drafts and retained conversation history')
            self.assertTrue(runtime.active()['placeholdersDismissed'])
            checked(11,'first attempt dismisses guidance; chat return keeps dismissal')
            runtime.turn(7,'Retry the original create command and reject a stale revision.')
            self.assertEqual(json.loads((runtime.artifacts/'retry-busy.json').read_text()),json.loads((runtime.artifacts/'create-busy.json').read_text()))
            self.assertEqual(runtime.cli(['wait','stale-revision'],6)['error'],'revision_conflict')
            self.assertEqual((runtime.project/'stories.nim').read_text().count('"name": "default busy"'),1)
            checked(8,'same commandId retry has byte-identical terminal result; stale revision denied')
            def project_files():
                return {str(path.relative_to(runtime.project)):{'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'mtime_ns':path.stat().st_mtime_ns}
                        for path in runtime.project.rglob('*') if path.is_file()}
            denied_files=project_files()
            runtime.turn(8,'Reject unsupported eval-script without changing source.')
            self.assertEqual(runtime.cli(['wait','unsupported'],4)['error'],'unsupported_capability')
            self.assertEqual((runtime.project/'stories.nim').read_text(),source)
            self.assertEqual(project_files(),denied_files)
            checked(9,'unsupported operation produces actual denied CLI result and no source mutation')
            runtime.action(action='source-permission',value=False)
            wait(lambda:runtime.cli(['state'])['permissions']['writeSource']==False,'actual source permission denied')
            runtime.turn(11,'Build is denied by this workspace source permission.')
            self.assertEqual(runtime.cli(['wait','denied-build'],4)['error'],'capability_or_permission')
            self.assertEqual((runtime.project/'stories.nim').read_text(),source)
            self.assertEqual(project_files(),denied_files)
            (runtime.artifacts/'denial-project-snapshot.json').write_text(json.dumps(denied_files,indent=2))
            checked(9,'source permission denial cannot invoke persistence/compiler')
            runtime.action(action='source-permission',value=True)
            runtime.action(action='approval',value=True)
            wait(lambda:runtime.cli(['state'])['approvalRequired']==True and runtime.cli(['state'])['permissions']['writeSource']==True,
                 'actual approval/source permission state published')
            runtime.turn(12,'Open the ready story after approval.')
            pending=runtime.cli(['wait','native-approved-open','--timeout-ms','100'],5)
            self.assertEqual(pending['operation']['status'],'pending')
            self.assertEqual(runtime.cli(['state'])['storyId'],'Card / default busy')
            runtime.action(action='decision',id='native-approved-open',value=True)
            self.assertEqual(runtime.cli(['wait','native-approved-open'])['status'],'applied')
            self.assertEqual(runtime.cli(['state'])['storyId'],'Card / default ready')
            runtime.turn(13,'Request opening the busy story, then reject it.')
            pending=runtime.cli(['wait','native-rejected-open','--timeout-ms','100'],5)
            self.assertEqual(pending['operation']['status'],'pending')
            self.assertEqual(runtime.cli(['state'])['storyId'],'Card / default ready')
            runtime.action(action='decision',id='native-rejected-open',value=False)
            self.assertEqual(runtime.cli(['wait','native-rejected-open'],4)['status'],'rejected')
            self.assertEqual(runtime.cli(['state'])['storyId'],'Card / default ready')
            checked(12,'shared approval policy pending/approve/reject actual navigation; DOM controls in GUI')
            runtime.action(action='pause-polls',value=True)
            def expired():
                try:return runtime.cli(['state'],3)['error']=='disconnected_instance'
                except AssertionError:return False
            wait(expired,'actual native host lease expiry',20)
            runtime.action(action='pause-polls',value=False)
            def resumed():
                try:return runtime.cli(['state'])['instance']==runtime.scope['instance']
                except AssertionError:return False
            wait(resumed,'authenticated same native host lease renewal')
            runtime.turn(9,'Inspect state after renewing this exact host connection.')
            self.assertEqual(runtime.active()['backend'],sid)
            self.assertEqual(runtime.providerIdentity(),identity)
            checked(7,'same host lease expires/renews; same worker scope succeeds; actual browser offline in GUI')
            # Reload a separate actual native VM from the persisted source/catalog.
            rebuilt=subprocess.run([sys.executable,str(ROOT/'tools/build_source_catalog.py'),str(runtime.project)],env=runtime.env,capture_output=True,text=True,timeout=120)
            (runtime.artifacts/'reload-build.log').write_text(rebuilt.stdout+rebuilt.stderr)
            self.assertEqual(rebuilt.returncode,0,rebuilt.stdout+rebuilt.stderr)
            reloaded_catalog=(runtime.project/'.isonim/catalog.json').read_bytes()
            # The direct producer retains its stdout newline; transactional
            # publication omits it. Compare every parsed field/HTML string,
            # preserving real persisted content rather than JSON framing bytes.
            prior_catalog=json.loads(catalog);fresh_catalog=json.loads(reloaded_catalog)
            self.assertEqual(fresh_catalog,prior_catalog)
            html_hashes=[]
            for prior,fresh in zip(prior_catalog['stories'],fresh_catalog['stories']):
                self.assertEqual(fresh['documentHtml'].encode(),prior['documentHtml'].encode())
                html_hashes.append({'story':fresh['name'],'html_sha256':hashlib.sha256(fresh['documentHtml'].encode()).hexdigest()})
            (runtime.artifacts/'catalog-before-reload.json').write_bytes(catalog)
            (runtime.artifacts/'catalog-after-reload.json').write_bytes(reloaded_catalog)
            (runtime.artifacts/'reload-catalog-comparison.json').write_text(json.dumps({'all_fields_equal':True,'exact_html':html_hashes,
                'before_sha256':hashlib.sha256(catalog).hexdigest(),'producer_stdout_sha256':hashlib.sha256(reloaded_catalog).hexdigest()},indent=2))
            reloaded,registration=runtime.freshNative()
            self.assertNotEqual(registration['instance'],runtime.scope['instance'])
            self.assertTrue(any(story['id']=='Card / default busy' for story in reloaded['state']['stories']))
            self.assertEqual(reloaded['chats'][0]['messages'],[])
            checked(1,'persisted source recompiles equivalent catalog content and loads into fresh actual native production VM')
            self.assertEqual(runtime.providerIdentity(),identity)
            post(runtime.origin+'/api/agent/close',{'sessionId':sid})
            wait(lambda:not any(row[2] and row[2][0]==str(runtime.provider) and str(runtime.scenario) in row[2] for row in runtime.observer.snapshot().values()),'actual provider closes')
            # The revoked conversation credential retained by the real provider
            # cannot continue querying this editor. This probe runs on the host,
            # so resolve the observed sandbox gateway back to the actual host
            # callback loopback, preserving port/path and every scoped identity.
            # It still executes the production private wrapper and real CLI.
            from urllib.parse import urlsplit,urlunsplit
            revoked_scope=json.loads((runtime.private/'provider-scope.json').read_text())
            endpoint=urlsplit(revoked_scope['ISONIM_EDITOR_ENDPOINT'])
            if endpoint.hostname=='10.0.2.2':
                revoked_scope['ISONIM_EDITOR_ENDPOINT']=urlunsplit(endpoint._replace(netloc='127.0.0.1:'+str(endpoint.port)))
            revoked_file=runtime.private/'revoked-host-scope.json'
            revoked_file.write_text(json.dumps(revoked_scope));revoked_file.chmod(0o600)
            revoked=subprocess.run([sys.executable,str(ROOT/'tools/editor_agent_env.py'),'--environment',str(revoked_file),'--',str(ROOT/'build/bin/isonim'),'editor','state'],env=runtime.env,capture_output=True,text=True,timeout=10)
            self.assertEqual(revoked.returncode,3);self.assertIn('invalid_control_credential',revoked.stdout)
            (runtime.artifacts/'revoked-result.json').write_text(revoked.stdout)
            checked(9,'actual provider tool credential revoked on close')
            (runtime.artifacts/'outcomes.json').write_text(json.dumps(evidence,indent=2))
        finally:
            try:(runtime.artifacts/'final-host-state.json').write_text(json.dumps(runtime.action(),indent=2))
            finally:runtime.close()

if __name__=='__main__':unittest.main()
