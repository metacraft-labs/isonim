"""Strict actual-wire evidence for the opt-in authoring acceptance gate."""
import ast
import hashlib
import json
from pathlib import Path
import re
import shlex


def correlated_responses(wire, request):
    # Provider requests share this stream and may reuse client request IDs.
    matches = [row['message'] for row in wire if row['direction'] == 'response'
               and row['message'].get('id') == request['id']
               and 'method' not in row['message']]
    if any(('result' in message) == ('error' in message) for message in matches):
        raise AssertionError('Correlated JSON-RPC response must contain exactly one result or error')
    return matches


def _inspection_commands(command):
    """Split only literal shell words/newlines; never interpret shell syntax.

    Single quotes protect every character. Double quotes still permit shell
    expansion, which is rejected here. Escapes preserve only literal characters;
    continuations and unquoted shell operators/globs are outside this grammar.
    shlex decodes each validated command without losing quoted Python newlines.
    """
    quote = None
    start = 0
    commands = []
    index = 0
    while index < len(command):
        char = command[index]
        if char in '\r\x00':
            raise AssertionError('Inspection contains CR or NUL')
        if quote == "'":
            if char == "'":
                quote = None
        elif char == "\\":
            if index+1 == len(command) or command[index+1] == '\n':
                raise AssertionError('Inspection cannot continue shell lines')
            # In double quotes only these escapes suppress shell meaning.
            if quote == '"' and command[index+1] not in '\\"$`':
                index += 1
                continue
            index += 1
        elif quote == '"':
            if char == '"':
                quote = None
            elif char in '$`':
                raise AssertionError('Inspection cannot expand shell values')
        elif char in "'\"":
            quote = char
        elif char == '\n':
            commands.append(command[start:index])
            start = index+1
        elif char in '$`;&|<>()*?[]{}~#':
            raise AssertionError('Inspection requires literal shell words only')
        index += 1
    if quote:
        raise AssertionError('Inspection has an unterminated shell quote')
    commands.append(command[start:])
    if commands[-1] == '':
        commands.pop()  # One optional final newline.
    if not commands or any(not part.strip() for part in commands):
        raise AssertionError('Inspection requires nonempty newline-separated commands')
    return [(part, shlex.split(part)) for part in commands]


def literal_result_read(command):
    """Authenticate one result path, including bounded output-only inspections."""
    # Preserve every established standalone reader, including the quoted
    # heredoc, which must be recognized before shell tokenization of its body.
    if not re.match(r'^(?:wc|grep)(?:[ \t]|$)', command):
        return _single_literal_result_read(command)
    commands = _inspection_commands(command)
    paths = []
    seen = set()
    for source, words in commands:
        if len(words) == 3 and words[:2] == ['wc', '-c']:
            kind, path = 'wc', words[2]
        elif (len(words) == 4 and words[:2] == ['grep', '-o'] and
              words[2] and not words[2].startswith('-') and '\n' not in words[2]):
            kind, path = 'grep', words[3]
        elif len(words) == 3 and words[:2] in (['python3', '-c'], ['python', '-c']):
            kind, path = 'python', str(_single_literal_result_read(source))
        else:
            raise AssertionError('Inspection supports only literal wc, grep and Python readers')
        if kind in seen or not path or path.startswith('-'):
            raise AssertionError('Inspection requires one command of each kind and a literal path')
        seen.add(kind)
        paths.append(path)
    if len(set(paths)) != 1:
        raise AssertionError('All inspections must read the same literal result path')
    return Path(paths[0])


