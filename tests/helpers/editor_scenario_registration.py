"""Required scenario recipe closure, checked by the real existing drivers.

This static guard complements runtime tests: a removed resource execute edge or
probe input must fail an already registered driver, rather than silently dropping
coverage. It parses the relevant ordinary Nim call blocks, strips comments, and
requires their unchanged action identities, producer prerequisites and collector
membership. It does not compile/evaluate Repro's graph or substitute any producer.
"""
import re

SOURCES = {
    'tests/test_editor_scenarios.py': 'isonim.scenario_execute.native',
    'tests/test_editor_scenario_stress.py': 'isonim.scenario_execute.stream_ownership',
    'tests/run_editor_scenarios_gui.py': 'isonim.scenario_execute.gui',
    'tests/test_editor_scenario_resources.py': 'isonim.scenario_execute.resource_visibility',
}


def call_end(clean, start):
    index, depth, quoted, escaped = start, 1, False, False
    while index < len(clean) and depth:
        char = clean[index]
        if quoted:
            if escaped: escaped = False
            elif char == '\\': escaped = True
            elif char == '"': quoted = False
        elif char == '"': quoted = True
        elif char == '(': depth += 1
        elif char == ')': depth -= 1
        index += 1
    assert depth == 0, 'Unclosed scenario edge'
    return index


def verify_recipe(source):
    # Relevant calls use plain strings; remove comments outside those strings.
    clean = re.sub(r'"(?:\\.|[^"\\])*"|#[^\n]*',
                    lambda match: '' if match[0].startswith('#') else match[0], source)
    producer_references = {}
    for match in re.finditer(r'\blet\s+(\w+)\s*=\s*([\w.]+)\(', clean):
        block = clean[match.end():call_end(clean, match.end())-1]
        identity = re.search(r'\bactionId\s*=\s*"([^"\\]*)"', block)
        if identity:
            producer_references[identity[1]] = match[1] + ('.action' if match[2] == 'buildNimUnittest.build' else '')
    references = {}
    for filename, action in SOURCES.items():
        matches = list(re.finditer(r'\blet\s+(\w+)\s*=\s*pythonUnittest\.run\(', clean))
        start = next((match for match in matches if re.search(r'\bsource\s*=\s*"' + re.escape(filename) + '"', clean[match.end():call_end(clean, match.end())-1])), None)
        assert start, 'Missing required scenario execute edge: ' + action
        variable = start[1]
        references[action] = variable
        index = call_end(clean, start.end())
        block = clean[start.end():index-1]
        assert re.search(r'\bsource\s*=\s*"' + re.escape(filename) + '"', block), action
        assert re.search(r'\bactionId\s*=\s*"' + re.escape(action) + '"', block), action
        assert not re.search(r'\bcacheable\s*=\s*true\b', block), 'Scenario execution cannot cache host verdicts'
        after = re.search(r'\bafter\s*=\s*@\[([^]]*)\]', block)
        assert after, 'Missing producer prerequisites: ' + action
        prerequisites = {value.strip() for value in after[1].split(',')}
        producer_ids = {'isonim.tool_build.isonim', 'isonim.source_build.browser',
                        'isonim.scenario_execute.preparation_clock_python',
                        'isonim.scenario_execute.preparation_clock_node'}
        if filename != 'tests/run_editor_scenarios_gui.py': producer_ids.add('isonim.scenario_build.native_host')
        assert producer_ids <= set(producer_references), 'Missing required producer identity'
        required = {producer_references[identity] for identity in producer_ids}
        assert required <= prerequisites, 'Missing producer prerequisites: ' + action
        inputs = re.search(r'\bextraInputs\s*=\s*@\[([^]]*)\]', block)
        assert inputs, 'Missing scenario inputs: ' + action
        names = set(re.findall(r'"([^"\\]*)"', inputs[1]))
        assert {'tests/helpers/editor_scenario_filesystem_probe.py',
                'tests/helpers/editor_scenario_registration.py', 'repro.nim',
                'tests/scenarios/agent-harbor/editor-workflows.yaml', filename} <= names, 'Missing scenario dependency: ' + action
        assert re.search(r'\btestExecuteActions\.add\(\s*' + variable + r'\s*\)', clean), 'Uncollected required scenario: ' + action
    for collector, actions in {
        'test-editor-scenarios-native': {'isonim.scenario_execute.native', 'isonim.scenario_execute.resource_visibility'},
        'test-editor-scenarios-stress': {'isonim.scenario_execute.stream_ownership'},
        'test-editor-scenarios-gui': {'isonim.scenario_execute.gui'},
        'test-editor-scenarios': set(SOURCES.values()),
    }.items():
        variables = {references[action] for action in actions}
        match = re.search(r'collect\("' + collector + r'",\s*@\[([^]]*)\]\)', clean)
        assert match and variables <= {item.strip() for item in match[1].split(',')}, 'Missing owning collector: ' + collector
    assert re.search(r'collect\("test",\s*testExecuteActions\)', clean), 'Required scenarios absent from full suite'
