#!/usr/bin/env python3
"""Authoring evidence controls using real temporary files and protocol data.

No provider, HTTP, compiler or tool result is mocked. Constructed JSON-RPC
records are input examples for this pure evidence parser, including malformed
and adversarial records that a real provider must never make acceptable. The
separate required real-Claude gate proves the actual provider/tool boundary.

The two heredoc body fixtures preserve actual failed live-run bodies at wire
orders195/203; only their private canonical path is replaced by this real
fixture path. These validation copies exercise the common AST/provenance
oracle, never execute model commands or substitute for fresh live acceptance.
The compound inspection fixture likewise preserves the exact rejected live
command at wire149, replacing only its private path with a real temporary file.
Its synthetic protocol rows test the shared parser, not native delivery.
"""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from helpers.editor_authoring_evidence import correlated_responses, verify_tool_inputs


ACTUAL_HEREDOC_BODIES = (
    'import json\nwith open("FIXTURE_CAPTURE_PATH") as f:\n    data = f.read()\nobj = json.loads(data)\nres = obj["result"]\nprint("ready:", res["ready"])\nprint("format:", res["format"])\nprint("viewport:", res.get("viewport"))\nhtml = res["documentHtml"]\nprint("html length:", len(html))\n# find title\nimport re\nm = re.search(r"<title>(.*?)</title>", html)\nprint("title:", m.group(1) if m else None)\nm2 = re.search(r\'<meta name="isonim-rendered-story" content="(.*?)"\', html)\nprint("rendered-story meta:", m2.group(1) if m2 else None)\nm3 = re.search(r\'<meta name="isonim-rendered-generation" content="(.*?)"\', html)\nprint("rendered-generation meta:", m3.group(1) if m3 else None)\n',
    'import json, re\nwith open("FIXTURE_CAPTURE_PATH") as f:\n    obj = json.loads(f.read())\nhtml = obj["result"]["documentHtml"]\nbody_start = html.find("<body")\nprint(html[body_start:body_start+2500])\n'
)


ACTUAL_INSPECTION_COMMAND = 'wc -c FIXTURE_CAPTURE_PATH\ngrep -o \'<body[^>]*>\' FIXTURE_CAPTURE_PATH\npython3 -c "\nimport re\nwith open(\'FIXTURE_CAPTURE_PATH\') as f:\n    data = f.read()\nimport json\nstart = data.index(\'{\')\nobj = json.loads(data[start:])\nhtml = obj[\'result\'][\'documentHtml\']\nprint(len(html))\nbody_start = html.index(\'<body\')\nprint(html[body_start:body_start+3000])\n"\n'


