#!/usr/bin/env python3
"""Scan foreign Nim code and JavaScript for unmediated platform boundaries.

Library entry points return findings; the CLI handles reporting and exit status.
Bounded source analysis, not general language/type/effect inference.
Allowances pin exact path/API counts, so new uses require a reasoned amendment.
"""
from __future__ import annotations
import argparse
from collections import Counter
from dataclasses import asdict, dataclass
from copy import copy
import json
from pathlib import Path
import re
import subprocess

from lint_privacy import (privacy_bindings, PRIVACY_APIS, Allocation, Scope,
                          metadata, metadata_relevant, invalidate, UNRESOLVED)


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    api: str
    severity: str = "error"


# Keep line positions when eliding comments and non-executable strings.
def blank(text: str) -> str:
    return ''.join('\n' if c == '\n' else ' ' for c in text)


def decode_nim_string(text: str) -> tuple[str, list[int]]:
    r"""Decode an ordinary Nim string and map output characters to source offsets.

    Follow Nim 2.2.4 compiler/lexer.nim getEscapedChar/handleHexChar/
    handleDecChars, not Python's different unicode_escape grammar. Nim strings
    contain bytes: hexadecimal/decimal bytes must be joined before UTF-8
    decoding (e.g. \xC2\xA0 is one JS whitespace character). \p is normalized
    to LF: both supported target newlines have the same JS lexical boundary.
    Invalid escapes fail closed instead of silently hiding foreign code.
    """
    data, origins = bytearray(), []
    simple = {'n': '\n', 'p': '\n', 'r': '\r', 'c': '\r', 'l': '\n',
              'f': '\f', 'e': '\x1b', 'a': '\a', 'b': '\b', 'v': '\v', 't': '\t',
              "'": "'", '"': '"', '\\': '\\'}
    i = 0
    while i < len(text):
        start = i
        if text[i] != '\\':
            chunk = text[i].encode('utf-8')
            i += 1
        else:
            i += 1
            if i == len(text): raise ValueError('unfinished Nim string escape')
            kind = text[i].lower()
            i += 1
            if kind in simple:
                chunk = simple[kind].encode('utf-8')
            elif kind in {'x', 'u'}:
                braced = kind == 'u' and text[i:i+1] == '{'
                if braced: i += 1
                digits = i
                limit = len(text) if braced else i + (2 if kind == 'x' else 4)
                while i < min(len(text), limit) and text[i] in '0123456789abcdefABCDEF':
                    i += 1
                if digits == i: raise ValueError('Nim hexadecimal escape needs a digit')
                value = int(text[digits:i], 16)
                if braced:
                    if text[i:i+1] != '}' or value > 0x10ffff:
                        raise ValueError('invalid Nim braced Unicode escape')
                    i += 1
                elif i < limit and i < len(text) and text[i] not in "\"'":
                    # Nim permits short hex escapes only at a quote boundary;
                    # the enclosing literal's closing quote is not in text.
                    raise ValueError('incomplete Nim hexadecimal escape')
                chunk = bytes([value]) if kind == 'x' else chr(value).encode('utf-8', 'surrogatepass')
            elif kind in '0123456789':
                digits = i - 1
                while i < len(text) and text[i] in '0123456789': i += 1
                value = int(text[digits:i], 10)
                if value > 255: raise ValueError('Nim decimal escape exceeds one byte')
                chunk = bytes([value])
            else:
                raise ValueError(f'invalid Nim string escape: \\{text[i - 1]}')
        data.extend(chunk)
        origins.extend([start] * len(chunk))
    decoded = data.decode('utf-8', 'surrogateescape')
    offsets, byte_index = [], 0
    for ch in decoded:
        offsets.append(origins[byte_index])
        byte_index += len(ch.encode('utf-8', 'surrogateescape'))
    return decoded, offsets


def nim_tokens(text: str, *, spans=False):
    """Shared Nim lexical tokens, retaining original identifiers and offsets.

    Foreign pragmas normalize their own names separately. Ordinary Nim names
    preserve the first character, matching compiler/idents.nim cmpIgnoreStyle.
    Generalized string macros remain two tokens and cannot be constant metadata.
    """
    tokens = []
    literal_lines = {}
    token_ends = {}
    source_lines = []
    line = 1
    for ch in text:
        source_lines.append(line)
        if ch == '\n': line += 1
    i = 0
    while i < len(text):
        start = i
        if text.startswith('#[', i):
            depth = 1
            i += 2
            while i < len(text) and depth:
                if text.startswith('#[', i): depth += 1; i += 2
                elif text.startswith(']#', i): depth -= 1; i += 2
                else: i += 1
        elif text[i] == '#':
            end = text.find('\n', i)
            i = len(text) if end < 0 else end
        elif text[i] == "'" and (match := re.match(r"'(?:\\(?:[xX][0-9a-fA-F]{2}|[0-9]{1,3}|.)|[^'\\\n])'", text[i:])):
            # Apostrophes also introduce numeric suffixes (1'i64); only a
            # complete character literal can hide a quote or comment marker.
            i += len(match[0])
        elif text[i] == '"' or (text[i:i+2].lower() == 'r"'):
            prefixed_r = text[i] != '"'
            raw = prefixed_r or (i > 0 and (text[i - 1].isalnum() or text[i - 1] == '_'))
            if prefixed_r: i += 1
            triple = text.startswith('"""', i)
            width = 3 if triple else 1
            i += width
            payload_start = i
            while i < len(text):
                if raw and not triple and text.startswith('""', i): i += 2
                elif text.startswith('"' * width, i) and not (triple and text.startswith('""""', i)): break
                elif not raw and not triple and text[i] == '\\': i += 2
                else: i += 1
            payload = text[payload_start:i]
            if raw and not triple:
                offsets = []
                cursor = 0
                while cursor < len(payload):
                    offsets.append(cursor)
                    cursor += 2 if payload.startswith('""', cursor) else 1
                payload = payload.replace('""', '"')
            elif triple:
                # Nim skips an optional whitespace-only first line in triples.
                leading = re.match(r'[ \t]*\n', payload)
                skip = leading.end() if leading else 0
                offsets = list(range(skip, len(payload)))
                payload = payload[skip:]
            else:
                payload, offsets = decode_nim_string(payload)
            literal_lines[start] = [source_lines[payload_start + offset] for offset in offsets]
            tokens.append(('string', payload, start))
            i += width
            token_ends[start] = i
        elif text[i].isalpha() or text[i] == '_':
            i += 1
            while i < len(text) and (text[i].isalnum() or text[i] == '_'): i += 1
            tokens.append(('id', text[start:i], start))
            token_ends[start] = i
        elif text[i].isspace(): i += 1
        else:
            tokens.append(('symbol', text[i], i)); i += 1
            token_ends[start] = i
    result = (tokens, literal_lines, source_lines)
    return result + (token_ends,) if spans else result


def foreign_fragments(text: str):
    """Yield foreign payloads using the same comment/literal-aware Nim lexer."""
    tokens, literal_lines, source_lines = nim_tokens(text)
    # Pragma names have historically folded the complete spelling. Preserve
    # that interface without using its normalization for Nim symbol identity.
    tokens = [(kind, value.lower().replace('_', '') if kind == 'id' else value, pos)
              for kind, value, pos in tokens]
    for index, (kind, value, pos) in enumerate(tokens):
        if kind != 'id' or value not in {'importjs', 'importc', 'emit'}: continue
        if index == 0 or tokens[index - 1][1] not in {'.', ','}: continue
        tail = tokens[index + 1:]
        if not tail or tail[0][1] != ':': continue
        tail = tail[1:]
        if tail and tail[0][0] == 'string':
            yield tail[0][1], literal_lines[tail[0][2]], []
        elif value == 'emit' and tail and tail[0][1] == '[':
            # Non-string Nim expressions splice generated identifiers. A marker
            # retains expression structure while adjacent strings concatenate.
            parts, locations, fragment, opaque = [], [], [], []
            nesting = []

            def append_fragment():
                # Only a literal array item is JavaScript. Strings passed to
                # indexed/called Nim expressions belong to those expressions.
                if len(fragment) == 1 and fragment[0][0] == 'string':
                    parts.append(fragment[0][1])
                    locations.extend(literal_lines[fragment[0][2]])
                elif fragment:
                    start = sum(map(len, parts))
                    opaque.append((start, start + len('__nim')))
                    parts.append('__nim')
                    locations.extend([source_lines[fragment[0][2]]] * len('__nim'))
                fragment.clear()

            for tk, val, at in tail[1:]:
                if tk == 'symbol':
                    if not nesting and val == ']':
                        append_fragment()
                        break
                    if not nesting and val == ',':
                        append_fragment()
                        continue
                    if val in '[({': nesting.append(val)
                    elif val in '])}' and nesting: nesting.pop()
                fragment.append((tk, val, at))
            yield ''.join(parts), locations, opaque


def nim_foreign(text: str):
    # Preserve the established two-item library interface. Privacy analysis uses
    # explicit splice spans from the same tokenizer, never marker spellings.
    for payload, positions, _opaque in foreign_fragments(text):
        yield payload, positions


