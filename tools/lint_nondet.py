#!/usr/bin/env python3
"""Scan foreign Nim code and JavaScript for unmediated platform boundaries.

Library entry points return findings; the CLI handles reporting and exit status.
This is a lexical policy check, not JavaScript data-flow or Nim effect inference.
Allowances pin exact path/API counts, so new uses require a reasoned amendment.
"""
from __future__ import annotations
import argparse
from collections import Counter
from dataclasses import asdict, dataclass
import json
from pathlib import Path
import re
import subprocess


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


def nim_foreign(text: str):
    """Yield importjs/importc/emit payloads, including emit fragment arrays.

    Tokenizing first prevents examples in comments or ordinary Nim strings from
    becoming code. Nested Nim block comments and multiline strings are supported.
    """
    tokens = []
    literal_lines = {}
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
        elif text[i].isalpha() or text[i] == '_':
            i += 1
            while i < len(text) and (text[i].isalnum() or text[i] == '_'): i += 1
            tokens.append(('id', text[start:i].lower().replace('_', ''), start))
        elif text[i].isspace(): i += 1
        else:
            tokens.append(('symbol', text[i], i)); i += 1
    for index, (kind, value, pos) in enumerate(tokens):
        if kind != 'id' or value not in {'importjs', 'importc', 'emit'}: continue
        if index == 0 or tokens[index - 1][1] not in {'.', ','}: continue
        tail = tokens[index + 1:]
        if not tail or tail[0][1] != ':': continue
        tail = tail[1:]
        if tail and tail[0][0] == 'string':
            yield tail[0][1], literal_lines[tail[0][2]]
        elif value == 'emit' and tail and tail[0][1] == '[':
            # Non-string Nim expressions splice generated identifiers. A marker
            # retains expression structure while adjacent strings concatenate.
            parts, locations, fragment = [], [], []
            nesting = []

            def append_fragment():
                # Only a literal array item is JavaScript. Strings passed to
                # indexed/called Nim expressions belong to those expressions.
                if len(fragment) == 1 and fragment[0][0] == 'string':
                    parts.append(fragment[0][1])
                    locations.extend(literal_lines[fragment[0][2]])
                elif fragment:
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
            yield ''.join(parts), locations


def executable_js(text: str) -> str:
    """Elide JS comments/string contents; retain template interpolation code.

    Bracket literal properties are canonicalized so Date['now'] is checked too.
    Regex literals are elided in expression-start positions. This intentionally
    stops short of resolving aliases, computed names or generated source.
    """
    out = list(text)

    def elide(start: int, end: int):
        out[start:end] = blank(text[start:end])

    def quoted(i: int) -> int:
        start, quote = i, text[i]
        i += 1
        while i < len(text):
            if text[i] == '\\': i += 2
            elif text[i] == quote: i += 1; break
            else: i += 1
        elide(start, i)
        return i

    def template(i: int) -> int:
        start = i
        i += 1
        while i < len(text):
            if text[i] == '\\': i += 2
            elif text[i] == '`':
                i += 1
                elide(start, i)
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
    result = ''.join(out)
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


def scan_file(path: Path, label: str) -> list[Finding]:
    text = path.read_text()
    if path.suffix == '.js':
        positions, line = [], 1
        for ch in text:
            positions.append(line)
            if ch == '\n': line += 1
        fragments = [(text, positions)]
    else:
        fragments = nim_foreign(text)
    findings = []
    for payload, positions in fragments:
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
            if path.resolve() == Path(__file__).resolve().parents[1] / 'src/isonim/core/nondet.nim': continue
            findings.extend(scan_file(path, label))
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
