#!/usr/bin/env python3
"""Genuine Harbor terminal visibility with two adversarial resource controls.

Only official Scenario-Format model playback substitutes inference. One native
production editor/session executes actual terminal commands and CLI state reads.
The positive turn hashes all real helper/CLI/provider/role resources, reads a
bound sentinel and proves a host-existing unbound /tmp sentinel is hidden. The
following turns poison one resource hash, then put the negative sentinel inside
the bound workspace: both must produce actual terminal assertion diagnostics,
with no proof file or CLI state output. On non-Linux hosts the latter
control names a genuinely missing bound resource instead: private /tmp is
Linux-specific, and the integration suite still runs. Real REST/SQLite, VM, compiler, process
identity and cleanup remain in use, no transport/filesystem/tool-output mock.
"""
from contextlib import closing
import json
import sqlite3
import sys
import unittest
from helpers.editor_scenario_runtime import Runtime, HARBOR, ROOT
from helpers.editor_scenario_registration import verify_recipe
from helpers.editor_process_observer import optional_sibling_available


class ResourceVisibility(unittest.TestCase):
    def test_required_registration_and_dependency_omissions_fail(self):
        recipe = (ROOT/'repro.nim').read_text()
        verify_recipe(recipe)
        for omitted in ['testExecuteActions.add(scenarioResourcesEdge)',
                        'tests/helpers/editor_scenario_filesystem_probe.py',
                        'tests/test_editor_scenario_resources.py']:
            self.assertIn(omitted, recipe)
            mutant = recipe.replace(omitted, 'REMOVED_REQUIRED_SCENARIO_INPUT')
            with self.subTest(omitted=omitted), self.assertRaises(AssertionError):
                verify_recipe(mutant)

        aggregate = 'collect("test-editor-scenarios", @[scenarioNativeEdge, scenarioResourcesEdge, scenarioStressEdge, scenarioGuiEdge])'
        self.assertIn(aggregate, recipe)
        with self.assertRaises(AssertionError):
            verify_recipe(recipe.replace(aggregate, aggregate.replace('scenarioResourcesEdge, ', '')))

    def test_real_terminal_resources_and_denial_controls(self):
        if not optional_sibling_available(HARBOR):
            self.skipTest('optional private Agent Harbor sibling absent')
        runtime = Runtime('native')
        try:
            manifest_file = runtime.private/'resource-manifest.json'
            manifest = json.loads(manifest_file.read_text())
            runtime.turn(9, 'Read actual editor state through the scoped CLI.')
            runtime.assertResourceVisibility()
            identity = runtime.providerIdentity()
            conversation = runtime.active()['backend']
            session = json.loads((runtime.private/'original-handoff.json').read_text())['session']
            self.assertNotEqual(conversation, session)
            def outputs():
                with closing(sqlite3.connect(runtime.harborState/'daemon.sqlite')) as database:
                    return [json.loads(payload).get('tool_output', '') for (payload,) in
                            database.execute("select payload from session_events where session_id=? and kind='tool_result'", (session,))]
            def cli_states(values):
                result = []
                for output in values:
                    for line in output.splitlines():
                        try: value = json.loads(line)
                        except json.JSONDecodeError: continue
                        if isinstance(value, dict) and {'workspace', 'instance', 'revision', 'permissions', 'storyId', 'selection'} <= set(value):
                            result.append(value)
                return result
            first_outputs = outputs()
            first_states = cli_states(first_outputs)
            self.assertTrue(first_states, first_outputs)
            for state in first_states:
                self.assertEqual(state['instance'], runtime.scope['instance'])
                self.assertEqual(state['workspace'], runtime.scope['workspace'])
                self.assertEqual(state['revision'], runtime.cli(['state'])['revision'])
            source = (runtime.project/runtime.source_file).read_bytes()
            cases = [('wrong-resource-hash', 'Provider resource bytes changed')]
            if sys.platform == 'linux':
                cases.append(('bound-negative-sentinel', 'Private /tmp exposed an unbound host file'))
            else:
                # Private /tmp is Linux-specific. Keep a genuine unavailable
                # resource control on other hosts instead of skipping the suite.
                cases.append(('missing-resource', 'FileNotFoundError'))
            (runtime.artifacts/'resource-visibility.json').unlink()
            for name, diagnostic in cases:
                poisoned = json.loads(json.dumps(manifest))
                if name == 'wrong-resource-hash':
                    poisoned['resources'][next(iter(poisoned['resources']))] = '0'*64
                elif name == 'bound-negative-sentinel':
                    poisoned['unboundSentinel'] = poisoned['boundSentinel']
                else:
                    poisoned['resources'][str(runtime.private/'does-not-exist')] = '0'*64
                manifest_file.write_text(json.dumps(poisoned))
                self.assertFalse((runtime.artifacts/'resource-visibility.json').exists())
                previous = len(outputs())
                runtime.turn(9, 'Read actual editor state through the scoped CLI: ' + name)
                current = outputs()[previous:]
                self.assertTrue(any(diagnostic in output for output in current), current)
                self.assertEqual(cli_states(current), [])
                self.assertFalse((runtime.artifacts/'resource-visibility.json').exists())
                self.assertEqual((runtime.project/runtime.source_file).read_bytes(), source)
                self.assertEqual(runtime.providerIdentity(), identity)
                self.assertEqual(runtime.active()['backend'], conversation)
                self.assertEqual(json.loads((runtime.private/'original-handoff.json').read_text())['session'], session)
            manifest_file.write_text(json.dumps(manifest))
            print('PASS actual terminal resource hashes and adversarial controls: ' + ', '.join(name for name, _ in cases), flush=True)
        finally:
            runtime.close()


if __name__ == '__main__':
    unittest.main()