def nim_name(name):
    """Nim symbol equality is first-character-sensitive, then ASCII style-folded."""
    return name[:1] + name[1:].replace('_', '').translate(
        str.maketrans('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'))


def nim_dom_privacy(text, label):
    """Track direct local calls to the shipped dom_api, without type inference.

    The source lexer supplies comments, literals and physical positions. This
    small frontend recognizes whole expressions and indentation-owned blocks;
    it never interprets arbitrary importcpp, macros, wrappers or helper returns.
    Allocation/metadata policy is shared with the JavaScript frontend.
    """
    tokens, _literal_lines, lines, ends = nim_tokens(text, spans=True)
    if not tokens: return []
    # Backticks quoting an ordinary identifier preserve identity, but quoted
    # keywords never become control/import headers. Operator identifiers remain
    # outside this direct API subset.
    unquoted, cursor = [], 0
    while cursor < len(tokens):
        if (cursor+2 < len(tokens) and tokens[cursor][:2] == ('symbol', '`')
                and tokens[cursor+1][0] == 'id' and tokens[cursor+2][:2] == ('symbol', '`')):
            unquoted.append(('quoted_id', tokens[cursor+1][1], tokens[cursor][2]))
            ends[tokens[cursor][2]] = ends[tokens[cursor+2][2]]
            cursor += 3
        else:
            unquoted.append(tokens[cursor]); cursor += 1
    tokens = unquoted
    def identifier(token): return token[0] in {'id', 'quoted_id'}
    findings = []
    owner = Scope()
    serial = 0
    declaration_origins = []
    def allocate(tag, *, origin=None, **kwargs):
        nonlocal serial
        serial += 1
        value = Allocation(tag, owner, **kwargs)
        value.nim_origin = serial if origin is None else (origin, tuple(declaration_origins)) if declaration_origins and origin[0] in {'site', 'call-binding'} else origin
        return value
    module = ('dom-module',)
    document = ('dom-document',)
    api_names = ('createElement', 'createTextNode', 'createDocumentFragment',
                 'setAttribute', 'removeAttribute', 'getAttribute', 'setJsProp',
                 'setJsPropBool', 'setJsPropCstring', 'setJsPropHandler',
                 'getJsProp', 'getJsPropBool', 'Node', 'Element', 'Document')
    apis = {nim_name(name): name for name in api_names}

    def spelling(ts): return ''.join(t[1] for t in ts)

    def split(ts, separator):
        pieces, start, depth = [], 0, []
        for i, t in enumerate(ts):
            value = t[1]
            if t[0] == 'symbol' and not depth and value == separator:
                pieces.append(ts[start:i]); start = i + 1
            elif t[0] == 'symbol' and value in '([{': depth.append(value)
            elif t[0] == 'symbol' and value in ')]}' and depth: depth.pop()
        return pieces + [ts[start:]]

    def whole_parens(ts):
        if len(ts) < 2 or ts[0][0] != 'symbol' or ts[-1][0] != 'symbol' or ts[0][1] != '(' or ts[-1][1] != ')': return False
        depth = 0
        for i, t in enumerate(ts):
            if t[0] == 'symbol' and t[1] == '(': depth += 1
            elif t[0] == 'symbol' and t[1] == ')': depth -= 1
            if depth == 0 and i != len(ts)-1: return False
        return depth == 0

    def constant(ts, env):
        while whole_parens(ts): ts = ts[1:-1]
        if len(ts) == 1 and ts[0][0] == 'string': return ts[0][1]
        if len(ts) == 1 and identifier(ts[0]):
            name = nim_name(ts[0][1])
            # Boolean enum names are ordinary shadowable Nim symbols. A local
            # unknown value is still a binding; only the unshadowed builtin can
            # certify metadata, including through quoted/style-equivalent use.
            if (name in {'true', 'false'} and name not in env
                    and not env.get('#otherimports')):
                return name
        return None

    # Logical statements retain physical token lines; only unmatched delimiters
    # continue a statement. A semicolon never changes a receiver's source line.
    statements, current, nesting = [], [], []
    def append_statement(ts):
        if not ts: return
        pos = ts[0][2]
        start = text.rfind('\n', 0, pos) + 1
        indent = len(text[start:pos]) - len(text[start:pos].lstrip(' \t'))
        statements.append([indent, ts, []])
    for token in tokens:
        if current and not nesting and lines[token[2]] > lines[ends[current[-1][2]]-1]:
            append_statement(current); current = []
        current.append(token)
        if token[0] == 'symbol':
            if token[1] in '([{': nesting.append(token[1])
            elif token[1] in ')]}' and nesting: nesting.pop()
    append_statement(current)
    # Inline block bodies are real sequential statements too. Only structural
    # headers split on colon/equal: a variable's type annotation is not a block.
    expanded = []
    routines = {'proc', 'func', 'method', 'iterator', 'template', 'macro', 'converter'}
    controls = {'if', 'elif', 'else', 'when', 'for', 'while', 'case', 'of',
                'try', 'except', 'finally', 'block', 'defer', 'static'}
    def inline(row):
        indent, ts, children = row
        # Semicolon tails belong to the inline header on this logical line.
        # Split only the first sibling before inspecting its structural header;
        # literals and delimiter-enclosed semicolons are already opaque to split.
        siblings = split(ts, ';')
        first_part = siblings[0]
        if not first_part:
            for part in siblings[1:]:
                if part: inline([indent, part, []])
            return
        first = first_part[0][1] if first_part[0][0] == 'id' else None
        separator = '=' if first in routines else ':'
        pieces = split(first_part, separator)
        if (first in routines | controls or first == 'ui') and len(pieces) > 1 and pieces[1]:
            cut = len(pieces[0]) + 1
            expanded.append([indent, ts[:cut], []])
            inline([indent+1, ts[cut:], []])
        else:
            expanded.append([indent, first_part, children])
            for part in siblings[1:]:
                if part: inline([indent, part, []])
    for row in statements: inline(row)
    roots, stack = [], []
    for row in expanded:
        while stack and row[0] <= stack[-1][0]: stack.pop()
        (stack[-1][2] if stack else roots).append(row)
        stack.append(row)

    def lookup(ts, env):
        while whole_parens(ts): ts = ts[1:-1]
        if len(ts) == 1 and identifier(ts[0]): return env.get(nim_name(ts[0][1]))
        if len(ts) == 3 and ts[1][0] == 'symbol' and ts[1][1] == '.' and identifier(ts[0]) and identifier(ts[2]):
            if env.get(nim_name(ts[0][1])) == module:
                name = nim_name(ts[2][1])
                return document if name == 'document' else ('dom-api', apis[name]) if name in apis else None
        return None

    def reachable(ts, env):
        return list({env[nim_name(t[1])] for t in ts if identifier(t)
                     and isinstance(env.get(nim_name(t[1])), Allocation)})

    def uncertain(values):
        values = tuple(dict.fromkeys(v for v in values if isinstance(v, Allocation)))
        if not values: return None
        # Abstract allocation sites are finite even when this join is revisited
        # across a loop back edge. Synthetic joins retain leaf origins rather
        # than acquiring a new identity on every dataflow iteration.
        pending, visited, origins = list(values), set(), set()
        while pending:
            value = pending.pop()
            if id(value) in visited: continue
            visited.add(id(value))
            if not (isinstance(value.nim_origin, tuple) and value.nim_origin[0] == 'alias'):
                origins.add(value.nim_origin)
            pending.extend(value.possible_aliases)
        return allocate(None, origin=('alias', frozenset(origins)),
                        uncertain=True, possible_aliases=values)

    def report(value, ts):
        if isinstance(value, Allocation) and (api := value.finding()):
            # Keep observations in the rollback-truncated stream: speculative
            # loop iterations must not reserve a source site before final analysis.
            span = (ts[0][2], ends[ts[-1][2]])
            findings.append((span, Finding(label, lines[ts[0][2]], api)))

    def call(ts):
        # Require the closing delimiter to consume the entire expression. A
        # method followed by operators/field access cannot grant return identity.
        for i, t in enumerate(ts):
            if t[0] != 'symbol' or t[1] != '(': continue
            depth = 0
            for j in range(i, len(ts)):
                if ts[j][0] == 'symbol' and ts[j][1] == '(': depth += 1
                elif ts[j][0] == 'symbol' and ts[j][1] == ')': depth -= 1
                if depth == 0:
                    if j == len(ts)-1: return ts[:i], split(ts[i+1:j], ',') if j > i+1 else []
                    break
            break
        return None

    def arguments(name, args):
        # These formal names are the actual owning importcpp declarations, not
        # type guesses. Reject duplicate/unknown/partial named argument lists.
        if name in {'Node', 'Element', 'Document'}: return args if len(args) == 1 else None
        if name == 'createElement': formals = ['d', 'tag']
        elif name == 'createTextNode': formals = ['d', 'text']
        elif name == 'createDocumentFragment': formals = ['d']
        elif name in {'setAttribute', 'getAttribute', 'removeAttribute'}:
            formals = ['e', 'name'] + (['value'] if name == 'setAttribute' else [])
        else: formals = ['n', 'name'] + (['value'] if name.startswith('set') else [])
        ordered = [None] * len(formals)
        position = 0
        for argument in args:
            parts = split(argument, '=')
            if len(parts) == 2 and len(parts[0]) == 1 and identifier(parts[0][0]):
                formal = nim_name(parts[0][0][1])
                if formal not in formals: return None
                index, value = formals.index(formal), parts[1]
            else:
                index, value = position, argument
                position += 1
            if index >= len(ordered) or ordered[index] is not None or not value: return None
            ordered[index] = value
        return ordered if all(value is not None for value in ordered) else None

    scope_frames = []
    active_prefixes = ()
    capture_effects = None
    capture_roots = frozenset()
    capture_depth = 0
    suppress_operation_observations = 0

    def binding_root(name):
        # Declaration ownership, not the caller's nearest same-spelled value,
        # identifies a captured mutable location throughout copied flow graphs.
        for frame in reversed(scope_frames):
            if name in frame['declared']:
                return ('nim-binding', frame['owner'], name)
        return None

    def dependencies(ts, env):
        return frozenset(root for token in ts if identifier(token)
                         if (root := binding_root(nim_name(token[1]))) is not None)

    def external_dependencies(roots, env):
        pending, visited, result = list(roots), set(), []
        while pending:
            root = pending.pop()
            if root in visited: continue
            visited.add(root)
            if root[:1] == ('nim-reference',): result.append(root)
            elif root in capture_roots:
                result.append(root)
                if (env.get(('nim-written-binding', root)) and isinstance(env.get(root), Allocation)
                        and env[root].possible_aliases):
                    pending.extend(env.get(('nim-dependency', root), ()))
            else: pending.extend(env.get(('nim-dependency', root), ()))
        return tuple(result)

    def capture_mutation(roots, env, effect=('invalidate',)):
        if capture_effects is None: return
        if effect[0] == 'rebind':
            optional = effect[1] or any(frame['conditional'] for frame in scope_frames[capture_depth:])
            effect = ('rebind', optional, external_dependencies(effect[2], env), effect[3])
        elif effect[0] == 'reference':
            effect = ('reference', effect[1], external_dependencies(effect[2], env), effect[3])
        pending, visited = [(root, effect) for root in roots if root is not None], set()
        while pending:
            root, operation = pending.pop()
            if operation[0] == 'at-reference':
                witness, underlying = operation[1:]
                snapshot = env.get(('nim-reference-current', witness), env.get(witness))
                if (underlying[0] in {'metadata', 'invalidate'}
                        and snapshot is env.get(root)
                        and env.get(('nim-written-binding', root))
                        and isinstance(snapshot, Allocation) and snapshot.possible_aliases):
                    pending.extend((dependency, underlying) for dependency in
                                   env.get(('nim-dependency', root), ()))
            if root[:1] == ('nim-reference',):
                # A copied reference denotes its snapshot object, not the
                # current value of the cell from which it was copied.
                owner_root, witness = root[1:]
                # A snapshot taken from the current loop-widened cell carries
                # its possible RHS receivers. A snapshot taken before a later
                # replacement remains a different object and cannot follow it.
                if (operation[0] in {'metadata', 'invalidate'}
                        and env.get(witness) is env.get(owner_root)
                        and env.get(('nim-written-binding', owner_root))
                        and isinstance(env.get(witness), Allocation)
                        and env[witness].possible_aliases):
                    pending.extend((dependency, operation) for dependency in
                                   env.get(('nim-dependency', owner_root), ()))
                operation = (operation if operation[0] in {'rebind', 'reference', 'at-reference', 'choice'} else
                             ('at-reference', witness, operation))
                root = owner_root
            if (root, operation) in visited: continue
            visited.add((root, operation))
            if root in capture_roots:
                item = (root, (operation,))
                if item not in capture_effects: capture_effects.append(item)
                if (operation[0] in {'metadata', 'invalidate'} and env.get(('nim-written-binding', root))
                        and isinstance(env.get(root), Allocation) and env[root].possible_aliases):
                    pending.extend((dependency, operation) for dependency in env.get(('nim-dependency', root), ()))
            elif effect[0] != 'rebind':
                # Reference aliases share receiver mutations, never the writes
                # to a separate local variable slot holding that reference.
                pending.extend((dependency, operation) for dependency in env.get(('nim-dependency', root), ()))
        # The isolated prefix snapshots own this ordered finite program. An
        # overload's provisional branch programs are collected as a choice.
        if not suppress_operation_observations:
            env[('nim-observed-effects',)] = ('nim-observed-effects', tuple(capture_effects))

    def invocation_program(alternatives, site):
        if declaration_origins: site = (site, tuple(declaration_origins))
        # A callee source site is insufficient identity when two authored caller
        # statements invoke it around a cell replacement. Compose lexical sites,
        # never execution counts, so repeated loop analysis still converges.
        witnesses = {}

        def collect(effect):
            if effect[0] == 'reference':
                witnesses[effect[1]] = ('nim-invocation-reference', site, effect[1])
            elif effect[0] == 'at-reference': collect(effect[2])
            elif effect[0] == 'choice':
                for program in effect[1]:
                    for root, effects in program:
                        for operation in effects: collect(operation)

        for program in alternatives:
            for root, effects in program:
                for effect in effects: collect(effect)

        def reference(root):
            if root[:1] == ('nim-reference',):
                return ('nim-reference', root[1], witnesses.get(root[2], root[2]))
            return root

        def operation(effect):
            kind = effect[0]
            if kind == 'at-reference':
                return (kind, witnesses.get(effect[1], effect[1]), operation(effect[2]))
            fields = list(effect)
            if kind == 'choice': fields[1] = tuple(program(branch) for branch in effect[1])
            elif kind == 'reference':
                fields[1] = witnesses[effect[1]]
                fields[2] = tuple(reference(root) for root in effect[2])
            elif kind == 'rebind': fields[2] = tuple(reference(root) for root in effect[2])
            if len(fields) > 1: fields[-1] = ('nim-invocation-site', site, fields[-1])
            return tuple(fields)

        def program(items):
            return tuple((reference(root), tuple(operation(effect) for effect in effects))
                         for root, effects in items)

        return tuple(program(items) for items in alternatives)

    def program_roots(program):
        pending, roots = list(program), []
        while pending:
            root, effects = pending.pop()
            if root not in roots: roots.append(root)
            for effect in effects:
                if effect[0] == 'choice':
                    pending.extend(item for alternative in effect[1] for item in alternative)
        return tuple(roots)

    def observe_prefixes(env, prefixes=None):
        if prefixes is None: prefixes = active_prefixes
        for sink, depth in prefixes:
            projected = dict(env)
            # An enclosing handler sees outer roots, not inner same-named
            # declarations. Roots travel in the same copied alias graph as
            # visible bindings, so restoration observes this instant's state.
            for frame in reversed(scope_frames[depth:]):
                if frame['scoped']:
                    for name in frame['declared']:
                        root = frame['roots'].get(name)
                        if root in projected: projected[name] = projected[root]
                        else: projected.pop(name, None)
                for root in frame['roots'].values(): projected.pop(root, None)
            sink.append(view(projected))

    def evaluate(ts, env):
        result = evaluate_inner(ts, env)
        # Nested calls in one expression can mutate a receiver before a later
        # reset. Observe effect boundaries, not just physical statements.
        observe_prefixes(env)
        return result

    def evaluate_inner(ts, env):
        while whole_parens(ts): ts = ts[1:-1]
        if not ts: return None
        sequence = split(ts, ';')
        if len(sequence) > 1:
            # Plain parenthesized statement lists introduce no Nim scope. Their
            # declarations and captured cells belong to the enclosing frame;
            # only an explicit source block supplies a new lexical owner.
            result = []
            completion = body([(0, part, []) for part in sequence if part], env,
                              enclosing=True, prefixes=active_prefixes,
                              expression_result=result)
            if completion.normal is not None and completion.normal is not env:
                env.clear(); env.update(completion.normal)
            # Preserve the already-evaluated tracked tail in its enclosing frame.
            # This is possible provenance, not inferred helper-return identity.
            if len(result) == 1 and isinstance(result[0], Allocation) and result[0].finding() is None:
                return result[0]
            return uncertain(result)
        value = lookup(ts, env)
        if value is not None: return value
        parsed = call(ts)
        if parsed:
            callee, args = parsed
            identity = lookup(callee, env)
            # UFCS is admitted only through an unshadowed imported function and
            # a receiver whose identity is already known in this lexical view.
            dots = split(callee, '.')
            if identity is None and len(dots) == 2 and len(dots[1]) == 1:
                symbol = env.get(nim_name(dots[1][0][1]))
                if isinstance(symbol, tuple) and symbol[:1] == ('dom-api',):
                    identity = symbol; args = [dots[0]] + args
            normalized = arguments(identity[1], args) if isinstance(identity, tuple) and identity[:1] == ('dom-api',) else None
            if normalized is not None:
                name = identity[1]
                args = normalized
                if name in {'Node', 'Element', 'Document'} and len(args) == 1:
                    return evaluate(args[0], env)
                if name in {'createElement', 'createTextNode', 'createDocumentFragment'} and len(args) == (1 if name == 'createDocumentFragment' else 2):
                    doc = evaluate(args[0], env)
                    if doc == document:
                        tag = constant(args[1], env) if name == 'createElement' else '#text' if name == 'createTextNode' else '#fragment'
                        if tag is not None: tag = tag.lower()
                        # Evaluate any authored argument access even if its value
                        # cannot be classified as a constant tag.
                        for arg in args[1:]: evaluate(arg, env)
                        return allocate(tag, origin=('site', ts[0][2]), text_node=name == 'createTextNode')
                setters = {'setAttribute', 'removeAttribute', 'setJsProp', 'setJsPropBool', 'setJsPropCstring', 'setJsPropHandler'}
                getters = {'getAttribute', 'getJsProp', 'getJsPropBool'}
                if name in setters | getters and len(args) >= 2:
                    target = evaluate(args[0], env)
                    prop = constant(args[1], env)
                    for arg in args[1:]: evaluate(arg, env)
                    if isinstance(target, Allocation):
                        attribute = name in {'setAttribute', 'removeAttribute', 'getAttribute'}
                        member = prop.lower() if attribute and prop is not None else prop
                        if member == 'value' or not attribute and member == 'textContent':
                            report(target, args[0])
                        if name in setters:
                            data = ('text' if member == 'type' else 'false' if member == 'contenteditable' else '') if name == 'removeAttribute' else constant(args[2], env) if len(args) > 2 else None
                            # Future mutable receivers can have a different tag.
                            # Record the member identity now; relevance belongs
                            # to the current allocation at actual invocation.
                            capture_mutation(dependencies(args[0], env), env,
                                             ('metadata', prop, attribute, ts[0][2]))
                            metadata(target, prop, data, attribute=attribute)
                    return None
            # Unknown calls may mutate passed aliases. Merely reading a label
            # does not make it DOM, but a tracked checkbox loses certification.
            values = []
            for arg in args:
                val = evaluate(arg, env)
                if isinstance(val, Allocation): values.append(val)
            values += reachable(callee, env)
            if values:
                capture_mutation(dependencies([*callee, *(token for arg in args for token in arg)], env), env, ('invalidate', ts[0][2]))
            for allocation in values: invalidate(allocation)
            captured_values = []
            if isinstance(identity, tuple) and identity[:1] == ('nim-routine',):
                captured_values += [env[root] for root in identity[1]
                           if isinstance(env.get(root), Allocation)]
                resolved_roots = {root for root in identity[1] if env.get(root) in captured_values}
                def reference_value(reference, state):
                    return state.get(reference[2] if reference[:1] == ('nim-reference',) else reference)

                def apply_effects(state, root, effects):
                    for effect in effects:
                        if effect[0] == 'choice':
                            execute_choices(state, effect[1]); continue
                        capture_mutation((root,), state, effect)
                        receiver = state.get(effect[1]) if effect[0] == 'at-reference' else state.get(root)
                        operation = effect[2] if effect[0] == 'at-reference' else effect
                        if root not in resolved_roots: continue
                        if operation[0] == 'reference':
                            refs = tuple(dict.fromkeys(value for dependency in operation[2]
                                                      if isinstance((value := reference_value(dependency, state)), Allocation)))
                            # One authored call in a loop reuses its finite witness
                            # slot. Earlier retained references must keep their old
                            # object alternatives when a later iteration rebinds.
                            state[('nim-reference-current', operation[1])] = refs[0] if len(refs) == 1 else uncertain(refs)
                            prior = state.get(operation[1])
                            if isinstance(prior, Allocation) and prior not in refs: refs = (*refs, prior)
                            state[operation[1]] = refs[0] if len(refs) == 1 else uncertain(refs)
                            continue
                        if not isinstance(receiver, Allocation): continue
                        if operation[0] == 'rebind':
                            effect = operation
                            current = receiver
                            replacement = allocate(None, origin=('call-binding', ts[0][2], root),
                                                   uncertain=True,
                                                   possible_aliases=(current,) if effect[1] else ())
                            rhs_aliases = tuple(value for dependency in effect[2]
                                                if isinstance((value := reference_value(dependency, state)), Allocation))
                            replacement.possible_aliases = tuple(dict.fromkeys(
                                (*replacement.possible_aliases, *rhs_aliases)))
                            state[root] = replacement
                            prior_dependencies = state.get(('nim-dependency', root), ()) if effect[1] else ()
                            state[('nim-dependency', root)] = frozenset((*prior_dependencies, *effect[2]))
                            if capture_effects is not None: state[('nim-written-binding', root)] = True
                            for name in list(state):
                                if isinstance(name, str) and binding_root(name) == root: state[name] = replacement
                            for frame in scope_frames:
                                for name, binding in frame['outer_bindings'].items():
                                    if binding == root: state[frame['roots'][name]] = replacement
                        elif operation[0] != 'metadata' or metadata_relevant(receiver, operation[1], attribute=operation[2]):
                            invalidate(receiver)
                        observe_prefixes(state)

                def execute_choices(env, alternatives):
                    nonlocal capture_effects, suppress_operation_observations
                    if len(alternatives) == 1:
                        for root, effects in alternatives[0]: apply_effects(env, root, effects)
                        return
                    base_effects = capture_effects
                    branches, branch_programs = [], []
                    suppress_operation_observations += 1
                    try:
                        for alternative in alternatives:
                            branch = view(env)
                            capture_effects = list(base_effects) if base_effects is not None else None
                            for root, effects in alternative: apply_effects(branch, root, effects)
                            branches.append(branch)
                            if capture_effects is not None:
                                branch_programs.append(tuple(capture_effects[len(base_effects):]))
                    finally:
                        capture_effects = base_effects
                        suppress_operation_observations -= 1
                    joined = join(env, branches)
                    env.clear(); env.update(joined)
                    if capture_effects is not None:
                        possible_roots = program_roots(item for program in branch_programs for item in program)
                        if possible_roots:
                            capture_mutation((possible_roots[0],), env,
                                             ('choice', tuple(branch_programs), ts[0][2]))
                    observe_prefixes(env)

                execute_choices(env, invocation_program(identity[2], ts[0][2]))
                captured_values.extend(env[root] for root in identity[1]
                                       if isinstance(env.get(root), Allocation))
            return uncertain([*values, *captured_values])
        dots = split(ts, '.')
        if len(dots) >= 2 and len(dots[-1]) == 1 and identifier(dots[-1][0]):
            receiver = ts[:len(ts)-len(dots[-1])-1]
            target = evaluate(receiver, env)
            if isinstance(target, Allocation) and nim_name(dots[-1][0][1]) == 'textcontent':
                report(target, receiver)
            return None
        # Unsupported expressions cannot turn a known receiver into an ordinary
        # model. Visit complete nested calls/accesses and retain possible aliases.
        values = reachable(ts, env)
        i = 0
        while i < len(ts):
            if identifier(ts[i]):
                j = i+1
                while j+1 < len(ts) and ts[j][0] == 'symbol' and ts[j][1] == '.' and identifier(ts[j+1]): j += 2
                if j < len(ts) and ts[j][0] == 'symbol' and ts[j][1] == '(':
                    depth, end = 1, j+1
                    while end < len(ts) and depth:
                        if ts[end][0] == 'symbol' and ts[end][1] == '(': depth += 1
                        elif ts[end][0] == 'symbol' and ts[end][1] == ')': depth -= 1
                        end += 1
                    if not depth:
                        evaluate(ts[i:end], env); i = end; continue
                if j > i+1:
                    evaluate(ts[i:j], env); i = j; continue
            i += 1
        return uncertain(values)

    def import_module(ts, env):
        # Exact path identity, including standard bracket imports and aliases.
        items = []
        for item in split(ts[1:], ','):
            opening = next((i for i, t in enumerate(item)
                            if t[0] == 'symbol' and t[1] == '['), None)
            if opening is not None and item[-1][0] == 'symbol' and item[-1][1] == ']':
                items.extend(item[:opening] + part
                             for part in split(item[opening+1:-1], ','))
            else: items.append(item)
        for item in items:
            path = spelling(item)
            alias = None
            for i, t in enumerate(item):
                if t[0] == 'id' and t[1] == 'as': alias = item[i+1:]; item = item[:i]; break
            excluded = next((i for i, t in enumerate(item)
                             if t[0] == 'id' and t[1] == 'except'), None)
            if excluded is not None:
                # Unresolved except imports provide no new authority and cannot
                # preserve an earlier binding for their module or symbols.
                path_tokens = item[:excluded]
                basename = spelling(path_tokens).rsplit('/', 1)[-1]
                env[nim_name(basename)] = None
                for key in apis: env[key] = None
                env['document'] = None
                env['#otherimports'] = True
                continue
            path = spelling(item)
            exact = path == 'isonim/web/dom_api'
            bracket = re.fullmatch(r'isonim/web/\[([^\]]+)\]', path)
            exact = exact or bracket is not None and bracket[1] == 'dom_api'
            if not exact:
                # A different imported module may supply competing overloads.
                # Fully qualified proven calls remain usable; unqualified names
                # cease to identify the owning API by spelling alone.
                env['#otherimports'] = True
                for key in apis: env[key] = None
                env['document'] = None
                basename = alias[0][1] if alias and len(alias) == 1 else path.rsplit('/', 1)[-1]
                if re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', basename):
                    env[nim_name(basename)] = None
                continue
            key = nim_name(alias[0][1]) if alias and len(alias) == 1 else 'domapi'
            env[key] = module
            if not env.get('#otherimports'):
                for key, name in apis.items(): env.setdefault(key, ('dom-api', name))
                env.setdefault('document', document)

    def join(base, views):
        # Canonicalize every copy of each creation origin, including hidden
        # possible-alias edges. Picking independent branch copies per variable
        # would disconnect a later uncertain-receiver mutation from an old alias.
        copies, visited = {}, set()
        pending = [value for branch in views for value in branch.values()]
        while pending:
            value = pending.pop()
            if isinstance(value, Allocation):
                if id(value) in visited: continue
                visited.add(id(value))
                copies.setdefault(value.nim_origin, []).append(value)
                pending.extend(value.possible_aliases)
        def state(value):
            return (value.tag, value.text_node, value.input_type, value.editable,
                    value.credential, value.uncertain)
        canonical = {origin: values[0] for origin, values in copies.items()}
        states = {origin: [state(value) for value in values]
                  for origin, values in copies.items()}
        edges = {origin: tuple(dict.fromkeys(alias.nim_origin for value in values
                                             for alias in value.possible_aliases))
                 for origin, values in copies.items()}
        for origin, value in canonical.items():
            # A branch/backedge difference in one metadata coordinate is not
            # an unknown mutation of the whole object. A later unconditional
            # literal write may establish that coordinate again. Unknown calls
            # and possible-receiver writes retain their separate sticky flag.
            for index, name in enumerate(('tag', 'text_node', 'input_type',
                                          'editable', 'credential')):
                if any(item[index] != states[origin][0][index] for item in states[origin]):
                    setattr(value, name, False if name == 'text_node' else None)
            value.uncertain = any(item[5] for item in states[origin])
            value.possible_aliases = tuple(canonical[other] for other in edges[origin])
        def remap(value):
            if isinstance(value, Allocation): return canonical[value.nim_origin]
            return value
        result, cache = dict(base), {}
        for key in base:
            vals = [remap(branch.get(key)) for branch in views]
            if isinstance(key, tuple) and key[:1] == ('nim-written-binding',):
                result[key] = any(vals)
            elif isinstance(key, tuple) and key[:1] == ('nim-dependency',):
                result[key] = frozenset(root for value in vals if value for root in value)
            elif all(not isinstance(v, Allocation) for v in vals):
                result[key] = vals[0] if all(v == vals[0] for v in vals) else None
            elif all(v is vals[0] for v in vals): result[key] = vals[0]
            else:
                signature = tuple(v.nim_origin if isinstance(v, Allocation) else None for v in vals)
                if signature not in cache: cache[signature] = uncertain(vals)
                result[key] = cache[signature]
        return result

    def view(env):
        # Copy allocation graphs iteratively: long alias histories and cycles
        # must not turn valid source input into Python recursion failures.
        pending, originals = list(env.values()), {}
        while pending:
            value = pending.pop()
            if isinstance(value, Allocation) and id(value) not in originals:
                originals[id(value)] = value
                pending.extend(value.possible_aliases)
        copies = {key: copy(value) for key, value in originals.items()}
        for key, value in originals.items():
            copies[key].possible_aliases = tuple(copies[id(other)] for other in value.possible_aliases)
        def remap(value):
            if isinstance(value, Allocation): return copies[id(value)]
            return value
        return {key: remap(value) for key, value in env.items()}

    class Flow:
        """A normal successor and separately owned abrupt completion states."""
        def __init__(self, normal, abrupt=()):
            self.normal, self.abrupt = normal, list(abrupt)

        def states(self):
            return ([] if self.normal is None else [self.normal]) + [state for _, _, state in self.abrupt]

    def merged(base, states):
        return join(base, states) if states else None

    def scoped_arm(rows, env, names=(), prefixes=(), conditional=False):
        local = view(env)
        shadowed = {name: local[name] for name in names if name in local}
        for name in names: local[name] = None
        return body(rows, local, True, prefixes=prefixes, shadowed=(names, shadowed), conditional=conditional)

    def flow_signature(env):
        """Finite abstract state, including hidden possible aliases/captures."""
        graph, pending = {}, list(env.values())
        def binding(value):
            if isinstance(value, Allocation): return ('allocation', value.nim_origin)
            if isinstance(value, tuple) and value[:1] == ('nim-routine',):
                return ('routine', value[1:])
            return value
        visited = set()
        while pending:
            value = pending.pop()
            if isinstance(value, Allocation) and id(value) not in visited:
                visited.add(id(value))
                state = (value.tag, value.text_node, value.input_type,
                         value.editable, value.credential, value.uncertain,
                         frozenset(v.nim_origin for v in value.possible_aliases))
                graph.setdefault(value.nim_origin, set()).add(state)
                pending.extend(value.possible_aliases)
        return (frozenset((name, binding(value)) for name, value in env.items()),
                frozenset((origin, frozenset(states)) for origin, states in graph.items()))

    def loop_entry(ts, children, env, names):
        # Widen zero iterations and every reachable back edge before collecting
        # findings. Each coordinate/alias set only loses precision, so finite
        # source allocation sites reach a fixed point without a guessed bound.
        nonlocal active_prefixes
        previous_prefixes, active_prefixes = active_prefixes, ()
        entry = view(env)
        try:
            while True:
                before = flow_signature(entry)
                checkpoint = len(findings)
                iteration = view(entry)
                if ts[0][1] == 'while': evaluate(ts[1:-1], iteration)
                after = scoped_arm(children, iteration, names, conditional=True)
                del findings[checkpoint:]
                backedges = ([] if after.normal is None else [after.normal]) + [
                    state for kind, target, state in after.abrupt
                    if kind == 'continue' and target is None]
                entry = join(entry, [view(entry), *backedges])
                if flow_signature(entry) == before: return entry
        finally:
            active_prefixes = previous_prefixes

    def body(rows, env, scoped=False, declaration_sink=None, prefixes=(), shadowed=((), {}),
             expression_result=None, conditional=False, enclosing=False, expression_action=None):
        nonlocal active_prefixes, capture_effects, capture_roots, capture_depth
        previous_prefixes, active_prefixes = active_prefixes, prefixes
        if enclosing:
            # Expression declarations are ordinary declarations in the current
            # lexical frame. Sharing its owner keeps later captures and prefix
            # projections tied to the same cells through scope restoration.
            declared = scope_frames[-1]['declared']
            roots = {}
        else:
            names, outer = shadowed
            declared = set(names)
            saved = dict(env)
            for name in names:
                if name in outer: saved[name] = outer[name]
                else: saved.pop(name, None)
            # Internal tuple keys cannot collide with source identifiers. Their
            # lexical row-list identity is stable across loop fixedpoint visits.
            # Keeping these roots in env lets view/join copy all alias edges once.
            roots = {name: ('nim-scope-root', id(rows), name)
                     for name in saved if isinstance(name, str)}
            env.update((key, saved[name]) for name, key in roots.items())
            outer_bindings = {name: binding_root(name) for name in roots}
            scope_frames.append(dict(scoped=scoped, declared=declared, roots=roots, owner=id(rows),
                                     outer_bindings=outer_bindings, conditional=conditional))
        abrupt = []
        def observe(state):
            if state is not None: observe_prefixes(state, prefixes)
        i = 0
        if expression_action is not None: expression_action()
        while i < len(rows) and env is not None:
            observe(env)
            _indent, ts, children = rows[i]
            first = ts[0][1] if ts[0][0] == 'id' else None
            if first == 'import': import_module(ts, env)
            elif first == 'from':
                # A from import can shadow existing identities even though this
                # bounded frontend does not resolve the imported definitions.
                separator = next((j for j, t in enumerate(ts)
                                  if t[0] == 'id' and t[1] == 'import'), None)
                if separator is not None:
                    for item in split(ts[separator+1:], ','):
                        if len(item) == 1 and identifier(item[0]):
                            env[nim_name(item[0][1])] = None
            elif first == 'include':
                # Included source is not expanded here. It may rebind names or
                # mutate current objects; retain their obligations, not authority.
                for key, value in list(env.items()):
                    if isinstance(value, Allocation):
                        if isinstance(key, str): capture_mutation((binding_root(key),), env, ('invalidate', ts[0][2]))
                        invalidate(value)
                    elif value == module or value == document or isinstance(value, tuple) and value[:1] == ('dom-api',):
                        env[key] = None
                env['#otherimports'] = True
            elif first == 'export': pass
            elif first in routines:
                if len(ts) > 1:
                    routine_name = nim_name(ts[1][1])
                    prior_routine = env.get(routine_name) if routine_name in declared else None
                    env[routine_name] = None; declared.add(routine_name)
                local = view(env)
                local.pop(('nim-observed-effects',), None)
                for marker in list(local):
                    if isinstance(marker, tuple) and marker[:1] == ('nim-written-binding',): local[marker] = False
                enclosing_effects, enclosing_roots, enclosing_depth = capture_effects, capture_roots, capture_depth
                capture_effects = []
                capture_depth = len(scope_frames)
                capture_roots = frozenset(key for key in env
                                         if isinstance(key, tuple) and key[:1] == ('nim-binding',) and isinstance(env.get(key), Allocation))
                formal_names = set()
                # Defaults are deferred just like the body. Their observations
                # belong to the possible-call summary, never an enclosing try.
                deferred_prefixes = []
                enclosing_prefixes = active_prefixes
                active_prefixes = ((deferred_prefixes, len(scope_frames)),)
                # Parameters are declarations, not calls; shadow imported names
                # only inside the body, and never mutate the present outer view.
                generic = next((j for j,t in enumerate(ts[2:], 2)
                                if t[0] == 'symbol' and t[1] in {'[', '('}), None)
                if generic is not None and ts[generic][1] == '[':
                    closing = next((j for j in range(generic+1, len(ts))
                                    if ts[j][0] == 'symbol' and ts[j][1] == ']'), len(ts))
                    for parameter in split(ts[generic+1:closing], ';'):
                        for name in split(split(parameter, ':')[0], ','):
                            if len(name) == 1 and identifier(name[0]):
                                formal_names.add(nim_name(name[0][1])); local[nim_name(name[0][1])] = None
                opening = next((j for j,t in enumerate(ts) if t[0] == 'symbol' and t[1] == '('), None)
                if opening is not None:
                    depth, closing = 1, opening+1
                    while closing < len(ts) and depth:
                        if ts[closing][0] == 'symbol' and ts[closing][1] == '(': depth += 1
                        elif ts[closing][0] == 'symbol' and ts[closing][1] == ')': depth -= 1
                        closing += 1
                    for group in split(ts[opening+1:closing-1], ';'):
                        names = []
                        for parameter in split(group, ','):
                            annotation = split(parameter, ':')
                            declaration = split(annotation[0], '=')
                            names.extend(nim_name(t[1]) for t in declaration[0] if identifier(t))
                            default = split(annotation[-1], '=')
                            if len(default) == 2:
                                # Establish the default's lexical owner before
                                # evaluation, sharing the ordinary frame cleanup.
                                # Prefix observations remain inside that owner.
                                def evaluate_default():
                                    if len(default) == 2: evaluate(default[1], local)
                                body([], local, scoped=True, prefixes=active_prefixes,
                                     expression_action=evaluate_default)
                            if len(annotation) > 1 or len(declaration) > 1:
                                for name in names:
                                    formal_names.add(name); local[name] = None
                                names = []
                        for name in names:
                            formal_names.add(name); local[name] = None
                local_declarations = set(formal_names)
                completion = body(children, local, declaration_sink=local_declarations,
                                  prefixes=active_prefixes)
                active_prefixes = enclosing_prefixes
                # The isolated execution-prefix snapshots own the operation
                # evidence, including idempotent writes and intermediate effects
                # before a later reset/throw. Present callers see none of it.
                pending = [value for prefix in deferred_prefixes for value in prefix.values()]
                observed_program = ()
                for value in pending:
                    if isinstance(value, tuple) and value[:1] == ('nim-observed-effects',):
                        if len(value[1]) > len(observed_program): observed_program = value[1]
                captures = list(observed_program)
                alternatives = (tuple(captures),)
                if isinstance(prior_routine, tuple) and prior_routine[:1] == ('nim-routine',):
                    # Same-scope overloads remain alternatives; a nested local
                    # declaration starts its own lexical routine owner.
                    alternatives += prior_routine[2]
                if len(ts) > 1:
                    routine_roots = program_roots(item for alternative in alternatives for item in alternative)
                    env[routine_name] = ('nim-routine', routine_roots, alternatives)
                capture_effects, capture_roots, capture_depth = enclosing_effects, enclosing_roots, enclosing_depth
            elif first in {'break', 'continue', 'return', 'raise'}:
                # Only an actual keyword terminates this path. A quoted name or
                # a nested routine cannot transfer control in its enclosing body.
                evaluate(ts[1:], env)
                target = nim_name(ts[1][1]) if first == 'break' and len(ts) == 2 and identifier(ts[1]) else None
                abrupt.append((first, target, view(env)))
                observe(env)
                env = None
            elif first in {'if', 'when'}:
                evaluate(ts[1:-1], env)
                arms = [body(children, view(env), True, prefixes=prefixes, conditional=True)]
                has_else = False
                while i+1 < len(rows) and rows[i+1][1][0][1] in {'elif', 'else'}:
                    i += 1; arm = rows[i]
                    evaluate(arm[1][1:-1], env)
                    arms.append(body(arm[2], view(env), True, prefixes=prefixes, conditional=True))
                    has_else |= arm[1][0][1] == 'else'
                if not has_else: arms.append(Flow(view(env)))
                abrupt.extend(item for arm in arms for item in arm.abrupt)
                env = merged(env, [arm.normal for arm in arms if arm.normal is not None])
            elif first in {'for', 'while'}:
                if first == 'for': evaluate(ts[1:-1], env)
                names = []
                if first == 'for':
                    boundary = next((j for j, t in enumerate(ts)
                                     if t[0] == 'id' and t[1] == 'in'), len(ts))
                    names = [nim_name(t[1]) for t in ts[1:boundary] if identifier(t)]
                entry = loop_entry(ts, children, env, names)
                if first == 'while': evaluate(ts[1:-1], entry)
                after = scoped_arm(children, entry, names, prefixes, conditional=True)
                # Entry includes zero iterations and every normal/continue back
                # edge. Breaks leave only this loop; labeled breaks and routine/
                # exception completions retain their outer target ownership.
                exits = [view(entry)]
                for kind, target, state in after.abrupt:
                    if kind == 'break' and target is None: exits.append(state)
                    elif not (kind == 'continue' and target is None):
                        abrupt.append((kind, target, state))
                env = join(env, exits)
            elif first == 'case':
                evaluate(ts[1:-1], env)
                arms = [body(arm[2], view(env), True, prefixes=prefixes, conditional=True) for arm in children]
                # A bounded source analysis does not prove exhaustive selectors.
                arms.append(Flow(view(env)))
                abrupt.extend(item for arm in arms for item in arm.abrupt)
                env = join(env, [arm.normal for arm in arms if arm.normal is not None])
            elif first == 'try':
                protected_prefixes = [view(env)]
                protected = scoped_arm(children, env, prefixes=prefixes+((protected_prefixes, len(scope_frames)),), conditional=True)
                normals = [] if protected.normal is None else [protected.normal]
                completions = list(protected.abrupt)
                # Any protected reachable prefix may transfer into a handler.
                # Looking only at the pre-try or normal final state would let
                # a later checkbox reset conceal an earlier text binding state.
                handler_entry = join(env, protected_prefixes)
                cleanup = None
                while i+1 < len(rows) and rows[i+1][1][0][1] in {'except', 'finally'}:
                    i += 1; arm = rows[i]
                    if arm[1][0][1] == 'finally': cleanup = arm[2]
                    else:
                        names = [nim_name(arm[1][j+1][1]) for j, t in enumerate(arm[1][:-1])
                                 if t[0] == 'id' and t[1] == 'as' and identifier(arm[1][j+1])]
                        handler = scoped_arm(arm[2], handler_entry, names, prefixes, conditional=True)
                        if handler.normal is not None: normals.append(handler.normal)
                        completions.extend(handler.abrupt)
                if cleanup is not None:
                    # Imported calls may throw without an authored raise, and
                    # no thrown-type proof lets this frontend exclude a prefix
                    # from exceptional cleanup, even with typed handlers.
                    completions.append(('raise', None, join(env, protected_prefixes)))
                    incoming = normals + [state for _, _, state in completions]
                    final = body(cleanup, join(env, incoming), True, prefixes=prefixes)
                    # Analyze each authored cleanup access once at a conservative
                    # joined entry, then preserve all incoming completion modes.
                    modes = {(kind, target) for kind, target, _ in completions}
                    had_normal = bool(normals)
                    normals = [] if not had_normal or final.normal is None else [view(final.normal)]
                    completions = list(final.abrupt)
                    if final.normal is not None:
                        completions.extend((kind, target, view(final.normal)) for kind, target in modes)
                abrupt.extend(completions)
                env = merged(env, normals)
            elif first in {'let', 'var', 'const', 'type'} and len(ts) == 1:
                for row in children:
                    env = statement([(ts[0][0], first, ts[0][2])] + row[1], row[2], env, declared)
            elif first in {'let', 'var', 'const', 'type'}:
                env = statement(ts, children, env, declared)
            elif first == 'block':
                target = nim_name(ts[1][1]) if len(ts) > 2 and identifier(ts[1]) else None
                result = body(children, env, True, prefixes=prefixes)
                exits = [] if result.normal is None else [result.normal]
                for kind, label, state in result.abrupt:
                    if kind == 'break' and (label is None or label == target): exits.append(state)
                    else: abrupt.append((kind, label, state))
                env = merged(env, exits)
            elif children:
                # Unknown block syntax (including ui macros) does not grant an
                # exception to raw authored calls. Conservatively join execution.
                evaluate(ts[:-1] if ts[-1][1] == ':' else ts, env)
                result = body(children, view(env), True, prefixes=prefixes, conditional=True)
                abrupt.extend(result.abrupt)
                env = join(env, [view(env)] + ([] if result.normal is None else [result.normal]))
            else: env = statement(ts, children, env, declared,
                                  expression_result if i == len(rows)-1 else None)
            observe(env)
            i += 1
        if declaration_sink is not None: declaration_sink.update(declared)
        result = Flow(env, abrupt)
        for state in result.states():
            # Prefix snapshots own operation observations; ordinary successor
            # environments do not retain an analyzer's observation payload.
            state.pop(('nim-observed-effects',), None)
            if scoped:
                for name in declared:
                    if name in roots: state[name] = state[roots[name]]
                    else: state.pop(name, None)
            for root in roots.values(): state.pop(root, None)
            # Only an actual lexical scope owns cells to release here. A plain
            # statement list leaves its enclosing declarations/captures alive.
            if not enclosing:
                for name in declared:
                    cell = ('nim-binding', id(rows), name)
                    state.pop(cell, None); state.pop(('nim-dependency', cell), None)
                    state.pop(('nim-written-binding', cell), None)
        if not enclosing: scope_frames.pop()
        active_prefixes = previous_prefixes
        return result

    def declaration_reference(value, rhs_dependencies, name, line, env):
        if capture_effects is not None and isinstance(value, Allocation) and rhs_dependencies:
            witness = ('nim-reference-slot', line, name)
            owners = tuple(dict.fromkeys(dep[1] if dep[:1] == ('nim-reference',) else dep
                                         for dep in rhs_dependencies))
            capture_mutation((owners[0],), env,
                             ('reference', witness, rhs_dependencies, line))
            env[witness] = value
            return tuple(('nim-reference', owner, witness) for owner in owners)
        return rhs_dependencies

    def bind_value(name, value, rhs, rhs_dependencies, env, declared, declaration, line, reference_recorded=False):
        prior = env.get(name)
        if not declaration and value is None and isinstance(prior, Allocation):
            value = uncertain([prior, *reachable(rhs, env)])
        if declaration: declared.add(name)
        root = binding_root(name)
        if not declaration: capture_mutation((root,), env, ('rebind', False, rhs_dependencies, line))
        env[name] = value
        if root is not None:
            env[root] = value
            if declaration: env[('nim-written-binding', root)] = False
            if not declaration and capture_effects is not None:
                env[('nim-written-binding', root)] = True
            if declaration and not reference_recorded:
                rhs_dependencies = declaration_reference(value, rhs_dependencies, name, line, env)
            env[('nim-dependency', root)] = frozenset(rhs_dependencies)

    def declaration_binder(ts):
        # Stock Nim parser identWithPragma: only the first identifier is a
        # binder. Export markers and pragma payloads never introduce locals.
        if not ts or not identifier(ts[0]): return None
        tail = ts[1:]
        if tail and tail[0][:2] == ('symbol', '*'): tail = tail[1:]
        if tail and not (len(tail) >= 4 and spelling(tail[:2]) == '{.'
                         and spelling(tail[-2:]) == '.}'):
            return None
        return nim_name(ts[0][1])

    def declaration_shape(ts):
        ts = split(ts, ':')[0]
        if whole_parens(ts):
            entries = split(ts[1:-1], ',')
            if entries and not entries[-1]: entries.pop()
            shapes = [declaration_shape(entry) for entry in entries]
            return shapes if shapes and all(shape is not None for shape in shapes) else None
        return declaration_binder(ts)

    def declaration_values(shape, rhs, env, tuple_member=False):
        # Tuple initializers run once, before any tuple binder is visible.
        # Only directly authored tuple positions project values; unknown tuple
        # expressions still execute their tracked accesses/effects once.
        if isinstance(shape, list):
            entries = split(rhs[1:-1], ',') if whole_parens(rhs) else []
            if entries and not entries[-1]: entries.pop()
            if len(entries) == len(shape):
                return [declaration_values(part, entry, env, True) for part, entry in zip(shape, entries)]
            value = evaluate(rhs, env)
            deps = dependencies(rhs, env)
            if capture_effects is not None: deps = external_dependencies(deps, env)
            def retain(part):
                if isinstance(part, list): return [retain(child) for child in part]
                possible = uncertain([value])
                refs = declaration_reference(possible, deps, part, rhs[0][2], env)
                return possible, rhs, refs, True
            # No positional/type inference for a nonliteral tuple. Already
            # tracked RHS obligations remain possible receivers of each binder.
            return retain(shape)
        value = evaluate(rhs, env)
        deps = dependencies(rhs, env)
        if capture_effects is not None: deps = external_dependencies(deps, env)
        # A tuple's earlier reference read precedes later initializer effects.
        # Record the value now, while its captured cell still names that value;
        # the source binder itself becomes visible only after the whole tuple.
        if tuple_member: deps = declaration_reference(value, deps, shape, rhs[0][2], env)
        return value, rhs, deps, tuple_member

    def bind_declaration(shape, values, env, declared, line):
        if isinstance(shape, list):
            for index, part in enumerate(shape):
                bind_declaration(part, None if values is None else values[index], env, declared, line)
        else:
            value, rhs, deps, recorded = values if values is not None else (None, [], frozenset(), False)
            bind_value(shape, value, rhs, deps, env, declared, True, line, recorded)

    def statement(ts, children, env, declared, expression_result=None):
        first = ts[0][1] if ts[0][0] == 'id' else None
        declaration = first in {'let', 'var', 'const', 'type'}
        content = ts[1:] if declaration else ts
        pieces = split(content, '=')
        # DECLARATION-BINDING-START: lexical identities belong to structural
        # binder positions, including wrapped and tuple bindings. Comma groups
        # repeat the initializer sequentially (fresh calls remain fresh, while
        # an actual alias still shares identity), as Nim2.2.4 does.
        if declaration and first != 'type' and len(pieces) in {1, 2}:
            head = split(pieces[0], ':')[0]
            shapes = [declaration_shape(part) for part in split(head, ',') if part]
            if shapes and all(shape is not None for shape in shapes):
                for ordinal, shape in enumerate(shapes):
                    rhs = pieces[1] if len(pieces) == 2 else []
                    # A repeated initializer has one finite authored execution
                    # context per binder, also for deferred captured-call effects.
                    if len(shapes) > 1: declaration_origins.append((ts[0][2], ordinal))
                    try:
                        values = declaration_values(shape, rhs, env) if rhs else None
                    finally:
                        if len(shapes) > 1: declaration_origins.pop()
                    bind_declaration(shape, values, env, declared, ts[0][2])
                return env
        # DECLARATION-BINDING-END
        if len(pieces) == 2:
            lhs, rhs = pieces
            if declaration: lhs = split(lhs, ':')[0]
            if len(lhs) == 1 and identifier(lhs[0]):
                value = evaluate(rhs, env)
                rhs_dependencies = dependencies(rhs, env)
                if capture_effects is not None: rhs_dependencies = external_dependencies(rhs_dependencies, env)
                bind_value(nim_name(lhs[0][1]), value, rhs, rhs_dependencies,
                           env, declared, declaration, ts[0][2])
                return env
            # Assignment target access is itself one authored binding.
            evaluate(lhs, env); evaluate(rhs, env)
            dots = split(lhs, '.')
            if len(dots) == 2:
                target = lookup(dots[0], env)
                if isinstance(target, Allocation):
                    member = dots[1][0][1] if len(dots[1]) == 1 else None
                    capture_mutation(dependencies(dots[0], env), env, ('metadata', member, False, ts[0][2]))
                    metadata(target, member, constant(rhs, env))
            else:
                capture_mutation(dependencies(lhs, env), env, ('invalidate', ts[0][2]))
                for allocation in reachable(lhs, env): invalidate(allocation)
        elif declaration:
            names = split(content, ':')[0]
            for name in split(names, ','):
                if len(name) == 1:
                    key = nim_name(name[0][1]); env[key] = None; declared.add(key)
                    env[binding_root(key)] = None
        else:
            value = evaluate(ts[1:] if first in {'discard', 'return', 'raise', 'yield'} else ts, env)
            if expression_result is not None and first not in {'discard', 'return', 'raise', 'yield'}:
                expression_result.append(value)
        return env

    body(roots, {})
    # One initializer can execute for multiple comma binders. Its effects and
    # allocations remain separate, but the receiver token is one authored site.
    # Aggregate retained observations only after fixed-point rollback is over.
    # A later unresolved receiver must upgrade an earlier known free-text one.
    authored = {}
    for span, finding in findings:
        if span not in authored or finding.api == UNRESOLVED:
            authored[span] = finding
    return list(authored.values())