def _single_literal_result_read(command):
    """Accept one simple literal read, with no additional file/process access."""
    # Quoting the entire delimiter disables shell expansion of the body. This
    # deliberately supports only one Python stdin heredoc, not shell parsing.
    header = re.fullmatch(r"(python3|python)[ \t]+-[ \t]+<<[ \t]*(['\"])([A-Za-z_][A-Za-z0-9_]*)\2[ \t]*",
                          command.split('\n', 1)[0])
    if header:
        if '\r' in command or '\x00' in command:
            raise AssertionError('Literal heredoc cannot contain CR or NUL')
        lines = command.split('\n')
        if lines[-1] == '':
            lines.pop()  # One optional final newline, never trailing commands.
        delimiter = header[3]
        if len(lines) < 3 or lines[-1] != delimiter or delimiter in lines[1:-1]:
            raise AssertionError('Literal heredoc requires its sole exact final delimiter')
        words = [header[1], '-c', '\n'.join(lines[1:-1])+'\n']
    else:
        words = shlex.split(command)
    # An output-only head tail does not add another read. Keep this exception
    # scoped to the single Python reader below, not arbitrary shell pipelines.
    if (len(words) >= 6 and words[-3:-1] == ['|', 'head'] and
        re.fullmatch(r'-[1-9][0-9]*', words[-1])):
        words = words[:-3]
        if words and words[-1] == '2>&1':
            words.pop()
        if len(words) != 3 or words[:2] not in (['python3', '-c'], ['python', '-c']):
            raise AssertionError('Output head requires one literal Python result reader')
    # A literal stderr merge adds no file input or output. Other shell tokens
    # remain invalid, including redirection to files and command chaining.
    if words and words[-1] == "2>&1":
        words.pop()
    if len(words) == 2 and words[0] == 'cat':
        return Path(words[1])
    pipeline = (len(words) == 6 and words[0] == 'cat' and words[2] == '|'
                and words[3:5] in (['python3', '-c'], ['python', '-c']))
    if pipeline:
        path = Path(words[1])
        words = words[3:6]
    if len(words) != 3 or words[:2] not in (['python3', '-c'], ['python', '-c']):
        raise AssertionError('Private tool result requires a verifiable single literal read')
    tree = ast.parse(words[2])
    paths = []
    parents = {child: parent for parent in ast.walk(tree)
               for child in ast.iter_child_nodes(parent)}
    pure_functions = {'print', 'len', 'min', 'max', 'sum', 'abs', 'all', 'any',
                      'round', 'str', 'int', 'float', 'bool', 'list', 'dict',
                      'tuple', 'set', 'sorted', 'reversed', 'enumerate', 'range',
                      'zip', 'repr', 'format'}
    for node in ast.walk(tree):
        parent = parents.get(node)
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load):
            if node.id in pure_functions | {'open'} and not (
                isinstance(parent, ast.Call) and parent.func is node):
                raise AssertionError('Result reader cannot alias or pass bare capabilities')
            if node.id in ('json', 'sys', 're') and not (
                isinstance(parent, ast.Attribute) and parent.value is node):
                raise AssertionError('Result reader cannot alias imported modules')
        if isinstance(node, ast.Attribute) and isinstance(node.ctx, ast.Load):
            constants = (isinstance(node.value, ast.Name) and
                         (node.value.id == 'sys' and node.attr == 'stdin' or
                          node.value.id == 're' and node.attr in (
                              'DOTALL', 'IGNORECASE', 'MULTILINE', 'ASCII', 'VERBOSE')))
            if not constants and not (isinstance(parent, ast.Call) and parent.func is node):
                raise AssertionError('Result reader cannot alias methods or pass callbacks')

        if isinstance(node, ast.Import):
            allowed_imports = ('json', 'sys', 're') if pipeline else ('json', 're')
            if any(alias.name not in allowed_imports or alias.asname for alias in node.names):
                raise AssertionError('Private result reader imports an unrelated capability')
        elif isinstance(node, (ast.ImportFrom, ast.FunctionDef, ast.AsyncFunctionDef,
                               ast.ClassDef, ast.Lambda)):
            raise AssertionError('Private result reader cannot hide additional reads')
        elif isinstance(node, ast.Attribute) and node.attr.startswith('_'):
            raise AssertionError('Private result reader cannot access hidden capabilities')
        elif isinstance(node, ast.Call):
            function = node.func
            if isinstance(function, ast.Name):
                if function.id == 'open':
                    if pipeline:
                        raise AssertionError('Pipeline reader cannot open another file')
                    if (len(node.args) != 1 or node.keywords or
                        not isinstance(node.args[0], ast.Constant) or
                        not isinstance(node.args[0].value, str)):
                        raise AssertionError('Result read must name one literal file')
                    paths.append(Path(node.args[0].value))
                elif function.id not in pure_functions:
                    raise AssertionError('Private result reader calls an unrelated capability')
            elif isinstance(function, ast.Attribute):
                if pipeline and function.attr == 'load':
                    if (not isinstance(function.value, ast.Name) or function.value.id != 'json'
                        or len(node.args) != 1 or node.keywords
                        or not isinstance(node.args[0], ast.Attribute)
                        or not isinstance(node.args[0].value, ast.Name)
                        or node.args[0].value.id != 'sys' or node.args[0].attr != 'stdin'):
                        raise AssertionError('Pipeline JSON reader must use its sole stdin')
                if function.attr not in ('load', 'loads', 'get', 'find', 'split', 'read',
                                          'startswith', 'endswith', 'strip', 'search', 'group',
                                          'dumps', 'lower', 'upper', 'items', 'keys', 'values',
                                          'replace', 'join', 'findall', 'sub', 'rfind', 'count',
                                          'index', 'splitlines', 'lstrip', 'rstrip', 'isdigit',
                                          'match', 'fullmatch', 'finditer', 'groups', 'groupdict',
                                          'readline', 'readlines'):
                    raise AssertionError('Private result reader calls an unrelated method')
            else:
                raise AssertionError('Private result reader has a dynamic call')
        elif isinstance(node, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            if any(isinstance(target, ast.Attribute) or
                   isinstance(target, ast.Name) and target.id in ('sys', 'json', 're')
                   for target in targets):
                raise AssertionError('Result reader cannot replace imported capabilities')
    if pipeline:
        if paths:
            raise AssertionError('Pipeline reader has another file input')
        return path
    if len(paths) != 1:
        raise AssertionError('Private result reader must read exactly one literal file')
    return paths[0]


def verify_tool_inputs(wire, nonce, operations, provider_session):
    """Allow only current-turn SDK offloads of exact authenticated CLI operations.

    `operations[turn][operationId]` contains the full immutable response returned
    by the actual scoped editor CLI after the validated operation/mounted checkpoint. No filesystem
    or conversation-history data supplies the expected result.
    """
    turn = 0
    inputs = {}
    advertised = {}
    verified = []
    for row in wire:
        message = row['message']
        if row['direction'] == 'request' and message.get('method') == 'session/prompt':
            if message['params']['sessionId'] != provider_session:
                raise AssertionError('Tool evidence belongs to another provider session')
            turn += 1
        if row['direction'] != 'response' or message.get('method') != 'session/update':
            continue
        if message['params'].get('sessionId') != provider_session:
            raise AssertionError('Tool update belongs to another provider session')
        update = message['params'].get('update', {})
        tool = update.get('toolCallId')
        value = update.get('rawInput')
        if value:
            text = json.dumps(value)
            if any(forbidden in text for forbidden in
                   ('real-provider-wire', 'context-nonce', '.scenario/private', nonce)):
                raise AssertionError('Model tools accessed private history/nonce evidence')
            inputs[(turn, tool)] = value
            if '.claude/projects' in text:
                tool_name = update.get('_meta', {}).get('claudeCode', {}).get('toolName')
                if tool_name == 'Bash':
                    path = literal_result_read(value.get('command', ''))
                elif tool_name == 'Read':
                    if (not isinstance(value.get('file_path'), str) or
                        set(value) - {'file_path', 'offset', 'limit'} or
                        any(type(value[key]) is not int or value[key] < 1
                            for key in ('offset', 'limit') if key in value)):
                        raise AssertionError('Current-result Read requires one literal file and valid bounds')
                    path = Path(value['file_path'])
                elif tool_name == 'Grep':
                    if (set(value) != {'pattern', 'path', 'output_mode', 'head_limit'} or
                        not isinstance(value.get('pattern'), str) or not value['pattern'] or
                        not isinstance(value.get('path'), str) or not value['path'] or
                        any(char in value['path'] for char in '*?[]\n\r\x00') or
                        value.get('output_mode') != 'content' or
                        type(value.get('head_limit')) is not int or value['head_limit'] < 1):
                        raise AssertionError('Current-result Grep requires one literal file and bounded content output')
                    path = Path(value['path'])
                else:
                    raise AssertionError('Private history read is not a known capture reader')
                if '.claude/projects' in text.replace(str(path), '') or nonce in str(path):
                    raise AssertionError('Additional private history reference in tool input')
                reference = advertised.get((turn, str(path)))
                if reference is None:
                    raise AssertionError('Stale or unreferenced SDK tool result')
                origin_tool, preview = reference
                if (path.parent.name != 'tool-results' or
                    path.parent.parent.name != provider_session or
                    path.resolve() != path.absolute()):
                    raise AssertionError('SDK result path does not target this provider session')
                raw = path.read_bytes()
                if nonce.encode() in raw or not raw.decode().startswith(preview):
                    raise AssertionError('SDK result contains nonce or differs from actual prior output')
                result = json.loads(raw)
                operation = result.get('operationId')
                expected = operations.get(turn, {}).get(operation)
                if expected is None or json.dumps(result, sort_keys=True) != json.dumps(expected, sort_keys=True):
                    raise AssertionError('SDK result is not the exact authenticated current operation result')
                origin = inputs.get((turn, origin_tool), {}).get('command', '')
                origin_words = shlex.split(origin)
                command = result.get('request', {}).get('command')
                if operation not in origin_words or not any(word in origin_words for word in (command, 'wait')):
                    raise AssertionError('SDK result is unrelated to its originating operation tool')
                if result.get('status') != 'applied' or command not in (
                    'create-story', 'build', 'open-story', 'capture-preview'):
                    raise AssertionError('SDK result is not an applied authoring operation')
                output = result.get('result', {})
                if command in ('create-story', 'build') and output.get('ok') is not True:
                    raise AssertionError('SDK result does not contain a successful compiler outcome')
                if command == 'create-story' and not output.get('storyId'):
                    raise AssertionError('SDK result does not identify the created story')
                if command == 'open-story' and not result['request'].get('storyId'):
                    raise AssertionError('SDK result does not identify the opened story')
                if command == 'capture-preview' and (output.get('ready') is not True or
                    output.get('format') != 'text/html' or not output.get('documentHtml')):
                    raise AssertionError('SDK result does not contain a successful HTML capture')
                verified.append({'turn': turn, 'originTool': origin_tool, 'readTool': tool,
                                 'operationId': operation, 'command': command,
                                 'fileSha256': hashlib.sha256(raw).hexdigest()})
        if update.get('status') == 'completed':
            for content in update.get('content', []):
                text = content.get('content', {}).get('text', '')
                match = re.search(r'Full output saved to: ([^\n]+)\n\nPreview \(first [^\n]+\):\n(.*?)\n\.\.\.\n</persisted-output>', text, re.S)
                if match:
                    if not tool or (turn, tool) not in inputs:
                        raise AssertionError('SDK offload has no actual originating tool input')
                    advertised[(turn, match[1])] = (tool, match[2])
    return verified
