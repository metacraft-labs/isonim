#!/usr/bin/env python3
"""Real-file/CLI controls for the lexical gate; no mock scanner or subprocess.
Temporary source trees deliberately contain forbidden APIs: they are the input
under test, not fake implementations of production platform behavior.
"""
from collections import Counter
import json
import hashlib
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import lint_nondet as lint

SCRIPT = Path(__file__).with_name('lint_nondet.py')
PROJECT = Path(__file__).resolve().parents[1]
SEEDS = {
    'fetch': 'fetch("/")', 'XMLHttpRequest': 'new XMLHttpRequest()',
    'WebSocket': 'new WebSocket("/")', 'Date.now': 'Date.now()',
    'new Date': 'new Date()', 'performance.now': 'performance.now()',
    'Math.random': 'Math.random()', 'crypto.getRandomValues': 'crypto.getRandomValues(a)',
    'localStorage': 'localStorage.getItem("k")', 'sessionStorage': 'sessionStorage.getItem("k")',
    'document.cookie': 'document.cookie', 'setTimeout': 'setTimeout(cb, 0)',
    'setInterval': 'setInterval(cb, 1)', 'requestAnimationFrame': 'requestAnimationFrame(cb)',
    'getBoundingClientRect': 'el.getBoundingClientRect()', 'getComputedStyle': 'getComputedStyle(el)',
    'matchMedia': 'matchMedia("screen")', 'addEventListener': 'el.addEventListener("click", cb)',
    'offset': 'el.offsetWidth', 'client': 'el.clientHeight', 'scroll': 'el.scrollTop',
}
EXPECTED = Counter({name: 1 for name in lint.PATTERNS})
EXPECTED['layout read'] = 3


class LintTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'site' / 'src'
        self.root.mkdir(parents=True)
        # Isolated scanner mutants need the same actual production dependency.
        shutil.copyfile(SCRIPT.with_name("lint_privacy.py"),
                        Path(self.temp.name) / "lint_privacy.py")

    def write(self, name, code):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(code)
        return path

    def retain_inputs(self, command):
        # Optional qualification receipts retain newly authored fixture bytes
        # before their real CLI/compiler consumer. This does not intercept or
        # replace subprocesses. Existing compiler -r probes have their original
        # execution phase and do not claim separately sealed generated binaries.
        destination = os.environ.get('ISONIM_LINT_RECEIPTS')
        if not destination: return
        dest = Path(tempfile.mkdtemp(prefix='fixture-', dir=destination))
        sources = [p for p in Path(self.temp.name).rglob('*')
                   if p.is_file() and p.suffix in {'.nim', '.js', '.py', '.json', '.log'}]
        sources += [SCRIPT, SCRIPT.with_name('lint_privacy.py'), Path(__file__)]
        rows = {}
        for index, path in enumerate(sorted(set(sources))):
            data = path.read_bytes()
            (dest / str(index)).write_bytes(data)
            rows[str(path)] = dict(sha256=hashlib.sha256(data).hexdigest(),
                                   size=len(data), payload=str(index))
        (dest / 'BEFORE.json').write_text(json.dumps(dict(
            command=list(map(str, command)), test=self.id(), sources=rows), indent=2))

    def cli(self, *args):
        self.retain_inputs([sys.executable, SCRIPT, '--json', self.root, *args])
        return subprocess.run([sys.executable, str(SCRIPT), '--json', str(self.root), *map(str, args)],
                              capture_output=True, text=True)

    def test_exact_seed_counts_in_js_and_foreign_pragmas(self):
        # One of each specified family, including all three DOM read prefixes.
        self.assertEqual(set(SEEDS) - {'offset', 'client', 'scroll'}, set(lint.PATTERNS) - {'layout read'})
        forms = [('\n'.join(SEEDS.values()) + ';', 'seed.js'),
                 ('\n'.join('proc p%d() {.importjs: %s.}' % (i, json.dumps(code))
                            for i, code in enumerate(SEEDS.values())), 'seed.nim'),
                 ('\n'.join('proc p%d() {.importc: %s.}' % (i, json.dumps(code))
                            for i, code in enumerate(SEEDS.values())), 'seed.nim'),
                 ('{.emit: """' + ';\n'.join(SEEDS.values()) + '""".}', 'seed.nim')]
        for code, name in forms:
            with self.subTest(form=name, prefix=code[:20]):
                path = self.write(name, code)
                findings = lint.scan([self.root])
                self.assertEqual(Counter(f.api for f in findings), EXPECTED)
                self.assertEqual(len(findings), 21)
                result = self.cli()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(len(json.loads(result.stdout)), 21)
                path.unlink()

    def test_lexical_forms_and_negative_controls(self):
        self.write('forms.nim', '''
# {.emit: "Date.now()".}
#[ nested #[ {.emit: "fetch('/')".} ]# ]#
let prose = "Date.now() setTimeout()"
{.emit: ["const t = Date", result, ".now();"].}
proc nativeClock(): int {.importc: "Date.now".}
''')
        self.assertEqual(Counter(f.api for f in lint.scan([self.root])), {'Date.now': 1})
        self.write('forms.js', '''
// Date.now()
/* fetch('/') */
const prose = "Math.random()";
const rx = /setTimeout()/;
function pattern() { return /Date.now()/; }
el.scrollTop = 1; el.scrollIntoView(); el.clientOnly();
Date /* spaced */ ?. now(); performance['now']();
const computed = `safe ${Math.random()}`;
''')
        self.assertEqual(Counter(f.api for f in lint.scan([self.root])),
                         {'Date.now': 2, 'performance.now': 1, 'Math.random': 1})

    def test_bare_foreign_symbol_bindings(self):
        names = ['fetch', 'setTimeout', 'setInterval', 'requestAnimationFrame',
                 'getBoundingClientRect', 'getComputedStyle', 'matchMedia', 'addEventListener']
        self.write('bindings.nim', '\n'.join(
            'proc raw%d() {.importc: %s.}' % (i, json.dumps(name))
            for i, name in enumerate(names)))
        self.assertEqual(Counter(f.api for f in lint.scan([self.root])), dict.fromkeys(names, 1))

    def test_template_interpolation_uses_lexical_brace_matching(self):
        expressions = ['"}" + Date.now()', '"{" + Date.now()',
                       '/* } { */ Date.now()', '/[{}]/.test("}") + Date.now()',
                       '`inside ${Date.now()} { }`', '{value: Date.now()}.value']
        for expression in expressions:
            payload = 'const result = `x ${' + expression + '} y`;\n'
            payload += 'const prose = `Date.now() ${"Date.now()"} Date.now()`;'
            for name, code in [('templates.js', payload),
                               ('templates.nim', '{.emit: """' + payload + '""".}')]:
                with self.subTest(form=name, expression=expression):
                    path = self.write(name, code)
                    result = self.cli()
                    self.assertEqual(result.returncode, 1, result.stderr)
                    findings = json.loads(result.stdout)
                    self.assertEqual(Counter(f['api'] for f in findings), {'Date.now': 1})
                    self.assertEqual([f['line'] for f in findings], [1])
                    path.unlink()

    def test_site_named_isonim_does_not_inherit_trusted_seam_exclusion(self):
        root = Path(self.temp.name) / 'isonim' / 'src'
        path = root / 'isonim/core/nondet.nim'
        path.parent.mkdir(parents=True)
        path.write_text('{.emit: "Date.now()".}')
        result = subprocess.run([sys.executable, str(SCRIPT), '--json', str(root)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual([f['api'] for f in json.loads(result.stdout)], ['Date.now'])

    def test_nim_characters_raw_literals_and_style_insensitive_pragmas(self):
        self.write('literal_forms.nim', '''
let quote = '\u0022'
let hash = '#'
let suffix = 1'i64
{.e_m_i_t: r"Date.now();".}
proc rawNow(): float {.import_js: r"Date.now()".}
proc rawNative(): float {.import_c: r"Date.now".}
{.emit: r"const prose = ""Date.now()""; Date.now();".}
''')
        result = self.cli()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(Counter(f['api'] for f in json.loads(result.stdout)), {'Date.now': 4})

    def test_emit_fragments_after_indexed_nim_expressions(self):
        self.write('fragments.nim', '''
var values = [1]
{.emit: [values[0], " = Date.now();"].}
{.emit: [values[[0][0]], " = performance.now();"].}
{.emit: [lookup("Math.random()"), " = 1;"].}
''')
        result = self.cli()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(Counter(f['api'] for f in json.loads(result.stdout)),
                         {'Date.now': 1, 'performance.now': 1})

    def test_decoded_nim_escapes_reveal_foreign_calls_at_physical_source_lines(self):
        cases = [
            r'{.emit: "// note\nDate.now();".}',
            r'proc clock(): float {.importjs: "\x44ate.now()".}',
            *[r'{.emit: "//' + '\\' + escape + r'Date.now();".}'
              for escape in ['n', 'N', 'l', 'L', 'p', 'P', 'r', 'R', 'c', 'C',
                             'x0A', '10', 'u000A', 'u2028', 'u{2029}']],
            *[r'proc clock(): float {.importjs: "' + '\\' + escape + r'ate.now()".}'
              for escape in ['X44', '68', '00000068', 'u0044', 'U0044', 'u{44}', 'U{44}']],
            r'{.emit: "\t\f\vDate.now();".}',
            r'{.emit: "\xC2\xA0Date.now();".}',
        ]
        for code in cases:
            with self.subTest(code=code):
                self.write('escapes.nim', '# physical source line one\n' + code)
                result = self.cli()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(json.loads(result.stdout), [dict(
                    path='site/src/escapes.nim', line=2, api='Date.now', severity='error')])
        self.write('escapes.nim', '# first\n{.emit: ["// note\\n",\n value[0],\n " = \\x44ate.now();"].}')
        result = self.cli()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual([f['line'] for f in json.loads(result.stdout)], [4])

    def test_nim_escapes_preserve_noncode_raw_and_triple_literals(self):
        self.write('negative.nim', r'''
# {.emit: "// note\nDate.now();".}
#[ {.emit: "\x44ate.now();".} ]#
let ordinary = "\x44ate.now()"
let regex = re"\d+\w+"
let interpolated = fmt"\unknown"
{.emit: r"// note\nDate.now();".}
{.emit: """// note\nDate.now();""".}
{.emit: "// note\\nDate.now();".}
{.emit: "\x22Date.now()\x22;".}
''')
        result = self.cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])
        self.write('triple.nim', '{.emit: """\n// actual newline\nDate.now();\n""".}')
        result = self.cli()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual([f['line'] for f in json.loads(result.stdout)], [3])

    def test_nim_decoder_matches_real_compiler_bytes_and_foreign_execution(self):
        # The real compiler is the oracle for the literal grammar; no Python
        # codec or second handwritten decoder supplies the expected bytes.
        spellings = [r'"// note\nDate.now();"', r'"\x44ate.now()"',
                     r'"\x4"', r'"\u4"',
                     r'"\00000068"', r'"\xC2\xA0"', r'"\u{1F642}"',
                     r'"\U{10FFFF}"', r'"\uD800"', r'"\255"', r'"\xFF"',
                     r'"café"', r'"\u00E9"', r'"\'\"\\"']
        spellings += ['"\\' + escape + '"' for escape in 'nNpPrRcClLfFeEaAbBvVtT']
        probe = Path(self.temp.name) / 'escape_probe.nim'
        probe.write_text('import std/strutils\nfor value in [' + ', '.join(spellings) + ''']:
  var encoded = ""
  for ch in value: encoded.add(toHex(ord(ch), 2))
  echo encoded
''')
        result = subprocess.run(['nim', 'c', '-r', '--hints:off',
                                 '--out:' + str(Path(self.temp.name) / 'escape_probe'), str(probe)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(result.stdout.splitlines()), len(spellings))
        for spelling, encoded in zip(spellings, result.stdout.splitlines()):
            with self.subTest(spelling=spelling):
                decoded, offsets = lint.decode_nim_string(spelling[1:-1])
                self.assertEqual(len(decoded), len(offsets))
                actual = bytes.fromhex(encoded)
                if spelling in [r'"\p"', r'"\P"']: actual = actual.replace(b'\r\n', b'\n')
                self.assertEqual(decoded.encode('utf-8', 'surrogateescape'), actual)
        probe = Path(self.temp.name) / 'foreign_probe.nim'
        probe.write_text(r'''{.emit: "// note\nDate.now();".}
proc clock(): float {.importjs: "\x44ate.now()".}
doAssert clock() > 0
echo "escaped_foreign_compiler_probe_ok"
''')
        result = subprocess.run(['nim', 'js', '-r', '--hints:off',
                                 '--out:' + str(Path(self.temp.name) / 'foreign_probe.js'), str(probe)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'escaped_foreign_compiler_probe_ok')

    def test_reverting_nim_decoder_misses_both_confirmed_escape_cases(self):
        # Isolated implementation mutation: restore the former quote/backslash
        # decoder. Both real CLI controls must distinguish it from the fix.
        mutant = Path(self.temp.name) / 'old_decoder.py'
        old = "payload = re.sub(r'\\\\([\"\\\\])', r'\\1', payload)\n                offsets = list(range(len(payload)))"
        source = SCRIPT.read_text()
        self.assertEqual(source.count('payload, offsets = decode_nim_string(payload)'), 1)
        mutant.write_text(source.replace('payload, offsets = decode_nim_string(payload)', old))
        for code in [r'{.emit: "// note\nDate.now();".}',
                     r'proc clock(): float {.importjs: "\x44ate.now()".}']:
            with self.subTest(code=code):
                self.write('mutant_control.nim', code)
                fixed = self.cli()
                self.assertEqual(fixed.returncode, 1, fixed.stderr)
                self.assertEqual([f['api'] for f in json.loads(fixed.stdout)], ['Date.now'])
                result = subprocess.run([sys.executable, str(mutant), '--json', str(self.root)],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), [])

    def test_allowlist_exact_counts_reasons_and_hmr_mutation(self):
        path = self.write('isonim/web/hmr_css_watch.nim', 'proc now(): float {.importjs: "Date.now()".}\n')
        entry = {'path': 'site/src/isonim/web/hmr_css_watch.nim', 'api': 'Date.now', 'count': 1,
                 'reason': 'HMR stylesheet cache-busting; absent from release page runtime.'}
        allow = Path(self.temp.name) / 'allow.json'
        allow.write_text(json.dumps([entry]))
        self.assertEqual(self.cli('--allowlist', allow).returncode, 0)
        path.write_text(path.read_text() + 'proc extra(): float {.importjs: "Date.now()".}\n')
        self.assertEqual(self.cli('--allowlist', allow).returncode, 2)
        allow.write_text('[]')
        result = self.cli('--allowlist', allow)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(json.loads(result.stdout)), 2)
        path.write_text('discard\n')
        allow.write_text(json.dumps([entry]))
        self.assertEqual(self.cli('--allowlist', allow).returncode, 2) # stale
        entry['reason'] = ' '
        allow.write_text(json.dumps([entry]))
        result = self.cli('--allowlist', allow)
        self.assertEqual(result.returncode, 2)
        self.assertIn('needs a reason', result.stderr)

    def test_refusal_warnings_do_not_hide_errors(self):
        self.write('refusal.js', 'new Worker("w"); WebAssembly.instantiate(a); new BroadcastChannel("b"); indexedDB.open("d");')
        result = self.cli()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(Counter(f['api'] for f in json.loads(result.stdout)), dict.fromkeys(lint.WARNINGS, 1))
        self.assertTrue(all(f['severity'] == 'warning' for f in json.loads(result.stdout)))
        self.write('fatal.js', 'Date.now()')
        result = self.cli()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(Counter(f['severity'] for f in json.loads(result.stdout)), {'warning': 4, 'error': 1})

    def test_repository_ownership_includes_new_source_excludes_ignored_and_submodules(self):
        repo = self.root.parent
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        (repo / '.gitignore').write_text('src/generated/\n')
        self.write('generated/out.js', 'fetch("/")')
        self.write('new.js', 'Date.now()')
        # A real gitlink entry: ls-files returns the submodule path, never its
        # third-party source. No submodule network checkout is needed.
        self.write('vendor/dependency.js', 'Math.random()')
        subprocess.run(['git', '-C', str(repo), 'update-index', '--add', '--cacheinfo',
                        '160000,1111111111111111111111111111111111111111,src/vendor'], check=True)
        result = self.cli()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual([f['api'] for f in json.loads(result.stdout)], ['Date.now'])


    def assert_privacy(self, source, expected, name='privacy.js'):
        self.write(name, source)
        result = self.cli()
        rows = [dict(path='site/src/' + name, line=line, api=api, severity='error')
                for line, api in expected]
        self.assertEqual(json.loads(result.stdout), rows)
        self.assertEqual(result.returncode, int(bool(rows)), result.stderr)

    def test_privacy_literal_field_matrix_and_nonfield_controls(self):
        raw = 'free-text binding'
        for tag in ['input', 'textarea']:
            with self.subTest(tag=tag):
                self.assert_privacy('const field = document.createElement(%s);\nfield.value = model.value;' % json.dumps(tag), [(2, raw)])
        for kind in ['text', 'search', 'email', 'tel', 'url', 'password', 'TEXT']:
            with self.subTest(kind=kind):
                self.assert_privacy('const field = document.createElement("input");\nfield.type = %s;\nfield.value = "seed";' % json.dumps(kind), [(3, raw)])
        for kind in ['checkbox', 'radio', 'button', 'number', 'range', 'color', 'hidden']:
            with self.subTest(kind=kind):
                self.assert_privacy('const field = document.createElement("input");\nfield.type = %s;\nfield.value = "seed";' % json.dumps(kind), [])
        for code in ['const field = document.createElement("button"); field.textContent = "Go";',
                     'const field = document.createTextNode(""); field.textContent = model.value;',
                     'const model = {}; model.value = "seed"; model.textContent = "label";',
                     'const field = document.createElement("div"); field.type = "password"; field.textContent = "label";',
                     'const field = document.createElement("textarea"); field.type = "checkbox"; field.textContent = "seed";']:
            with self.subTest(code=code):
                self.assert_privacy(code, [(1, raw)] if 'textarea' in code else [])
        self.assert_privacy('const field = document.createElement("input");\nfield.type = model.kind;\nfield.value = "seed";', [(3, raw)])
        self.assert_privacy('const field = document.createElement("input");\nfield.TYPE = "checkbox";\nfield.value = "seed";', [(3, raw)])
        self.assert_privacy('const field = document.createElement("input");\nfield.setAttribute("TYPE", "checkbox");\nfield.value = "seed";', [])

    def test_privacy_credential_tokens_and_editable_states(self):
        for value, flagged in [('cc-number', True), ('section-a CURRENT-PASSWORD', True),
                               ('one-time-code', True), ('new-password', True),
                               ('CC-anything', True), ('section-a\tcc-number', True),
                               ('section-a\fcc-number', True), ('section-a\vcc-number', False),
                               ('section-a\u00a0cc-number', False), ('xcurrent-password', False),
                               ('credit-card', False), ('off', False)]:
            with self.subTest(value=value):
                source = 'const field = document.createElement("input");\nfield.type = "checkbox";\nfield.autocomplete = %s;\nfield.value = "seed";' % json.dumps(value)
                self.assert_privacy(source, [(4, 'free-text binding')] if flagged else [])
        for value, api in [('true', 'free-text binding'), ('plaintext-only', 'free-text binding'),
                           ('', 'free-text binding'), ('false', None),
                           ('inherit', 'unresolved DOM privacy binding')]:
            with self.subTest(editable=value):
                self.assert_privacy('const field = document.createElement("div");\nfield.contentEditable = %s;\nfield.textContent = "seed";' % json.dumps(value), [(3, api)] if api else [])
        self.assert_privacy('const field = document.createElement("div");\nfield.setAttribute("CONTENTEDITABLE", "TRUE");\nfield.textContent = "seed";', [(3, 'free-text binding')])
        self.assert_privacy('const field = document.createElement("input");\nfield.type = "";\nfield.value = "seed";', [(3, 'unresolved DOM privacy binding')])

    def test_privacy_alias_type_mutation_and_order(self):
        self.assert_privacy('const field = document.createElement("input");\nfield.type = "checkbox";\nconst alias = field;\nalias.type = "text";\nfield.value = "seed";', [(5, 'free-text binding')])
        self.assert_privacy('const field = document.createElement("input");\nconst alias = field;\nalias.type = "checkbox";\nfield.value = "seed";', [])
        self.assert_privacy('const field = document.createElement("input");\nfield.value = "seed";\nfield.type = "checkbox";\nfield.value = "later";', [(2, 'free-text binding')])
        self.assert_privacy('let field = document.createElement("input");\nconst alias = field;\nfield = {};\nfield.value = "model";\nalias.value = "field";', [(5, 'free-text binding')])

    def test_privacy_scope_parameters_hoisting_tdz_and_shadowing(self):
        for code in ['function component(document) { const field = document.createElement("input"); field.value = "seed"; }',
                     'function component() { const field = document.createElement("input"); field.value = "seed"; var document; }',
                     'function component() { const field = document.createElement("input"); field.value = "seed"; let document; }',
                     'function component() { const field = document.createElement("input"); field.value = "seed"; const document = model; }',
                     '(document) => { const field = document.createElement("input"); field.value = "seed"; };',
                     'const field = document.createElement("button"); { const field = document.createElement("button"); field.textContent = "safe"; } field.textContent = "safe";',
                     'function first() { const field = document.createElement("input"); } function second() { const field = model; field.value = "safe"; }']:
            with self.subTest(code=code): self.assert_privacy(code, [])
        self.assert_privacy('const field = document.createElement("input");\n{ const field = document.createElement("button"); field.textContent = "safe"; }\nfield.value = "seed";', [(3, 'free-text binding')])

    def test_privacy_unknown_mutation_does_not_retain_checkbox_exemption(self):
        for middle in ['mutate(field);', 'field.unknownMethod();', 'if (flag) { field.type = "checkbox"; }',
                       'field.setAttribute(attributeName, "checkbox");']:
            with self.subTest(middle=middle):
                self.assert_privacy('const field = document.createElement("input");\nfield.type = "checkbox";\n'+middle+'\nfield.value = "seed";', [(4, 'unresolved DOM privacy binding')])
        self.assert_privacy('const field = document.createElement(tag);\nfield.value = "seed";', [(2, 'unresolved DOM privacy binding')])
        self.assert_privacy('const field = document.createElement("input");\nfield[member] = "seed";', [(2, 'unresolved DOM privacy binding')])

    def test_privacy_binding_patterns_do_not_bind_default_expressions_or_keys(self):
        for code in ['function f(value = document) { const field = document.createElement("input"); field.value = "seed"; }',
                     'const {document: unused} = model; const field = document.createElement("input"); field.value = "seed";',
                     'function f({document: unused}) { const field = document.createElement("input"); field.value = "seed"; }']:
            with self.subTest(code=code): self.assert_privacy(code, [(1, 'free-text binding')])
        for code in ['function f(document = model) { const field = document.createElement("input"); field.value = "seed"; }',
                     'const {document} = model; const field = document.createElement("input"); field.value = "seed";',
                     'function f({key: document}) { const field = document.createElement("input"); field.value = "seed"; }']:
            with self.subTest(code=code): self.assert_privacy(code, [])

    def test_privacy_metadata_requires_whole_literal_rhs(self):
        for statement, api in [('field.type = "checkbox" + suffix;', 'free-text binding'),
                               ('field.type += "checkbox";', 'free-text binding'),
                               ('field.type = flag ? "checkbox" : "text";', 'free-text binding'),
                               ('field.autocomplete = "off" + suffix;', 'unresolved DOM privacy binding')]:
            with self.subTest(statement=statement):
                self.assert_privacy('const field = document.createElement("input");\nfield.type = "checkbox";\n'+statement+'\nfield.value = "seed";', [(4, api)])
        self.assert_privacy('const field = document.createElement("div");\nfield.contentEditable = "false" + suffix;\nfield.textContent = "seed";', [(3, 'unresolved DOM privacy binding')])
        self.assert_privacy('const field = document.createElement("input");\nfield.type = "checkbox";\nfield.autocomplete = "off";\nfield.value = "seed";', [])

    def test_privacy_unrelated_functions_do_not_mutate_other_allocations(self):
        self.assert_privacy('function first() { const field = document.createElement("input"); field.type = "checkbox"; }\nfunction unrelated() { if (flag) unknown(); }\nfunction later() { const field = document.createElement("button"); field.textContent = "safe"; }', [])
        self.assert_privacy('const field = document.createElement("input");\nfield.type = "checkbox";\nfunction later() { field.type = "text"; }\nfield.value = "safe-now";', [])
        self.assert_privacy('const field = document.createElement("input");\nfield.type = "checkbox";\nfunction later() { field.type = "text"; }\nlater();\nfield.value = "unknown-now";', [(5, 'unresolved DOM privacy binding')])

    def test_privacy_deferred_captured_binding_reassignment(self):
        raw, unknown = 'free-text binding', 'unresolved DOM privacy binding'
        prefix = 'const original = document.createElement("input");\nlet field = original;\n'
        self.assert_privacy(prefix + 'function later() { field = {}; }\nfield.value = "seed";\noriginal.value = "seed";', [(4, raw), (5, raw)])
        cases = [
            ('function later() { field = document.createElement("button"); }\nfield.value = "seed";', [(4, raw)]),
            ('function later() { field = document.createElement("button"); }\nlater();\nfield.value = "seed";', [(5, unknown)]),
            ('function outer() { function later() { field = document.createElement("button"); } }\nfield.value = "seed";', [(4, raw)]),
            ('const later = () => { field = document.createElement("button"); };\nfield.value = "seed";', [(4, raw)]),
            ('function later() { let field = document.createElement("button"); field.value = "label"; }\nfield.value = "seed";', [(4, raw)]),
        ]
        for source, expected in cases:
            with self.subTest(source=source): self.assert_privacy(prefix + source, expected)
        self.assert_privacy('let model = {};\nfunction later() { model = {}; }\nmodel.value = "model";', [])
        self.assert_privacy('let button = document.createElement("button");\nfunction later() { button = {}; }\nbutton.textContent = "label";', [])
        self.assert_privacy('let button = document.createElement("button");\nfunction later() { button = document.createElement("input"); }\nbutton.textContent = "label";', [])
        # These are actual ECMAScript lexical bindings, not a mock DOM. The
        # separate source above exercises the production DOM-origin scanner.
        path = Path(self.temp.name) / 'lexical.js'
        path.write_text('''const assert = require('node:assert/strict');
const original = {}; const replacement = {}; let field = original;
function later() { field = replacement; }
function outer() { function nested() { field = replacement; } return nested; }
const nested = outer();
assert.equal(field, original);
later(); assert.equal(field, replacement);
field = original; nested(); assert.equal(field, replacement);
console.log("lexical-binding-controls: passed");
''')
        command = ['node', str(path)]
        self.retain_inputs(command)
        result = subprocess.run(command, capture_output=True, text=True)
        (path.parent/'lexical.log').write_text(result.stdout + result.stderr)
        self.retain_inputs(command)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, 'lexical-binding-controls: passed\n')

    def test_privacy_unknown_reassignment_keeps_uncertain_dom_provenance(self):
        self.assert_privacy('let field = document.createElement("input");\nfield.type = "checkbox";\nconst alias = field;\nfield = unknownValue;\nfield.value = "unknown";\nalias.value = "old";', [(5, 'unresolved DOM privacy binding')])
        for rhs in ['makeReplacement()', 'flag ? {} : replacement']:
            with self.subTest(rhs=rhs):
                self.assert_privacy('let field = document.createElement("input");\nfield.type = "checkbox";\nconst alias = field;\nfield = '+rhs+';\nfield.value = "unknown";\nalias.value = "old";', [(5, 'unresolved DOM privacy binding')] + ([(6, 'unresolved DOM privacy binding')] if '(' in rhs else []))
        self.assert_privacy('let field = document.createElement("input");\nconst alias = field;\nfield = {};\nfield.value = "model";\nalias.value = "field";', [(5, 'free-text binding')])
        self.assert_privacy('let field = document.createElement("input");\nconst alias = field;\nfield = document.createElement("button");\nfield.value = "label";\nalias.value = "field";', [(5, 'free-text binding')])
        self.assert_privacy('let field = document.createElement("input");\nconst replacement = document.createElement("button");\nfield = replacement;\nfield.value = "label";', [])

    def test_privacy_literal_lexical_forms_and_physical_nim_lines(self):
        self.assert_privacy('const field = document.createElement("in\\x70ut");\nfield["v\\u0061lue"] += "seed";', [(2, 'free-text binding')])
        self.assert_privacy('const field = document.createElement("input");\nconst text = `value: ${field.value}`;', [(2, 'free-text binding')])
        self.assert_privacy('const example = "document.createElement(\\"input\\"); field.value = 1";\n// field.value = 1\nconst rx = /field.value/; const template = `field.value`; /* field.value */', [])
        self.write('privacy.js', '')
        self.assert_privacy('# physical line one\n{.emit: "const field = document.createElement(\\\"input\\\");\\nfield.value = 1;".}', [(2, 'free-text binding')], 'privacy.nim')
        self.assert_privacy('{.emit: """\nconst field = document.createElement("input");\nfield.value = 1;\n""".}', [(3, 'free-text binding')], 'privacy.nim')
        self.assert_privacy('{.emit: r"const field = document.createElement(""input""); field.value = 1;".}', [(1, 'free-text binding')], 'privacy.nim')

    def test_privacy_conditional_reassignment_keeps_uncertain_dom_provenance(self):
        prefix = 'let field = document.createElement("input");\nfield.type = "checkbox";\n'
        self.assert_privacy(prefix + 'if (flag) { field = {}; }\nfield.value = "unknown";', [(4, 'unresolved DOM privacy binding')])
        for statement in ['if (flag) field = {};',
                          'if (flag) { field = document.createElement("button"); }',
                          'if (flag) field = document.createElement("button");',
                          'while (flag) { field = {}; }',
                          'while (flag) field = {};',
                          'for (; flag;) { field = {}; }',
                          'for (; flag;) field = {};',
                          'try { field = {}; } catch (error) {}',
                          'if (flag) { if (other) { field = {}; } }']:
            with self.subTest(statement=statement):
                self.assert_privacy(prefix + statement + '\nfield.value = "unknown";', [(4, 'unresolved DOM privacy binding')])
        # Fresh unconditional replacements recover known identity. Unknown
        # model locals never acquire DOM provenance merely from an if keyword.
        for replacement in ['{}', 'document.createElement("button")']:
            self.assert_privacy(prefix + 'if (flag) { field = {}; }\nfield = '+replacement+';\nfield.value = "known";', [])
            self.assert_privacy(prefix + 'field = '+replacement+';\nfield.value = "known";', [])
        self.assert_privacy('let model = {};\nif (flag) model = {};\nmodel.value = "model";', [])
        self.assert_privacy('if (flag) { let field = document.createElement("button"); field.value = "label"; }', [])

    def test_privacy_literal_contents_never_become_syntax(self):
        for prose in ['}', '{', 'if', 'const', 'function']:
            with self.subTest(prose=prose):
                self.assert_privacy('function f() { const field = document.createElement("input"); const prose = %s; field.value = "seed"; }' % json.dumps(prose), [(1, 'free-text binding')])
                self.assert_privacy('function f() { const field = document.createElement("input"); field.type = "checkbox"; const prose = %s; field.value = "safe"; }' % json.dumps(prose), [])

    def test_privacy_splices_are_metadata_not_identifier_spelling(self):
        self.assert_privacy('const __nim = document.createElement("input");\n__nim.value = "seed";', [(2, 'free-text binding')])
        self.write('privacy.js', '')
        # Neither Nim receiver identity is established by foreign syntax. This
        # is explicitly unanalysed, not a certification that raw Nim is safe.
        self.assert_privacy('{.emit: [left, " = document.createElement(\\"input\\"); ", right, ".value = 1;"].}', [], 'privacy.nim')
        self.assert_privacy('{.emit: ["const __nim = document.createElement(\\"input\\"); __nim.value = ", value[0], ";"].}', [(1, 'free-text binding')], 'privacy.nim')

    def test_privacy_allowlist_cannot_hide_findings(self):
        self.write('privacy.js', 'Date.now();\nconst field = document.createElement("input");\nfield.value = "seed";')
        allow = Path(self.temp.name) / 'allow.json'
        allow.write_text(json.dumps([dict(path='site/src/privacy.js', api='Date.now', count=1, reason='clock control')]))
        result = self.cli('--allowlist', allow)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout), [dict(path='site/src/privacy.js', line=3, api='free-text binding', severity='error')])
        for api in ['free-text binding', 'unresolved DOM privacy binding']:
            allow.write_text(json.dumps([dict(path='site/src/privacy.js', api=api, count=1, reason='not authorized')]))
            result = self.cli('--allowlist', allow)
            self.assertEqual(result.returncode, 2)
            self.assertIn('privacy findings cannot be allowed', result.stderr)

    def test_privacy_trusted_backend_exclusion_is_platform_only(self):
        # A real isolated checkout-shaped scanner path, not a site-name trick.
        repo = Path(self.temp.name) / 'framework'
        tools = repo / 'tools'; tools.mkdir(parents=True)
        for name in ['lint_nondet.py', 'lint_privacy.py']:
            shutil.copyfile(SCRIPT.with_name(name), tools / name)
        root = repo / 'src'; path = root / 'isonim/core/nondet.nim'; path.parent.mkdir(parents=True)
        path.write_text('{.emit: """Date.now();\nconst field = document.createElement("input");\nfield.value = "seed";""".}')
        command = [sys.executable, str(tools/'lint_nondet.py'), '--json', str(root)]
        self.retain_inputs(command)
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout), [dict(path='framework/src/isonim/core/nondet.nim', line=3, api='free-text binding', severity='error')])

    def test_privacy_real_component_exact_finding_removal_and_dsl_counterpart(self):
        path = self.write('privacy_component.nim', '''import isonim/web/dom_api
proc rawComponent*(initial: cstring): Element {.importjs: """(function(v) {
  const field = document.createElement("input");
  field.value = v;
  return field;
})(#)""".}
discard rawComponent(cstring"seed")
''')
        def compile_component():
            command = ['nim', 'js', '--hints:off', '--path:' + str(PROJECT/'src'),
                       '--path:' + str(PROJECT.parent/'nim-everywhere/src'),
                       '--nimcache:' + str(Path(self.temp.name)/'cache'),
                       '--out:' + str(Path(self.temp.name)/'component.js'), str(path)]
            self.retain_inputs(command)
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        compile_component()
        result = self.cli()
        self.assertEqual(json.loads(result.stdout), [dict(path='site/src/privacy_component.nim', line=4, api='free-text binding', severity='error')])
        self.assertEqual(result.returncode, 1, result.stderr)
        path.unlink()
        result = self.cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])
        path.write_text('''import isonim/web/web_renderer
import isonim/web/dom_api
import isonim/rxcore
import isonim/dsl/ui
proc publicComponent*(r: WebRenderer): Element =
  ui(r):
    input(`type` = "text", public = true, value = "seed")
discard publicComponent(WebRenderer())
''')
        compile_component()
        result = self.cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])

    def test_privacy_git_inventory_tracks_actual_sources(self):
        repo = self.root.parent
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        (repo / '.gitignore').write_text('src/generated/\n')
        code = 'const field = document.createElement("input");\nfield.value = "seed";'
        self.write('generated/out.js', code)
        tracked = self.write('tracked.js', code)
        subprocess.run(['git', '-C', str(repo), 'add', str(tracked)], check=True)
        self.write('new.js', code)
        self.write('vendor/dependency.js', code)
        subprocess.run(['git', '-C', str(repo), 'update-index', '--add', '--cacheinfo',
                        '160000,1111111111111111111111111111111111111111,src/vendor'], check=True)
        result = self.cli()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout), [dict(path='site/src/'+name, line=2, api='free-text binding', severity='error') for name in ['new.js', 'tracked.js']])

    def test_privacy_nonfield_only_control(self):
        self.assert_privacy('const button = document.createElement("button"); button.textContent = "Go";\nconst text = document.createTextNode(""); text.textContent = model.value;\nconst field = document.createElement("input"); field.type = "checkbox"; field.value = "on";', [])

    def test_privacy_metadata_write_operator_family(self):
        # This independent fixture table intentionally does not import the
        # production operator set: omissions in that set must stay observable.
        assignments = ['=', '+=', '-=', '*=', '/=', '%=', '**=', '<<=',
                       '>>=', '>>>=', '&=', '^=', '|=', '&&=', '||=', '??=']
        updates = ['prefix++', 'prefix--', 'postfix++', 'postfix--']
        for metadata, tag, initial, api in [
                ('type', 'input', 'checkbox', 'free-text binding'),
                ('autocomplete', 'input', 'off', 'unresolved DOM privacy binding'),
                ('contentEditable', 'div', 'false', 'unresolved DOM privacy binding')]:
            for form in ['direct', 'bracket', 'alias']:
                for operator in assignments + updates:
                    with self.subTest(metadata=metadata, form=form, operator=operator):
                        receiver = 'alias' if form == 'alias' else 'field'
                        member = receiver + ('[' + json.dumps(metadata) + ']' if form == 'bracket' else '.' + metadata)
                        if operator.startswith('prefix'):
                            mutation = operator[6:] + member
                        elif operator.startswith('postfix'):
                            mutation = member + operator[7:]
                        else:
                            mutation = member + ' ' + operator + ' model.kind'
                        setup = ('const field = document.createElement(' + json.dumps(tag) + ');\n'
                                 + ('field.type = "checkbox"; ' if metadata == 'autocomplete' else '')
                                 + 'field.' + metadata + ' = ' + json.dumps(initial) + ';\n'
                                 + 'const alias = field;\n')
                        self.assert_privacy(setup + mutation + ';\nfield.value = "seed";', [(5, api)])
        for operator in assignments + updates:
            with self.subTest(nonfield=operator):
                member = 'model.type'
                mutation = (operator[6:] + member if operator.startswith('prefix') else
                            member + operator[7:] if operator.startswith('postfix') else
                            member + ' ' + operator + ' other.kind')
                self.assert_privacy('const model = {};\n' + mutation + ';\nmodel.value = "seed";', [])
        # Raw accesses are findings independently of their read/write operator.
        for operator in assignments + updates:
            member = 'field.textContent'
            mutation = (operator[6:] + member if operator.startswith('prefix') else
                        member + operator[7:] if operator.startswith('postfix') else
                        member + ' ' + operator + ' model.kind')
            with self.subTest(raw_access=operator):
                self.assert_privacy('const field = document.createElement("textarea");\n' + mutation + ';', [(2, 'free-text binding')])

    def test_privacy_metadata_multiply_loses_checkbox_certification(self):
        self.assert_privacy('const field = document.createElement("input");\nfield.type = "checkbox";\nfield.type *= 2;\nfield.value = "seed";', [(4, 'free-text binding')])

    def test_privacy_metadata_readonly_operators_preserve_checkbox(self):
        for operator in ['==', '===', '!=', '!==', '<', '<=', '>', '>=', '<<', '>>', '>>>', '**', '&&', '||', '??']:
            with self.subTest(operator=operator):
                self.assert_privacy('const field = document.createElement("input");\nfield.type = "checkbox";\nconst result = field.type ' + operator + ' "checkbox";\nfield.value = "on";', [])

    def receiver_case(self, source, expected):
        # The actual Node parser validates authored fixtures, without a mock DOM
        # or a claim that --check executes browser semantics.
        path = self.write('privacy.js', source)
        command = ['node', '--check', str(path)]
        self.retain_inputs(command)
        result = subprocess.run(command, capture_output=True, text=True)
        (path.parent/'receiver-syntax.log').write_text(result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_privacy(source, expected)

    def test_privacy_receiver_logical_replacement_exact_finding(self):
        self.receiver_case('const replacement=document.createElement("input");\nlet field=document.createElement("input");\nfield.type="checkbox";\nfield &&= replacement;\nfield.value="privacy-test";', [(5, 'unresolved DOM privacy binding')])

    def test_privacy_receiver_complete_write_family_and_models(self):
        # Independent authored operator inventory; do not import production sets.
        assignments = ['+=', '-=', '*=', '/=', '%=', '**=', '<<=', '>>=', '>>>=', '&=', '^=', '|=', '&&=', '||=', '??=']
        for operator in assignments:
            with self.subTest(operator=operator):
                self.receiver_case('const replacement=document.createElement("input");\nlet field=document.createElement("input");\nfield.type="checkbox";\nfield '+operator+' replacement;\nfield.value="seed";', [(5, 'unresolved DOM privacy binding')])
                self.receiver_case('const replacement={};\nlet field={};\nfield '+operator+' replacement;\nfield.value="model";', [])
                self.receiver_case('const replacement=document.createElement("input");\nlet field={};\nfield '+operator+' replacement;\nfield.value="seed";', [(4, 'unresolved DOM privacy binding')])
        for expression in ['++field', '--field', 'field++', 'field--']:
            with self.subTest(update=expression):
                self.receiver_case('let field=document.createElement("input");\nfield.type="checkbox";\n'+expression+';\nfield.value="seed";', [(4, 'unresolved DOM privacy binding')])
                self.receiver_case('let field={};\n'+expression+';\nfield.value="model";', [])

    def test_privacy_receiver_possible_alias_mutations_keep_identities(self):
        unresolved = 'unresolved DOM privacy binding'
        prefix = 'const replacement=document.createElement("input");\nreplacement.type="checkbox";\nlet field=document.createElement("input");\nfield.type="checkbox";\nconst old=field;\n'
        for operator in ['&&=', '||=', '??=']:
            for rhs in ['field', 'replacement']:
                with self.subTest(operator=operator, rhs=rhs):
                    # Merely rebinding does not change either old allocation.
                    self.receiver_case(prefix+'field '+operator+' '+rhs+';\nold.value="safe";\nreplacement.value="safe";', [])
                    expected = [(8, unresolved)] + ([(9, unresolved)] if rhs == 'replacement' else [])
                    self.receiver_case(prefix+'field '+operator+' '+rhs+';\nfield.type="text";\nold.value="seed";\nreplacement.value="seed";', expected)
        # A separate RHS mutation cannot reach the unrelated old allocation.
        self.receiver_case(prefix+'field &&= replacement;\nreplacement.type="text";\nold.value="safe";\nreplacement.value="seed";', [(9, 'free-text binding')])
        # Plain replacement is exact, while its former alias retains its object.
        self.receiver_case(prefix+'field = replacement;\nfield.type="text";\nold.value="safe";\nreplacement.value="seed";', [(9, 'free-text binding')])

    def test_privacy_receiver_possible_alias_method_mutations(self):
        prefix = 'const replacement=document.createElement("input");\nreplacement.type="checkbox";\nlet field=document.createElement("input");\nfield.type="checkbox";\nconst old=field;\n'
        for method in ["field.setAttribute('type','text')", "field.removeAttribute('type')", 'field.unknownMutation()']:
            for rhs in ['field', 'replacement']:
                with self.subTest(method=method, rhs=rhs):
                    expected = [(8, 'unresolved DOM privacy binding')] + ([(9, 'unresolved DOM privacy binding')] if rhs == 'replacement' or method == 'field.unknownMutation()' else [])
                    self.receiver_case(prefix+'field &&= '+rhs+';\n'+method+';\nold.value="seed";\nreplacement.value="seed";', expected)
                    self.receiver_case('let field={};\nfield &&= {};\n'+method+';\nfield.value="model";', [])

    def test_privacy_receiver_deferred_and_conditional_views(self):
        unresolved = 'unresolved DOM privacy binding'
        prefix = 'const replacement=document.createElement("input");\nreplacement.type="checkbox";\nlet field=document.createElement("input");\nfield.type="checkbox";\nconst old=field;\n'
        for rhs in ['field', 'replacement']:
            body = 'function later() {\nfield &&= '+rhs+';\nfield.type="text";\nold.value="seed";\nreplacement.value="seed";\n}\n'
            # Scanning a deferred definition must not alter present outer state.
            inside = [(9, unresolved), (10, unresolved)]
            self.receiver_case(prefix+body+'old.value="present-safe";\nreplacement.value="present-safe";', inside)
            # Calling an opaque local helper loses outer metadata certainty.
            self.receiver_case(prefix+body+'later();\nold.value="after-call";\nreplacement.value="after-call";', inside+[(13, unresolved), (14, unresolved)])
        for statement in ['if (flag) field &&= replacement;', 'if (flag) { field ||= replacement; }', 'while (flag) field ??= replacement;']:
            self.receiver_case(prefix+statement+'\nfield.type="text";\nold.value="seed";\nreplacement.value="seed";', [(8, unresolved), (9, unresolved)])
        self.receiver_case(prefix+'{ let field={}; field &&= {}; field.value="model"; }\nold.value="safe";\nreplacement.value="safe";', [])

    def test_privacy_receiver_readonly_and_plain_nonfield_controls(self):
        for operator in ['==', '===', '!=', '!==', '<', '<=', '>', '>=', '<<', '>>', '>>>', '**', '&&', '||', '??']:
            with self.subTest(readonly=operator):
                self.receiver_case('let field=document.createElement("input");\nfield.type="checkbox";\nconst result=field '+operator+' other;\nfield.value="safe";', [])
        for rhs in ['{}', 'document.createElement("button")', 'document.createTextNode("label")']:
            self.receiver_case('let field=document.createElement("input");\nfield = '+rhs+';\nfield.value="safe";', [])

    def plain_alias_prefix(self):
        return ('const old=document.createElement("input");\nold.type="checkbox";\n'
                'const replacement=document.createElement("input");\nreplacement.type="checkbox";\n'
                'let field=old;\n')

    def test_privacy_plain_uncertain_alias_exact_finding(self):
        self.receiver_case(self.plain_alias_prefix()+'field=flag?old:old;\nfield.type="text";\nold.value="seed";', [(8, 'unresolved DOM privacy binding')])

    def test_privacy_plain_conditional_and_local_alias_metadata(self):
        for rhs in ['flag?old:replacement', 'choice']:
            setup = self.plain_alias_prefix()
            if rhs == 'choice': setup += 'const choice=flag?old:replacement;\n'
            line = 9 if rhs == 'choice' else 8
            for mutation in ['field.type="text"', 'field["type"]="text"', 'field.autocomplete="current-password"', 'field.contentEditable="true"', 'field.setAttribute("type","text")', 'field.removeAttribute("type")', 'field.unknownMutation()', 'delete field.type', 'field[unknown]="text"']:
                with self.subTest(rhs=rhs, mutation=mutation):
                    expected = ([(line-1, 'unresolved DOM privacy binding')] if mutation == 'field[unknown]="text"' else [])
                    expected += [(line, 'unresolved DOM privacy binding'), (line+1, 'unresolved DOM privacy binding')]
                    self.receiver_case(setup+'field='+rhs+';\n'+mutation+';\nold.value="seed";\nreplacement.value="seed";', expected)

    def test_privacy_plain_rebinding_preserves_distinct_aliases(self):
        prefix = self.plain_alias_prefix()
        self.receiver_case(prefix+'field=flag?old:replacement;\nold.value="safe";\nreplacement.value="safe";', [])
        self.receiver_case(prefix+'field=flag?old:old;\nfield.type="text";\nold.value="seed";\nreplacement.value="safe";', [(8, 'unresolved DOM privacy binding')])
        self.receiver_case(prefix+'field=flag?old:replacement;\nreplacement.type="text";\nold.value="safe";\nreplacement.value="seed";', [(9, 'free-text binding')])
        self.receiver_case(prefix+'field=replacement;\nfield.type="text";\nold.value="safe";\nreplacement.value="seed";', [(9, 'free-text binding')])
        for rhs in ['{}', 'document.createElement("button")', 'document.createTextNode("label")']:
            self.receiver_case(prefix+'field='+rhs+';\nfield.value="safe";\nold.value="safe";\nreplacement.value="safe";', [])
        self.receiver_case(prefix+'field=flag?old:replacement;\nfield=document.createElement("button");\nfield.value="safe";\nold.value="safe";\nreplacement.value="safe";', [])
        self.receiver_case('const model={};\nconst other={};\nlet field=flag?model:other;\nfield.type="text";\nfield.value="safe";\nmodel.value="safe";\nother.value="safe";', [])

    def test_privacy_plain_alias_deferred_views(self):
        prefix = self.plain_alias_prefix()
        body = ('function later(){\nfield=flag?old:replacement;\nfield.type="text";\n'
                'old.value="seed";\nreplacement.value="seed";\n}\n')
        inside = [(9, 'unresolved DOM privacy binding'), (10, 'unresolved DOM privacy binding')]
        self.receiver_case(prefix+body+'old.value="safe";\nreplacement.value="safe";', inside)
        self.receiver_case(prefix+body+'later();\nold.value="seed";\nreplacement.value="seed";', inside+[(13, 'unresolved DOM privacy binding'), (14, 'unresolved DOM privacy binding')])

    def test_privacy_plain_alias_depth_and_shared_graph(self):
        # Bounded source-only CLI reliability control, no timing assertion.
        source = 'const old=document.createElement("input");\nold.type="checkbox";\nlet field=old;\n'
        for index in range(180):
            source += 'field=flag?field:old;\n'
        source += 'function later(){field.type="text";}\nold.value="safe";\nfield.type="text";\nold.value="seed";'
        self.receiver_case(source, [(187, 'unresolved DOM privacy binding')])

    def test_privacy_plain_alias_does_not_infer_property_or_closure_returns(self):
        prefix = 'const old=document.createElement("input");\nold.type="checkbox";\n'
        for expression in ['old.children', 'old["children"]', 'flag?old.children:old.dataset', '{old}', '[old]', '()=>old', 'function(){return old;}', 'old===other', 'old?{}:{}', 'old?model:other', 'pick(old)', 'flag?old:old']:
            with self.subTest(expression=expression):
                # An unknown call still invalidates its passed DOM argument;
                # that is distinct from inventing DOM identity for its result.
                expected = [(5, 'unresolved DOM privacy binding')] if expression == 'pick(old)' else []
                self.receiver_case(prefix+'const model='+expression+';\nmodel.value="safe";\nold.value="safe";', expected)

    def test_privacy_plain_partial_choice_retains_unknown_result_arms(self):
        unresolved = 'unresolved DOM privacy binding'
        prefix = ('const old=document.createElement("input");\nold.type="checkbox";\n'
                  'const replacement=document.createElement("input");\nreplacement.type="checkbox";\n'
                  'const choice=flag?old:replacement;\nlet field=old;\n')
        for rhs in ['choice', 'flag?old:choice', 'flag?choice:old',
                    'flag?(again?old:choice):old', 'flag?old:(again?choice:old)',
                    'flag?(again?old:replacement):choice', 'flag?old:replacement']:
            with self.subTest(rhs=rhs):
                self.receiver_case(prefix+'field='+rhs+';\nfield.type="text";\nold.value="seed";\nreplacement.value="seed";', [(9, unresolved), (10, unresolved)])
                # Rebinding alone does not change either possible object.
                self.receiver_case(prefix+'field='+rhs+';\nold.value="safe";\nreplacement.value="safe";', [])
                self.receiver_case(prefix+'field='+rhs+';\nfield=document.createElement("button");\nfield.value="safe";\nold.value="safe";\nreplacement.value="safe";', [])
        body = 'function later(){\nfield=flag?old:choice;\nfield.type="text";\nold.value="seed";\nreplacement.value="seed";\n}\n'
        self.receiver_case(prefix+body+'old.value="safe";\nreplacement.value="safe";', [(10, unresolved), (11, unresolved)])
        self.receiver_case(prefix+body+'later();\nold.value="seed";\nreplacement.value="seed";', [(10, unresolved), (11, unresolved), (14, unresolved), (15, unresolved)])
        self.receiver_case('const old={};\nconst replacement={};\nconst choice=flag?old:replacement;\nlet field=old;\nfield=flag?old:choice;\nfield.type="text";\nfield.value="model";\nold.value="model";\nreplacement.value="model";', [])

    def test_privacy_nonplain_rhs_exact_finding(self):
        self.receiver_case('const old=document.createElement("input");\nold.type="checkbox";\nconst replacement=document.createElement("input");\nreplacement.type="checkbox";\nlet field=old;\nfield&&=flag?old:replacement;\nfield.type="text";\nold.value="x";\nreplacement.value="y";', [(8, 'unresolved DOM privacy binding'), (9, 'unresolved DOM privacy binding')])

    def test_privacy_receiver_rhs_shapes_compose_with_write_operators(self):
        unresolved = 'unresolved DOM privacy binding'
        prefix = ('const old=document.createElement("input");\nold.type="checkbox";\n'
                  'const replacement=document.createElement("input");\nreplacement.type="checkbox";\n'
                  'const choice=flag?old:replacement;\nlet field=old;\n')
        # Independent semantic cases: retain-old logical writes, coercing writes,
        # and complete/partial/nested/parenthesized result identities. These are
        # authored fixture expectations, not the production operator inventory.
        cases = [('&&=', 'flag?old:replacement'), ('||=', 'flag?old:choice'),
                 ('??=', '(flag?(again?old:choice):replacement)'),
                 ('+=', '(flag?replacement:old)'), ('*=', 'flag?old:replacement'),
                 ('<<=', 'flag?choice:old'), ('&=', '(flag?old:(again?choice:replacement))'),
                 ('**=', 'choice'), ('=', 'flag?old:choice')]
        for operator, rhs in cases:
            for mutation in ['field.type="text"', 'field["type"]="text"',
                             'field.setAttribute("type","text")', 'field.removeAttribute("type")',
                             'field.unknownMutation()', 'delete field.type', 'field[unknown]="text"']:
                with self.subTest(operator=operator, rhs=rhs, mutation=mutation):
                    expected = ([(8, unresolved)] if mutation == 'field[unknown]="text"' else [])
                    self.receiver_case(prefix+'field'+operator+rhs+';\n'+mutation+';\nold.value="x";\nreplacement.value="y";', expected+[(9, unresolved), (10, unresolved)])
            self.receiver_case(prefix+'field'+operator+rhs+';\nold.value="safe";\nreplacement.value="safe";', [])
            self.receiver_case(prefix+'field'+operator+rhs+';\nfield=document.createElement("button");\nfield.value="safe";\nold.value="safe";\nreplacement.value="safe";', [])
        body = 'function later(){\nfield&&=flag?old:choice;\nfield.type="text";\nold.value="x";\nreplacement.value="y";\n}\n'
        self.receiver_case(prefix+body+'old.value="safe";\nreplacement.value="safe";', [(10, unresolved), (11, unresolved)])
        self.receiver_case(prefix+body+'later();\nold.value="x";\nreplacement.value="y";', [(10, unresolved), (11, unresolved), (14, unresolved), (15, unresolved)])
        self.receiver_case('const old={};\nconst replacement={};\nlet field=old;\nfield&&=flag?old:replacement;\nfield.type="text";\nold.value="model";\nreplacement.value="model";', [])


    def syntax_privacy(self, source, expected):
        # Node validates authored JavaScript syntax only. The actual production
        # CLI supplies the complete diagnostic list, file, physical line and exit.
        path = self.write('privacy.js', source)
        command = [shutil.which('node'), '--check', str(path)]
        self.assertIsNotNone(command[0], 'Node is required; no syntax-check skip')
        self.retain_inputs(command)
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_privacy(source, expected)

    def test_privacy_asi_allocation_exact_finding(self):
        self.assert_privacy('const field=document.createElement("input")\nfield.value="privacy-test"\n', [(2, 'free-text binding')])

    def test_privacy_asi_allocation_alias_and_replacement_pairs(self):
        raw = 'free-text binding'
        unresolved = 'unresolved DOM privacy binding'
        cases = [
            ('const field=document.createElement("input")\nfield.value="seed"\n', [(2, raw)]),
            ('const field=document.createElement("textarea")\nconst alias=field\nalias.value="seed"\n', [(3, raw)]),
            ('const field=document.createElement("input")\nconst alias=field\nalias.type="checkbox"\nfield.value="control"\n', []),
            ('let field=document.createElement("button")\nfield=document.createElement("textarea")\nfield.value="seed"\n', [(3, raw)]),
            ('const old=document.createElement("input")\nold.type="checkbox"\nlet field=old\nfield=old\nfield.type="text"\nold.value="seed"\n', [(6, raw)]),
            ('const old=document.createElement("input")\nold.type="checkbox"\nconst replacement=document.createElement("input")\nreplacement.type="checkbox"\nlet field=old\nfield&&=flag?old:replacement\nfield.type="text"\nold.value="x"\nreplacement.value="y"\n', [(8, unresolved), (9, unresolved)]),
            ('const model={}\nlet field=model\nfield.value="model"\n', []),
        ]
        for source, expected in cases:
            for delimiter in ['', ';']:
                code = ''.join(line+delimiter+'\n' for line in source.splitlines())
                with self.subTest(code=code): self.syntax_privacy(code, expected)

    def test_privacy_asi_metadata_and_expression_continuations(self):
        raw = 'free-text binding'
        # A newline after an operator/assignment is not ASI. Nor is a newline
        # before a binary, conditional, call, property or bracket continuation.
        for rhs in ['"checkbox"\n+suffix', '"checkbox"+\nsuffix',
                    '"checkbox"\n?"checkbox":"text"', '"checkbox"\n||model.kind',
                    '"checkbox"\nin model', '"checkbox"\ninstanceof Constructor',
                    '"checkbox"\n.toString()', '"checkbox"\n[0]',
                    '"checkbox"\n(model)', '"checkbox"\n`tagged prose`']:
            source = 'const field=document.createElement("input");\nfield.type='+rhs+';\nfield.value="seed";\n'
            # Calling an unknown method retains the existing conservative
            # allocation invalidation; other dynamic RHS forms are definite text.
            expected_api = 'unresolved DOM privacy binding' if rhs == '"checkbox"\n.toString()' else raw
            with self.subTest(rhs=rhs): self.syntax_privacy(source, [(4, expected_api)])
        self.syntax_privacy('const field=document.createElement("input")\nfield.type=\n"checkbox"\nfield.value="control"\n', [])
        self.syntax_privacy('const field=document.createElement(\n"input"\n)\nfield.value="seed"\n', [(4, raw)])
        # Property/call-derived results and booleans are ordinary models, not
        # direct DOM origins. The source line break must not promote them.
        for tail in ['.style', '["style"]', '(model)', '`prose ${model.value}`',
                     'in model', 'instanceof Constructor', '+model',
                     '?model:other', '&&model']:
            source = 'const field=document.createElement("input")\n'+tail+';\nfield.value="model";\n'
            with self.subTest(tail=tail): self.syntax_privacy(source, [])
        for tail in ['.style', '["style"]', '(model)', '`prose`', 'in model',
                     'instanceof Constructor', '+model', '?model:other', '&&model']:
            source = 'const original=document.createElement("input");\nconst field=original\n'+tail+';\nfield.value="model";\n'
            with self.subTest(alias_tail=tail): self.syntax_privacy(source, [])
        self.syntax_privacy('const field=document.createElement("input");\nfield.type="checkbox";\nfield.type\n==model.kind;\nfield.value="control";\n', [])

    def test_privacy_asi_comments_and_real_line_terminators(self):
        raw = 'free-text binding'
        for gap, line in [('\n', 2), ('\r\n', 2), ('\r', 2), ('\u2028', 2), ('\u2029', 2),
                          (' /* ` { const document = fake; */\n', 2),
                          (' /* ` } fake\nprose */ ', 2),
                          (' // ` { fake declaration\n', 2)]:
            source = 'const field=document.createElement("input")'+gap+'field.value="seed"\n'
            with self.subTest(gap=gap): self.syntax_privacy(source, [(line, raw)])
        # A tagged template is continuation syntax even through a comment;
        # its prose cannot act as declarations and interpolation code is visited.
        self.syntax_privacy('const model=document.createElement("input") /* comment */\n`const field=document.createElement("input"); field.value="prose"`;\nmodel.value="model";\n', [])
        self.syntax_privacy('const prose=`ignored ${(()=>{\nconst field=document.createElement("input")\nfield.value="seed"\n})()}`;\n', [(3, raw)])
        (self.root/'privacy.js').unlink()
        # Actual JS newlines decoded from a one-line Nim literal are ASI, while
        # findings retain the physical authored Nim line, never decoded line 2.
        self.assert_privacy('{.emit: "const field=document.createElement(\\\"input\\\")\\nfield.value=\\\"seed\\\"\\n".}\n', [(1, raw)], 'privacy.nim')
        (self.root/'privacy.nim').unlink()
        self.assert_privacy('{.emit: """const field=document.createElement("input")\nfield.value="seed"\n""".}\n', [(2, raw)], 'privacy.nim')

    def test_privacy_asi_control_recovery_and_deferred_views(self):
        unresolved = 'unresolved DOM privacy binding'
        for control in ['if(flag)', 'while(flag)', 'for(;flag;)']:
            for delimiter in ['', ';']:
                code = ('let field=document.createElement("input");\nfield.type="checkbox";\n'
                        +control+' field=document.createElement("textarea")'+delimiter+'\n'
                        'field=document.createElement("button")'+delimiter+'\nfield.value="control"'+delimiter+'\n')
                with self.subTest(control=control, delimiter=delimiter): self.syntax_privacy(code, [])
        self.syntax_privacy('let field=document.createElement("input")\nfield.type="checkbox"\nif(flag) field=document.createElement("button")\nfield.value="seed"\n', [(4, unresolved)])
        self.syntax_privacy('const old=document.createElement("input")\nold.type="checkbox"\nlet field=old\nfunction later(){\nfield=old\nfield.type="text"\nold.value="seed"\n}\nold.value="control"\n', [(7, unresolved)])
        self.syntax_privacy('const old=document.createElement("input")\nold.type="checkbox"\nlet field=old\nfunction later(){\nfield=old\nfield.type="text"\nold.value="seed"\n}\nlater()\nold.value="seed"\n', [(7, unresolved), (10, unresolved)])

    def test_privacy_asi_restricted_postfix_updates(self):
        raw = 'free-text binding'
        # ++/-- after a line break belong to the next expression. They cannot
        # turn a read-only metadata access into a write to the DOM allocation.
        for operator in ['++', '--']:
            self.syntax_privacy('const field=document.createElement("input");\nfield.type="checkbox";\nlet counter=0;\nfield.type\n'+operator+'counter;\nfield.value="control";\n', [])
            self.syntax_privacy('const field=document.createElement("input");\nfield.type="checkbox";\nfield.type'+operator+';\nfield.value="seed";\n', [(4, raw)])
            self.syntax_privacy('const field=document.createElement("input");\nfield.type="checkbox";\n'+operator+'\nfield.type;\nfield.value="seed";\n', [(5, raw)])
            self.syntax_privacy('const old=document.createElement("input");\nold.type="checkbox";\nlet field=old;\nlet counter=0;\nfield\n'+operator+'counter;\nfield.type="text";\nold.value="seed";\n', [(8, raw)])


    def test_privacy_loop_header_exact_post_loop_finding(self):
        self.syntax_privacy("for(const document of []){}; const field=document.createElement('input');field.value='privacy-test'", [(1, 'free-text binding')])

    def test_privacy_loop_header_lexical_extent_matrix(self):
        raw = 'free-text binding'
        for declaration in ['let', 'const']:
            for header in [declaration+' document of []', declaration+' document in {}',
                           declaration+' document=null;false;']:
                for body in ['{}', 'model.value="model";',
                             'for(let inner of []) {model.value="model";}',
                             'if(flag) model.value="model"; else model.value="model";']:
                    with self.subTest(header=header, body=body):
                        self.syntax_privacy('for('+header+') '+body+'\nconst field=document.createElement("input");\nfield.value="seed";', [(3, raw)])
                self.syntax_privacy('label: for('+header+') {const field=document.createElement("input");field.value="model";}\nconst field=document.createElement("input");field.value="seed";', [(2, raw)])
        # Async iteration has the same lexical name ownership; this is syntax
        # qualification, not an assertion that the iterable is executed.
        self.syntax_privacy('async function f(){for await(const document of []){}; const field=document.createElement("input");field.value="seed";}', [(1, raw)])

    def test_privacy_loop_header_model_var_and_tdz_controls(self):
        for declaration in ['let', 'const', 'var']:
            for header in [declaration+' document of []', declaration+' document in {}',
                           declaration+' document=null;false;']:
                self.syntax_privacy('function f(model){for('+header+'){const field=document.createElement("input");field.value="model";}}', [])
        for code in [
            'function f(model){const field=document.createElement("input");field.value="model"; for(var document of []){}}',
            'function f(model){for(var document of []){}; const field=document.createElement("input");field.value="model";}',
            'for(let document=document.createElement("input");false;){document.value="model";}',
            'const field=document.createElement("input");field.type="checkbox"; for(const field of []){field.value="model";}',
            'const field=document.createElement("button");for(let field of []){field.value="model";}',
            'for(const field of []){}; const model={};model.value="model";',
        ]:
            with self.subTest(code=code): self.syntax_privacy(code, [])

    def test_privacy_loop_header_alias_control_and_deferred_composition(self):
        raw, unresolved = 'free-text binding', 'unresolved DOM privacy binding'
        for header in ['let field of []', 'const field in {}', 'let field=null;false;']:
            self.syntax_privacy('for('+header+'){field.value="model";}\nconst field=document.createElement("input");field.value="seed";', [(2, raw)])
        self.syntax_privacy('let field=document.createElement("input");field.type="checkbox";\nfor(let item of []) field=document.createElement("button");\nfield.value="seed";', [(3, unresolved)])
        self.syntax_privacy('let field=document.createElement("input");field.type="checkbox";\nfor(let item of []) field=document.createElement("textarea");\nfield=document.createElement("button");field.value="control";', [])
        self.syntax_privacy('for(let item of []){const field=document.createElement("input");field.value="seed";}', [(1, raw)])
        self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";\nfunction later(){for(let item of []){field.type="text";field.value="seed";}}\nfield.value="control";', [(2, unresolved)])
        self.syntax_privacy('function later(){for(let document of []){};const field=document.createElement("input");field.value="seed";}', [(1, raw)])
        self.syntax_privacy('const original=document.createElement("input");original.type="checkbox";\nfor(let alias of []){alias=model;}\nconst alias=original;alias.type="text";original.value="seed";', [(3, unresolved)])

    def test_privacy_catch_var_hoists_to_real_function(self):
        self.syntax_privacy('function f(model){try{throw 0}catch(e){var document=model} const field=document.createElement("input");field.value="model";}', [])

    def test_privacy_catch_binding_and_control_composition(self):
        raw, unresolved = 'free-text binding', 'unresolved DOM privacy binding'
        self.syntax_privacy('try{throw 0}catch(document){const field=document.createElement("input");field.value="model";}\nconst field=document.createElement("input");field.value="seed";', [(2, raw)])
        self.syntax_privacy('function f(model){try{throw 0}catch(e){if(flag){var document=model}} const field=document.createElement("input");field.value="model";}', [])
        self.syntax_privacy('try{throw 0}catch(e){let document=model;const field=document.createElement("input");field.value="model";}\nconst field=document.createElement("input");field.value="seed";', [(2, raw)])
        self.syntax_privacy('try{throw 0}catch(e){const field=document.createElement("input");field.value="seed";}', [(1, raw)])
        self.syntax_privacy('let field=document.createElement("input");field.type="checkbox";\ntry{throw 0}catch(e){field=document.createElement("button");}\nfield.value="seed";', [(3, unresolved)])

    def test_privacy_opaque_template_keeps_tag_continuation(self):
        self.assert_privacy('{.emit: ["""const field=document.createElement("input")\n`prose ${""", splice, """}`;\nfield.value="model";\n"""].}\n', [], 'privacy.nim')

    def test_privacy_opaque_template_interpolation_stays_executable(self):
        self.assert_privacy('{.emit: ["""const prose=`example ${""", splice, """ + (()=>{const field=document.createElement("input");field.value="seed";})()}`;"""].}\n', [(1, 'free-text binding')], 'privacy.nim')
        self.assert_privacy('{.emit: ["""const field=document.createElement("input");field.type="checkbox"; const prose=`${""", splice, """}`;field.value="seed";"""].}\n', [(1, 'unresolved DOM privacy binding')], 'privacy.nim')

    def test_privacy_loop_inverse_independent_controls(self):
        self.syntax_privacy('const field=document.createElement("input");field.value="seed";', [(1, 'free-text binding')])
        self.syntax_privacy('for(const document of []){const field=document.createElement("input");field.value="model";}', [])
        self.syntax_privacy('function f(){for(var document of []){};const field=document.createElement("input");field.value="model";}', [])
        self.syntax_privacy('const field=document.createElement("button");field.textContent="control";', [])

    def test_privacy_catch_method_exact_finding(self):
        self.syntax_privacy('const obj={catch(){var document={}}}; const field=document.createElement("input");field.value="seed";', [(1, 'free-text binding')])

    def test_privacy_keyword_method_var_and_parameter_ownership(self):
        raw = 'free-text binding'
        for name in ['catch', 'if', 'for', 'while', 'switch', 'with', 'await',
                     'try', 'finally', 'do', 'else', 'function', 'class']:
            for container in ['const obj={%s};', 'class Model{%s}']:
                for header, body in [(name+'()', 'var document={};'),
                                     (name+'(document)', 'const field=document.createElement("input");field.value="model";')]:
                    with self.subTest(name=name, container=container, header=header):
                        self.syntax_privacy(container % (header+'{'+body+'}')+'\nconst field=document.createElement("input");field.value="seed";', [(2, raw)])
                self.syntax_privacy(container % (name+'(){var document={};const field=document.createElement("input");field.value="model";}'), [])

    def test_privacy_method_property_and_modifier_syntax(self):
        for header in ['"catch"()', '["catch"]()', 'get catch()', 'set catch(value)',
                       'async catch()', '*catch()', 'async *catch()']:
            for container in ['const obj={%s};', 'class Model{%s}']:
                with self.subTest(header=header, container=container):
                    self.syntax_privacy(container % (header+'{var document={};}')+'\nconst field=document.createElement("input");field.value="seed";', [(2, 'free-text binding')])
        self.syntax_privacy('class Model{static catch(){var document={};} static get if(){var document={};} static *for(){var document={};}}\nconst field=document.createElement("input");field.value="seed";', [(2, 'free-text binding')])
        self.syntax_privacy('const obj={first(){var document={};},catch(){var document={};}};\nclass Model{first(){var document={};}catch(){var document={};}}\nconst field=document.createElement("input");field.value="seed";', [(3, 'free-text binding')])

    def test_privacy_static_block_var_exact_finding(self):
        self.syntax_privacy('class Model{static{var document={}}}; const field=document.createElement("input");field.value="seed";', [(1, 'free-text binding')])

    def test_privacy_static_block_immediate_metadata_exact_finding(self):
        self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";class Model{static{field.type="text"}};field.value="seed";', [(1, 'free-text binding')])

    def test_privacy_static_block_scope_and_immediate_effects(self):
        raw = 'free-text binding'
        self.syntax_privacy('class Model{static{var document={};const field=document.createElement("input");field.value="model";}catch(){const field=document.createElement("input");field.value="seed";}}', [(1, raw)])
        self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";class Model{static{field.type="text";field.value="seed";}}field.value="seed";', [(1, raw), (1, raw)])
        self.syntax_privacy('const field=document.createElement("input");class Model{static{field.type="checkbox"}}field.value="control";', [])
        self.syntax_privacy('class Model{static{const field=document.createElement("input");field.type="checkbox";field.value="control";}}', [])

    def test_privacy_call_newline_block_var_exact_control(self):
        self.syntax_privacy('function f(model){foo()\n{var document=model};const field=document.createElement("input");field.value="model";}', [])

    def test_privacy_ordinary_block_and_explicit_function_ownership(self):
        raw = 'free-text binding'
        for header in ['foo()', 'obj.catch()', 'obj["catch"]()', '(foo)()']:
            self.syntax_privacy('function f(model){'+header+'\n{var document=model};const field=document.createElement("input");field.value="model";}', [])
        for header in ['function f()', 'function* f()', 'async function f()',
                       'async function* f()', 'const f=function()',
                       'const f=function*()', 'const f=async function*()',
                       'const f=()=>', 'const f=async ()=>']:
            self.syntax_privacy(header+'{var document={};};\nconst field=document.createElement("input");field.value="seed";', [(2, raw)])
        self.syntax_privacy('function f(model){foo()\n{let document=model;const field=document.createElement("input");field.value="model";}\nconst field=document.createElement("input");field.value="seed";}', [(3, raw)])

    def test_privacy_method_deferred_views_and_genuine_catch_controls(self):
        unresolved = 'unresolved DOM privacy binding'
        for container in ['const obj={%s};', 'class Model{%s}']:
            source = 'const field=document.createElement("input");field.type="checkbox";\n'+container % 'catch(){field.type="text";field.value="seed";}'+'\nfield.value="control";'
            self.syntax_privacy(source, [(2, unresolved)])
        self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";\nconst obj={catch(){field.type="text";field.value="seed";}};\nobj.catch();field.value="seed";', [(2, unresolved), (3, unresolved)])
        self.syntax_privacy('function f(model){try{throw 0}catch(e){var document=model;}const field=document.createElement("input");field.value="model";}', [])
        self.syntax_privacy('try{throw 0}catch(document){const field=document.createElement("input");field.value="model";}\nconst field=document.createElement("input");field.value="seed";', [(2, 'free-text binding')])

    def test_privacy_scope_roles_actual_node_lexical_controls(self):
        # Execute ordinary JS lexical bindings only, with no DOM implementation
        # or scanner oracle. This checks the ownership rationale independently.
        path = self.write('scope-runtime.js', """const checks=[];
var document='global';const obj={catch(){var document='local';return document;}};
checks.push(document==='global',obj.catch()==='local',document==='global');
class Model{static{var document='static';checks.push(document==='static');}catch(){return document;}}
checks.push(document==='global',new Model().catch()==='global');
function block(model){function foo(){};foo()
{var document=model};return document===model;}
checks.push(block('block'));
function caught(model){try{throw 0}catch(e){var document=model}return document===model;}
checks.push(caught('caught'));
console.log(JSON.stringify(checks));""")
        command = [shutil.which('node'), str(path)]
        self.assertIsNotNone(command[0], 'Node is required; no execution skip')
        self.retain_inputs(command)
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '[true,true,true,true,true,true,true,true]\n')
        path.unlink()

    def test_privacy_numeric_and_private_method_member_slots(self):
        for name in ['1', '1.5', '.5', '0x1', '0b1', '0o1', '1e3', '1_000', '1n']:
            for container in ['const obj={%s};', 'class Model{%s}']:
                self.syntax_privacy(container % (name+'(){var document={};}')+'\nconst field=document.createElement("input");field.value="seed";', [(2, 'free-text binding')])
                self.syntax_privacy(container % (name+'(document){const field=document.createElement("input");field.value="model";}'), [])
        for name in ['#catch', 'static #catch', 'get #catch', 'set #catch']:
            params = 'value' if name.startswith('set') else ''
            self.syntax_privacy('class Model{'+name+'('+params+'){var document={};}}\nconst field=document.createElement("input");field.value="seed";', [(2, 'free-text binding')])

    def test_privacy_concrete_covered_method_capture_pairs(self):
        prefix = 'const replacement=document.createElement("input");replacement.type="checkbox";\nconst field=document.createElement("button");\n'
        method = 'field.unknownMutation=function(){replacement.type="text";};\n'
        self.syntax_privacy(prefix+method+'field.unknownMutation();\nreplacement.value="seed";', [(5, 'unresolved DOM privacy binding')])
        self.syntax_privacy(prefix+method+'replacement.value="control";', [])
        self.syntax_privacy(prefix+'field.setAttribute("type","button");field.removeAttribute("autocomplete");\nreplacement.value="control";', [])

    def test_privacy_bracket_invocation_exact_finding(self):
        self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";const obj={catch(){field.type="text"}};obj["catch"]();field.value="seed";', [(1, 'unresolved DOM privacy binding')])

    def test_privacy_tagged_invocation_exact_finding(self):
        self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";function later(){field.type="text"}later`data`;field.value="seed";', [(1, 'unresolved DOM privacy binding')])

    def test_privacy_unknown_dom_method_capture_exact_finding(self):
        self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";const other=document.createElement("button");other.mutate=()=>{field.type="text"};other.mutate();field.value="seed";', [(1, 'unresolved DOM privacy binding')])

    def test_privacy_uninvoked_keyword_method_exact_control(self):
        self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";const obj={if(){const model={}}};field.value="control";', [])

    def test_privacy_optional_catch_replacement_exact_finding(self):
        self.syntax_privacy('let field=document.createElement("input");field.type="checkbox";try{throw 0}catch{field=document.createElement("button")};field.value="seed";', [(1, 'unresolved DOM privacy binding')])

    def test_privacy_invocation_context_and_noninvocation_pairs(self):
        prefix = 'const field=document.createElement("input");field.type="checkbox";\n'
        for call in ['obj.catch()', 'obj["catch"]()', 'obj[key]()',
                     '(obj.catch)()', '(later)()', '(later)?.()',
                     '(function(){field.type="text"})()', '(()=>{field.type="text"})()',
                     'later`data`', '(later)`data`', 'obj["catch"]`data`']:
            self.syntax_privacy(prefix+'const key="catch";const obj={catch(){field.type="text"}};function later(){field.type="text"}\n'+call+';\nfield.value="seed";', [(4, 'unresolved DOM privacy binding')])
        for prose in ['const text=`later() field.type="text"`', '(later)',
                      'function later(){field.type="text"}',
                      'const later=()=>{field.type="text"}',
                      'const obj={catch(){field.type="text"}}',
                      'class Model{catch(){field.type="text"}}']:
            self.syntax_privacy(prefix+prose+';\nfield.value="control";', [])
        # Known literal DOM metadata operations do not become arbitrary calls;
        # a noninvoked keyword-shaped method cannot invalidate a captured local.
        self.syntax_privacy(prefix+'const other=document.createElement("input");other.setAttribute("type","checkbox");other.removeAttribute("autocomplete");\nfield.value="control";other.value="control";', [])
        for name in ['catch', 'if', 'for', 'while', 'switch', 'with', 'await', 'try', 'finally', 'do', 'else']:
            for container in ['const obj={%s};', 'class Model{%s}']:
                self.syntax_privacy(prefix+container % (name+'(){field.type="text";}')+'\nfield.value="control";', [])

    def test_privacy_genuine_control_and_member_slot_composition(self):
        for expression in ['flag?{catch(){var document={}}}:{}',
                           'flag||{catch(){var document={}}}',
                           'flag&&{catch(){var document={}}}',
                           'flag??{catch(){var document={}}}']:
            self.syntax_privacy('const obj='+expression+';\nconst field=document.createElement("input");field.value="seed";', [(2, 'free-text binding')])
        self.syntax_privacy('function f(model){obj.function()\n{var document=model};const field=document.createElement("input");field.value="model";}', [])
        self.syntax_privacy('function f(model){try{throw 0}catch{var document=model;}const field=document.createElement("input");field.value="model";}', [])
        self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";if(flag){field.type="text";}field.value="seed";', [(1, 'unresolved DOM privacy binding')])

    def test_privacy_invocation_actual_node_capture_controls(self):
        # Plain objects exercise JS call/effect order; no DOM is mocked and no
        # runtime object classification is used as the production lint oracle.
        path = self.write('invocation-runtime.js', """const state={kind:'checkbox'},checks=[];
function later(){state.kind='text'};const obj={catch:later};const key='catch';
for(const invoke of [()=>obj.catch(),()=>obj['catch'](),()=>obj[key](),
 ()=> (later)(),()=> (function(){later()})(),()=> (()=>{later()})(),
 ()=>later`data`]){state.kind='checkbox';invoke();checks.push(state.kind==='text');}
state.kind='checkbox';const prose=`later() state.kind='text'`;checks.push(state.kind==='checkbox');
console.log(JSON.stringify(checks));""")
        command = [shutil.which('node'), str(path)]
        self.assertIsNotNone(command[0], 'Node is required; no execution skip')
        self.retain_inputs(command)
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '[true,true,true,true,true,true,true,true]\n')
        path.unlink()

    def test_privacy_invocation_production_inverses(self):
        scanner = SCRIPT.read_text(); helper = SCRIPT.with_name('lint_privacy.py').read_text()
        call = "and i not in statement_headers and callee_before(i):"
        tagged = "if token.kind == 'template' and callee_before(i):"
        control = 'if i in control_tokens:'
        capture = '                    invalidate_visible(scope)\n        # Passing a known DOM allocation'
        catch = "elif name in {'else', 'try', 'finally', 'do', 'catch'} and brace_roles.get(index+1) == 'control':"
        for anchor in [call, tagged, control, capture, catch]: self.assertEqual(helper.count(anchor), 1)
        variants = [
            ('drop-callee-context', helper.replace(call, call.replace('callee_before(i)', "ts[i-1].kind == 'id'")),
             'test_privacy_bracket_invocation_exact_finding', 'unresolved DOM privacy binding'),
            ('drop-tagged-call', helper.replace(tagged, 'if False:'),
             'test_privacy_tagged_invocation_exact_finding', 'unresolved DOM privacy binding'),
            ('covered-method-local-only', helper.replace(capture, capture.replace('invalidate_visible(scope)', 'invalidate(allocation)')),
             'test_privacy_unknown_dom_method_capture_exact_finding', 'unresolved DOM privacy binding'),
            ('keyword-spelling-control', helper.replace(control, "if v(i) in {'if', 'for', 'while', 'switch', 'try', 'with'}:"),
             'test_privacy_uninvoked_keyword_method_exact_control', 'unresolved DOM privacy binding'),
            ('drop-optional-catch-range', helper.replace(catch, catch.replace(", 'catch'", '')),
             'test_privacy_optional_catch_replacement_exact_finding', 'unresolved DOM privacy binding'),
        ]
        for name, source, failing, api in variants:
            with self.subTest(mutation=name):
                directory = Path(self.temp.name)/name/'tools'; directory.mkdir(parents=True)
                (directory/'lint_nondet.py').write_text(scanner)
                (directory/'lint_privacy.py').write_text(source)
                (directory/'test_lint_nondet.py').write_text(Path(__file__).read_text().replace(
                    'PROJECT = Path(__file__).resolve().parents[1]', 'PROJECT = Path('+repr(str(PROJECT))+')', 1))
                command = [sys.executable, str(directory/'test_lint_nondet.py'), 'LintTests.'+failing,
                           'LintTests.test_privacy_catch_var_hoists_to_real_function',
                           'LintTests.test_privacy_nonfield_only_control',
                           'LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
                self.retain_inputs(command)
                result = subprocess.run(command, capture_output=True, text=True)
                (directory/'inverse.log').write_text(result.stdout+result.stderr); self.retain_inputs(command)
                self.assertEqual(result.returncode, 1, result.stdout+result.stderr)
                self.assertIn('FAIL: '+failing, result.stderr)
                self.assertIn('AssertionError: Lists differ', result.stderr)
                self.assertIn('site/src/privacy.js', result.stderr)
                self.assertIn(api, result.stderr)
                self.assertIn('FAILED (failures=1)', result.stderr)
                self.assertNotIn('ERROR:', result.stderr)

    def test_privacy_syntax_role_production_inverses(self):
        scanner = SCRIPT.read_text(); helper = SCRIPT.with_name('lint_privacy.py').read_text()
        method = 'method = start is not None and method_header(start, parent)'
        static_var = "var_owner=function or brace_roles[i] == 'static'"
        static_view = "function = brace_roles[i] == 'function'"
        block = 'function = arrow or (start is not None and (explicit_function(start) or method))'
        for anchor in [method, static_var, static_view, block]: self.assertEqual(helper.count(anchor), 1)
        variants = [
            ('catch-method-role', helper.replace(method, method+" and v(start-1) != 'catch'"),
             'test_privacy_catch_method_exact_finding', 'free-text binding'),
            ('static-var-owner', helper.replace(static_var, 'var_owner=function'),
             'test_privacy_static_block_var_exact_finding', 'free-text binding'),
            ('static-deferred-view', helper.replace(static_view, "function = brace_roles[i] in {'function', 'static'}"),
             'test_privacy_static_block_immediate_metadata_exact_finding', 'free-text binding'),
            ('call-block-function', helper.replace(block, block+" or (start is not None and v(start-1) == 'foo')"),
             'test_privacy_call_newline_block_var_exact_control', 'free-text binding'),
        ]
        for name, source, failing, api in variants:
            with self.subTest(mutation=name):
                directory = Path(self.temp.name)/name/'tools'; directory.mkdir(parents=True)
                (directory/'lint_nondet.py').write_text(scanner)
                (directory/'lint_privacy.py').write_text(source)
                (directory/'test_lint_nondet.py').write_text(Path(__file__).read_text().replace(
                    'PROJECT = Path(__file__).resolve().parents[1]', 'PROJECT = Path('+repr(str(PROJECT))+')', 1))
                command = [sys.executable, str(directory/'test_lint_nondet.py'), 'LintTests.'+failing,
                           'LintTests.test_privacy_catch_var_hoists_to_real_function',
                           'LintTests.test_privacy_nonfield_only_control',
                           'LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
                self.retain_inputs(command)
                result = subprocess.run(command, capture_output=True, text=True)
                (directory/'inverse.log').write_text(result.stdout+result.stderr); self.retain_inputs(command)
                self.assertEqual(result.returncode, 1, result.stdout+result.stderr)
                self.assertIn('FAIL: '+failing, result.stderr)
                self.assertIn('AssertionError: Lists differ', result.stderr)
                self.assertIn('site/src/privacy.js', result.stderr)
                self.assertIn(api, result.stderr)
                self.assertIn('FAILED (failures=1)', result.stderr)
                self.assertNotIn('ERROR:', result.stderr)

    def test_privacy_scope_metadata_production_inverses(self):
        scanner = SCRIPT.read_text(); helper = SCRIPT.with_name('lint_privacy.py').read_text()
        loop = "if i in loop_extents: stack.append((Scope(stack[-1][0]), loop_extents[i]))"
        catch = "var_owner=function or brace_roles[i] == 'static'"
        template = "x <= a < y if template else x < b and y > a"
        for anchor in [loop, catch, template]: self.assertEqual(helper.count(anchor), 1)
        variants = [
            ('outer-loop-binding', helper.replace(loop, 'if False: pass'),
             'test_privacy_loop_header_exact_post_loop_finding', 'privacy.js', 'free-text binding'),
            ('catch-function-boundary', helper.replace(catch, catch+" or pairs.get(end) in catch_headers"),
             'test_privacy_catch_var_hoists_to_real_function', 'privacy.js', 'free-text binding'),
            ('drop-opaque-template-extent', helper.replace(template, 'x < b and y > a'),
             'test_privacy_opaque_template_keeps_tag_continuation', 'privacy.nim', 'unresolved DOM privacy binding'),
        ]
        for name, source, failing, fixture, api in variants:
            with self.subTest(mutation=name):
                directory = Path(self.temp.name)/name/'tools'; directory.mkdir(parents=True)
                (directory/'lint_nondet.py').write_text(scanner)
                (directory/'lint_privacy.py').write_text(source)
                (directory/'test_lint_nondet.py').write_text(Path(__file__).read_text().replace(
                    'PROJECT = Path(__file__).resolve().parents[1]', 'PROJECT = Path('+repr(str(PROJECT))+')', 1))
                command = [sys.executable, str(directory/'test_lint_nondet.py'), 'LintTests.'+failing,
                           'LintTests.test_privacy_nonfield_only_control',
                           'LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
                if name == 'outer-loop-binding':
                    command += ['LintTests.test_privacy_loop_inverse_independent_controls']
                self.retain_inputs(command)
                result = subprocess.run(command, capture_output=True, text=True)
                (directory/'inverse.log').write_text(result.stdout+result.stderr);self.retain_inputs(command)
                self.assertEqual(result.returncode, 1, result.stdout+result.stderr)
                self.assertIn('FAIL: '+failing, result.stderr)
                self.assertIn('AssertionError: Lists differ', result.stderr)
                self.assertIn('site/src/'+fixture, result.stderr)
                self.assertIn(api, result.stderr)
                self.assertIn('FAILED (failures=1)', result.stderr)
                self.assertNotIn('ERROR:', result.stderr)

    def test_privacy_production_mutations_fail_exact_finding_assertions(self):
        # Isolated actual scanner copies, with the actual production helper.
        # The unmodified count/file/line assertions run in real subprocesses;
        # each mutant must cause one named assertion failure, never an import,
        # syntax or compiler error. Legal/old-platform controls run beside it.
        scanner = SCRIPT.read_text(); helper = SCRIPT.with_name('lint_privacy.py').read_text()
        integration = 'for offset, api in privacy_bindings(payload, mask, literals, opaque)'
        state = 'allocation.input_type = lowered if lowered in TEXT_TYPES | OTHER_TYPES or lowered == \'<dynamic>\' else None'
        self.assertEqual(scanner.count(integration), 1)
        self.assertEqual(helper.count(state), 1)
        variants = [
            ('remove-integration', scanner.replace(integration, 'for offset, api in []'), helper,
             'test_privacy_real_component_exact_finding_removal_and_dsl_counterpart', 'privacy_component.nim', 'free-text binding'),
            ('stale-alias-type', scanner, helper.replace(state,
             'if lowered != "text" or allocation.input_type != "checkbox":\n            '+state),
             'test_privacy_alias_type_mutation_and_order', 'privacy.js', 'free-text binding'),
        ]
        captured = 'binding_views[function_scope(scope), target, name] = allocation'
        unknown = 'allocation = Allocation(None, scope, uncertain=True)'
        self.assertEqual(helper.count(captured), 1)
        self.assertEqual(helper.count(unknown), 1)
        variants.extend([
            ('eager-captured-write', scanner, helper.replace(captured, 'target.bindings[name] = allocation'),
             'test_privacy_deferred_captured_binding_reassignment', 'privacy.js', 'free-text binding'),
            ('drop-unknown-provenance', scanner, helper.replace(unknown, 'allocation = None'),
             'test_privacy_unknown_reassignment_keeps_uncertain_dom_provenance', 'privacy.js', 'unresolved DOM privacy binding'),
        ])
        conditional = 'if crosses_control(i, target) and (old is not None or allocation is not None):'
        self.assertEqual(helper.count(conditional), 1)
        variants.append(('drop-conditional-provenance', scanner, helper.replace(conditional, 'if False:'),
                         'test_privacy_conditional_reassignment_keeps_uncertain_dom_provenance',
                         'privacy.js', 'unresolved DOM privacy binding'))
        operator_gate = "elif v(after) in ASSIGNMENT_OPERATORS | UPDATE_OPERATORS or v(member_left-1) in UPDATE_OPERATORS:"
        self.assertEqual(helper.count(operator_gate), 1)
        variants.append(('narrow-metadata-operators', scanner, helper.replace(operator_gate,
                         "elif v(after) in {'=', '+=', '-=', '++', '--'}:"),
                         'test_privacy_metadata_multiply_loses_checkbox_certification',
                         'privacy.js', 'free-text binding'))
        receiver_gate = "elif token.kind == 'id' and (v(write) in ASSIGNMENT_OPERATORS | UPDATE_OPERATORS or (v(left-1) in UPDATE_OPERATORS and not member(i))) and (left == 0 or v(left-1) not in {'.', '?.'}):"
        self.assertEqual(helper.count(receiver_gate), 1)
        variants.append(('narrow-receiver-writes', scanner, helper.replace(receiver_gate,
                         "elif token.kind == 'id' and v(i+1) == '=' and (i == 0 or v(i-1) not in {'.', '?.'}):"),
                         'test_privacy_receiver_logical_replacement_exact_finding',
                         'privacy.js', 'unresolved DOM privacy binding'))
        plain_edges = 'allocation.possible_aliases = rhs_aliases'
        self.assertEqual(helper.count(plain_edges), 1)
        variants.append(('drop-plain-uncertain-edges', scanner, helper.replace(plain_edges,
                         'allocation.possible_aliases = ()'),
                         'test_privacy_plain_uncertain_alias_exact_finding',
                         'privacy.js', 'unresolved DOM privacy binding'))
        nonplain_edges = ' + list(rhs_aliases)))'
        self.assertEqual(helper.count(nonplain_edges), 1)
        variants.append(('drop-nonplain-rhs-edges', scanner, helper.replace(nonplain_edges, ' + []))'),
                         'test_privacy_nonplain_rhs_exact_finding',
                         'privacy.js', 'unresolved DOM privacy binding'))
        asi = 'if not line_break(before, after): return False'
        self.assertEqual(helper.count(asi), 1)
        variants.append(('drop-asi-boundaries', scanner, helper.replace(asi, 'if True: return False'),
                         'test_privacy_asi_allocation_exact_finding',
                         'privacy.js', 'free-text binding'))
        for name, scanner_source, helper_source, failing, fixture, expected_api in variants:
            with self.subTest(mutation=name):
                directory = Path(self.temp.name) / name / 'tools'; directory.mkdir(parents=True)
                (directory/'lint_nondet.py').write_text(scanner_source)
                (directory/'lint_privacy.py').write_text(helper_source)
                test_source = Path(__file__).read_text().replace(
                    'PROJECT = Path(__file__).resolve().parents[1]', 'PROJECT = Path('+repr(str(PROJECT))+')', 1)
                (directory/'test_lint_nondet.py').write_text(test_source)
                command = [sys.executable, str(directory/'test_lint_nondet.py'),
                           'LintTests.'+failing, 'LintTests.test_privacy_nonfield_only_control',
                           'LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
                self.retain_inputs(command)
                result = subprocess.run(command, capture_output=True, text=True)
                (directory/'inverse.log').write_text(result.stdout + result.stderr)
                self.retain_inputs(command)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('FAIL: '+failing, result.stderr)
                self.assertIn('AssertionError: Lists differ', result.stderr)
                self.assertIn('site/src/'+fixture, result.stderr)
                self.assertIn(expected_api, result.stderr)
                self.assertIn('FAILED (failures=1)', result.stderr)
                self.assertNotIn('ERROR:', result.stderr)
                self.assertNotIn('ModuleNotFoundError', result.stderr)


    def test_privacy_identifier_escape_exact_finding(self):
        self.assert_privacy(r'const field=docu\u006dent.createElement("input");field.v\u0061lue="seed";', [(1, 'free-text binding')], 'identifier.js')

    def test_privacy_identifier_global_member_and_local_spellings(self):
        raw = 'free-text binding'
        for document in ['document', r'docu\u006dent', r'\u{64}ocument']:
            for constructor in ['createElement', r'create\u0045lement', r'\u{63}reateElement']:
                for declaration, reference in [('field', r'fi\u0065ld'), (r'fi\u{65}ld', 'field'), (r'\u0066ield', r'fie\u006cd')]:
                    for member in ['value', r'v\u0061lue', r'\u{76}alue', r'["v\u0061lue"]']:
                        access = member if member.startswith('[') else '.'+member
                        source = 'const '+declaration+'='+document+'.'+constructor+'("input");\n'+reference+access+'="seed";'
                        with self.subTest(source=source): self.assert_privacy(source, [(2, raw)])

    def test_privacy_identifier_shadow_and_contextual_identity(self):
        for shadow in [r'const docu\u006dent=model;', r'let \u{64}ocument=model;', r'var docu\u006dent=model;']:
            self.assert_privacy('function f(model){'+shadow+'const field=document.createElement("input");field.value="model";}', [])
        for header in [r'function f(docu\u006dent)', r'const f=(docu\u{6d}ent)=>', r'function f({source:docu\u006dent})']:
            self.assert_privacy(header+'{const field=document.createElement("input");field.value="model";}\nconst field=document.createElement("input");field.value="seed";', [(2, 'free-text binding')])
        for name in ['async', 'get', 'set', 'static', 'of', 'let', 'yield', 'await']:
            escaped = '\\u%04x'%ord(name[0])+name[1:]
            self.assert_privacy('var '+escaped+'=document.createElement("input");\n'+name+'.value="seed";', [(2, 'free-text binding')])
            self.assert_privacy('var '+name+'=document.createElement("input");\n'+escaped+'.value="seed";', [(2, 'free-text binding')])
        self.assert_privacy(r'const model={};model.v\u0061lue="ordinary";const field=Document.createElement("input");field.value="model";', [])
        self.assert_privacy(r'const field=document.createElement("input");field.Value="ordinary";field.TextContent="ordinary";', [])
        self.assert_privacy(r'const obj={c\u0061tch(){var document={}}};const field=document.createElement("input");field.value="seed";', [(1, 'free-text binding')])

    def test_privacy_identifier_unicode_and_alias_mutation(self):
        for plain, escaped in [('é', r'\u00e9'), ('α', r'\u{3b1}'), ('𐐀', r'\u{10400}'), ('℘', r'\u2118'), ('a·', r'a\u00b7'), ('a・', r'a\u30fb'), ('a\u200c', r'a\u200c'), ('á', r'a\u0301')]:
            source = 'const '+escaped+'=document.createElement("input");\n'+plain+'.value="seed";'
            with self.subTest(name=plain): self.assert_privacy(source, [(2, 'free-text binding')])
            self.assert_privacy('const '+plain+'=document.createElement("input");\n'+escaped+'.textContent="seed";', [(2, 'free-text binding')])
        self.assert_privacy(r'const fi\u0065ld=document.createElement("input");'+'\n'+r'field.t\u0079pe="checkbox";'+'\n'+r'const ali\u0061s=field;'+'\n'+r'alias.t\u{79}pe="text";'+'\n'+r'fi\u0065ld.v\u0061lue="seed";', [(5, 'free-text binding')])
        self.assert_privacy(r'const field=document.createElement("input");field.set\u0041ttribute("type","checkbox");field.v\u0061lue="on";', [])
        self.assert_privacy(r'const field=document.createElement("input");field.type="checkbox";unknown(fi\u0065ld);field.value="seed";', [(1, 'unresolved DOM privacy binding')])

    def test_privacy_identifier_production_inverse(self):
        scanner = SCRIPT.read_text(); helper = SCRIPT.with_name('lint_privacy.py').read_text()
        anchor = "ch = chr(point)"
        self.assertEqual(helper.count(anchor), 1)
        directory = Path(self.temp.name)/'identifier-identity-inverse'/'tools'; directory.mkdir(parents=True)
        (directory/'lint_nondet.py').write_text(scanner)
        (directory/'lint_privacy.py').write_text(helper.replace(anchor, "ch = '_'"))
        (directory/'test_lint_nondet.py').write_text(Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]', 'PROJECT = Path('+repr(str(PROJECT))+')', 1))
        command = [sys.executable, str(directory/'test_lint_nondet.py'), 'LintTests.test_privacy_identifier_escape_exact_finding', 'LintTests.test_privacy_nonfield_only_control', 'LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
        self.retain_inputs(command)
        result = subprocess.run(command, capture_output=True, text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr); self.retain_inputs(command)
        self.assertEqual(result.returncode, 1, result.stdout+result.stderr)
        self.assertIn('FAIL: test_privacy_identifier_escape_exact_finding', result.stderr)
        self.assertIn('AssertionError: Lists differ', result.stderr)
        self.assertIn('site/src/identifier.js', result.stderr)
        self.assertIn('free-text binding', result.stderr)
        self.assertIn('FAILED (failures=1)', result.stderr)
        self.assertNotIn('ERROR:', result.stderr)


    def test_privacy_named_expression_outer_exact_finding(self):
        self.syntax_privacy('const later=function document(){};\nconst field=document.createElement("input");\nfield.value="privacy-test";', [(3, 'free-text binding')])

    def test_privacy_named_expression_function_class_forms(self):
        for header in ['function document(){}', 'async function document(){}',
                       'function* document(){}', 'async function* document(){}',
                       r'function docu\u006dent(){}', r'async function* docu\u006dent(){}',
                       'class document {}', r'class docu\u006dent {}',
                       'class document {static {} method(){}}']:
            for expression in ['const later='+header+';', 'const later=('+header+');',
                               'const later={member:'+header+'};', 'const later=['+header+'];',
                               'const later=flag?'+header+':null;', 'const later=flag?null:'+header+';']:
                with self.subTest(expression=expression):
                    self.syntax_privacy(expression+'\nconst field=document.createElement("input");\nfield.value="seed";', [(3, 'free-text binding')])

    def test_privacy_named_expression_private_self_and_captured_names(self):
        raw = 'free-text binding'
        for expression in ['function document(){const field=document.createElement("input");field.value="model";}',
                           'async function document(){const field=document.createElement("input");field.value="model";}',
                           'function* document(){const field=document.createElement("input");field.value="model";}',
                           'class document {method(){const field=document.createElement("input");field.value="model";} static {const field=document.createElement("input");field.value="model";}}']:
            self.syntax_privacy('const later='+expression+';\nconst field=document.createElement("input");field.value="seed";', [(2, raw)])
        for expression in ['function field(){field.value="self-model";}',
                           'async function* field(){field.value="self-model";}',
                           'class field {method(){field.value="self-model";}static{field.value="self-model";}}']:
            self.syntax_privacy('const field=document.createElement("input");\nconst later='+expression+';\nfield.value="seed";', [(3, raw)])
        self.syntax_privacy('const field=document.createElement("input");\nconst later=function self(){field.value="seed";};', [(2, 'unresolved DOM privacy binding')])

    def test_privacy_named_declarations_tdz_and_ordinary_local_controls(self):
        for declaration in ['function document(){}', 'async function document(){}',
                            'function* document(){}', 'async function* document(){}',
                            r'function docu\u006dent(){}', 'class document {}',
                            'let document=model;', 'const document=model;', 'var document=model;']:
            self.syntax_privacy('const field=document.createElement("input");field.value="model";\n'+declaration, [])
            self.syntax_privacy(declaration+'\nconst field=document.createElement("input");field.value="model";', [])
        self.syntax_privacy('{class document {} const field=document.createElement("input");field.value="model";}\nconst field=document.createElement("input");field.value="seed";', [(2, 'free-text binding')])
        self.syntax_privacy('function f(document){const later=function self(){};const field=document.createElement("input");field.value="model";}\nconst field=document.createElement("input");field.value="seed";', [(2, 'free-text binding')])

    def test_privacy_named_expression_nested_methods_static_and_asi(self):
        raw = 'free-text binding'
        for container in ['function holder(){%s}', 'const obj={method(){%s}};', 'class Holder{method(){%s}}', 'class Holder{static{%s}}']:
            for expression in ['function document(){}', 'class document {}']:
                self.syntax_privacy(container%('const later='+expression+';\nconst field=document.createElement("input");field.value="seed";'), [(2, raw)])
        self.syntax_privacy('const later=\nfunction document(){}\nconst field=document.createElement("input")\nfield.value="seed"', [(4, raw)])
        self.syntax_privacy('function factory(){return function document(){};}\nconst field=document.createElement("input");field.value="seed";', [(2, raw)])
        self.syntax_privacy('function factory(){const field=document.createElement("input");field.value="seed";return class document {};}', [(1, raw)])
        self.syntax_privacy('const obj={function(){},class(){}};\nconst field=document.createElement("input");field.value="seed";', [(2, raw)])
        self.syntax_privacy('const later=class extends Base {};\nconst field=document.createElement("input");field.value="seed";', [(2, raw)])

    def test_privacy_named_expression_real_javascript_scope_oracle(self):
        # Pure language binding/identity execution, with no DOM or scanner stand-in.
        path = self.write('named-scope-oracle.js', r"""
const checks=[];
const normal=function document(){return document;};
const asyncNormal=async function document(){return document;};
const generator=function* document(){yield document;};
const asyncGenerator=async function* document(){yield document;};
const cls=class document {static self(){return document;}static{checks.push(document===this);}};
checks.push(normal()===normal, generator().next().value===generator, cls.self()===cls);
checks.push(typeof document==='undefined');
Promise.all([asyncNormal(),asyncGenerator().next()]).then(([a,g])=>{
 checks.push(a===asyncNormal,g.value===asyncGenerator);
 if(checks.length!==7||checks.some(value=>value!==true))throw new Error('named expression scope');
 process.stdout.write('named-expression-scope-ok\n');
});
""")
        command=['node',str(path)];self.retain_inputs(command)
        result=subprocess.run(command,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'named-expression-scope-ok\n')
        self.assertEqual(result.stderr,'')
        self.assertEqual(lint.scan([self.root]),[])


    def test_privacy_named_switch_declarations_and_expression_pairs(self):
        for header in ['case 0:', 'case flag?0:1:', 'default:']:
            for kind in ['function document(){}', 'function* document(){}', 'class document {}']:
                self.syntax_privacy('switch(flag){'+header+kind+'const field=document.createElement("input");field.value="model";}', [])
                self.syntax_privacy('switch(flag){'+header+'const later='+kind+';const field=document.createElement("input");field.value="seed";}', [(1, 'free-text binding')])


    def test_privacy_named_object_value_cannot_shadow_sibling_body(self):
        for expression in ['function document(){}', 'async function* document(){}',
                           'class document {}', r'function docu\u006dent(){}']:
            for key in ['member', 'default', '"member"', '["member"]']:
                for sibling in ['other:function(){%s}', 'other(){%s}', 'async other(){%s}', '*other(){%s}']:
                    body='const field=document.createElement("input");field.value="seed";'
                    source='const model={'+key+':'+expression+','+sibling%body+'};'
                    with self.subTest(source=source):self.syntax_privacy(source, [(1, 'free-text binding')])
            self.syntax_privacy('const model={member:'+expression+',other(){const document=ordinary;const field=document.createElement("input");field.value="model";}};', [])
        self.syntax_privacy('label:function document(){} const field=document.createElement("input");field.value="model";', [])
        self.syntax_privacy('const field=document.createElement("input");\nconst model={member:function field(){field.value="model";},other(){field.value="seed";}};', [(2, 'unresolved DOM privacy binding')])

    def test_privacy_named_expression_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor='if not declaration_position(keyword):'
        self.assertEqual(helper.count(anchor),1)
        directory=Path(self.temp.name)/'named-expression-inverse'/'tools';directory.mkdir(parents=True)
        (directory/'lint_nondet.py').write_text(scanner)
        (directory/'lint_privacy.py').write_text(helper.replace(anchor,'if False:'))
        (directory/'test_lint_nondet.py').write_text(Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]','PROJECT = Path('+repr(str(PROJECT))+')',1))
        command=[sys.executable,str(directory/'test_lint_nondet.py'),'LintTests.test_privacy_named_expression_outer_exact_finding','LintTests.test_privacy_nonfield_only_control','LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
        self.retain_inputs(command);result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr);self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: test_privacy_named_expression_outer_exact_finding',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/privacy.js',result.stderr)
        self.assertIn('free-text binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)


    def test_privacy_conditional_colon_exact_finding(self):
        self.syntax_privacy("switch(flag){case 0: flag ? null : function document(){}; const field=document.createElement('input');field.value='privacy-test';}", [(1, 'free-text binding')])

    def test_privacy_conditional_colon_switch_expression_pairs(self):
        for header in ['case 0:', 'case flag?0:1:', 'case flag?(other?0:1):2:', 'default:']:
            for kind in ['function document(){}', 'function* document(){}', 'class document {}']:
                for expression in ['flag?null:'+kind, 'flag?other?null:'+kind+':null', 'flag?null:other?null:'+kind]:
                    with self.subTest(header=header, expression=expression):
                        self.syntax_privacy('switch(flag){'+header+expression+';const field=document.createElement("input");field.value="seed";}', [(1, 'free-text binding')])
                self.syntax_privacy('switch(flag){'+header+kind+' const field=document.createElement("input");field.value="model";}', [])

    def test_privacy_conditional_colon_delimiter_and_keyword_controls(self):
        for kind in ['function document(){}', 'class document {}']:
            for header in ['case obj.case:', 'case obj.default:', 'case (flag?0:1):', 'case ({case:flag?0:1}).case:', 'default:']:
                self.syntax_privacy('switch(flag){'+header+'flag?null:'+kind+';const field=document.createElement("input");field.value="seed";}', [(1, 'free-text binding')])
                self.syntax_privacy('switch(flag){'+header+kind+' const field=document.createElement("input");field.value="model";}', [])
            for expression in ['(flag?null:'+kind+')', '({case:flag?null:'+kind+'})', '[flag?null:'+kind+']', 'flag?({default:'+kind+'}):null']:
                self.syntax_privacy(expression+';const field=document.createElement("input");field.value="seed";', [(1, 'free-text binding')])
        self.syntax_privacy('outer:inner:function document(){} const field=document.createElement("input");field.value="model";', [])
        self.syntax_privacy('const prose="case default : ?";flag?null:function document(){};const field=document.createElement("input");field.value="seed";', [(1, 'free-text binding')])
        self.syntax_privacy('switch(flag){case 0: flag?null:function document(){const field=document.createElement("input");field.value="model";};const field=document.createElement("input");field.value="seed";}', [(1, 'free-text binding')])
        self.syntax_privacy('switch(flag){case 0: const document=model;flag?null:function self(){};const field=document.createElement("input");field.value="model";}', [])

    def test_privacy_conditional_colon_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor="if v(before) == ':': return before in statement_colons"
        self.assertEqual(helper.count(anchor),1)
        directory=Path(self.temp.name)/'conditional-colon-inverse'/'tools';directory.mkdir(parents=True)
        (directory/'lint_nondet.py').write_text(scanner)
        # Remove only the conditional-colon distinction at declaration dispatch.
        # The local named expression then leaks its name into the switch owner.
        (directory/'lint_privacy.py').write_text(helper.replace(anchor,"if v(before) == ':': return before in statement_colons or before in conditional_colons"))
        (directory/'test_lint_nondet.py').write_text(Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]','PROJECT = Path('+repr(str(PROJECT))+')',1))
        command=[sys.executable,str(directory/'test_lint_nondet.py'),'LintTests.test_privacy_conditional_colon_exact_finding','LintTests.test_privacy_nonfield_only_control','LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
        self.retain_inputs(command);result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr);self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: test_privacy_conditional_colon_exact_finding',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/privacy.js',result.stderr)
        self.assertIn('free-text binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)


    def test_privacy_instance_field_exact_finding(self):
        self.syntax_privacy('const field=document.createElement("input");class Model{saved=(field.type="checkbox");}field.value="privacy-test";', [(1, 'free-text binding')])

    def test_privacy_class_field_timing_and_head_pairs(self):
        raw='free-text binding'
        for key in ['saved', 'static', '#saved', '"saved"', '123', '0xA', '1e2', '123n']:
            for effect in ['field.type="checkbox"', 'field.setAttribute("type","checkbox")', 'field={}', 'field=document.createElement("button")']:
                prefix='let field=document.createElement("input");'
                self.syntax_privacy(prefix+'class Model{'+key+'=('+effect+');}field.value="seed";', [(1,raw)])
        for modifier in ['', 'static ']:
            for key in ['field', '#field', '"field"', '123']:
                self.syntax_privacy('let field=document.createElement("input");class Model{'+modifier+key+'={};}field.value="seed";',[(1,raw)])
        for body in ['static saved=(field.type="checkbox");', 'static #saved=(field.type="checkbox");', 'static{field.type="checkbox";}', 'static\nsaved=(field.type="checkbox");']:
            self.syntax_privacy('const field=document.createElement("input");class Model{'+body+'}field.value="control";',[])
        self.syntax_privacy('const field=document.createElement("input");class Model{saved=(field.type="checkbox")\nother=1\n}field.value="seed";',[(3,raw)])
        self.syntax_privacy('const field=document.createElement("input");class Model{static saved=(field.type="checkbox")\nother=1\n}field.value="control";',[])
        self.syntax_privacy('const field=document.createElement("input");class Model{saved=(field.type="checkbox");static{field.type="text";}}field.value="seed";',[(1,raw)])
        self.syntax_privacy('const field=document.createElement("input");class Model{saved=(field.type="text");static saved=(field.type="checkbox");}field.value="control";',[])
        self.syntax_privacy('const model={};class Model{saved=(model.value="ordinary");}model.value="ordinary";',[])
        self.syntax_privacy('const field=document.createElement("input");class Model{static async\nfoo=(field.type="checkbox");}field.value="seed";',[(2,raw)])

    def test_privacy_class_field_nested_routines_and_construction(self):
        raw='free-text binding';unresolved='unresolved DOM privacy binding'
        for construction in ['new Model()', 'new Model', 'new (Model)']:
            self.syntax_privacy('const field=document.createElement("input");class Model{saved=(field.type="checkbox");}'+construction+';field.value="seed";',[(1,unresolved)])
        self.syntax_privacy('const field=document.createElement("input");class Model{saved=()=>{field.type="checkbox";};}field.value="seed";',[(1,raw)])
        self.syntax_privacy('const field=document.createElement("input");class Model{saved={method(){field.type="checkbox";}};}field.value="seed";',[(1,raw)])
        self.syntax_privacy('class Model{saved=(()=>{const field=document.createElement("input");field.value="seed";})();}',[(1,raw)])
        self.syntax_privacy('const field=document.createElement("input");class Model{saved=(field.type="checkbox");method(){const field=document.createElement("input");field.value="seed";}}field.value="seed";',[(1,raw),(1,raw)])
        self.syntax_privacy('const field=document.createElement("input");class Model{saved=(class Nested{static{field.type="checkbox";}});}field.value="seed";',[(1,raw)])
        self.syntax_privacy('const field=document.createElement("input");class Model{static saved=()=>{field.type="checkbox";};}field.value="seed";',[(1,raw)])

    def test_privacy_class_field_real_language_timing_oracle(self):
        # Ordinary JavaScript objects prove language timing; no DOM stand-in or
        # scanner classifier is executed by this independent state oracle.
        path=self.write('class-field-oracle.js',r"""
let value='before';
let field={kind:'text'};
class Model {
 field={};
 static=(field.kind='instance-static-name');
 #private=(value='instance');
 saved=(value='instance');
 static saved=(value='static');
 static{if(field.kind!=='text')throw new Error('instance field ran early');}
}
if(value!=='static'||field.kind!=='text')throw new Error('class evaluation');
new Model;
if(value!=='instance'||field.kind!=='instance-static-name')throw new Error('construction');
if(typeof field!=='object'||field.kind!=='instance-static-name')throw new Error('field head');
value='before-async-name';
class AsyncName { static async
 saved=(value='constructed-async-name'); }
if(value!=='before-async-name')throw new Error('async field boundary');
new AsyncName;
if(value!=='constructed-async-name')throw new Error('async field construction');
process.stdout.write('class-field-timing-ok\n');
""")
        command=['node',str(path)];self.retain_inputs(command)
        result=subprocess.run(command,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'class-field-timing-ok\n')
        self.assertEqual(result.stderr,'')
        self.assertEqual(lint.scan([self.root]),[])

    def test_privacy_instance_field_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor='if not static and start < cursor:'
        self.assertEqual(helper.count(anchor),1)
        directory=Path(self.temp.name)/'instance-field-inverse'/'tools';directory.mkdir(parents=True)
        (directory/'lint_nondet.py').write_text(scanner)
        # Remove only instance-field deferred views; static timing and member
        # heads stay intact. The original outer checkbox exemption returns.
        (directory/'lint_privacy.py').write_text(helper.replace(anchor,'if False and start < cursor:'))
        (directory/'test_lint_nondet.py').write_text(Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]','PROJECT = Path('+repr(str(PROJECT))+')',1))
        command=[sys.executable,str(directory/'test_lint_nondet.py'),'LintTests.test_privacy_instance_field_exact_finding','LintTests.test_privacy_nonfield_only_control','LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
        self.retain_inputs(command);result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr);self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: test_privacy_instance_field_exact_finding',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/privacy.js',result.stderr)
        self.assertIn('free-text binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)


    def test_privacy_guarded_expression_exact_finding(self):
        self.syntax_privacy('const field=document.createElement("input");flag ? (field.type="checkbox") : null;field.value="privacy-test";', [(1,'unresolved DOM privacy binding')])

    def test_privacy_guarded_expression_metadata_pairs(self):
        unresolved='unresolved DOM privacy binding'
        effects=['field.type="checkbox"', 'field["type"]="checkbox"', 'field.setAttribute("type","checkbox")', 'field.removeAttribute("type")', 'delete field.type', 'field.unknownMutation()']
        for effect in effects:
            for guard in ['flag ? ('+effect+') : null', 'flag ? null : ('+effect+')', 'flag && ('+effect+')', 'flag || ('+effect+')', 'flag ?? ('+effect+')']:
                with self.subTest(guard=guard):
                    self.syntax_privacy('const field=document.createElement("input");'+guard+';field.value="seed";',[(1,unresolved)])
        for operator in ['&&=', '||=', '??=']:
            self.syntax_privacy('const field=document.createElement("input");let flag=model;flag '+operator+' (field.type="checkbox");field.value="seed";',[(1,unresolved)])
        self.syntax_privacy('const field=document.createElement("div");field.contentEditable="true";flag?(field.contentEditable="false"):null;field.textContent="seed";',[(1,unresolved)])
        self.syntax_privacy('const field=document.createElement("input");flag?(field.autocomplete="one-time-code"):null;field.type="checkbox";field.value="seed";',[(1,unresolved)])

    def test_privacy_guarded_expression_receiver_and_alias_pairs(self):
        unresolved='unresolved DOM privacy binding'
        for effect in ['field={}', 'field=document.createElement("button")', 'field=replacement']:
            for guard in ['flag?('+effect+'):null', 'flag && ('+effect+')', 'flag || ('+effect+')', 'flag ?? ('+effect+')']:
                self.syntax_privacy('let field=document.createElement("input");const replacement=document.createElement("button");'+guard+';field.value="seed";',[(1,unresolved)])
        self.syntax_privacy('const field=document.createElement("input");const alias=field;flag?(alias.type="checkbox"):null;field.value="seed";',[(1,unresolved)])
        self.syntax_privacy('let field=document.createElement("input");const original=field;const replacement=document.createElement("input");field.type="checkbox";replacement.type="checkbox";flag?(field=replacement):null;field.type="text";original.value="seed";replacement.value="seed";',[(1,unresolved),(1,unresolved)])

    def test_privacy_guarded_expression_nesting_and_delimiter_pairs(self):
        unresolved='unresolved DOM privacy binding'
        for expression in ['flag?(other?(field.type="checkbox"):null):null', 'flag?null:(other?(field.type="checkbox"):null)', 'flag && (other || (field.type="checkbox"))', '({saved:flag?(field.type="checkbox"):null})', '[flag?(field.type="checkbox"):null]', 'flag?(0,(field.type="checkbox")):null']:
            self.syntax_privacy('const field=document.createElement("input");'+expression+';field.value="seed";',[(1,unresolved)])
        for expression in ['flag && 1, field.type="checkbox"', 'flag?0:null;field.type="checkbox"', '({saved:flag?0:1});field.type="checkbox"', '[flag&&1];field.type="checkbox"', 'flag && 1\nfield.type="checkbox"']:
            self.syntax_privacy('const field=document.createElement("input");'+expression+';field.value="control";',[])
        self.syntax_privacy('const field=document.createElement("input");flag?\n(field.type="checkbox"):\nnull;\nfield.value="seed";',[(4,unresolved)])

    def test_privacy_guarded_expression_readonly_and_condition_controls(self):
        for expression in ['flag?field:null', 'flag?field:replacement', 'field===replacement?0:1', 'flag && field', 'flag || field', 'flag ?? field', 'flag?(field.type==="text"):null', '({saved:flag?field:replacement})']:
            self.syntax_privacy('const field=document.createElement("input");const replacement=document.createElement("input");field.type="checkbox";replacement.type="checkbox";'+expression+';field.value="control";replacement.value="control";',[])
        for expression in ['(field.type="checkbox")?0:1', '(field.type="checkbox") && 1', '(field.type="checkbox") || 1', '(field.type="checkbox") ?? 1']:
            self.syntax_privacy('const field=document.createElement("input");'+expression+';field.value="control";',[])
        self.syntax_privacy('const model={};flag?(model.type="checkbox"):null;model.value="ordinary";',[])

    def test_privacy_guarded_expression_fresh_and_deferred_controls(self):
        raw='free-text binding'
        for body in ['function(){field.type="checkbox";}', 'class Model{saved=(field.type="checkbox");}', '()=>{field.type="checkbox";}']:
            self.syntax_privacy('const field=document.createElement("input");flag?('+body+'):null;field.value="seed";',[(1,raw)])
        self.syntax_privacy('flag?function(){const field=document.createElement("input");field.type="checkbox";field.value="control";}:null;',[])
        self.syntax_privacy('let field=document.createElement("input");flag?(field.type="checkbox"):null;field=document.createElement("input");field.type="checkbox";field.value="control";',[])
        self.syntax_privacy('const field=document.createElement("input");class Model{static saved=flag?(field.type="checkbox"):null;}field.value="seed";',[(1,'unresolved DOM privacy binding')])

    def test_privacy_guarded_expression_escaped_allocation_pairs(self):
        unresolved='unresolved DOM privacy binding'
        for allocation in ["let field;{field=document.createElement('input');}", "let field;{const local=document.createElement('input');field=local;}"]:
            for effect in ['field.type="checkbox"', 'field.setAttribute("type","checkbox")', 'field.removeAttribute("type")']:
                for expression in ['flag?('+effect+'):null', 'flag && ('+effect+')', 'flag || ('+effect+')', 'flag ?? ('+effect+')']:
                    self.syntax_privacy(allocation+expression+';field.value="seed";',[(1,unresolved)])
            self.syntax_privacy(allocation+'field.type="checkbox";flag?field:null;field.value="control";',[])
            self.syntax_privacy(allocation+'flag?(field.type="checkbox"):null;field=document.createElement("input");field.type="checkbox";field.value="control";',[])

    def test_privacy_guarded_expression_branch_local_var_controls(self):
        for tag in ['style', 'script', 'button']:
            for effect in ['field.id="ordinary";', 'field.setAttribute("data-ordinary","true");']:
                self.syntax_privacy('if(flag){var field=document.createElement("'+tag+'");'+effect+'field.textContent="ordinary";}',[])
                self.syntax_privacy('flag?function(){if(other){var field=document.createElement("'+tag+'");'+effect+'field.textContent="ordinary";}}:null;',[])
        self.syntax_privacy('if(flag){var field=document.createElement("input");field.type="checkbox";field.value="control";}',[])
        self.syntax_privacy('flag?function(){if(other){var field=document.createElement("input");field.type="checkbox";field.value="control";}}:null;',[])
        self.syntax_privacy('if(flag){var field=document.createElement("input");other?(field.type="checkbox"):null;field.value="seed";}',[(1,'unresolved DOM privacy binding')])

    def test_privacy_guarded_expression_unrelated_metadata_controls(self):
        for tag in ['input', 'button', 'style', 'script']:
            initial='field.type="checkbox";' if tag=='input' else ''
            for effect in ['field.id="ordinary"', 'field.setAttribute("id","ordinary")', 'field.setAttribute("data-ordinary","true")']:
                for expression in ['flag?('+effect+'):null', 'flag && ('+effect+')']:
                    self.syntax_privacy('const field=document.createElement("'+tag+'");'+initial+expression+';field.textContent="ordinary";',[])
        self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";flag?(field.type="text"):null;field.value="seed";',[(1,'unresolved DOM privacy binding')])

    def test_privacy_guarded_expression_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor='control_ranges.extend(expression_controls)'
        self.assertEqual(helper.count(anchor),1)
        directory=Path(self.temp.name)/'guarded-expression-inverse'/'tools';directory.mkdir(parents=True)
        (directory/'lint_nondet.py').write_text(scanner)
        # Remove only guarded expression ranges, restoring the unconditional
        # checkbox exemption while preserving statement control and metadata.
        (directory/'lint_privacy.py').write_text(helper.replace(anchor,'control_ranges.extend(())'))
        (directory/'test_lint_nondet.py').write_text(Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]','PROJECT = Path('+repr(str(PROJECT))+')',1))
        command=[sys.executable,str(directory/'test_lint_nondet.py'),'LintTests.test_privacy_guarded_expression_exact_finding','LintTests.test_privacy_nonfield_only_control','LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
        self.retain_inputs(command);result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr);self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: test_privacy_guarded_expression_exact_finding',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/privacy.js',result.stderr)
        self.assertIn('unresolved DOM privacy binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)


    def test_privacy_guarded_var_declaration_exact_finding(self):
        self.syntax_privacy('if(flag){var field=document.createElement("input");}else{var field=document.createElement("button");}field.value="privacy-test";',[(1,'unresolved DOM privacy binding')])

    def test_privacy_guarded_var_declaration_distinct_arm_pairs(self):
        unresolved='unresolved DOM privacy binding'
        for replacement in ['document.createElement("button")', '{}', 'null']:
            self.syntax_privacy('if(flag){var field=document.createElement("input");}else{var field='+replacement+';}field.value="seed";',[(1,unresolved)])
            self.syntax_privacy('if(flag){var field=document.createElement("input");}else{var field=document.createElement("input");var field='+replacement+';}field.value="seed";',[(1,unresolved)])
        self.syntax_privacy('if(flag){var field=document.createElement("input");}else if(other){var field=document.createElement("button");}else{var field={};}field.value="seed";',[(1,unresolved)])
        self.syntax_privacy('var field=document.createElement("input");if(flag){var field=document.createElement("button");}field.value="seed";',[(1,unresolved)])
        self.syntax_privacy('if(flag){var field=document.createElement("input");if(other){var field=document.createElement("button");}}field.value="seed";',[(1,unresolved)])

    def test_privacy_guarded_var_declaration_same_path_controls(self):
        for body in ['var field=document.createElement("input");var field=document.createElement("button");', 'var field=document.createElement("input");{var field=document.createElement("button");}', 'var field=document.createElement("input");if(other){var field=document.createElement("input");}var field=document.createElement("button");', 'var field=document.createElement("input");field=document.createElement("button");var field=document.createElement("button");']:
            self.syntax_privacy('if(flag){'+body+'field.value="control";}',[])
        self.syntax_privacy('if(flag){var field=document.createElement("input");}else{var field=document.createElement("button");}var field=document.createElement("button");field.value="control";',[])
        self.syntax_privacy('if(flag){var field=document.createElement("button");var field=document.createElement("input");field.value="seed";}',[(1,'free-text binding')])
        self.syntax_privacy('if(flag){var model={};}else{var model={};}model.value="ordinary";',[])

    def test_privacy_guarded_var_declaration_alias_and_loop_controls(self):
        self.syntax_privacy('let original;let replacement;if(flag){var field=document.createElement("input");original=field;}else{var field=document.createElement("button");replacement=field;}field.value="seed";',[(1,'unresolved DOM privacy binding')])
        self.syntax_privacy('var field=document.createElement("input");for(var field=document.createElement("button");false;){}field.value="control";',[])
        self.syntax_privacy('for(let i=0;i<1;i++){var field=document.createElement("style");field.id="ordinary";field.textContent="ordinary";}',[])
        self.syntax_privacy('if(flag){var field=document.createElement("input");}else{var field=document.createElement("button");}function later(){var field=document.createElement("button");field.value="control";}field.value="seed";',[(1,'unresolved DOM privacy binding')])

    def test_privacy_guarded_var_declaration_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor='allocation = join_binding(i, target, token.value, allocation, old)'
        self.assertEqual(helper.count(anchor),1)
        directory=Path(self.temp.name)/'guarded-var-declaration-inverse'/'tools';directory.mkdir(parents=True)
        (directory/'lint_nondet.py').write_text(scanner)
        # Restore last-visited declaration initialization only; expression and
        # ordinary assignment joins retain all their original behavior.
        (directory/'lint_privacy.py').write_text(helper.replace(anchor,'allocation = allocation'))
        (directory/'test_lint_nondet.py').write_text(Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]','PROJECT = Path('+repr(str(PROJECT))+')',1))
        command=[sys.executable,str(directory/'test_lint_nondet.py'),'LintTests.test_privacy_guarded_var_declaration_exact_finding','LintTests.test_privacy_nonfield_only_control','LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
        self.retain_inputs(command);result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr);self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: test_privacy_guarded_var_declaration_exact_finding',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/privacy.js',result.stderr)
        self.assertIn('unresolved DOM privacy binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)


    def test_privacy_abrupt_statement_exact_finding(self):
        self.syntax_privacy("for(let i=0;i<1;i++){var field=document.createElement('input');break;field.type='checkbox';}field.value='privacy-test';", [(1,'unresolved DOM privacy binding')])

    def test_privacy_optional_for_update_exact_finding(self):
        self.syntax_privacy("for(var field=document.createElement('input');false;field.type='checkbox'){}field.value='privacy-test';", [(1,'unresolved DOM privacy binding')])

    def test_privacy_abrupt_statement_metadata_and_alias_pairs(self):
        unresolved='unresolved DOM privacy binding'
        for jump in ['break;', 'continue;', 'if(flag)break;', 'if(flag)continue;']:
            for effect in ['field.type="checkbox";', 'field["type"]="checkbox";', 'field.setAttribute("type","checkbox");', 'const alias=field;alias.type="checkbox";']:
                self.syntax_privacy('for(let i=0;i<1;i++){var field=document.createElement("input");'+jump+effect+'}field.value="seed";',[(1,unresolved)])
            for effect in ['field={};', 'field=document.createElement("button");', 'var field=document.createElement("button");']:
                self.syntax_privacy('for(let i=0;i<1;i++){var field=document.createElement("input");'+jump+effect+'}field.value="seed";',[(1,unresolved)])
        self.syntax_privacy('for(let i=0;i<1;i++){var field=document.createElement("div");field.contentEditable="true";break;field.contentEditable="false";}field.textContent="seed";',[(1,unresolved)])

    def test_privacy_abrupt_statement_nested_and_label_pairs(self):
        unresolved='unresolved DOM privacy binding'
        for body in ['{break;}field.type="checkbox";', 'outer:{break outer;field.type="checkbox";}', 'outer:inner:{break outer;field.type="checkbox";}', 'outer:{inner:{break outer;field.type="checkbox";}}']:
            self.syntax_privacy('for(let i=0;i<1;i++){var field=document.createElement("input");'+body+'}field.value="seed";',[(1,unresolved)])
        self.syntax_privacy('outer:for(let i=0;i<1;i++){var field=document.createElement("input");for(let j=0;j<1;j++){continue outer;field.type="checkbox";}}field.value="seed";',[(1,unresolved)])
        self.syntax_privacy('for(let i=0;i<1;i++){for(let j=0;j<1;j++){break;}const field=document.createElement("input");field.type="checkbox";field.value="control";}',[])
        self.syntax_privacy('outer:{const field=document.createElement("input");break outer;field.type="checkbox";field.value="seed";}',[(1,unresolved)])

    def test_privacy_abrupt_statement_return_throw_pairs(self):
        unresolved='unresolved DOM privacy binding';raw='free-text binding'
        for jump in ['return;', 'throw error;', 'if(flag)return;', 'if(flag)throw error;']:
            self.syntax_privacy('function later(){const field=document.createElement("input");'+jump+'field.type="checkbox";field.value="seed";}',[(1,unresolved)])
        for jump in ['return field.value;', 'throw field.value;']:
            self.syntax_privacy('function later(){const field=document.createElement("input");'+jump+'}',[(1,raw)])
        self.syntax_privacy('function later(){const field=document.createElement("input");return (field.type="checkbox",field.value);}',[])
        self.syntax_privacy('function later(){const field=document.createElement("input");return\nfield.type="checkbox";field.value="seed";}',[(2,unresolved)])

    def test_privacy_abrupt_statement_caught_throw_recovery_controls(self):
        self.syntax_privacy("function f(){let field=document.createElement('input');try{throw 0;}catch{}field=document.createElement('input');field.type='checkbox';field.value='control';}",[])
        self.syntax_privacy("function f(){try{const field=document.createElement('input');throw field.value;}catch{}}",[(1,'free-text binding')])
        self.syntax_privacy("function f(){try{throw 0;}catch{throw error;const field=document.createElement('input');field.type='checkbox';field.value='seed';}}",[(1,'unresolved DOM privacy binding')])
        self.syntax_privacy("function f(){try{try{throw 0;}catch{throw error;}}catch{}const field=document.createElement('input');field.type='checkbox';field.value='control';}",[])

    def test_privacy_abrupt_statement_syntax_and_deferred_controls(self):
        for key in ['break', 'continue', 'return', 'throw']:
            self.syntax_privacy('const field=document.createElement("input");const object={'+key+'(){return 1;}};field.type="checkbox";field.value="control";',[])
            self.syntax_privacy('const field=document.createElement("input");class Model{'+key+'(){throw error;}}field.type="checkbox";field.value="control";',[])
            self.syntax_privacy('const field=document.createElement("input");const object={'+key+':1};field.type="checkbox";field.value="control";',[])
        self.syntax_privacy('const field=document.createElement("input");function later(){return;field.type="text";}field.type="checkbox";field.value="control";',[])
        self.syntax_privacy('const field=document.createElement("input");class Model{saved=(()=>{return;field.type="text";})();static{field.type="checkbox";}}field.value="control";',[])

    def test_privacy_abrupt_statement_recovery_and_nonprivacy_controls(self):
        for tag in ['style', 'script', 'button']:
            for effect in ['field.id="ordinary";', 'field.setAttribute("data-ordinary","true");']:
                self.syntax_privacy('for(let i=0;i<1;i++){var field=document.createElement("'+tag+'");break;'+effect+'}field.textContent="ordinary";',[])
        self.syntax_privacy('for(let i=0;i<1;i++){var field=document.createElement("input");break;field.type="checkbox";}field=document.createElement("input");field.type="checkbox";field.value="control";',[])
        self.syntax_privacy('for(let i=0;i<1;i++){var field=document.createElement("input");field.type="checkbox";break;}field.value="control";',[])
        self.syntax_privacy('function later(){return;const field=document.createElement("button");field.value="control";}',[])

    def test_privacy_optional_for_update_metadata_and_timing_pairs(self):
        unresolved='unresolved DOM privacy binding'
        for effect in ['field.type="checkbox"', 'field.setAttribute("type","checkbox")', 'field=document.createElement("button")']:
            self.syntax_privacy('for(var field=document.createElement("input");false;'+effect+'){}field.value="seed";',[(1,unresolved)])
        self.syntax_privacy('for(var field=document.createElement("input"),unused=(field.type="checkbox");false;){}field.value="control";',[])
        self.syntax_privacy('for(var field=document.createElement("input");field.type="checkbox";){}field.value="control";',[])
        self.syntax_privacy('for(var field=document.createElement("input");false;field.type==="checkbox"){}field.value="seed";',[(1,'free-text binding')])
        self.syntax_privacy('for(let i=0;i<1;i++){const field=document.createElement("input");field.type="checkbox";field.value="control";}',[])
        self.syntax_privacy('for(var field=document.createElement("style");false;field.id="ordinary"){}field.textContent="ordinary";',[])

    def test_privacy_abrupt_statement_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor='if after < end: abrupt_ranges.append((after, end, routine))'
        self.assertEqual(helper.count(anchor),1)
        directory=Path(self.temp.name)/'abrupt_statement-inverse'/'tools';directory.mkdir(parents=True)
        (directory/'lint_nondet.py').write_text(scanner)
        (directory/'lint_privacy.py').write_text(helper.replace(anchor,'if False: abrupt_ranges.append((after, end, routine))'))
        (directory/'test_lint_nondet.py').write_text(Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]','PROJECT = Path('+repr(str(PROJECT))+')',1))
        command=[sys.executable,str(directory/'test_lint_nondet.py'),'LintTests.test_privacy_abrupt_statement_exact_finding','LintTests.test_privacy_nonfield_only_control','LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
        self.retain_inputs(command);result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr);self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: test_privacy_abrupt_statement_exact_finding',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/privacy.js',result.stderr)
        self.assertIn('unresolved DOM privacy binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)

    def test_privacy_optional_for_update_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor='if len(separators) == 2 and separators[1]+1 < pairs[header]:'
        self.assertEqual(helper.count(anchor),1)
        directory=Path(self.temp.name)/'optional_for_update-inverse'/'tools';directory.mkdir(parents=True)
        (directory/'lint_nondet.py').write_text(scanner)
        (directory/'lint_privacy.py').write_text(helper.replace(anchor,'if False and len(separators) == 2:'))
        (directory/'test_lint_nondet.py').write_text(Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]','PROJECT = Path('+repr(str(PROJECT))+')',1))
        command=[sys.executable,str(directory/'test_lint_nondet.py'),'LintTests.test_privacy_optional_for_update_exact_finding','LintTests.test_privacy_nonfield_only_control','LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
        self.retain_inputs(command);result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr);self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: test_privacy_optional_for_update_exact_finding',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/privacy.js',result.stderr)
        self.assertIn('unresolved DOM privacy binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)


    def test_privacy_statement_comma_control_exact_finding(self):
        self.syntax_privacy("let field=document.createElement('input');if(flag)0,field=document.createElement('button');field.value='privacy-test';", [(1,'unresolved DOM privacy binding')])

    def test_privacy_statement_comma_return_throw_order_pairs(self):
        for keyword in ['return', 'throw']:
            for grouped in [False, True]:
                for expression, expected in [
                    ('0,field.type="checkbox",field.value', []),
                    ('0,field.value,field.type="checkbox"', [(1,'free-text binding')]),
                    ('field.type="checkbox",0,field.value', []),
                    ('field.value,0,field.type="checkbox"', [(1,'free-text binding')]),
                ]:
                    operand='('+expression+')' if grouped else expression
                    self.syntax_privacy('function f(){const field=document.createElement("input");'+keyword+' '+operand+';}',expected)

    def test_privacy_statement_comma_multiline_and_restricted_pairs(self):
        for keyword in ['return', 'throw']:
            self.syntax_privacy('function f(){const field=document.createElement("input");'+keyword+' 0,\nfield.type="checkbox",\nfield.value;}',[])
            self.syntax_privacy('function f(){const field=document.createElement("input");'+keyword+' 0,\nfield.value,\nfield.type="checkbox";}',[(2,'free-text binding')])
            self.syntax_privacy('function f(){const field=document.createElement("input");'+keyword+' field.type==="checkbox",\nfield.value;}',[(2,'free-text binding')])
            self.syntax_privacy('function f(){const field=document.createElement("input");'+keyword+' 0,field.type="checkbox"\nfield.value;}',[])
        self.syntax_privacy('function f(){const field=document.createElement("input");return\n0,field.type="checkbox",field.value;}',[(2,'unresolved DOM privacy binding')])
        self.syntax_privacy('function f(){const field=document.createElement("input");return /* newline\n */ 0,field.type="checkbox",field.value;}',[(2,'unresolved DOM privacy binding')])

    def test_privacy_statement_comma_braceless_control_pairs(self):
        unresolved='unresolved DOM privacy binding'
        for header in ['if(flag)', 'while(flag)', 'for(;flag;)', 'for(const item of items)']:
            for grouped in [False,True]:
                for effect in ['field=document.createElement("button")', 'field.type="checkbox"', 'alias.type="checkbox"']:
                    body='0,'+effect
                    if grouped:body='('+body+')'
                    self.syntax_privacy('let field=document.createElement("input");const alias=field;'+header+body+';field.value="seed";',[(1,unresolved)])
        self.syntax_privacy('let field=document.createElement("input");if(flag)0,field=document.createElement("button");else 0,field.type="checkbox";field.value="seed";',[(1,unresolved)])
        self.syntax_privacy('let field=document.createElement("input");if(flag)0,field=document.createElement("button")\nfield.value="seed";',[(2,unresolved)])

    def test_privacy_statement_comma_component_boundaries_and_recovery(self):
        self.syntax_privacy('const field=document.createElement("input"),other=document.createElement("input");field.type="checkbox";other.value="seed";',[(1,'free-text binding')])
        self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";const model={};consume(model,field);field.value="seed";',[(1,'unresolved DOM privacy binding')])
        self.syntax_privacy('let field=document.createElement("input");if(flag)0,field=document.createElement("button");field=document.createElement("input");field.type="checkbox";field.value="control";',[])
        self.syntax_privacy('const model={};if(flag)0,model.value="ordinary";model.textContent="ordinary";',[])
        self.syntax_privacy('const field=document.createElement("input");0,field.type="checkbox",field.value;',[])
        self.syntax_privacy('const field=document.createElement("input");0,field.value,field.type="checkbox";',[(1,'free-text binding')])

    def test_privacy_statement_comma_throw_handler_extent(self):
        self.syntax_privacy('let field=document.createElement("input");try{throw 0,field.type="checkbox",field.value;}catch{}field=document.createElement("input");field.type="checkbox";field.value="control";',[(1,'unresolved DOM privacy binding')])

    def test_privacy_statement_comma_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor='end = expression_end(start, sequence=True)'
        self.assertEqual(helper.count(anchor),1)
        directory=Path(self.temp.name)/'statement-comma-inverse'/'tools';directory.mkdir(parents=True)
        (directory/'lint_nondet.py').write_text(scanner)
        (directory/'lint_privacy.py').write_text(helper.replace(anchor,'end = expression_end(start)'))
        (directory/'test_lint_nondet.py').write_text(Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]','PROJECT = Path('+repr(str(PROJECT))+')',1))
        command=[sys.executable,str(directory/'test_lint_nondet.py'),'LintTests.test_privacy_statement_comma_control_exact_finding','LintTests.test_privacy_nonfield_only_control','LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
        self.retain_inputs(command);result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr);self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: test_privacy_statement_comma_control_exact_finding',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/privacy.js',result.stderr)
        self.assertIn('unresolved DOM privacy binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)


    def test_privacy_grouped_alias_exact_finding(self):
        self.syntax_privacy('const field=document.createElement("input");const alias=(field);alias.value="privacy-test";',[(1,'free-text binding')])

    def test_privacy_grouped_primary_compositions(self):
        for receiver in ['field','(field)','((field))']:
            for expression in ['field','(field)','((field))']:
                self.syntax_privacy('const field=document.createElement("input");const alias='+expression+';'+receiver+'.value="seed";alias.value="seed";',[(1,'free-text binding'),(1,'free-text binding')])
        for constructor in ['document.createElement("input")','(document.createElement("input"))','((document.createElement("input")))','(document).createElement("input")','((document)).createElement("input")']:
            self.syntax_privacy('const field='+constructor+';field.value="seed";',[(1,'free-text binding')])
        self.syntax_privacy('const field=(document.createTextNode("label"));(field).textContent="ordinary";',[])

    def test_privacy_grouped_receiver_exact_finding(self):
        self.syntax_privacy('const field=document.createElement("input");(field).value="privacy-test";',[(1,'free-text binding')])

    def test_privacy_optional_bracket_exact_finding(self):
        self.syntax_privacy('const field=document.createElement("input");const value=field?.["value"];',[(1,'free-text binding')])

    def test_privacy_grouped_mutations_and_optional_members(self):
        for receiver in ['(field)','((field))']:
            for member in ['.type','["type"]']:
                self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";'+receiver+member+'="text";field.value="seed";',[(1,'free-text binding')])
            self.syntax_privacy('let field=document.createElement("input");field.type="checkbox";'+receiver+'=(document.createElement("input"));field.value="seed";',[(1,'free-text binding')])
            self.syntax_privacy('let field=document.createElement("input");const alias=field;'+receiver+'={};field.value="ordinary";alias.value="seed";',[(1,'free-text binding')])
            self.syntax_privacy('const field=document.createElement("input");'+receiver+'.setAttribute("type","checkbox");'+receiver+'.value="control";',[])
            self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";'+receiver+'.removeAttribute("type");field.value="seed";',[(1,'free-text binding')])
            self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";const value='+receiver+'?.["value"];',[])
            self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";const value='+receiver+'?.[dynamic];',[(1,'unresolved DOM privacy binding')])
        self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";const alias=((field));alias.type="text";field.value="seed";',[(1,'free-text binding')])

    def test_privacy_grouped_prefix_delete_and_model_replacement(self):
        for effect in ['++(field).type', '--((field))["type"]', 'delete (field).type']:
            self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";'+effect+';field.value="seed";',[(1,'unresolved DOM privacy binding' if effect.startswith('delete') else 'free-text binding')])
        for model in ['{}','({})','(({}))']:
            self.syntax_privacy('let field=document.createElement("input");field='+model+';field.value="ordinary";',[])
        for receiver in ['model.field','(model.field)','model?.field','model["field"]']:
            self.syntax_privacy('const field=document.createElement("input");const model={};const value='+receiver+'.value;',[])

    def test_privacy_grouped_nonidentity_controls(self):
        for expression in ['factory(field)','factory((field))','(factory(field))','(0,field)','(flag?field:field)','({value:field})','[field]']:
            self.syntax_privacy('const field=document.createElement("input");const model='+expression+';model.value="ordinary";',[])
        for expression in ['factory(field)','factory((field))','(factory(field))']:
            self.syntax_privacy('const field=document.createElement("input");'+expression+'.value="ordinary";',[])
        self.syntax_privacy('const field=document.createElement("input");function f(field){(field).value="ordinary";}',[])
        self.syntax_privacy('const document={};const field=((document).createElement("input"));(field).value="ordinary";',[])
        self.syntax_privacy('const model={};const alias=((model));(alias).value="ordinary";',[])
        self.syntax_privacy('const field=document.createElement("input");field.type="checkbox";if(field){}for(;field;)break;field.value="control";',[(1,'unresolved DOM privacy binding')])

    def test_privacy_grouped_physical_lines_and_opaque_splices(self):
        self.syntax_privacy('const field=(document.createElement("input"));\nconst alias=(\nfield\n);\n(\nalias\n).value="seed";',[(6,'free-text binding')])
        self.write('privacy.js','')
        self.assert_privacy('{.emit: """\nconst field=(document.createElement("input"));\nconst alias=(field);\n(alias)?.["value"];\n""".}',[(4,'free-text binding')],'privacy.nim')
        self.assert_privacy('{.emit: ["const field=document.createElement(\"input\"); const alias=(", first, "); alias.value=1; (", second, ").value=2;"].}',[],'privacy.nim')

    def test_privacy_primary_identity_production_inverses(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        variants=[
            ('group-alias','if allocation is None: allocation = local_identity(i+2, scope)','if False: allocation = local_identity(i+2, scope)','test_privacy_grouped_alias_exact_finding'),
            ('group-member','_first, after = primary_span(i)','_first, after = i, i+1','test_privacy_grouped_receiver_exact_finding'),
            ('optional-bracket',"if v(after) == '?.' and v(after+1) == '[': after += 1",'if False: after += 1','test_privacy_optional_bracket_exact_finding'),
        ]
        for name,anchor,replacement,failing in variants:
            with self.subTest(mutation=name):
                self.assertEqual(helper.count(anchor),1)
                directory=Path(self.temp.name)/name/'tools';directory.mkdir(parents=True)
                (directory/'lint_nondet.py').write_text(scanner)
                (directory/'lint_privacy.py').write_text(helper.replace(anchor,replacement))
                (directory/'test_lint_nondet.py').write_text(Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]','PROJECT = Path('+repr(str(PROJECT))+')',1))
                command=[sys.executable,str(directory/'test_lint_nondet.py'),'LintTests.'+failing,'LintTests.test_privacy_nonfield_only_control','LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
                self.retain_inputs(command);result=subprocess.run(command,capture_output=True,text=True)
                (directory/'inverse.log').write_text(result.stdout+result.stderr);self.retain_inputs(command)
                self.assertEqual(result.returncode,1,result.stdout+result.stderr)
                self.assertIn('FAIL: '+failing,result.stderr)
                self.assertIn('AssertionError: Lists differ',result.stderr)
                self.assertIn('site/src/privacy.js',result.stderr)
                self.assertIn('free-text binding',result.stderr)
                self.assertIn('FAILED (failures=1)',result.stderr)
                self.assertNotIn('ERROR:',result.stderr)


    def test_privacy_grouped_whole_member_assignment_exact(self):
        self.syntax_privacy('const field=document.createElement("input");\nfield.type="checkbox";\n(field.type)="text";\nfield.value="privacy-test";',[(4,'free-text binding')])

    def test_privacy_grouped_whole_member_delete_exact(self):
        self.syntax_privacy('const field=document.createElement("input");\nfield.type="checkbox";\ndelete (field.type);\nfield.value="privacy-test";',[(4,'unresolved DOM privacy binding')])

    def test_privacy_grouped_whole_member_operator_pairs(self):
        base='const field=document.createElement("input");\nfield.type="checkbox";\n'
        for member in ['(field.type)','((field["type"]))','(((field).type))','(((field))["type"])']:
            for operator in ['=','+=','-=','*=','/=','%=','**=','<<=','>>=','>>>=','&=','|=','^=','&&=','||=','??=']:
                self.syntax_privacy(base+member+operator+'"text";\nfield.value="seed";',[(4,'free-text binding')])
            for update in ['++'+member,'--'+member,member+'++',member+'--']:
                self.syntax_privacy(base+update+';\nfield.value="seed";',[(4,'free-text binding')])
            self.syntax_privacy(base+'delete '+member+';\nfield.value="seed";',[(4,'unresolved DOM privacy binding')])
            self.syntax_privacy(base+member+'="checkbox";\nfield.value="control";',[])
        for member in ['(field.title)','((field["id"]))']:
            self.syntax_privacy(base+member+'="label";\nfield.value="control";',[])
        self.syntax_privacy(base+'(field.type).label="ordinary";\nfield.value="control";',[])

    def test_privacy_grouped_whole_member_known_methods(self):
        base='const field=document.createElement("input");\nfield.type="checkbox";\n'
        for method in ['(field.setAttribute)','((field["setAttribute"]))','(((field).setAttribute))']:
            self.syntax_privacy(base+method+'("type","text");\nfield.value="seed";',[(4,'free-text binding')])
            self.syntax_privacy(base+method+'("type","checkbox");\nfield.value="control";',[])
            self.syntax_privacy(base+method+'("title","label");\nfield.value="control";',[])
        for method in ['(field.removeAttribute)','((field["removeAttribute"]))']:
            self.syntax_privacy(base+method+'("type");\nfield.value="seed";',[(4,'free-text binding')])
        self.syntax_privacy('const field=document.createElement("input");\n(field.setAttribute)("value","seed");',[(2,'free-text binding')])

    def test_privacy_grouped_whole_member_alias_control_and_nonfields(self):
        self.syntax_privacy('const old=document.createElement("input");\nold.type="checkbox";\nconst replacement=document.createElement("input");\nreplacement.type="checkbox";\nlet field=old;\nfield=flag?old:replacement;\ndelete ((field.type));\nold.value="seed";\nreplacement.value="seed";',[(8,'unresolved DOM privacy binding'),(9,'unresolved DOM privacy binding')])
        base='const field=document.createElement("input");\nfield.type="checkbox";\nconst alias=field;\n'
        self.syntax_privacy(base+'((alias.type))="text";\nfield.value="seed";',[(5,'free-text binding')])
        self.syntax_privacy(base+'if(flag)((alias.type))="text";\nfield.value="seed";',[(5,'unresolved DOM privacy binding')])
        self.syntax_privacy(base+'function later(){((alias.type))="text";}\nfield.value="control";',[])
        self.syntax_privacy(base+'factory(field).type="text";\nfield.value="seed";',[(5,'unresolved DOM privacy binding')])
        for source in ['const field={};(field.type)="text";(field.value)="ordinary";',
                       'const field=document.createElement("button");(field.title)="label";(field.textContent)="ordinary";',
                       'const field=document.createTextNode("");(field.textContent)="ordinary";',
                       'const field=document.createElement("input");factory((field)).value="ordinary";',
                       'const field=document.createElement("input");function later(field){(field.value)="ordinary";}']:
            self.syntax_privacy(source,[])

    def test_privacy_grouped_whole_member_reads_and_lines(self):
        for member in ['(field.value)','((field["value"]))','(field?.value)','((field?.["value"]))']:
            self.syntax_privacy('const field=document.createElement("input");\nconst raw='+member+';',[(2,'free-text binding')])
            self.syntax_privacy('const field=document.createElement("input");\nfield.type="checkbox";\nconst control='+member+';',[])
        self.syntax_privacy('const field=document.createElement("input");\nfield.type="checkbox";\n(\n(field["type"])\n)="text";\n(\nfield\n.value)="seed";',[(7,'free-text binding')])
        self.write('privacy.js','')
        self.assert_privacy('{.emit: """\nconst field=document.createElement("input");\nfield.type="checkbox";\n((field.type))="text";\n(field.value)="seed";\n""".}',[(5,'free-text binding')],'privacy.nim')
        self.assert_privacy(r'{.emit: ["const field=document.createElement(\"input\"); field.type=\"checkbox\"; (", receiver, ").type=\"text\"; field.value=1;"].}',[(1,'unresolved DOM privacy binding')],'privacy.nim')

    def test_privacy_grouped_whole_member_production_inverses(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        variants=[
            ('nonprivacy-delete', "v(member_left-1) == 'delete' and metadata_relevant(allocation, name)", "v(member_left-1) == 'delete'", 'test_privacy_grouped_nonprivacy_delete_exact_control', 'unresolved DOM privacy binding'),
            ('constructor-member', 'method_left, call = grouped_reference(start, m[1])', 'method_left, call = start, m[1]', 'test_privacy_grouped_constructor_member_exact', 'free-text binding'),
            ('member-end','member_left, after = grouped_reference(left, after)','member_left = left','test_privacy_grouped_whole_member_assignment_exact','free-text binding'),
            ('member-delete',"if (v(member_left-1) == 'delete' and metadata_relevant(allocation, name)) or (name is None and (write_after(after) or prefix_before(member_left))):",'if name is None and (write_after(after) or prefix_before(member_left)):','test_privacy_grouped_whole_member_delete_exact','unresolved DOM privacy binding'),
        ]
        for name,anchor,replacement,failing,diagnostic in variants:
            with self.subTest(mutation=name):
                self.assertEqual(helper.count(anchor),1)
                directory=Path(self.temp.name)/name/'tools';directory.mkdir(parents=True)
                (directory/'lint_nondet.py').write_text(scanner)
                (directory/'lint_privacy.py').write_text(helper.replace(anchor,replacement))
                (directory/'test_lint_nondet.py').write_text(Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]','PROJECT = Path('+repr(str(PROJECT))+')',1))
                command=[sys.executable,str(directory/'test_lint_nondet.py'),'LintTests.'+failing,'LintTests.test_privacy_nonfield_only_control','LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
                self.retain_inputs(command);result=subprocess.run(command,capture_output=True,text=True)
                (directory/'inverse.log').write_text(result.stdout+result.stderr);self.retain_inputs(command)
                self.assertEqual(result.returncode,1,result.stdout+result.stderr)
                self.assertIn('FAIL: '+failing,result.stderr)
                self.assertIn('AssertionError: Lists differ',result.stderr)
                self.assertIn('site/src/privacy.js',result.stderr)
                self.assertIn(diagnostic,result.stderr)
                self.assertIn('FAILED (failures=1)',result.stderr)
                self.assertNotIn('ERROR:',result.stderr)


    def test_privacy_grouped_constructor_member_exact(self):
        self.syntax_privacy('const field=(document.createElement)("input");\nfield.value="privacy-test";',[(2,'free-text binding')])

    def test_privacy_grouped_constructor_member_pairs(self):
        for expression in ['(document.createElement)("input")','((document["createElement"]))("input")','((document).createElement)("input")','(((document)["createElement"]))("input")']:
            self.syntax_privacy('const field='+expression+';\nfield.value="seed";',[(2,'free-text binding')])
            self.syntax_privacy('const field='+expression+';\n(field.type)="checkbox";\nfield.value="control";',[])
        for expression in ['(document.createTextNode)("label")','(document.createElement)("button")','factory(document).createElement("input")','(factory(document).createElement)("input")','(model.createElement)("input")']:
            self.syntax_privacy('const field='+expression+';\nfield.value="ordinary";',[])
        self.syntax_privacy('const document={};const field=(document.createElement)("input");field.value="ordinary";',[])


    def test_privacy_grouped_nonprivacy_delete_exact_control(self):
        self.syntax_privacy('const field=document.createElement("input");\nfield.type="checkbox";\ndelete (field.title);\nfield.value="control";',[])
        for member in ['field.id','((field["title"]))','((field)["className"])']:
            self.syntax_privacy('const field=document.createElement("input");\nfield.type="checkbox";\ndelete '+member+';\nfield.value="control";',[])


    def test_privacy_possible_alias_unrelated_metadata_exact(self):
        self.syntax_privacy('const old=document.createElement("input");\nold.type="checkbox";\nconst replacement=document.createElement("input");\nreplacement.type="checkbox";\nlet field=old;\nfield=flag?old:replacement;\nfield.id="ordinary";\nold.value="ordinary";\nreplacement.value="ordinary";',[])

    def test_privacy_possible_alias_unrelated_operator_and_attribute_pairs(self):
        base='const old=document.createElement("input");\nold.type="checkbox";\nconst replacement=document.createElement("input");\nreplacement.type="checkbox";\nlet field=old;\nfield=flag?old:replacement;\n'
        tail='\nold.value="ordinary";\nreplacement.value="ordinary";'
        for member in ['field.id','((field.id))','field["title"]','((field)["title"])']:
            for operator in ['=','+=','-=','*=','/=','%=','**=','<<=','>>=','>>>=','&=','|=','^=','&&=','||=','??=']:
                with self.subTest(member=member,operator=operator):
                    self.syntax_privacy(base+member+operator+'2;'+tail,[])
            for update in [member+'++',member+'--','++'+member,'--'+member,'delete '+member]:
                with self.subTest(update=update):
                    self.syntax_privacy(base+update+';'+tail,[])
        for operation in ['field.setAttribute("id","ordinary")','((field["setAttribute"]))("TITLE","ordinary")','flag&&(field["title"]+=1)']:
            with self.subTest(operation=operation):
                self.syntax_privacy(base+operation+';'+tail,[])

    def test_privacy_possible_alias_relevant_unknown_and_deferred_pairs(self):
        base='const old=document.createElement("input");\nold.type="checkbox";\nconst replacement=document.createElement("input");\nreplacement.type="checkbox";\nlet field=old;\nfield=flag?old:replacement;\n'
        tail='\nold.value="ordinary";\nreplacement.value="ordinary";'
        unresolved=[(8,'unresolved DOM privacy binding'),(9,'unresolved DOM privacy binding')]
        for operation in ['field.type="text"','((field["type"]))="text"','field.type++','field.setAttribute("TYPE","text")','field.autocomplete="current-password"','field.setAttribute("AUTOCOMPLETE","one-time-code")','field.contentEditable="true"','field.setAttribute("contenteditable","true")','field.setAttribute(name,"ordinary")','delete ((field.type))','if(flag)field.type="text"']:
            with self.subTest(operation=operation):
                self.syntax_privacy(base+operation+';'+tail,unresolved)
        # A computed member is itself unresolved as well as invalidating the
        # possible input objects. Keep its exact additional physical-line row.
        self.syntax_privacy(base+'field[name]="ordinary";'+tail,[(7,'unresolved DOM privacy binding')]+unresolved)
        # A statement control boundary itself loses visible metadata certainty.
        # Its empty-body control must match the unrelated-write body exactly.
        self.syntax_privacy(base+'if(flag)0;'+tail,unresolved)
        self.syntax_privacy(base+'if(flag)field.id="ordinary";'+tail,unresolved)
        self.syntax_privacy(base+'function later(){field.type="text";}'+tail,[])
        self.syntax_privacy(base+'function later(){field.id="ordinary";}'+tail,[])
        self.syntax_privacy('const old={};const replacement={};let field=old;field=flag?old:replacement;field.type="text";field.id="ordinary";old.value="ordinary";replacement.value="ordinary";',[])
        self.syntax_privacy('const old=document.createElement("input");\nold.type="checkbox";\nconst alias=old;\nalias.id="ordinary";\nold.value="ordinary";',[])

    def test_privacy_possible_alias_relevance_order_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor='    if not relevant: return\n    for possible in allocation.possible_aliases:\n        invalidate(possible)'
        replacement='    for possible in allocation.possible_aliases:\n        invalidate(possible)\n    if not relevant: return'
        self.assertEqual(helper.count(anchor),1)
        directory=Path(self.temp.name)/'alias-relevance-order'/'tools';directory.mkdir(parents=True)
        (directory/'lint_nondet.py').write_text(scanner)
        (directory/'lint_privacy.py').write_text(helper.replace(anchor,replacement))
        (directory/'test_lint_nondet.py').write_text(Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]','PROJECT = Path('+repr(str(PROJECT))+')',1))
        failing='test_privacy_possible_alias_unrelated_metadata_exact'
        command=[sys.executable,str(directory/'test_lint_nondet.py'),'LintTests.'+failing,'LintTests.test_privacy_nonfield_only_control','LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
        self.retain_inputs(command);result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr);self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: '+failing,result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/privacy.js',result.stderr)
        self.assertIn('unresolved DOM privacy binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)

if __name__ == '__main__':
    unittest.main()