def js_lexical_parts(text: str):
    """Elide JS comments/string contents; retain template interpolation code.

    Bracket literal properties are canonicalized so Date['now'] is checked too.
    Regex literals are elided in expression-start positions. This intentionally
    stops short of resolving aliases, computed names or generated source.
    """
    out = list(text)
    literals = []

    def elide(start: int, end: int):
        out[start:end] = blank(text[start:end])

    def quoted(i: int) -> int:
        start, quote = i, text[i]
        i += 1
        while i < len(text):
            if text[i] == '\\': i += 2
            elif text[i] == quote: i += 1; break
            else: i += 1
        literals.append((start, i))
        elide(start, i)
        return i

    def template(i: int) -> int:
        # Structural extent is separate from the elided prose. Privacy flow
        # needs to distinguish a tagged-template continuation from an ASI gap;
        # executable interpolation tokens remain in the mask as before.
        template_start = i
        start = i
        i += 1
        while i < len(text):
            if text[i] == '\\': i += 2
            elif text[i] == '`':
                i += 1
                elide(start, i)
                literals.append((template_start, i))
                return i
            elif text.startswith('${', i):
                elide(start, i + 2)
                # Match expression braces using the code lexer, which respects
                # quoted braces, comments, regexes and nested template literals.
                i = code(i + 2, closing_brace=True)
                start = i - 1
            else: i += 1
        elide(start, i)
        return i

    def code(i: int, closing_brace=False) -> int:
        previous = ''
        while i < len(text):
            start = i
            if text.startswith('//', i):
                end = re.search(r'[\r\n\u2028\u2029]', text[i:])
                i = i + end.start() if end else len(text)
                elide(start, i)
            elif text.startswith('/*', i):
                end = text.find('*/', i + 2); i = len(text) if end < 0 else end + 2
                elide(start, i)
            elif text[i] in "\"'":
                i = quoted(i)
                previous = 'v'
            elif text[i] == '`':
                i = template(i)
                previous = 'v'
            elif text[i] == '/' and (not previous or previous in '=(:,[!&|?;{}' or
                                      re.search(r'\b(?:return|throw|case|delete|typeof|void|yield|await|in|of)\s*$', text[:i])):
                i += 1; in_class = False
                while i < len(text) and text[i] not in '\r\n\u2028\u2029':
                    if text[i] == '\\': i += 2; continue
                    if text[i] == '[': in_class = True
                    elif text[i] == ']': in_class = False
                    elif text[i] == '/' and not in_class: i += 1; break
                    i += 1
                elide(start, i)
                previous = 'v'
            elif text[i] == '{':
                i = code(i + 1, closing_brace=True)
                previous = '}'
            elif text[i] == '}' and closing_brace:
                return i + 1
            else:
                if not text[i].isspace(): previous = text[i]
                i += 1
        return i

    code(0)
    return ''.join(out), literals