class AuthoringEvidence(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.session = 'actual-session'
        self.path = Path(self.directory.name)/'.claude/projects/project'/self.session/'tool-results/capture.txt'
        self.path.parent.mkdir(parents=True)
        self.result = {'operationId': 'capture-one', 'status': 'applied',
                        'request': {'command': 'capture-preview'},
                        'result': {'ready': True, 'format': 'text/html',
                                  'documentHtml': '<html><body>current preview</body></html>'}}
        self.raw = json.dumps(self.result)
        self.path.write_text(self.raw)
        self.captures = {1: {'capture-one': copy.deepcopy(self.result)}}
        self.wire = [
            {'direction': 'request', 'message': {'method': 'session/prompt', 'params': {'sessionId': self.session}}},
            self.update('capture-tool', rawInput={'command': 'isonim editor capture-preview --command-id capture-one --wait'}),
            self.update('capture-tool', status='completed', content=[{'type': 'content', 'content': {'type': 'text', 'text':
                f'<persisted-output>\nOutput too large. Full output saved to: {self.path}\n\nPreview (first 2KB):\n{self.raw[:50]}\n...\n</persisted-output>'}}]),
            self.update('read-tool', rawInput={'command': 'python3 -c '+self.quote(
                f"import json\nwith open({str(self.path)!r}) as f:\n data=json.load(f)\nprint(data['result'].get('documentHtml'))")})]

    @staticmethod
    def quote(value):
        import shlex
        return shlex.quote(value)

    def update(self, tool, **fields):
        return {'direction': 'response', 'message': {'method': 'session/update', 'params': {
            'sessionId': self.session, 'update': {'toolCallId': tool,
            '_meta': {'claudeCode': {'toolName': 'Bash'}}, **fields}}}}

    def verify(self, wire=None, captures=None):
        return verify_tool_inputs(wire or self.wire, 'PRIVATE_NONCE', self.captures if captures is None else captures, self.session)

    def test_jsonrpc_direction_does_not_confuse_provider_request(self):
        response = {'direction': 'response', 'message': {'id': 2, 'result': {'sessionId': 'actual'}}}
        request = {'direction': 'response', 'message': {'id': 2, 'method': 'session/request_permission', 'params': {}}}
        wire = [request, response]
        self.assertEqual(correlated_responses(wire, {'id': 2}), [response['message']])
        self.assertEqual(len(wire), 2)
        self.assertEqual(correlated_responses([request], {'id': 2}), [])
        self.assertEqual(len(correlated_responses([response, response], {'id': 2})), 2)

    def test_malformed_response_cannot_be_accepted(self):
        for message in ({'id': 2}, {'id': 2, 'result': {}, 'error': None}):
            with self.subTest(message=message), self.assertRaises(AssertionError):
                correlated_responses([{'direction': 'response', 'message': message}], {'id': 2})

    def test_current_exact_capture_offload_is_allowed(self):
        proof = self.verify()
        self.assertEqual(len(proof), 1)
        self.assertEqual(proof[0]['originTool'], 'capture-tool')
        self.assertEqual(proof[0]['readTool'], 'read-tool')
        self.assertEqual(proof[0]['operationId'], 'capture-one')
        self.assertEqual(proof[0]['turn'], 1)

    def current_reader(self, form):
        wire = copy.deepcopy(self.wire)
        update = wire[-1]['message']['params']['update']
        if form == 'grep':
            update['_meta']['claudeCode']['toolName'] = 'Grep'
            update['rawInput'] = {'pattern': '"id":"Hero pane', 'path': str(self.path),
                                  'output_mode': 'content', 'head_limit': 20}
        elif form in ('inspection', 'wc', 'shellgrep'):
            command = ACTUAL_INSPECTION_COMMAND.replace('FIXTURE_CAPTURE_PATH', str(self.path))
            if form == 'wc':
                command = 'wc -c '+self.quote(str(self.path))
            elif form == 'shellgrep':
                command = "grep -o '<body[^>]*>' "+self.quote(str(self.path))
            update['rawInput']['command'] = command
        elif form.startswith('heredoc'):
            body=ACTUAL_HEREDOC_BODIES[0 if form=='heredoc195' else 1].replace('FIXTURE_CAPTURE_PATH', str(self.path))
            update['rawInput']['command'] = "python3 - <<'EOF'\n"+body+'EOF'
        else:
            update['rawInput']['command'] += ' 2>&1 | head -60'
        return wire

    def test_actual_same_result_inspections_preserve_quoted_newlines(self):
        wire = self.current_reader('inspection')
        command = wire[-1]['message']['params']['update']['rawInput']['command']
        self.assertGreater(command.count('\n'), 3)
        for variant in (command, command[:-1], command.replace('python3 -c', 'python -c')):
            wire[-1]['message']['params']['update']['rawInput']['command'] = variant
            proof = self.verify(wire)
            self.assertEqual((proof[0]['operationId'], proof[0]['turn'], proof[0]['originTool']),
                              ('capture-one', 1, 'capture-tool'))
        for form in ('wc', 'shellgrep'):
            self.assertEqual(self.verify(self.current_reader(form))[0]['operationId'], 'capture-one')

    def test_inspections_reject_shell_syntax_options_and_mismatched_paths(self):
        wire = self.current_reader('inspection')
        base = wire[-1]['message']['params']['update']['rawInput']['command']
        path = str(self.path)
        variants = [base.replace('wc -c', head, 1) for head in
                    ('wc', 'wc -l', 'wc -c -c', 'wc --bytes', 'wc -c --', 'wc -c $EXTRA')]
        variants += [base.replace("grep -o '<body[^>]*>'", head, 1) for head in
                      ('grep -o', 'grep -o -e body', 'grep -o -- body', 'grep -o -f patterns',
                      'grep -o -n body', 'grep -o "$(cat history.jsonl)"',
                      'grep -o "$PATTERN"', 'grep -o "`cat history.jsonl`"',
                      "grep -o ''", "grep -o '-body'")]
        variants += [base.replace('wc -c '+path, 'wc -c '+target, 1) for target in
                      (path+' other.txt', str(self.path.parent/'other.txt'), '$FILE',
                      '"$FILE"', '$(echo '+path+')', '`echo '+path+'`', path+'*')]
        variants += [base.replace(
                          "'<body[^>]*>' "+path, "'<body[^>]*>' "+str(self.path.parent/'other.txt'), 1)]
        variants += [base+tail for tail in ('true', '\ntrue', '\ncat '+path, '\n',
                                            '; true', ' && true', ' > output.txt', ' | cat', '\nwc -c '+path)]
        variants += [base.replace('\ngrep', separator+'grep', 1) for separator in
                      ('; ', ' && ', ' | ', ' & ', '\\\n', '\n#comment\n')]
        variants += [base.replace('python3 -c "', 'python3 -c "print(\'$HOME\')\n', 1),
                      base.replace('python3 -c "', 'python3 -c "print(\'$(true)\')\n', 1),
                      base.replace('python3 -c "', 'python3 -c "print(\'`true`\')\n', 1),
                      base.replace('\n', '\r\n'), base+'\x00', base.replace('wc -c ', 'wc -c < ', 1),
                      base.replace("'<body[^>]*>'", "'<body\n[^>]*>'", 1),
                      base.replace('wc -c '+path, 'wc -c '+self.quote(path)+' > output', 1)]
        for command in variants:
            wire[-1]['message']['params']['update']['rawInput']['command'] = command
            with self.subTest(command=command), self.assertRaises((AssertionError, ValueError, SyntaxError)):
                self.verify(wire)

    def test_inspections_preserve_python_capability_and_turn_guards(self):
        wire = self.current_reader('inspection')
        base = wire[-1]['message']['params']['update']['rawInput']['command']
        for escape in ("open('history.jsonl')", "f.write('changed')", "open('output', 'w')",
                        "import os", "import subprocess", "alias=open", "alias=f.read",
                        "alias=json", "eval('1')", "exec('1')", "__import__('os')",
                        "sorted(['history'], key=open)", "getattr(obj, 'get')('result')"):
            crossed = copy.deepcopy(wire)
            crossed[-1]['message']['params']['update']['rawInput']['command'] = (
                base.replace('\"\n', '\n'+escape+'\n\"\n'))
            with self.subTest(escape=escape), self.assertRaises(AssertionError):
                self.verify(crossed)
        with self.assertRaises(AssertionError):
            self.verify(wire, {2: copy.deepcopy(self.captures[1])})
        with self.assertRaises(AssertionError):
            self.verify(wire[:2]+[wire[3], wire[2]])

    def test_current_sdk_grep_of_create_result_is_authenticated(self):
        # Observed SDK input shape; full independently acknowledged JSON, rather
        # than the matched/clipped output, supplies the authentication boundary.
        result = copy.deepcopy(self.result)
        result['request']['command'] = 'create-story'
        result['result'] = {'ok': True, 'storyId': 'Hero pane / example 1'}
        raw = json.dumps(result)
        self.path.write_text(raw)
        wire = self.current_reader('grep')
        wire[1]['message']['params']['update']['rawInput']['command'] = (
            'isonim editor create-story --command-id capture-one --wait')
        wire[2]['message']['params']['update']['content'][0]['content']['text'] = (
            f'<persisted-output>\nFull output saved to: {self.path}\n\n'
            f'Preview (first 2KB):\n{raw[:50]}\n...\n</persisted-output>')
        proof = self.verify(wire, {1: {'capture-one': result}})
        self.assertEqual((proof[0]['command'], proof[0]['originTool'], proof[0]['turn']),
                          ('create-story', 'capture-tool', 1))

    def test_current_python_result_reader_with_output_head_is_authenticated(self):
        wire = self.current_reader('head')
        program = (f"import json,re\nwith open({str(self.path)!r}) as f:\n"
                    " data=json.load(f)\noutput=data.get('result', {})\n"
                    "print(output.get('ready'), output.get('format'), data.get('revision'), data.get('status'))\n"
                    "html=output.get('documentHtml', '')\n"
                    "body=re.search('<body>(.*?)</body>', html, re.DOTALL)\nprint(body.group(1))")
        base = 'python3 -c '+self.quote(program)
        for suffix in (' | head -60', ' 2>&1 | head -60'):
            wire[-1]['message']['params']['update']['rawInput']['command'] = base+suffix
            with self.subTest(suffix=suffix):
                proof = self.verify(wire)
                self.assertEqual((proof[0]['operationId'], proof[0]['originTool']),
                                  ('capture-one', 'capture-tool'))

    def test_actual_literal_heredoc_bodies_are_authenticated(self):
        for form in ('heredoc195', 'heredoc203'):
            wire=self.current_reader(form)
            base=wire[-1]['message']['params']['update']['rawInput']['command']
            for command in (base, base+'\n', base.replace("<<'EOF'", '<<"EOF"')):
                wire[-1]['message']['params']['update']['rawInput']['command']=command
                with self.subTest(form=form, delimiter=command.split('\n')[0]):
                    proof=self.verify(wire)
                    self.assertEqual((proof[0]['operationId'],proof[0]['turn'],proof[0]['originTool']),('capture-one',1,'capture-tool'))
            # These characters are literal under quoted heredoc semantics.
            wire[-1]['message']['params']['update']['rawInput']['command']=base[:-3]+"print('$HOME $(cat history.jsonl) `cat history.jsonl`')\nEOF"
            self.assertEqual(self.verify(wire)[0]['operationId'],'capture-one')

    def test_literal_heredoc_rejects_unsafe_shell_wrappers(self):
        for form in ('heredoc195','heredoc203'):
            wire=self.current_reader(form)
            base=wire[-1]['message']['params']['update']['rawInput']['command']
            header,body=base.split('\n',1)
            headers=("python3 - <<EOF", "python3 - <<$EOF", "python3 - <<'E'OF", "python3 - <<$(echo EOF)",
                      "python3 - <<'EOF'; true", "python3 - <<'EOF' | cat", "python3 - <<'EOF' > output.txt",
                      "python3 - <<'EOF' 2>&1", "python3 - <<'EOF' <<'OTHER'", "python3 - x <<'EOF'",
                      "$(echo python3) - <<'EOF'", "python3 - <<-'EOF'", "python3 - <<'E\nOF'")
            commands=[h+'\n'+body for h in headers]
            commands += [base+'\ntrue',base+'\n\n',base[:-3]+' EOF',base[:-3]+'EOF ',base[:-3]+'OTHER',
                          base.replace('\n','\r\n'),base+'\x00',header+'\nEOF\n'+body,
                          header+"\ntext='''\nEOF\n'''\n"+body]
            for command in commands:
                wire[-1]['message']['params']['update']['rawInput']['command']=command
                with self.subTest(form=form,wrapper=command.split('\n')[0]),self.assertRaises((AssertionError,ValueError,SyntaxError)):
                    self.verify(wire)

    def test_literal_heredoc_preserves_capability_and_turn_guards(self):
        for form in ('heredoc195','heredoc203'):
            wire=self.current_reader(form)
            base=wire[-1]['message']['params']['update']['rawInput']['command']
            escapes=("open('history.jsonl')", "import os", "__import__('os')", "eval('1')", "getattr(obj,'get')('result')",
                      "alias=open", "alias=f.read", "alias=json", "sorted(['history.jsonl'],key=open)", "f.write('changed')",
                      "open('history.jsonl', 'w')", "import subprocess; subprocess.run(['true'])")
            for escape in escapes:
                crossed=copy.deepcopy(wire)
                crossed[-1]['message']['params']['update']['rawInput']['command']=base[:-3]+escape+'\nEOF'
                with self.subTest(form=form,escape=escape),self.assertRaises(AssertionError):self.verify(crossed)
            with self.subTest(form=form,later_ack=True),self.assertRaises(AssertionError):
                self.verify(wire,{2:copy.deepcopy(self.captures[1])})
            # Moving advertisement after the actual read cannot backfill origin.
            with self.subTest(form=form,later_origin=True),self.assertRaises(AssertionError):
                self.verify(wire[:2]+[wire[3],wire[2]])

    def test_sdk_grep_rejects_extra_inputs_and_invalid_options(self):
        good = self.current_reader('grep')[-1]['message']['params']['update']['rawInput']
        changes = ({'head_limit': True}, {'head_limit': 0}, {'head_limit': -20},
                    {'head_limit': '20'}, {'head_limit': 1.5}, {'pattern': None},
                    {'pattern': ''}, {'path': [str(self.path)]}, {'path': ''},
                    {'path': str(self.path.parent)}, {'path': str(self.path.parent/'*.txt')},
                    {'path': str(self.path.parent/'[capture].txt')},
                    {'path': str(self.path)+'\nother.txt'}, {'glob': '*.txt'},
                    {'output_mode': 'files_with_matches'}, {'multiline': True},
                    {'other_file': 'history.jsonl'}, {'pattern': 'PRIVATE_NONCE'})
        for change in changes:
            wire = self.current_reader('grep')
            wire[-1]['message']['params']['update']['rawInput'].update(change)
            if change.get('path') == '':
                # Keep the private-history reference when the path is missing;
                # ordinary project Grep is outside this parser's exception.
                wire[-1]['message']['params']['update']['rawInput']['pattern'] = str(self.path)
            with self.subTest(change=change), self.assertRaises(AssertionError):
                self.verify(wire)
        for key in good:
            wire = self.current_reader('grep')
            del wire[-1]['message']['params']['update']['rawInput'][key]
            if key == 'path':
                wire[-1]['message']['params']['update']['rawInput']['pattern'] = str(self.path)
            with self.subTest(missing=key), self.assertRaises(AssertionError):
                self.verify(wire)

    def test_output_head_rejects_shell_inputs_and_capability_escapes(self):
        base = self.wire[-1]['message']['params']['update']['rawInput']['command']
        suffixes = (' | head -0', ' | head --60', ' | head -1.5', ' | head -$LIMIT',
                    ' | head -$(cat history.jsonl)', ' | head -60 history.jsonl',
                    ' | head -60 -v', ' | head -60 | cat', ' | head -60; cat history.jsonl',
                    ' | head -60 > output.txt', ' 2> history.jsonl | head -60',
                    ' 2>&1 2>&1 | head -60', ' | head -60 2>&1',
                    ' | head -60 && true')
        for suffix in suffixes:
            wire = self.current_reader('head')
            wire[-1]['message']['params']['update']['rawInput']['command'] = base+suffix
            with self.subTest(suffix=suffix), self.assertRaises(AssertionError):
                self.verify(wire)
        prefix = f"import json\nwith open({str(self.path)!r}) as f:\n data=json.load(f)\n"
        for escape in ("open('history.jsonl')", "f.write('changed')", "alias=open",
                        "alias=f.read", "getattr(data, 'get')('result')",
                        "sorted(['history.jsonl'], key=open)", "import os", "eval('1')"):
            wire = self.current_reader('head')
            wire[-1]['message']['params']['update']['rawInput']['command'] = (
                'python3 -c '+self.quote(prefix+escape)+' 2>&1 | head -60')
            with self.subTest(escape=escape), self.assertRaises(AssertionError):
                self.verify(wire)
        for command in ('cat '+str(self.path)+' | head -60',
                        'cat '+str(self.path)+' | python3 -c '+self.quote(
                            'import sys,json; print(json.load(sys.stdin))')+' | head -60'):
            wire = self.current_reader('head')
            wire[-1]['message']['params']['update']['rawInput']['command'] = command
            with self.subTest(command=command), self.assertRaises(AssertionError):
                self.verify(wire)

    def test_new_read_forms_preserve_all_current_result_provenance_guards(self):
        for form in ('grep', 'head', 'heredoc195', 'heredoc203', 'inspection', 'wc', 'shellgrep'):
            wire = self.current_reader(form)
            self.assertEqual(self.verify(wire)[0]['operationId'], 'capture-one')
            unreferenced = wire[:2]+wire[3:]
            stale = wire[:3]+[copy.deepcopy(wire[0])]+wire[3:]
            incomplete = copy.deepcopy(wire)
            incomplete[2]['message']['params']['update']['status'] = 'running'
            wrong_session = copy.deepcopy(wire)
            wrong_session[-1]['message']['params']['sessionId'] = 'other-session'
            wrong_origin = copy.deepcopy(wire)
            wrong_origin[1]['message']['params']['update']['rawInput']['command'] = 'isonim editor state'
            for candidate in (unreferenced, stale, incomplete, wrong_session, wrong_origin):
                with self.subTest(form=form, wire=candidate), self.assertRaises(AssertionError):
                    self.verify(candidate)
            with self.subTest(form=form, acknowledgement='missing'), self.assertRaises(AssertionError):
                self.verify(wire, {})
            forged = copy.deepcopy(self.captures)
            forged[1]['capture-one']['epoch'] = 'other-epoch'
            with self.subTest(form=form, acknowledgement='wrong scope'), self.assertRaises(AssertionError):
                self.verify(wire, forged)
            changed_file = copy.deepcopy(self.result)
            changed_file['result']['documentHtml'] = 'forged after advertised prefix'
            self.path.write_text(json.dumps(changed_file))
            with self.subTest(form=form, acknowledgement='prefix alone'), self.assertRaises(AssertionError):
                self.verify(wire)
            self.path.write_text(self.raw)
            self.path.write_text(self.raw+'PRIVATE_NONCE')
            with self.subTest(form=form, nonce='full file'), self.assertRaises(AssertionError):
                self.verify(wire)
            self.path.write_text(self.raw)
            unsuccessful = copy.deepcopy(self.result)
            unsuccessful['result']['ready'] = False
            raw = json.dumps(unsuccessful)
            self.path.write_text(raw)
            failed = copy.deepcopy(wire)
            failed[2]['message']['params']['update']['content'][0]['content']['text'] = (
                f'<persisted-output>\nFull output saved to: {self.path}\n\n'
                f'Preview (first 2KB):\n{raw[:50]}\n...\n</persisted-output>')
            with self.subTest(form=form, unsuccessful=True), self.assertRaises(AssertionError):
                self.verify(failed, {1: {'capture-one': unsuccessful}})
            self.path.write_text(self.raw)
            alias = self.path.parent/'alias.txt'
            alias.symlink_to(self.path)
            try:
                for target in (self.path.parent/'other.txt',
                                self.path.parent.parent/'history.jsonl', alias,
                                self.path.parent/'PRIVATE_NONCE.txt'):
                    changed = copy.deepcopy(wire)
                    update = changed[-1]['message']['params']['update']
                    if form == 'grep':
                        update['rawInput']['path'] = str(target)
                    else:
                        update['rawInput']['command'] = update['rawInput']['command'].replace(str(self.path), str(target))
                    with self.subTest(form=form, target=str(target)), self.assertRaises(AssertionError):
                        self.verify(changed)
                # Advertised aliases must still fail the canonical no-symlink boundary.
                changed[2]['message']['params']['update']['content'][0]['content']['text'] = (
                    changed[2]['message']['params']['update']['content'][0]['content']['text'].replace(str(self.path), str(alias)))
                if form == 'grep':
                    changed[-1]['message']['params']['update']['rawInput']['path'] = str(alias)
                else:
                    changed[-1]['message']['params']['update']['rawInput']['command'] = (
                        wire[-1]['message']['params']['update']['rawInput']['command'].replace(str(self.path), str(alias)))
                with self.subTest(form=form, advertised_symlink=True), self.assertRaises(AssertionError):
                    self.verify(changed)
                for target in (self.path.parent/'..'/'tool-results'/self.path.name,
                                self.path.parent.parent.parent/'other-session'/'tool-results/capture.txt',
                                self.path.parent.parent/'history.jsonl'):
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text(self.raw)
                    changed = copy.deepcopy(wire)
                    changed[2]['message']['params']['update']['content'][0]['content']['text'] = (
                        changed[2]['message']['params']['update']['content'][0]['content']['text'].replace(str(self.path), str(target)))
                    if form == 'grep':
                        changed[-1]['message']['params']['update']['rawInput']['path'] = str(target)
                    else:
                        changed[-1]['message']['params']['update']['rawInput']['command'] = (
                            wire[-1]['message']['params']['update']['rawInput']['command'].replace(str(self.path), str(target)))
                    with self.subTest(form=form, advertised_invalid_path=str(target)), self.assertRaises(AssertionError):
                        self.verify(changed)
            finally:
                alias.unlink()

    def test_current_sdk_read_and_stdin_pipeline_are_authenticated(self):
        read = copy.deepcopy(self.wire)
        update = read[-1]['message']['params']['update']
        update['_meta']['claudeCode']['toolName'] = 'Read'
        update['rawInput'] = {'file_path': str(self.path), 'offset': 1, 'limit': 100}
        self.assertEqual(self.verify(read)[0]['operationId'], 'capture-one')
        pipeline = copy.deepcopy(self.wire)
        pipeline[-1]['message']['params']['update']['rawInput']['command'] = (
            'cat '+str(self.path)+' | python3 -c '+self.quote(
                "import sys, json, re\nr=json.load(sys.stdin)\nhtml=r.get('result', {}).get('documentHtml', '')\nbody=re.search('<body>(.*?)</body>', html, re.DOTALL)\nprint(body.group(1))")+' 2>&1')
        self.assertEqual(self.verify(pipeline)[0]['originTool'], 'capture-tool')
        for candidate in (read, pipeline):
            with self.assertRaises(AssertionError):
                self.verify(candidate[:2]+candidate[3:])
            with self.assertRaises(AssertionError):
                self.verify(candidate[:3]+[copy.deepcopy(self.wire[0])]+candidate[3:])
            with self.assertRaises(AssertionError):
                self.verify(candidate, captures={})

    def test_stderr_merge_does_not_allow_file_redirects_or_extra_commands(self):
        wire = copy.deepcopy(self.wire)
        command = wire[-1]['message']['params']['update']['rawInput']['command']
        wire[-1]['message']['params']['update']['rawInput']['command'] = command+' 2>&1'
        self.assertEqual(self.verify(wire)[0]['operationId'], 'capture-one')
        for suffix in (' 2> history.jsonl', ' > output.txt', ' 2>&1; cat history.jsonl',
                        ' 2>&1 | cat history.jsonl', ' 2>&1 2>&1'):
            wire[-1]['message']['params']['update']['rawInput']['command'] = command+suffix
            with self.subTest(suffix=suffix), self.assertRaises(AssertionError):
                self.verify(wire)

    def test_sdk_read_rejects_history_extra_input_and_invalid_bounds(self):
        for data in ({'file_path': str(self.path.parent.parent/'history.jsonl')},
                      {'file_path': str(self.path), 'other_file': 'history.jsonl'},
                      {'file_path': str(self.path), 'limit': True},
                      {'file_path': str(self.path), 'offset': -1},
                      {'file_path': str(self.path), 'limit': '100'},
                      {'file_path': str(self.path), 'limit': 0}):
            wire = copy.deepcopy(self.wire)
            update = wire[-1]['message']['params']['update']
            update['_meta']['claudeCode']['toolName'] = 'Read'
            update['rawInput'] = data
            with self.subTest(data=data), self.assertRaises(AssertionError):
                self.verify(wire)

    def test_pipeline_cannot_open_additional_files_or_run_processes(self):
        for program in ("import sys,json; json.load(sys.stdin); open('history.jsonl')",
                        "import os; os.system('cat history.jsonl')",
                        "import sys,json; json.load(open('history.jsonl'))",
                        "import sys,json; sys.stdin=open('history.jsonl')"):
            wire = copy.deepcopy(self.wire)
            wire[-1]['message']['params']['update']['rawInput']['command'] = (
                'cat '+str(self.path)+' | python3 -c '+self.quote(program))
            with self.subTest(program=program), self.assertRaises(AssertionError):
                self.verify(wire)

    def test_all_current_applied_authoring_results_require_exact_acknowledgement(self):
        for command in ('create-story', 'build', 'open-story', 'capture-preview'):
            result = copy.deepcopy(self.result)
            result['request']['command'] = command
            result['request']['storyId'] = 'Hero pane / example 1'
            result['result'].update(ok=True, storyId='Hero pane / example 1', catalog={'stories': []})
            raw = json.dumps(result)
            self.path.write_text(raw)
            wire = copy.deepcopy(self.wire)
            wire[1]['message']['params']['update']['rawInput']['command'] = (
                'isonim editor '+command+' --command-id capture-one --wait')
            content = wire[2]['message']['params']['update']['content'][0]['content']
            content['text'] = (f'<persisted-output>\nFull output saved to: {self.path}\n\n'
                                f'Preview (first 2KB):\n{raw[:50]}\n...\n</persisted-output>')
            wire[-1]['message']['params']['update']['rawInput']['command'] = 'python3 -c '+self.quote(
                f"import json,re\nwith open({str(self.path)!r}) as f:\n data=json.load(f)\nprint(json.dumps(data.get('result', {{}})))\nprint(data.get('status','').lower())")+' 2>&1'
            expected = {1: {'capture-one': copy.deepcopy(result)}}
            with self.subTest(command=command):
                self.assertEqual(self.verify(wire, expected)[0]['command'], command)
                with self.assertRaises(AssertionError):
                    self.verify(wire, {})
                forged = copy.deepcopy(expected)
                forged[1]['capture-one']['revision'] = 999
                with self.assertRaises(AssertionError):
                    self.verify(wire, forged)
                self.path.write_text(raw+'PRIVATE_NONCE')
                with self.assertRaises(AssertionError):
                    self.verify(wire, expected)
                self.path.write_text(raw)

    def test_wrong_or_unsuccessful_operation_result_is_rejected(self):
        for command, output in (('state', {}), ('create-story', {'ok': False}),
                                ('build', {'ok': False}), ('open-story', {})):
            result = copy.deepcopy(self.result)
            result['request']['command'] = command
            result['result'] = output
            raw = json.dumps(result)
            self.path.write_text(raw)
            wire = copy.deepcopy(self.wire)
            wire[1]['message']['params']['update']['rawInput']['command'] = (
                'isonim editor '+command+' --command-id capture-one --wait')
            wire[2]['message']['params']['update']['content'][0]['content']['text'] = (
                f'<persisted-output>\nFull output saved to: {self.path}\n\nPreview (first 2KB):\n{raw[:50]}\n...\n</persisted-output>')
            with self.subTest(command=command), self.assertRaises(AssertionError):
                self.verify(wire, {1: {'capture-one': result}})

    def test_pure_excerpt_processing_cannot_escape_to_capabilities(self):
        wire = copy.deepcopy(self.wire)
        prefix = f"import json\nwith open({str(self.path)!r}) as f:\n data=json.load(f)\nhtml=data['result']['documentHtml']\n"
        command = 'python3 -c '+self.quote(prefix+
            "print(html[html.find('<body'):min(html.find('<body')+3000,len(html))])\nprint(str(max([1,2])), sum([1,2]), list(sorted([2,1])))")
        wire[-1]['message']['params']['update']['rawInput']['command'] = command
        self.assertEqual(self.verify(wire)[0]['operationId'], 'capture-one')
        for escape in ("eval('1')", "exec('print(1)')", "getattr(data, 'get')('result')",
                        "__import__('os')", "globals()", "locals()", "input()",
                        "open('history.jsonl')", "f.write('changed')",
                        "alias=open", "alias=json", "alias=f.read",
                        "sorted(['history.jsonl'], key=open)",
                        "sorted(['history.jsonl'], key=json.load)",
                        "sorted(['history.jsonl'], key=f.read)",
                        "re.sub('x', open, 'history.jsonl')") :
            wire[-1]['message']['params']['update']['rawInput']['command'] = 'python3 -c '+self.quote(prefix+escape)
            with self.subTest(escape=escape), self.assertRaises(AssertionError):
                self.verify(wire)

    def test_unreferenced_and_stale_result_are_rejected(self):
        with self.assertRaises(AssertionError):
            self.verify(self.wire[:2]+self.wire[3:])
        stale = self.wire[:3]+[copy.deepcopy(self.wire[0])]+self.wire[3:]
        with self.assertRaises(AssertionError):
            self.verify(stale)
        with self.assertRaises(AssertionError):
            self.verify(captures={})

    def test_changed_file_or_forged_capture_cannot_pass(self):
        changed = copy.deepcopy(self.result)
        changed['result']['documentHtml'] = 'other contents'
        self.path.write_text(json.dumps(changed))
        with self.assertRaises(AssertionError):
            self.verify()
        self.path.write_text(self.raw)
        wrong = copy.deepcopy(self.captures)
        wrong[1]['capture-one']['request']['command'] = 'state'
        with self.assertRaises(AssertionError):
            self.verify(captures=wrong)

    def test_nonce_in_file_reference_or_input_is_rejected(self):
        self.path.write_text(self.raw+'PRIVATE_NONCE')
        with self.assertRaises(AssertionError):
            self.verify()
        self.path.write_text(self.raw)
        for suffix in (' PRIVATE_NONCE', ' .scenario/private/context-nonce.json', str(self.path.parent/'PRIVATE_NONCE.txt')):
            wire = copy.deepcopy(self.wire)
            wire[-1]['message']['params']['update']['rawInput']['description'] = suffix
            with self.subTest(suffix=suffix), self.assertRaises(AssertionError):
                self.verify(wire)

    def test_history_transcript_and_arbitrary_results_are_rejected(self):
        for target in (self.path.parent.parent/'conversation.jsonl',
                        self.path.parent/'arbitrary.txt', self.path.parent/'real-provider-wire.jsonl'):
            target.write_text(self.raw)
            wire = copy.deepcopy(self.wire)
            wire[-1]['message']['params']['update']['rawInput']['command'] = 'cat '+str(target)
            with self.subTest(target=target.name), self.assertRaises(AssertionError):
                self.verify(wire)

    def test_additional_and_dynamic_reads_are_rejected(self):
        for command in ('cat '+str(self.path)+'; cat conversation.jsonl',
                        'python3 -c '+self.quote(f"open({str(self.path)!r}); open('conversation.jsonl')"),
                        'python3 -c '+self.quote(f"import os; open({str(self.path)!r}); os.system('cat history')")):
            wire = copy.deepcopy(self.wire)
            wire[-1]['message']['params']['update']['rawInput']['command'] = command
            with self.subTest(command=command), self.assertRaises(AssertionError):
                self.verify(wire)

    def test_origin_and_provider_identity_are_required(self):
        wrong = copy.deepcopy(self.wire)
        wrong[1]['message']['params']['update']['rawInput']['command'] = 'isonim editor state'
        with self.assertRaises(AssertionError):
            self.verify(wrong)
        wrong = copy.deepcopy(self.wire)
        wrong[-1]['message']['params']['sessionId'] = 'other-session'
        with self.assertRaises(AssertionError):
            self.verify(wrong)


if __name__ == '__main__':
    unittest.main(verbosity=2)