def executable_js(text: str) -> str:
    result, _literals = js_lexical_parts(text)
    # Only literal member names; strings elsewhere remain invisible.
    for m in re.finditer(r'\[\s*([\'"])([A-Za-z_$][\w$]*)\1\s*\]', text):
        if result[m.start():m.start()+1] == '[':
            replacement = '.' + m[2]
            result = result[:m.start()] + replacement.ljust(m.end()-m.start()) + result[m.end():]
    return result


IDENT = r'(?<![\w$])'
MEMBER = r'\s*(?:\?\.|\.)\s*'
PATTERNS = {
    'fetch': IDENT + r'fetch\s*\(',
    **{name: IDENT + name + r'(?![\w$])' for name in
       ['XMLHttpRequest', 'WebSocket', 'localStorage', 'sessionStorage']},
    'Date.now': IDENT + r'Date' + MEMBER + r'now\b',
    'new Date': IDENT + r'new\s+Date\s*\(',
    'performance.now': IDENT + r'performance' + MEMBER + r'now\b',
    'Math.random': IDENT + r'Math' + MEMBER + r'random\b',
    'crypto.getRandomValues': IDENT + r'crypto' + MEMBER + r'getRandomValues\b',
    'document.cookie': IDENT + r'document' + MEMBER + r'cookie\b',
    **{name: IDENT + name + r'\s*\(' for name in
       ['setTimeout', 'setInterval', 'requestAnimationFrame',
        'getBoundingClientRect', 'getComputedStyle', 'matchMedia', 'addEventListener']},
    'layout read': r'\.\s*(?:offset|client|scroll)[A-Z][\w$]*\b(?!\s*\()(?!\s*=(?!=))',
}
WARNINGS = ['Worker', 'WebAssembly', 'BroadcastChannel', 'indexedDB']


def scan_file(path: Path, label: str, *, platform: bool = True) -> list[Finding]:
    text = path.read_text()
    if path.suffix == '.js':
        positions, line = [], 1
        for index, ch in enumerate(text):
            positions.append(line)
            if ch in '\r\u2028\u2029' or (ch == '\n' and (index == 0 or text[index-1] != '\r')):
                line += 1
        fragments = [(text, positions, [])]
    else:
        fragments = foreign_fragments(text)
    findings = nim_dom_privacy(text, label) if path.suffix == '.nim' else []
    for payload, positions, opaque in fragments:
        mask, literals = js_lexical_parts(payload)
        findings.extend(Finding(label, positions[offset], api)
                        for offset, api in privacy_bindings(payload, mask, literals, opaque))
        if not platform: continue
        code = executable_js(payload)
        for api, pattern in PATTERNS.items():
            matches = list(re.finditer(pattern, code))
            for match in matches:
                findings.append(Finding(label, positions[match.start()], api))
            # importc commonly names the symbol rather than spelling a call.
            # A bare foreign binding must not evade the call-shaped checks.
            if not matches and path.suffix == '.nim' and code.strip() == api:
                findings.append(Finding(label, positions[0], api))
        for api in WARNINGS:
            for match in re.finditer(IDENT + api + r'(?![\w$])', code):
                findings.append(Finding(label, positions[match.start()], api, 'warning'))
    return findings


def scan(roots: list[Path]) -> list[Finding]:
    findings = []
    for root in roots:
        root = root.resolve()
        if not root.is_dir(): raise ValueError(f'missing source root: {root}')
        # Git's ownership view excludes submodule trees, vendored/ignored build
        # outputs, and includes new, untracked source files before their commit.
        repo = subprocess.run(['git', '-C', str(root), 'rev-parse', '--show-toplevel'],
                              capture_output=True, text=True)
        if repo.returncode == 0:
            top = Path(repo.stdout.strip())
            inventory = subprocess.run(
                ['git', '-C', str(top), 'ls-files', '-z', '--cached', '--others',
                 '--exclude-standard', '--', str(root.relative_to(top))],
                capture_output=True, check=True)
            paths = {top / name.decode() for name in inventory.stdout.split(b'\0') if name}
        else:
            paths = set(root.rglob('*'))
        for path in sorted(paths):
            if path.suffix not in {'.nim', '.js'}: continue
            relative = path.relative_to(root).as_posix()
            label = root.parent.name + '/' + root.name + '/' + relative
            # This exact framework backend owns foreign platform reads. A site's
            # similarly named module is still scanned.
            platform = path.resolve() != Path(__file__).resolve().parents[1] / 'src/isonim/core/nondet.nim'
            findings.extend(scan_file(path, label, platform=platform))
    return findings


def apply_allowlist(findings: list[Finding], entries: list[dict]) -> list[Finding]:
    if not isinstance(entries, list): raise ValueError('allowlist must be an array')
    counts = Counter((f.path, f.api) for f in findings if f.severity == 'error')
    allowed = set()
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {'path', 'api', 'count', 'reason'}:
            raise ValueError('allowlist entries require path, api, count, reason')
        if not all(isinstance(entry[name], str) and entry[name].strip() for name in ('path', 'api')):
            raise ValueError('allowance path and api must be nonempty strings')
        if entry['api'] in PRIVACY_APIS:
            raise ValueError('privacy findings cannot be allowed')
        key = (entry['path'], entry['api'])
        if key in allowed: raise ValueError(f'duplicate allowance: {key}')
        if not isinstance(entry['reason'], str) or not entry['reason'].strip():
            raise ValueError(f'allowance needs a reason: {key}')
        if type(entry['count']) is not int or entry['count'] < 1:
            raise ValueError(f'allowance needs a positive count: {key}')
        if counts[key] != entry['count']:
            raise ValueError(f'allowance count mismatch: {key}: expected {entry["count"]}, found {counts[key]}')
        allowed.add(key)
    return [f for f in findings if f.severity == 'warning' or (f.path, f.api) not in allowed]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('roots', type=Path, nargs='+', help='source directories (including a site src/)')
    parser.add_argument('--allowlist', type=Path)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    try:
        findings = scan(args.roots)
        if args.allowlist:
            findings = apply_allowlist(findings, json.loads(args.allowlist.read_text()))
    except (ValueError, OSError) as exc:
        parser.exit(2, f'lint-nondet: {exc}\n')
    errors = sum(f.severity == 'error' for f in findings)
    warnings = len(findings) - errors
    if args.json: print(json.dumps([asdict(f) for f in findings]))
    else:
        for f in findings: print(f'{f.path}:{f.line}: {f.severity}: raw {f.api}')
        print(f'lint-nondet: {errors} errors, {warnings} warnings')
    return int(errors > 0)


if __name__ == '__main__':
    raise SystemExit(main())
