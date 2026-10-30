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

class NimPrivacyTests(unittest.TestCase):
    # Real source input, CLI, Git and stock compiler; no mock DOM or scanner.
    setUp = LintTests.setUp
    write = LintTests.write
    retain_inputs = LintTests.retain_inputs
    cli = LintTests.cli

    def check(self, source, expected, name='ordinary.nim'):
        path = self.write(name, source)
        result = self.cli()
        self.assertEqual(json.loads(result.stdout), [dict(path='site/src/'+name,
                         line=line, api=api, severity='error') for line, api in expected])
        self.assertEqual(result.returncode, 1 if expected else 0, result.stderr)
        path.unlink()

    def compile(self, path):
        command = ['nim', 'js', '--hints:off', '--path:'+str(PROJECT/'src'),
                   '--path:'+str(PROJECT.parent/'nim-everywhere/src'),
                   '--nimcache:'+str(Path(self.temp.name)/'cache'),
                   '--out:'+str(Path(self.temp.name)/'component.js'), str(path)]
        self.retain_inputs(command)
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)

    def test_nim_compiled_raw_component_removal_and_public_dsl(self):
        path = self.write('ordinary.nim', '''import isonim/web/dom_api
proc rawComponent(initial: cstring): Element =
  let field = dom_api.createElement(dom_api.document, "input")
  dom_api.setJsPropCstring(field, "value", initial)
  result = field
discard rawComponent("seed")
''')
        self.compile(path)
        result = self.cli()
        self.assertEqual(json.loads(result.stdout), [dict(path='site/src/ordinary.nim',
                         line=4, api='free-text binding', severity='error')])
        self.assertEqual(result.returncode, 1, result.stderr)
        path.unlink()
        result = self.cli()
        self.assertEqual(json.loads(result.stdout), [])
        self.assertEqual(result.returncode, 0, result.stderr)
        path.write_text('''import isonim/web/web_renderer
import isonim/web/dom_api
import isonim/rxcore
import isonim/dsl/ui
proc publicComponent(r: WebRenderer): Element =
  ui(r):
    input(`type` = "text", public = true, value = "seed")
discard publicComponent(WebRenderer())
''')
        self.compile(path)
        result = self.cli()
        self.assertEqual(json.loads(result.stdout), [])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_nim_compiled_inherited_text_content(self):
        source = '''import isonim/web/dom_api
proc rawText(initial: cstring): Element =
  let field = dom_api.createElement(dom_api.document, "textarea")
  field.textContent = initial
  result = field
discard rawText("seed")
'''
        path = self.write('ordinary.nim', source)
        self.compile(path)
        result = self.cli()
        self.assertEqual(json.loads(result.stdout), [dict(path='site/src/ordinary.nim',
                         line=4, api='free-text binding', severity='error')])
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_nim_field_policy_exact_table(self):
        cases = [('input', '', 'free-text binding'),
                 *[('input', 'dom_api.setAttribute(field, "type", "'+t+'")\n', 'free-text binding')
                   for t in ['text','search','email','tel','url','password']],
                 ('textarea', '', 'free-text binding'),
                 ('input', 'dom_api.setAttribute(field, "type", dynamicType)\n', 'free-text binding'),
                 ('div', 'dom_api.setAttribute(field, "contenteditable", "true")\n', 'free-text binding'),
                 ('div', 'dom_api.setAttribute(field, "contenteditable", "plaintext-only")\n', 'free-text binding'),
                 ('input', 'dom_api.setAttribute(field, "autocomplete", "section-login current-password")\n', 'free-text binding'),
                 ('input', 'dom_api.setAttribute(field, "autocomplete", "cc-number")\n', 'free-text binding'),
                 ('input', 'dom_api.setAttribute(field, "type", "checkbox")\n', None),
                 ('input', 'dom_api.setAttribute(field, "type", "button")\n', None),
                 ('div', 'dom_api.setAttribute(field, "contenteditable", "false")\n', None),
                 ('label', '', None)]
        for tag, metadata, api in cases:
            with self.subTest(tag=tag, metadata=metadata):
                source = ('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "'+tag+'")\n'+
                          metadata+'dom_api.setJsPropCstring(field, "value", "seed")\n')
                self.check(source, [(source.count('\n'), api)] if api else [])

    def test_nim_alias_transition_order_and_recovery(self):
        self.check('''import isonim/web/dom_api
var field = dom_api.createElement(dom_api.document, "input")
let alias = field
dom_api.setAttribute(alias, "type", "checkbox")
dom_api.setJsPropCstring(field, "value", "ok")
dom_api.setAttribute(alias, "type", "text")
dom_api.setJsPropCstring(field, "value", "seed")
field = dom_api.createElement(dom_api.document, "button")
dom_api.setJsPropCstring(field, "value", "ok")
dom_api.setJsPropCstring(alias, "value", "seed")
''', [(7,'free-text binding'),(10,'free-text binding')])

    def test_nim_literal_contents_are_never_structure(self):
        for value in ['(', ')', '[', ']', '{', '}', ':', '=', '.', ',', ';', 'if', 'proc', 'import', 'as']:
            with self.subTest(value=value):
                self.check('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "input")\n'+
                           'dom_api.setAttribute(field, "id", '+json.dumps(value)+')\n'+
                           'dom_api.setJsPropCstring(field, "value", '+json.dumps(value)+')\n', [(4,'free-text binding')])
        self.check('''import isonim/web/dom_api
#[ outer #[ dom_api.setJsPropCstring(field, "value", "seed") ]# ]#
let prose = "dom_api.createElement(document, input)"
let field = dom_api.createElement(dom_api.document, """input""")
dom_api.setAttribute(field, "title", """
if: ( ) = ;
  import pretend/dom_api
""")
dom_api.setJsPropCstring(
  field, "value", "seed")
''', [(10,'free-text binding')])

    def test_nim_literal_decoding_and_generalized_macro_bounds(self):
        for tag in ['"in\\x70ut"', 'r"input"', '"""input"""']:
            with self.subTest(tag=tag):
                self.check('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, '+tag+')\n'+
                           'dom_api.setJsPropCstring(field, "val\\x75e", "seed")\n', [(3,'free-text binding')])
        self.check('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, custom"input")
dom_api.setJsPropCstring(field, "value", "seed")
''', [(3,'unresolved DOM privacy binding')])

    def test_nim_import_alias_style_ufcs_and_upcast(self):
        sources = [
            ('import isonim/web/dom_api as browser', 'browser.create_Element(browser.document, "input")', 'browser.set_Js_Prop_Cstring(field, "value", "seed")'),
            ('import isonim/web/[dom_api]', 'document.createElement("input")', 'field.setJsPropCstring("value", "seed")'),
            ('import isonim/web/dom_api', 'createElement(document, "input")', 'setJsPropCstring(Node(field), "value", "seed")')]
        for imp, allocation, access in sources:
            with self.subTest(imp=imp): self.check(imp+'\nlet field = '+allocation+'\n'+access+'\n', [(3,'free-text binding')])

    def test_nim_compiled_shadowed_module_and_model(self):
        source = '''import isonim/web/dom_api as browser
type Model = object
  value: string
  textContent: string
  document: int
proc createElement(model: Model, d: int, tag: string): Model = model
proc setJsPropCstring(model: Model, field: Model, name, value: string) = discard
proc modelComponent() =
  var browser = Model(value: "seed", textContent: "label", document: 1)
  let field = browser.createElement(browser.document, "input")
  browser.setJsPropCstring(field, "value", "ordinary")
  browser.value = "ordinary"
  browser.textContent = "ordinary"
modelComponent()
'''
        path = self.write('ordinary.nim',source);self.compile(path)
        result = self.cli()
        self.assertEqual(json.loads(result.stdout), [])
        self.assertEqual(result.returncode,0,result.stderr)
        path.unlink()
        self.check('''import isonim/web/dom_api as browser
block:
  let browser = ordinaryModel
  let field = browser.createElement(browser.document, "input")
  browser.setJsPropCstring(field, "value", "ordinary")
let field = browser.createElement(browser.document, "input")
browser.setJsPropCstring(field, "value", "seed")
''',[(7,'free-text binding')])

    def test_nim_first_character_and_sequential_shadowing(self):
        self.check('''import isonim/web/dom_api
let before = dom_api.createElement(dom_api.document, "input")
dom_api.setJsPropCstring(before, "value", "seed")
let dom_api = ordinaryModel
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setJsPropCstring(field, "value", "ordinary")
''',[(3,'free-text binding')])
        self.check('''import isonim/web/dom_api
let field = Dom_api.createElement(Dom_api.document, "input")
Dom_api.setJsPropCstring(field, "value", "ordinary")
''',[])
        self.check('''import other/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setJsPropCstring(field, "value", "ordinary")
''',[])

    def test_nim_parameter_procedure_and_type_shadowing(self):
        for declaration in ['proc createElement(d: int, tag: string): int = 1',
                            'template createElement(d, tag: untyped): untyped = 1',
                            'type createElement = int']:
            with self.subTest(declaration=declaration):
                self.check('import isonim/web/dom_api\n'+declaration+'\n'+
                           'let field = createElement(document, "input")\n'+
                           'setJsPropCstring(field, "value", "ordinary")\n',[])
        self.check('''import isonim/web/dom_api
proc model(dom_api: Model) =
  let field = dom_api.createElement(dom_api.document, "input")
  dom_api.setJsPropCstring(field, "value", "ordinary")
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setJsPropCstring(field, "value", "seed")
''',[(6,'free-text binding')])

    def test_nim_metadata_unknown_alias_and_harmless_mutations(self):
        for mutation, api in [('dom_api.setAttribute(alias, "id", "x")',None),
                              ('dom_api.setAttribute(alias, "title", "x")',None),
                              ('dom_api.setAttribute(alias, dynamicName, "x")','unresolved DOM privacy binding'),
                              ('unknown(alias)','unresolved DOM privacy binding'),
                              ('dom_api.setJsPropCstring(alias, "type", dynamicType)','free-text binding')]:
            with self.subTest(mutation=mutation):
                self.check('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "input")\n'+
                           'dom_api.setAttribute(field, "type", "checkbox")\nlet alias = field\n'+mutation+'\n'+
                           'dom_api.setJsPropCstring(field, "value", "seed")\n',[(6,api)] if api else [])

    def test_nim_branch_loop_case_and_exception_merges(self):
        bodies = ['if condition:\n  dom_api.setAttribute(field, "type", "text")',
                  'while condition:\n  dom_api.setAttribute(field, "type", "text")',
                  'for i in 0..1:\n  dom_api.setAttribute(field, "type", "text")',
                  'case kind\nof 1:\n  dom_api.setAttribute(field, "type", "text")\nelse:\n  discard',
                  'try:\n  dom_api.setAttribute(field, "type", "text")\nexcept ValueError:\n  discard',
                  'when defined(js):\n  dom_api.setAttribute(field, "type", "text")']
        for control in bodies:
            with self.subTest(control=control):
                source = ('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document, "input")\n'+
                          'dom_api.setAttribute(field, "type", "checkbox")\n'+control+'\n'+
                          'dom_api.setJsPropCstring(field, "value", "seed")\n')
                self.check(source,[(source.count('\n'),'unresolved DOM privacy binding')])

    def test_nim_uninvoked_and_invoked_capture_views(self):
        source = '''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
proc changeType() =
  dom_api.setAttribute(field, "type", "text")
'''
        path=self.write('ordinary.nim',source+'dom_api.setJsPropCstring(field, "value", "ok")\n')
        self.compile(path)
        result=self.cli();self.assertEqual(json.loads(result.stdout),[]);self.assertEqual(result.returncode,0,result.stderr)
        path.write_text(source+'changeType()\ndom_api.setJsPropCstring(field, "value", "seed")\n')
        self.compile(path)
        result=self.cli()
        self.assertEqual(json.loads(result.stdout),[dict(path='site/src/ordinary.nim',line=7,api='unresolved DOM privacy binding',severity='error')])
        self.assertEqual(result.returncode,1,result.stderr)

    def test_nim_branch_alias_mutation_and_replacement_recovery(self):
        self.check('''import isonim/web/dom_api
var field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
let prior = field
if condition:
  field = dom_api.createElement(dom_api.document, "button")
dom_api.setAttribute(field, "type", "text")
dom_api.setJsPropCstring(prior, "value", "seed")
field = dom_api.createElement(dom_api.document, "button")
dom_api.setJsPropCstring(field, "value", "ok")
''',[(8,'unresolved DOM privacy binding')])

    def test_nim_access_kinds_markers_and_multiple_on_one_line(self):
        self.check('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "data-isonim-public", "true")
discard dom_api.getAttribute(field, "value"); dom_api.setAttribute(field, "value", "seed")
discard dom_api.getJsProp(field, "value")
field.textContent = "seed"; discard field.textContent
''',[(4,'free-text binding'),(4,'free-text binding'),(5,'free-text binding'),(6,'free-text binding'),(6,'free-text binding')])
        self.check('''import isonim/web/dom_api
let text = dom_api.createTextNode(dom_api.document, "label")
text.textContent = "ordinary"
let button = dom_api.createElement(dom_api.document, "button")
button.textContent = "ordinary"
''',[])

    def test_nim_git_and_platform_allowances_do_not_authorize_privacy(self):
        repo=self.root.parent;subprocess.run(['git','init','-q',str(repo)],check=True)
        (repo/'.gitignore').write_text('src/generated/\n')
        source='import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "input")\ndom_api.setJsPropCstring(field, "value", "seed")\n'
        self.write('tracked.nim',source)
        subprocess.run(['git','-C',str(repo),'add','src/tracked.nim'],check=True)
        self.write('untracked.nim',source);self.write('generated/ignored.nim',source)
        result=self.cli()
        self.assertEqual(json.loads(result.stdout),[dict(path='site/src/'+n,line=3,api='free-text binding',severity='error') for n in ['tracked.nim','untracked.nim']])
        self.assertEqual(result.returncode,1,result.stderr)
        allow=Path(self.temp.name)/'allow.json';allow.write_text(json.dumps([dict(path='site/src/tracked.nim',api='free-text binding',count=1,reason='not authority')]))
        result=self.cli('--allowlist',allow)
        self.assertEqual(result.returncode,2);self.assertIn('privacy findings cannot be allowed',result.stderr)
        framework=Path(self.temp.name)/'framework';tools=framework/'tools';tools.mkdir(parents=True)
        for name in ['lint_nondet.py','lint_privacy.py']:shutil.copyfile(SCRIPT.with_name(name),tools/name)
        path=framework/'src/isonim/core/nondet.nim';path.parent.mkdir(parents=True);path.write_text(source)
        result=subprocess.run([sys.executable,str(tools/'lint_nondet.py'),'--json',str(framework/'src')],capture_output=True,text=True)
        self.assertEqual(json.loads(result.stdout),[dict(path='framework/src/isonim/core/nondet.nim',line=3,api='free-text binding',severity='error')])
        self.assertEqual(result.returncode,1,result.stderr)

    def test_nim_unknown_replacement_and_inline_recovery(self):
        self.check('''import isonim/web/dom_api
var field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
let prior = field
field = opaque()
dom_api.setJsPropCstring(field, "value", "seed")
dom_api.setAttribute(field, "type", "text")
dom_api.setJsPropCstring(prior, "value", "seed")
field = dom_api.createElement(dom_api.document, "button")
dom_api.setJsPropCstring(field, "value", "ok")
''', [(6,'unresolved DOM privacy binding'), (8,'unresolved DOM privacy binding')])
        self.check('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
if condition: dom_api.setAttribute(field, "type", "text")
dom_api.setJsPropCstring(field, "value", "seed")
''',[(5,'unresolved DOM privacy binding')])

    def test_nim_harmless_branch_preserves_alias_certification(self):
        self.check('''import isonim/web/dom_api
var field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
let prior = field
if condition:
  dom_api.setAttribute(field, "id", "x")
dom_api.setJsPropCstring(prior, "value", "ok")
if condition:
  field = dom_api.createElement(dom_api.document, "button")
dom_api.setAttribute(field, "title", "x")
dom_api.setJsPropCstring(prior, "value", "ok")
''',[])

    def test_nim_bracket_import_and_direct_allocation_access(self):
        self.check('''import isonim/web/[dom_api, web_renderer]
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setJsPropCstring(field, "value", "seed")
dom_api.createElement(dom_api.document, "textarea").textContent = "seed"
''',[(3,'free-text binding'),(4,'free-text binding')])

    def test_nim_compiled_named_arguments_and_attribute_property_distinction(self):
        source = '''import isonim/web/dom_api
let field = dom_api.createElement(tag = "input", d = dom_api.document)
dom_api.setAttribute(value = "ordinary attribute", name = "textContent", e = field)
discard dom_api.getAttribute(name = "textContent", e = field)
dom_api.setJsPropCstring(value = "seed", n = field, name = "value")
discard dom_api.getJsProp(name = "value", n = field)
let checkbox = dom_api.createElement(tag = "input", d = dom_api.document)
dom_api.setAttribute(value = "checkbox", e = checkbox, name = "type")
dom_api.setJsPropCstring(name = "value", value = "ok", n = checkbox)
dom_api.removeAttribute(name = "type", e = checkbox)
dom_api.setAttribute(value = "seed", e = checkbox, name = "value")
'''
        path = self.write('ordinary.nim', source)
        self.compile(path)
        result = self.cli()
        self.assertEqual(json.loads(result.stdout), [dict(path='site/src/ordinary.nim',
                         line=line, api='free-text binding', severity='error') for line in [5,6,11]])
        self.assertEqual(result.returncode,1,result.stderr)

    def test_nim_compiled_backtick_identifier_and_keyword_controls(self):
        source = '''import isonim/web/dom_api as browser
proc `if`() = discard
`if`()
let field = browser.`createElement`(browser.`document`, "textarea")
field.`textContent` = "seed"
'''
        path = self.write('ordinary.nim', source)
        self.compile(path)
        result = self.cli()
        self.assertEqual(json.loads(result.stdout), [dict(path='site/src/ordinary.nim',
                         line=5,api='free-text binding',severity='error')])
        self.assertEqual(result.returncode,1,result.stderr)

    def test_nim_long_alias_history_keeps_iterative_views(self):
        source = ('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document, "input")\n'+
                  'dom_api.setAttribute(field, "type", "checkbox")\n'+
                  'field = opaque()\n'*1100+
                  'if condition:\n  dom_api.setAttribute(field, "id", "x")\n'+
                  'dom_api.setJsPropCstring(field, "value", "seed")\n')
        self.check(source,[(source.count('\n'),'unresolved DOM privacy binding')])

    def test_nim_compiled_routine_local_shadow_keeps_outer_checkbox(self):
        source = '''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
proc localLabel() =
  let field = dom_api.createElement(dom_api.document, "button")
  field.textContent = "label"
localLabel()
dom_api.setJsPropCstring(field, "value", "ok")
'''
        path = self.write('ordinary.nim',source)
        self.compile(path)
        result = self.cli()
        self.assertEqual(json.loads(result.stdout),[])
        self.assertEqual(result.returncode,0,result.stderr)

    def test_nim_unresolved_imports_remove_stale_authority(self):
        for imported, create in [
                ('from other import dom_api', 'dom_api.createElement(dom_api.document, "input")'),
                ('from other import createElement, document', 'createElement(document, "input")'),
                ('import other/dom_api', 'dom_api.createElement(dom_api.document, "input")'),
                ('import other/model as dom_api', 'dom_api.createElement(dom_api.document, "input")'),
                ('import isonim/web/dom_api except createElement', 'dom_api.createElement(dom_api.document, "input")'),
                ('include model_bindings', 'dom_api.createElement(dom_api.document, "input")')]:
            with self.subTest(imported=imported):
                self.check('import isonim/web/dom_api\n'+imported+'\nlet field = '+create+'\n'+
                           'field.textContent = "ordinary model"\n', [])
        self.check('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "textarea")
from other import dom_api
field.textContent = "seed"
''', [(4,'free-text binding')])
        self.check('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
include unknown_bindings
field.textContent = "seed"
''', [(5,'unresolved DOM privacy binding')])

    def test_nim_compiled_loop_module_shadow_has_lexical_extent(self):
        source = '''import isonim/web/dom_api as browser
type Model = object
  document: int
proc createElement(model: Model, d: int, tag: string): Model = model
proc setJsPropCstring(model: Model, field: Model, name, value: string) = discard
for browser in [Model(document: 1)]:
  let field = browser.createElement(browser.document, "input")
  browser.setJsPropCstring(field, "value", "ordinary")
let field = browser.createElement(browser.document, "input")
browser.setJsPropCstring(field, "value", "seed")
'''
        path = self.write('ordinary.nim',source)
        self.compile(path)
        result = self.cli()
        self.assertEqual(json.loads(result.stdout),[dict(path='site/src/ordinary.nim',line=10,api='free-text binding',severity='error')])
        self.assertEqual(result.returncode,1,result.stderr)
        path.unlink()
        self.check('''import isonim/web/dom_api
proc generic[dom_api](model: dom_api) =
  let field = dom_api.createElement(dom_api.document, "input")
  dom_api.setJsPropCstring(field, "value", "ordinary")
''',[])

    def test_nim_compiled_comma_parameter_shadow_and_default_read(self):
        source = '''import isonim/web/dom_api as browser
type Model = object
  document: int
proc createElement(model: Model, d: int, tag: string): Model = model
proc setJsPropCstring(model: Model, field: Model, name, value: string) = discard
proc modelComponent(dummy: int, browser: Model) =
  let field = browser.createElement(browser.document, "input")
  browser.setJsPropCstring(field, "value", "ordinary")
modelComponent(0, Model(document: 1))
let field = browser.createElement(browser.document, "textarea")
proc consume(value: cstring = field.textContent) = discard
consume()
'''
        path = self.write('ordinary.nim',source)
        self.compile(path)
        result = self.cli()
        self.assertEqual(json.loads(result.stdout),[dict(path='site/src/ordinary.nim',line=11,api='free-text binding',severity='error')])
        self.assertEqual(result.returncode,1,result.stderr)

    def test_nim_production_inverses_fail_named_exact_assertions(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        integration="nim_dom_privacy(text, label) if path.suffix == '.nim' else []"
        identity="if env.get(nim_name(ts[0][1])) == module:"
        state="metadata(target, prop, data, attribute=attribute)"
        for anchor in [integration,identity,state]:self.assertEqual(scanner.count(anchor),1)
        variants=[('drop-nim-integration',scanner.replace(integration,'[]'),helper,
                   'test_nim_compiled_raw_component_removal_and_public_dsl','free-text binding'),
                  ('remove-module-identity',scanner.replace(identity,'if True:'),helper,
                   'test_nim_compiled_shadowed_module_and_model','free-text binding'),
                  ('retain-stale-checkbox',scanner.replace(state,
                   "if not (name == 'setAttribute' and prop == 'type' and data == 'text'):\n                                "+state),helper,
                   'test_nim_alias_transition_order_and_recovery','free-text binding')]
        for name,source,helper_source,failing,api in variants:
            with self.subTest(name=name):
                directory=Path(self.temp.name)/name;directory.mkdir()
                (directory/'lint_nondet.py').write_text(source)
                (directory/'lint_privacy.py').write_text(helper_source)
                test_source = Path(__file__).read_text()
                test_source = test_source.replace(
                    'PROJECT = Path(__file__).resolve().parents[1]',
                    'PROJECT = Path('+repr(str(PROJECT))+')', 1)
                (directory/'test_lint_nondet.py').write_text(test_source)
                # The compiled component imports the real shipped framework,
                # not a fake module supplied by the isolated mutation copy.
                (directory/'src').symlink_to(PROJECT/'src',target_is_directory=True)
                command=[sys.executable,str(directory/'test_lint_nondet.py'),
                         'NimPrivacyTests.'+failing,
                         'LintTests.test_privacy_nonfield_only_control',
                         'LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
                self.retain_inputs(command)
                result=subprocess.run(command,capture_output=True,text=True)
                (directory/'inverse.log').write_text(result.stdout+result.stderr);self.retain_inputs(command)
                self.assertEqual(result.returncode,1,result.stdout+result.stderr)
                self.assertIn('FAIL: '+failing,result.stderr)
                self.assertIn('AssertionError: Lists differ',result.stderr)
                self.assertIn('site/src/ordinary.nim',result.stderr)
                self.assertIn(api,result.stderr)
                self.assertIn('FAILED (failures=1)',result.stderr)
                self.assertNotIn('ERROR:',result.stderr)

    def compiled_control(self, source, expected):
        path = self.write('ordinary.nim', source)
        directory = Path(self.temp.name)/('compiled-'+str(len(list(Path(self.temp.name).glob('compiled-*')))))
        directory.mkdir()
        command = ['nim', 'js', '--hints:off', '--path:'+str(PROJECT/'src'),
                   '--path:'+str(PROJECT.parent/'nim-everywhere/src'),
                   '--nimcache:'+str(directory/'cache'), '--out:'+str(directory/'component.js'), str(path)]
        self.retain_inputs(command)
        compiled = subprocess.run(command, capture_output=True, text=True)
        (directory/'compiler.stdout.log').write_text(compiled.stdout)
        (directory/'compiler.stderr.log').write_text(compiled.stderr)
        (directory/'compiler.json').write_text(json.dumps(dict(argv=command, exit=compiled.returncode)))
        self.retain_inputs(command)
        self.assertEqual(compiled.returncode, 0, compiled.stdout+compiled.stderr)
        result = self.cli()
        (directory/'cli.stdout.log').write_text(result.stdout)
        (directory/'cli.stderr.log').write_text(result.stderr)
        (directory/'cli.json').write_text(json.dumps(dict(exit=result.returncode)))
        self.retain_inputs([sys.executable, SCRIPT, '--json', self.root])
        self.assertEqual(json.loads(result.stdout), [dict(path='site/src/ordinary.nim',
                         line=line, api=api, severity='error') for line, api in expected])
        self.assertEqual(result.returncode, 1 if expected else 0, result.stderr)
        path.unlink()

    def test_nim_compiled_loop_backedge_exact_finding(self):
        self.compiled_control('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
for i in 0..1:
  dom_api.setJsPropCstring(field, "value", "seed")
  dom_api.setAttribute(field, "type", "text")
''', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_inline_if_semicolon_ownership(self):
        self.compiled_control('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
let flag = false
if flag: dom_api.setAttribute(field, "id", "x"); dom_api.setAttribute(field, "type", "checkbox")
dom_api.setJsPropCstring(field, "value", "seed")
''', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_inline_uninvoked_routine_ownership(self):
        self.compiled_control('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
proc change() = dom_api.setAttribute(field, "id", "x"); dom_api.setAttribute(field, "type", "checkbox")
dom_api.setJsPropCstring(field, "value", "seed")
''', [(4, 'free-text binding')])

    def test_nim_compiled_loop_readonly_harmless_and_reset_controls(self):
        for contents in [
                '  dom_api.setJsPropCstring(field, "value", "ok")',
                '  dom_api.setAttribute(field, "id", "literal; : =")\n  dom_api.setJsPropCstring(field, "value", "ok")',
                '  dom_api.setAttribute(field, "type", "checkbox")\n  dom_api.setJsPropCstring(field, "value", "ok")\n  dom_api.setAttribute(field, "type", "text")',
                '  let field = dom_api.createElement(dom_api.document, "input")\n  dom_api.setAttribute(field, "type", "checkbox")\n  dom_api.setJsPropCstring(field, "value", "ok")']:
            with self.subTest(contents=contents):
                self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "input")\n'+
                                      'dom_api.setAttribute(field, "type", "checkbox")\nfor i in 0..1:\n'+contents+'\n', [])

    def test_nim_compiled_inline_and_multiline_controls(self):
        for statement in [
                'if flag: dom_api.setAttribute(field, "id", "x"); dom_api.setAttribute(field, "type", "checkbox")',
                'if flag:\n  dom_api.setAttribute(field, "id", "x")\n  dom_api.setAttribute(field, "type", "checkbox")']:
            with self.subTest(statement=statement):
                source='import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "input")\nlet flag = false\n'+statement+'\ndom_api.setJsPropCstring(field, "value", "seed")\n'
                self.compiled_control(source, [(source.count('\n'), 'unresolved DOM privacy binding')])
        self.compiled_control('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input"); dom_api.setAttribute(field, "type", "checkbox")
if true: dom_api.setAttribute(field, "id", "semicolon; proc fake() = :"); dom_api.setAttribute(field, "title", "safe")
dom_api.setJsPropCstring(field, "value", "ok")
''', [])

    def test_nim_compiled_inline_routine_capture_and_invocation_controls(self):
        for declaration in [
                'proc change() = dom_api.setAttribute(field, "id", "x"); dom_api.setAttribute(field, "type", "text")',
                'proc change() =\n  dom_api.setAttribute(field, "id", "x")\n  dom_api.setAttribute(field, "type", "text")']:
            for invoke in [False, True]:
                with self.subTest(declaration=declaration, invoke=invoke):
                    source='import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "input")\ndom_api.setAttribute(field, "type", "checkbox")\n'+declaration+'\n'+('change()\n' if invoke else '')+'dom_api.setJsPropCstring(field, "value", "ok")\n'
                    self.compiled_control(source, [(source.count('\n'), 'unresolved DOM privacy binding')] if invoke else [])

    def test_nim_compiled_nested_backedge_aliases_and_fresh_controls(self):
        self.compiled_control('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
let alias = field
for i in 0..1:
  for j in 0..1:
    dom_api.setJsPropCstring(alias, "value", "seed")
    dom_api.setAttribute(field, "type", "text")
''', [(7, 'unresolved DOM privacy binding')])
        self.compiled_control('''import isonim/web/dom_api
for i in 0..1:
  let field = dom_api.createElement(dom_api.document, "input")
  dom_api.setAttribute(field, "type", "checkbox")
  let alias = field
  for j in 0..1:
    dom_api.setAttribute(alias, "type", "checkbox")
    dom_api.setJsPropCstring(field, "value", "ok")
    dom_api.setAttribute(field, "type", "text")
''', [])

    def test_nim_compiled_while_condition_order_and_unknown_call(self):
        source='''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
var i = 0
while (dom_api.setAttribute(field, "type", "text"); i < 2):
  dom_api.setJsPropCstring(field, "value", "seed")
  dom_api.setAttribute(field, "type", "checkbox")
  inc i
'''
        self.compiled_control(source, [(6, 'free-text binding')])
        self.compiled_control('''import isonim/web/dom_api
proc opaque(field: Element) = discard
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
for i in 0..1:
  opaque(field)
  dom_api.setAttribute(field, "type", "checkbox")
  dom_api.setJsPropCstring(field, "value", "seed")
''', [(8, 'unresolved DOM privacy binding')])

    def test_nim_compiled_readonly_loop_alias_controls(self):
        for header, tail in [('for i in 0..1:', ''),
                             ('var i = 0\nwhile i < 2:', '  inc i\n')]:
            with self.subTest(header=header):
                self.compiled_control('import isonim/web/dom_api\n'+
                    'let field = dom_api.createElement(dom_api.document, "input")\n'+
                    'dom_api.setAttribute(field, "type", "checkbox")\nlet alias = field\n'+
                    header+'\n  discard dom_api.getAttribute(alias, "type")\n'+
                    '  discard dom_api.getJsProp(field, "value")\n'+tail+
                    'dom_api.setJsPropCstring(field, "value", "still-checkbox")\n', [])

    def test_nim_local_control_production_inverses(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        backedge='entry = loop_entry(ts, children, env, names)'
        inline="inline([indent+1, ts[cut:], []])"
        for anchor in [backedge, inline]: self.assertEqual(scanner.count(anchor), 1)
        variants=[('drop-backedge',scanner.replace(backedge, 'entry = view(env)'),
                   'test_nim_compiled_loop_backedge_exact_finding'),
                  ('detach-inline-tail',scanner.replace(inline,
                   "inline([indent+1, first_part[cut:], []])\n            for part in siblings[1:]:\n                if part: inline([indent, part, []])"),
                   'test_nim_compiled_inline_if_semicolon_ownership')]
        for name, source, failing in variants:
            with self.subTest(name=name):
                directory=Path(self.temp.name)/name;directory.mkdir()
                (directory/'lint_nondet.py').write_text(source)
                (directory/'lint_privacy.py').write_text(helper)
                tests=Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
                     'PROJECT = Path('+repr(str(PROJECT))+')',1)
                (directory/'test_lint_nondet.py').write_text(tests)
                command=[sys.executable,str(directory/'test_lint_nondet.py'),
                         'NimPrivacyTests.'+failing,
                         'LintTests.test_privacy_nonfield_only_control',
                         'LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
                self.retain_inputs(command)
                result=subprocess.run(command,capture_output=True,text=True)
                (directory/'inverse.log').write_text(result.stdout+result.stderr)
                self.retain_inputs(command)
                self.assertEqual(result.returncode,1,result.stdout+result.stderr)
                self.assertIn('FAIL: '+failing,result.stderr)
                self.assertIn('AssertionError: Lists differ',result.stderr)
                self.assertIn('site/src/ordinary.nim',result.stderr)
                self.assertIn('unresolved DOM privacy binding',result.stderr)
                self.assertIn('FAILED (failures=1)',result.stderr)
                self.assertNotIn('ERROR:',result.stderr)


    def test_nim_compiled_exception_prefix_exact_finding(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "input")\ndom_api.setAttribute(field, "type", "checkbox")\ntry:\n  dom_api.setAttribute(field,"type","text")\n  raise newException(ValueError,"privacy fixture")\nexcept ValueError:\n  dom_api.setJsPropCstring(field,"value","seed")\n', [(8, 'unresolved DOM privacy binding')])

    def test_nim_compiled_continue_suffix_exact_finding(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "input")\ndom_api.setAttribute(field, "type", "checkbox")\nfor i in 0..1:\n  dom_api.setAttribute(field, "type", "text")\n  continue\n  dom_api.setAttribute(field, "type", "checkbox")\ndom_api.setJsPropCstring(field, "value", "seed")\n', [(8, 'unresolved DOM privacy binding')])

    def test_nim_compiled_exception_harmless_readonly_controls(self):
        for operation in ['dom_api.setAttribute(field,"id","text")',
                          'discard dom_api.getAttribute(field,"type")',
                          'discard dom_api.getJsProp(field,"value")']:
            with self.subTest(operation=operation):
                self.compiled_control('import isonim/web/dom_api\n'+
                    'let field = dom_api.createElement(dom_api.document, "input")\n'+
                    'dom_api.setAttribute(field, "type", "checkbox")\ntry:\n  '+operation+'\n'+
                    '  raise newException(ValueError,"privacy fixture")\nexcept ValueError:\n'+
                    '  dom_api.setJsPropCstring(field,"value","ok")\n', [])

    def test_nim_compiled_exception_earlier_prefix_before_normal_reset(self):
        self.compiled_control('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
try:
  dom_api.setAttribute(field, "type", "text")
  discard dom_api.getAttribute(field, "id")
  dom_api.setAttribute(field, "type", "checkbox")
except ValueError:
  dom_api.setJsPropCstring(field, "value", "seed")
''', [(9, 'unresolved DOM privacy binding')])

    def test_nim_compiled_exception_alias_rebinding_prefix(self):
        self.compiled_control('''import isonim/web/dom_api
let checkbox = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(checkbox, "type", "checkbox")
let text = dom_api.createElement(dom_api.document, "textarea")
var alias = checkbox
try:
  alias = text
  discard dom_api.getAttribute(alias, "id")
  alias = checkbox
except ValueError:
  dom_api.setJsPropCstring(alias, "value", "seed")
''', [(11, 'unresolved DOM privacy binding')])

    def test_nim_compiled_exception_handler_reset_and_fresh_controls(self):
        for recovery in ['dom_api.setAttribute(field, "type", "checkbox")',
                         'field = dom_api.createElement(dom_api.document, "input")\n  dom_api.setAttribute(field, "type", "checkbox")']:
            with self.subTest(recovery=recovery):
                self.compiled_control('import isonim/web/dom_api\n'+
                    'var field = dom_api.createElement(dom_api.document, "input")\n'+
                    'dom_api.setAttribute(field, "type", "checkbox")\ntry:\n'+
                    '  dom_api.setAttribute(field,"type","text")\n'+
                    '  raise newException(ValueError,"privacy fixture")\nexcept ValueError:\n  '+recovery+'\n'+
                    '  dom_api.setJsPropCstring(field,"value","ok")\n', [])

    def test_nim_compiled_abrupt_harmless_and_literal_reset_controls(self):
        for abrupt in ['continue', 'break']:
            for contents in ['  dom_api.setAttribute(field, "id", "x")',
                             '  discard dom_api.getJsProp(field, "value")',
                             '  dom_api.setAttribute(field, "type", "text")\n  dom_api.setAttribute(field, "type", "checkbox")']:
                with self.subTest(abrupt=abrupt, contents=contents):
                    self.compiled_control('import isonim/web/dom_api\n'+
                        'let field = dom_api.createElement(dom_api.document, "input")\n'+
                        'dom_api.setAttribute(field, "type", "checkbox")\nfor i in 0..1:\n'+contents+'\n  '+abrupt+'\n'+
                        '  dom_api.setAttribute(field, "type", "checkbox")\n'+
                        'dom_api.setJsPropCstring(field, "value", "ok")\n', [])

    def test_nim_compiled_break_suffix_and_named_block_targets(self):
        for header, transfer in [('for i in 0..1:', 'break'),
                                 ('block outer:', 'break outer')]:
            with self.subTest(header=header):
                self.compiled_control('import isonim/web/dom_api\n'+
                    'let field = dom_api.createElement(dom_api.document, "input")\n'+
                    'dom_api.setAttribute(field, "type", "checkbox")\n'+header+'\n'+
                    '  dom_api.setAttribute(field, "type", "text")\n  '+transfer+'\n'+
                    '  dom_api.setAttribute(field, "type", "checkbox")\n'+
                    'dom_api.setJsPropCstring(field, "value", "seed")\n',
                    [(8, 'unresolved DOM privacy binding')] if transfer=='break' else [(8, 'free-text binding')])
        self.compiled_control('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
block outer:
  for i in 0..1:
    dom_api.setAttribute(field, "type", "text")
    break outer
    dom_api.setAttribute(field, "type", "checkbox")
  dom_api.setAttribute(field, "type", "checkbox")
dom_api.setJsPropCstring(field, "value", "seed")
''', [(10, 'unresolved DOM privacy binding')])

    def test_nim_compiled_nested_break_continue_ownership_controls(self):
        self.compiled_control('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
for i in 0..1:
  for j in 0..1:
    dom_api.setAttribute(field, "type", "text")
    break
    dom_api.setAttribute(field, "type", "checkbox")
  dom_api.setAttribute(field, "type", "checkbox")
  continue
  dom_api.setAttribute(field, "type", "text")
dom_api.setJsPropCstring(field, "value", "ok")
''', [])
        self.compiled_control('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
for i in 0..1:
  block inner:
    dom_api.setAttribute(field, "type", "text")
    continue
    dom_api.setAttribute(field, "type", "checkbox")
  dom_api.setAttribute(field, "type", "checkbox")
dom_api.setJsPropCstring(field, "value", "seed")
''', [(10, 'unresolved DOM privacy binding')])

    def test_nim_compiled_return_raise_suffix_and_deferred_controls(self):
        for transfer in ['return', 'raise newException(ValueError,"privacy fixture")']:
            for invoke in [False, True]:
                with self.subTest(transfer=transfer, invoke=invoke):
                    source=('import isonim/web/dom_api\n'+
                        'let field = dom_api.createElement(dom_api.document, "input")\n'+
                        'dom_api.setAttribute(field, "type", "checkbox")\nproc change() =\n'+
                        '  dom_api.setAttribute(field, "type", "text")\n  '+transfer+'\n'+
                        '  dom_api.setAttribute(field, "type", "checkbox")\n'+
                        ('try:\n  change()\nexcept ValueError:\n  discard\n' if invoke else '')+                        'dom_api.setJsPropCstring(field, "value", "seed")\n')
                    self.compiled_control(source, [(source.count('\n'),'unresolved DOM privacy binding')] if invoke else [])

    def test_nim_compiled_branch_abrupt_excludes_completed_paths(self):
        self.compiled_control('''import isonim/web/dom_api
proc component(flag: bool) =
  let field = dom_api.createElement(dom_api.document, "input")
  dom_api.setAttribute(field, "type", "checkbox")
  if flag:
    dom_api.setAttribute(field, "type", "text")
    return
    dom_api.setAttribute(field, "type", "checkbox")
  dom_api.setJsPropCstring(field, "value", "ok")
component(false)
''', [])

    def test_nim_compiled_finally_cleanup_completion_and_handler_controls(self):
        for reset, expected in [(False, [(12,'unresolved DOM privacy binding')]), (True, [])]:
            with self.subTest(reset=reset):
                self.compiled_control('import isonim/web/dom_api\n'+
                    'let field = dom_api.createElement(dom_api.document, "input")\n'+
                    'dom_api.setAttribute(field, "type", "checkbox")\nfor i in 0..1:\n  try:\n'+
                    '    dom_api.setAttribute(field, "type", "text")\n    continue\n'+
                    '    dom_api.setAttribute(field, "type", "checkbox")\n  finally:\n'+
                    ('    dom_api.setAttribute(field, "type", "checkbox")\n' if reset else '    dom_api.setAttribute(field, "id", "x")\n')+
                    '  dom_api.setAttribute(field, "type", "checkbox")\n'+
                    'dom_api.setJsPropCstring(field, "value", "seed")\n', expected)
        self.compiled_control('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
for i in 0..1:
  try:
    dom_api.setAttribute(field, "type", "text")
    raise newException(ValueError,"privacy fixture")
  except ValueError:
    continue
    dom_api.setAttribute(field, "type", "checkbox")
  finally:
    dom_api.setAttribute(field, "type", "checkbox")
dom_api.setJsPropCstring(field, "value", "ok")
''', [])

    def test_nim_compiled_finally_override_and_nested_handler_prefix(self):
        self.compiled_control('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
block outer:
  try:
    dom_api.setAttribute(field, "type", "text")
    raise newException(ValueError,"privacy fixture")
  finally:
    dom_api.setAttribute(field, "type", "checkbox")
    break outer
    dom_api.setAttribute(field, "type", "text")
dom_api.setJsPropCstring(field, "value", "ok")
''', [])
        self.compiled_control('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
try:
  try:
    dom_api.setAttribute(field, "type", "text")
    raise newException(ValueError,"privacy fixture")
  except ValueError:
    raise newException(IOError,"privacy fixture")
    dom_api.setAttribute(field, "type", "checkbox")
except IOError:
  dom_api.setJsPropCstring(field, "value", "seed")
''', [(12, 'unresolved DOM privacy binding')])

    def test_nim_exception_abrupt_production_inverses(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        handler='handler_entry = join(env, protected_prefixes)'
        abrupt="elif first in {'break', 'continue', 'return', 'raise'}:"
        for anchor in [handler, abrupt]: self.assertEqual(scanner.count(anchor), 1)
        variants=[('drop-handler-prefixes',scanner.replace(handler, 'handler_entry = view(env)'),
                   'test_nim_compiled_exception_prefix_exact_finding'),
                  ('ignore-continue-completion',scanner.replace(abrupt,
                   "elif first in {'break', 'return', 'raise'}:"),
                   'test_nim_compiled_continue_suffix_exact_finding')]
        for name, source, failing in variants:
            with self.subTest(name=name):
                directory=Path(self.temp.name)/name;directory.mkdir()
                (directory/'lint_nondet.py').write_text(source)
                (directory/'lint_privacy.py').write_text(helper)
                tests=Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
                     'PROJECT = Path('+repr(str(PROJECT))+')',1)
                (directory/'test_lint_nondet.py').write_text(tests)
                command=[sys.executable,str(directory/'test_lint_nondet.py'),
                         'NimPrivacyTests.'+failing,
                         'LintTests.test_privacy_nonfield_only_control',
                         'LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
                self.retain_inputs(command)
                result=subprocess.run(command,capture_output=True,text=True)
                (directory/'inverse.log').write_text(result.stdout+result.stderr)
                self.retain_inputs(command)
                self.assertEqual(result.returncode,1,result.stdout+result.stderr)
                self.assertIn('FAIL: '+failing,result.stderr)
                self.assertIn('AssertionError: Lists differ',result.stderr)
                self.assertIn('site/src/ordinary.nim',result.stderr)
                self.assertIn('unresolved DOM privacy binding',result.stderr)
                self.assertIn('FAILED (failures=1)',result.stderr)
                self.assertNotIn('ERROR:',result.stderr)



    def test_nim_compiled_handler_shadowed_local_restores_outer_root(self):
        self.compiled_control('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
try:
  let field = dom_api.createElement(dom_api.document, "textarea")
  discard dom_api.getAttribute(field, "id")
  raise newException(ValueError,"privacy fixture")
except ValueError:
  dom_api.setJsPropCstring(field, "value", "ok")
''', [])

    def test_nim_compiled_handler_shadow_root_alias_prefix_kept(self):
        self.compiled_control('''import isonim/web/dom_api
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
let alias = field
try:
  dom_api.setAttribute(alias, "type", "text")
  block:
    let field = dom_api.createElement(dom_api.document, "textarea")
    dom_api.setAttribute(alias, "type", "checkbox")
    raise newException(ValueError,"privacy fixture")
except ValueError:
  dom_api.setJsPropCstring(field, "value", "seed")
''', [(12, 'unresolved DOM privacy binding')])

    def test_nim_compiled_finally_implicit_exception_prefix(self):
        self.compiled_control('''import isonim/web/dom_api
proc fail() = raise newException(ValueError,"privacy fixture")
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
try:
  dom_api.setAttribute(field, "type", "text")
  fail()
  dom_api.setAttribute(field, "type", "checkbox")
finally:
  dom_api.setJsPropCstring(field, "value", "seed")
''', [(10, 'unresolved DOM privacy binding')])

    def test_nim_compiled_expression_effect_prefix_before_reset(self):
        self.compiled_control('''import isonim/web/dom_api
proc fail() = raise newException(ValueError,"privacy fixture")
let field = dom_api.createElement(dom_api.document, "input")
dom_api.setAttribute(field, "type", "checkbox")
try:
  discard (dom_api.setAttribute(field, "type", "text"); fail(); dom_api.setAttribute(field, "type", "checkbox"); 0)
except ValueError:
  dom_api.setJsPropCstring(field, "value", "seed")
''', [(8, 'unresolved DOM privacy binding')])

    def test_nim_compiled_finally_implicit_harmless_reset_controls(self):
        for operation, cleanup in [
                ('dom_api.setAttribute(field,"id","x")', ''),
                ('discard dom_api.getAttribute(field,"type")', ''),
                ('dom_api.setAttribute(field,"type","text")',
                 '  dom_api.setAttribute(field,"type","checkbox")\n'),
                ('dom_api.setAttribute(field,"type","text")',
                 '  let field = dom_api.createElement(dom_api.document, "input")\n  dom_api.setAttribute(field,"type","checkbox")\n')]:
            with self.subTest(operation=operation, cleanup=cleanup):
                self.compiled_control('import isonim/web/dom_api\n'+
                    'proc fail() = raise newException(ValueError,"privacy fixture")\n'+
                    'let field = dom_api.createElement(dom_api.document, "input")\n'+
                    'dom_api.setAttribute(field,"type","checkbox")\ntry:\n  '+operation+'\n'+
                    '  fail()\n  dom_api.setAttribute(field,"type","checkbox")\nfinally:\n'+cleanup+
                    '  dom_api.setJsPropCstring(field,"value","ok")\n', [])




    def test_nim_compiled_uninvoked_default_prefix_isolation(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "input")\ndom_api.setAttribute(field, "type", "checkbox")\ntry:\n  proc uninvoked(x: int = (dom_api.setAttribute(field, "type", "text"); 0)) = discard\n  raise newException(ValueError, "privacy fixture")\nexcept ValueError:\n  dom_api.setJsPropCstring(field, "value", "ok")\n', [])

    def test_nim_compiled_harmless_default_prefix_control(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "input")\ndom_api.setAttribute(field, "type", "checkbox")\ntry:\n  proc uninvoked(x: int = (dom_api.setAttribute(field, "id", "text"); 0)) = discard\n  raise newException(ValueError, "privacy fixture")\nexcept ValueError:\n  dom_api.setJsPropCstring(field, "value", "ok")\n', [])

    def test_nim_compiled_invoked_default_capture_prefix(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "input")\ndom_api.setAttribute(field, "type", "checkbox")\ntry:\n  proc uninvoked(x: int = (dom_api.setAttribute(field, "type", "text"); 0)) = discard\n  uninvoked()\n  raise newException(ValueError, "privacy fixture")\nexcept ValueError:\n  dom_api.setJsPropCstring(field, "value", "ok")\n', [(9, 'unresolved DOM privacy binding')])

    def test_nim_compiled_deferred_intermediate_capture_before_reset(self):
        for default in [False, True]:
            for invoke in [False, True]:
                with self.subTest(default=default, invoke=invoke):
                    source = 'import isonim/web/dom_api\nproc fail() = raise newException(ValueError,"privacy fixture")\nlet field = dom_api.createElement(dom_api.document, "input")\ndom_api.setAttribute(field,"type","checkbox")\n'
                    if default:
                        source += 'proc deferred(x: int = (dom_api.setAttribute(field,"type","text"); fail(); dom_api.setAttribute(field,"type","checkbox"); 0)) = discard\n'
                    else:
                        source += 'proc deferred() =\n  dom_api.setAttribute(field,"type","text")\n  fail()\n  dom_api.setAttribute(field,"type","checkbox")\n'
                    source += 'try:\n'+('  deferred()\n' if invoke else '  discard\n')+'except ValueError:\n  discard\n'
                    source += 'dom_api.setJsPropCstring(field,"value","seed")\n'
                    self.compiled_control(source, [(source.count('\n'),'unresolved DOM privacy binding')] if invoke else [])

    def test_nim_compiled_deferred_default_readonly_and_local_controls(self):
        for effect in ['discard dom_api.getAttribute(field,"type")',
                       'dom_api.setAttribute(field,"id","label")',
                       'let field = dom_api.createElement(dom_api.document,"textarea"); dom_api.setAttribute(field,"type","text")']:
            with self.subTest(effect=effect):
                source = 'import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\n'
                source += 'proc deferred(x: int = ('+effect+'; 0)) = discard\ntry:\n  deferred()\nexcept ValueError:\n  discard\ndom_api.setJsPropCstring(field,"value","ok")\n'
                self.compiled_control(source, [])

    def test_nim_compiled_deferred_default_formal_shadow_control(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc deferred(field: int; x: int = field) = discard\ndeferred(0)\ndom_api.setJsPropCstring(field,"value","ok")\n', [])

    def test_nim_compiled_deferred_body_intermediate_capture(self):
        self.compiled_control('import isonim/web/dom_api\nproc fail() = raise newException(ValueError,"privacy fixture")\nlet field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc deferred() =\n  dom_api.setAttribute(field,"type","text")\n  fail()\n  dom_api.setAttribute(field,"type","checkbox")\ntry:\n  deferred()\nexcept ValueError:\n  discard\ndom_api.setJsPropCstring(field,"value","seed")\n', [(13, "unresolved DOM privacy binding")])

    def test_nim_deferred_default_production_inverses(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        isolation='if len(default) == 2: evaluate(default[1], local)'
        prefix='[value for prefix in deferred_prefixes for value in prefix.values()]'
        result_origin='return uncertain(result)'
        for anchor in [isolation, prefix, result_origin]: self.assertEqual(scanner.count(anchor), 1)
        variants=[('leak-deferred-default-prefix',scanner.replace(isolation, isolation+'; observe_prefixes(local, enclosing_prefixes)'),
                   'test_nim_compiled_uninvoked_default_prefix_isolation'),
                  ('drop-deferred-intermediate-captures',scanner.replace(prefix, '[]'),
                   'test_nim_compiled_deferred_body_intermediate_capture'),
                  ('drop-statement-list-result',scanner.replace(result_origin, 'return None'),
                   'test_nim_compiled_statement_list_final_alias_preserved')]
        for name, source, failing in variants:
            with self.subTest(name=name):
                directory=Path(self.temp.name)/name;directory.mkdir()
                (directory/'lint_nondet.py').write_text(source)
                (directory/'lint_privacy.py').write_text(helper)
                tests=Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
                     'PROJECT = Path('+repr(str(PROJECT))+')',1)
                (directory/'test_lint_nondet.py').write_text(tests)
                command=[sys.executable,str(directory/'test_lint_nondet.py'),
                         'NimPrivacyTests.'+failing,
                         'LintTests.test_privacy_nonfield_only_control',
                         'LintTests.test_exact_seed_counts_in_js_and_foreign_pragmas']
                self.retain_inputs(command)
                result=subprocess.run(command,capture_output=True,text=True)
                (directory/'inverse.log').write_text(result.stdout+result.stderr)
                self.retain_inputs(command)
                self.assertEqual(result.returncode,1,result.stdout+result.stderr)
                self.assertIn('FAIL: '+failing,result.stderr)
                self.assertIn('AssertionError: Lists differ',result.stderr)
                self.assertIn('site/src/ordinary.nim',result.stderr)
                self.assertIn('unresolved DOM privacy binding',result.stderr)
                self.assertIn('FAILED (failures=1)',result.stderr)
                self.assertNotIn('ERROR:',result.stderr)

    def test_nim_compiled_deferred_overload_capture_union(self):
        for nested in [False, True]:
            with self.subTest(nested=nested):
                source = 'import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc change(x: int) = dom_api.setAttribute(field,"type","text")\n'
                if nested:
                    source += 'block:\n  proc change(x: string) = discard\n  change("label")\n'
                else:
                    source += 'proc change(x: string) = discard\nchange(0)\n'
                source += 'dom_api.setJsPropCstring(field,"value","seed")\n'
                self.compiled_control(source, [] if nested else [(source.count('\n'),'unresolved DOM privacy binding')])

    def test_nim_compiled_statement_list_final_alias_preserved(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","text")\nlet alias = (discard 0; field)\ndom_api.setJsPropCstring(alias,"value","seed")\n', [(5, "unresolved DOM privacy binding")])

    def test_nim_compiled_statement_list_final_model_and_shadow_controls(self):
        self.compiled_control('import isonim/web/dom_api\ntype Model = object\n  label: int\nproc setJsPropCstring(model: Model; name, value: string) = discard\nlet field = dom_api.createElement(dom_api.document,"input")\nlet alias = (discard field; Model(label: 1))\nsetJsPropCstring(alias,"value","ordinary")\n', [])
        self.compiled_control('import isonim/web/dom_api\ntype Model = object\n  label: int\nproc setJsPropCstring(model: Model; name, value: string) = discard\nlet field = dom_api.createElement(dom_api.document,"input")\nproc ordinary() =\n  let field = Model(label: 1)\n  let alias = (discard 0; field)\n  setJsPropCstring(alias,"value","ordinary")\nordinary()\n', [])

    def test_nim_compiled_statement_list_nonfield_alias_and_mutation_controls(self):
        for constructor, prop in [('createElement(dom_api.document,"button")', 'value'),
                                  ('createTextNode(dom_api.document,"label")', 'textContent')]:
            with self.subTest(constructor=constructor):
                self.compiled_control('import isonim/web/dom_api\nlet alias = (discard 0; dom_api.'+constructor+')\ndom_api.setJsPropCstring(alias,"'+prop+'","ordinary")\n', [])
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet alias = (discard 0; field)\ndom_api.setAttribute(alias,"type","text")\ndom_api.setJsPropCstring(field,"value","seed")\n', [(6, 'free-text binding')])

    def test_nim_compiled_capture_current_binding(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document, "input")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate() =\n  dom_api.setAttribute(field,"type","text")\nfield = dom_api.createElement(dom_api.document, "input")\ndom_api.setAttribute(field,"type","checkbox")\nmutate()\ndom_api.setJsPropCstring(field,"value","seed")\n', [(9, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_uninvoked_binding(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document, "input")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate() =\n  dom_api.setAttribute(field,"type","text")\nfield = dom_api.createElement(dom_api.document, "input")\ndom_api.setAttribute(field,"type","checkbox")\ndom_api.setJsPropCstring(field,"value","ok")\n', [])

    def test_nim_compiled_capture_routine_local_shadow(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document, "input")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate() =\n  let field = dom_api.createElement(dom_api.document,"input")\n  dom_api.setAttribute(field,"type","text")\nfield = dom_api.createElement(dom_api.document, "input")\ndom_api.setAttribute(field,"type","checkbox")\nmutate()\ndom_api.setJsPropCstring(field,"value","ok")\n', [])

    def test_nim_compiled_capture_discarded_alias_stays_clean(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias = field\nproc mutate() = dom_api.setAttribute(field,"type","text")\nfield = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nmutate()\ndom_api.setJsPropCstring(oldalias,"value","seed")\ndom_api.setJsPropCstring(field,"value","seed")\n', [(10, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_immutable_alias_retains_object(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias = field\nproc mutate() = dom_api.setAttribute(oldalias,"type","text")\nfield = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nmutate()\ndom_api.setJsPropCstring(oldalias,"value","seed")\ndom_api.setJsPropCstring(field,"value","seed")\n', [(9, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_caller_shadow_resolves_outer(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate() = dom_api.setAttribute(field,"type","text")\nfield = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nblock:\n  let field = dom_api.createElement(dom_api.document,"input")\n  dom_api.setAttribute(field,"type","checkbox")\n  mutate()\n  dom_api.setJsPropCstring(field,"value","seed")\ndom_api.setJsPropCstring(field,"value","seed")\n', [(12, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_call_before_replacement(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate() = dom_api.setAttribute(field,"type","text")\nmutate()\ndom_api.setJsPropCstring(field,"value","seed")\nfield = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\ndom_api.setJsPropCstring(field,"value","seed")\n', [(6, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_local_alias_dependency(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate() =\n  let localalias = field\n  dom_api.setAttribute(localalias,"type","text")\nfield = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nmutate()\ndom_api.setJsPropCstring(field,"value","seed")\n', [(10, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_nested_invocation(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate() =\n  proc inner() = dom_api.setAttribute(field,"type","text")\n  inner()\nfield = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nmutate()\ndom_api.setJsPropCstring(field,"value","seed")\n', [(10, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_replacement_readonly(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate() = dom_api.setAttribute(field,"id","label")\nfield = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nmutate()\ndom_api.setJsPropCstring(field,"value","seed")\n', [])

    def test_nim_compiled_capture_branch_binding_join(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias = field\nproc mutate() = dom_api.setAttribute(field,"type","text")\nif true:\n  field = dom_api.createElement(dom_api.document,"input")\n  dom_api.setAttribute(field,"type","checkbox")\nmutate()\ndom_api.setJsPropCstring(oldalias,"value","seed")\ndom_api.setJsPropCstring(field,"value","seed")\n', [(10, 'unresolved DOM privacy binding'), (11, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_loop_binding_join(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate() = dom_api.setAttribute(field,"type","text")\nfor index in 0..1:\n  field = dom_api.createElement(dom_api.document,"input")\n  dom_api.setAttribute(field,"type","checkbox")\n  mutate()\ndom_api.setJsPropCstring(field,"value","seed")\n', [(9, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_deferred_rebinding(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate() =\n  field = dom_api.createElement(dom_api.document,"textarea")\nfield = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nmutate()\ndom_api.setJsPropCstring(field,"value","seed")\n', [(9, 'unresolved DOM privacy binding')])

    def test_nim_capture_binding_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor='values += [env[root] for root in identity[1]\n                           if isinstance(env.get(root), Allocation)]'
        self.assertEqual(scanner.count(anchor),1)
        directory=Path(self.temp.name)/'drop-current-capture-binding';directory.mkdir()
        (directory/'lint_nondet.py').write_text(scanner.replace(anchor,'values += []'))
        (directory/'lint_privacy.py').write_text(helper)
        tests=Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
              'PROJECT = Path('+repr(str(PROJECT))+')',1)
        (directory/'test_lint_nondet.py').write_text(tests)
        command=[sys.executable,str(directory/'test_lint_nondet.py'),
                 'NimPrivacyTests.test_nim_compiled_capture_current_binding',
                 'NimPrivacyTests.test_nim_compiled_capture_uninvoked_binding',
                 'NimPrivacyTests.test_nim_compiled_capture_routine_local_shadow']
        self.retain_inputs(command)
        result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr)
        self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: test_nim_compiled_capture_current_binding',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/ordinary.nim',result.stderr)
        self.assertIn('unresolved DOM privacy binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)

    def test_nim_compiled_capture_idempotent_declaration_future_write(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","text")\nproc mutate() = dom_api.setAttribute(field,"type","text")\nfield = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nmutate()\ndom_api.setJsPropCstring(field,"value","seed")\n', [(8, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_old_tag_does_not_hide_future_effect(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"div")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate() = dom_api.setAttribute(field,"type","text")\nfield = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nmutate()\ndom_api.setJsPropCstring(field,"value","seed")\n', [(8, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_binding_write_keeps_old_object_clean(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias = field\nproc mutate() =\n  field = dom_api.createElement(dom_api.document,"textarea")\nmutate()\ndom_api.setJsPropCstring(oldalias,"value","seed")\ndom_api.setJsPropCstring(field,"value","seed")\n', [(9, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_rebind_then_metadata_keeps_old_clean(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias = field\nproc mutate() =\n  field = dom_api.createElement(dom_api.document,"input")\n  dom_api.setAttribute(field,"type","text")\nmutate()\ndom_api.setJsPropCstring(oldalias,"value","seed")\ndom_api.setJsPropCstring(field,"value","seed")\n', [(10, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_dependency_branch_union(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate() =\n  let other = dom_api.createElement(dom_api.document,"input")\n  dom_api.setAttribute(other,"type","checkbox")\n  var localalias = other\n  if true: localalias = field\n  dom_api.setAttribute(localalias,"type","text")\nfield = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nmutate()\ndom_api.setJsPropCstring(field,"value","seed")\n', [(13, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_current_nonfield_metadata_control(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"div")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate() = dom_api.setAttribute(field,"type","text")\nmutate()\ndom_api.setJsPropCstring(field,"value","seed")\n', [])

    def test_nim_compiled_capture_optional_rebind_retains_old_possible_receiver(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias = field\nproc mutate() =\n  if true: field = dom_api.createElement(dom_api.document,"textarea")\n  dom_api.setAttribute(field,"type","text")\nmutate()\ndom_api.setJsPropCstring(oldalias,"value","seed")\ndom_api.setJsPropCstring(field,"value","seed")\n', [(9, 'unresolved DOM privacy binding'), (10, 'unresolved DOM privacy binding')])

    def test_nim_capture_rebinding_alias_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor='possible_aliases=(current,) if effect[1] else ())'
        self.assertEqual(scanner.count(anchor),1)
        directory=Path(self.temp.name)/'retain-discarded-capture-object';directory.mkdir()
        (directory/'lint_nondet.py').write_text(scanner.replace(anchor,'possible_aliases=(current,))'))
        (directory/'lint_privacy.py').write_text(helper)
        tests=Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
              'PROJECT = Path('+repr(str(PROJECT))+')',1)
        (directory/'test_lint_nondet.py').write_text(tests)
        command=[sys.executable,str(directory/'test_lint_nondet.py'),
                 'NimPrivacyTests.test_nim_compiled_capture_rebind_then_metadata_keeps_old_clean',
                 'NimPrivacyTests.test_nim_compiled_capture_uninvoked_binding',
                 'NimPrivacyTests.test_nim_compiled_capture_routine_local_shadow']
        self.retain_inputs(command)
        result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr)
        self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: test_nim_compiled_capture_rebind_then_metadata_keeps_old_clean',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/ordinary.nim',result.stderr)
        self.assertIn('unresolved DOM privacy binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)

    def test_nim_compiled_capture_immutable_binding_future_metadata(self):
        self.compiled_control('import isonim/web/dom_api\nlet field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","text")\nproc mutate()=dom_api.setAttribute(field,"type","text")\ndom_api.setAttribute(field,"type","checkbox")\nmutate()\ndom_api.setJsPropCstring(field,"value","seed")\n', [(7, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_local_slot_rebinding_control(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate()=\n  var scratch=field\n  scratch=dom_api.createElement(dom_api.document,"textarea")\nmutate()\ndom_api.setJsPropCstring(field,"value","seed")\n', [])

    def test_nim_compiled_capture_immutable_uninvoked_control(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","text")\nproc mutate() = dom_api.setAttribute(field,"type","text")\ndom_api.setAttribute(field,"type","checkbox")\ndom_api.setJsPropCstring(field,"value","seed")\n', [])

    def test_nim_compiled_capture_local_reference_mutation_reaches_outer(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate() =\n  var scratch = field\n  dom_api.setAttribute(scratch,"type","text")\nmutate()\ndom_api.setJsPropCstring(field,"value","seed")\n', [(8, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_nested_private_slot_dependency_reset(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate() =\n  var scratch = field\n  proc replaceScratch() = scratch = dom_api.createElement(dom_api.document,"textarea")\n  replaceScratch()\n  dom_api.setAttribute(scratch,"type","text")\nmutate()\ndom_api.setJsPropCstring(field,"value","seed")\n', [])

    def test_nim_compiled_capture_nested_caller_shadow_hidden_outer_root(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate() = dom_api.setAttribute(field,"type","text")\nblock:\n  let field = dom_api.createElement(dom_api.document,"input")\n  dom_api.setAttribute(field,"type","checkbox")\n  proc wrapper() = mutate()\n  wrapper()\n  dom_api.setJsPropCstring(field,"value","seed")\ndom_api.setJsPropCstring(field,"value","seed")\n', [(11, 'unresolved DOM privacy binding')])

    def test_nim_capture_local_slot_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor="elif effect[0] != 'rebind':"
        self.assertEqual(scanner.count(anchor),1)
        directory=Path(self.temp.name)/'follow-reference-alias-for-slot-write';directory.mkdir()
        (directory/'lint_nondet.py').write_text(scanner.replace(anchor,'else:'))
        (directory/'lint_privacy.py').write_text(helper)
        tests=Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
              'PROJECT = Path('+repr(str(PROJECT))+')',1)
        (directory/'test_lint_nondet.py').write_text(tests)
        command=[sys.executable,str(directory/'test_lint_nondet.py'),
                 'NimPrivacyTests.test_nim_compiled_capture_local_slot_rebinding_control',
                 'NimPrivacyTests.test_nim_compiled_capture_uninvoked_binding',
                 'NimPrivacyTests.test_nim_compiled_capture_routine_local_shadow']
        self.retain_inputs(command)
        result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr)
        self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: test_nim_compiled_capture_local_slot_rebinding_control',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/ordinary.nim',result.stderr)
        self.assertIn('unresolved DOM privacy binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)

    def test_nim_compiled_capture_include_observation(self):
        self.write('privacy_fragment.nim', 'discard 0\n')
        for invoke in [False, True]:
            with self.subTest(invoke=invoke):
                source='import isonim/web/dom_api\nlet field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc mutate()=\n  include privacy_fragment\n'+('mutate()\n' if invoke else '')+'dom_api.setJsPropCstring(field,"value","seed")\n'
                self.compiled_control(source,[(source.count('\n'),'unresolved DOM privacy binding')] if invoke else [])

    def test_nim_compiled_capture_known_rhs_reference(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias=field\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nproc mutate()=\n  field=other\n  dom_api.setAttribute(field,"type","text")\nmutate()\ndom_api.setJsPropCstring(oldalias,"value","ok")\ndom_api.setJsPropCstring(other,"value","seed")\n', [(12, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_optional_rhs_composition(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias=field\nlet first=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(first,"type","checkbox")\nlet second=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(second,"type","checkbox")\nproc mutate()=\n  field=first\n  if true: field=second\n  dom_api.setAttribute(field,"type","text")\nmutate()\ndom_api.setJsPropCstring(oldalias,"value","ok")\ndom_api.setJsPropCstring(first,"value","seed")\ndom_api.setJsPropCstring(second,"value","seed")\n', [(15, 'unresolved DOM privacy binding'), (16, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_overload_alternative_graphs(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias=field\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nproc mutate(x: string)=dom_api.setAttribute(field,"type","text")\nproc mutate(x: int)=field=other\nmutate("text")\ndom_api.setJsPropCstring(oldalias,"value","seed")\ndom_api.setJsPropCstring(other,"value","ok")\n', [(10, 'unresolved DOM privacy binding')])

        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias=field\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nproc mutate(x: int)=field=other\nproc mutate(x: string)=dom_api.setAttribute(field,"type","text")\nmutate("text")\ndom_api.setJsPropCstring(oldalias,"value","seed")\ndom_api.setJsPropCstring(other,"value","ok")\n', [(10, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_rhs_assignment_without_mutation(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias=field\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nproc mutate()=\n  field=other\nmutate()\ndom_api.setJsPropCstring(oldalias,"value","seed")\ndom_api.setJsPropCstring(other,"value","seed")\n', [])

    def test_nim_compiled_capture_rhs_readonly_metadata(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias=field\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nproc mutate()=\n  field=other\n  dom_api.setAttribute(field,"id","label")\nmutate()\ndom_api.setJsPropCstring(oldalias,"value","seed")\ndom_api.setJsPropCstring(other,"value","seed")\n', [])

    def test_nim_compiled_capture_local_rhs_alias_transfer(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias=field\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nproc mutate()=\n  let localalias=other\n  field=localalias\n  dom_api.setAttribute(field,"type","text")\nmutate()\ndom_api.setJsPropCstring(oldalias,"value","seed")\ndom_api.setJsPropCstring(other,"value","seed")\n', [(13, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_unconditional_rhs_composition(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias=field\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nlet last=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(last,"type","checkbox")\nproc mutate()=\n  field=other\n  field=last\n  dom_api.setAttribute(field,"type","text")\nmutate()\ndom_api.setJsPropCstring(oldalias,"value","seed")\ndom_api.setJsPropCstring(other,"value","seed")\ndom_api.setJsPropCstring(last,"value","seed")\n', [(16, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_harmless_overload_alternatives(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias=field\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nproc mutate(x: string)=dom_api.setAttribute(field,"id","label")\nproc mutate(x: int)=field=other\nmutate("label")\ndom_api.setJsPropCstring(oldalias,"value","seed")\ndom_api.setJsPropCstring(other,"value","seed")\n', [])

    def test_nim_capture_rhs_edge_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor='*rhs_aliases'
        self.assertEqual(scanner.count(anchor),1)
        directory=Path(self.temp.name)/'drop-known-rhs-reference';directory.mkdir()
        (directory/'lint_nondet.py').write_text(scanner.replace(anchor,'*()'))
        (directory/'lint_privacy.py').write_text(helper)
        tests=Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
              'PROJECT = Path('+repr(str(PROJECT))+')',1)
        (directory/'test_lint_nondet.py').write_text(tests)
        command=[sys.executable,str(directory/'test_lint_nondet.py'),
                 'NimPrivacyTests.test_nim_compiled_capture_known_rhs_reference',
                 'NimPrivacyTests.test_nim_compiled_capture_uninvoked_binding',
                 'NimPrivacyTests.test_nim_compiled_capture_routine_local_shadow']
        self.retain_inputs(command)
        result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr)
        self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: test_nim_compiled_capture_known_rhs_reference',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/ordinary.nim',result.stderr)
        self.assertIn('unresolved DOM privacy binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)

    def test_nim_capture_overload_graph_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor='branch = view(env)'
        self.assertEqual(scanner.count(anchor),1)
        directory=Path(self.temp.name)/'reuse-one-overload-graph';directory.mkdir()
        (directory/'lint_nondet.py').write_text(scanner.replace(anchor,'branch = env'))
        (directory/'lint_privacy.py').write_text(helper)
        tests=Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
              'PROJECT = Path('+repr(str(PROJECT))+')',1)
        (directory/'test_lint_nondet.py').write_text(tests)
        command=[sys.executable,str(directory/'test_lint_nondet.py'),
                 'NimPrivacyTests.test_nim_compiled_capture_overload_alternative_graphs',
                 'NimPrivacyTests.test_nim_compiled_capture_uninvoked_binding',
                 'NimPrivacyTests.test_nim_compiled_capture_routine_local_shadow']
        self.retain_inputs(command)
        result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr)
        self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: test_nim_compiled_capture_overload_alternative_graphs',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/ordinary.nim',result.stderr)
        self.assertIn('unresolved DOM privacy binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)

    def test_nim_compiled_capture_composition_nested_overload_wrapper(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias=field\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nproc mutate(x: string)=dom_api.setAttribute(field,"type","text")\nproc mutate(x: int)=field=other\nproc wrapper()=mutate("text")\nwrapper()\ndom_api.setJsPropCstring(oldalias,"value","seed")\ndom_api.setJsPropCstring(other,"value","seed")\n', [(11, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_composition_repeated_metadata_before_and_after_rebind(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias=field\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nproc mutate()=\n  dom_api.setAttribute(field,"type","text")\n  field=other\n  dom_api.setAttribute(field,"type","text")\nmutate()\ndom_api.setJsPropCstring(oldalias,"value","seed")\ndom_api.setJsPropCstring(other,"value","seed")\n', [(12, 'unresolved DOM privacy binding'), (13, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_composition_loop_rebind_then_next_iteration_metadata(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias=field\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nproc mutate()=\n  for index in 0..1:\n    dom_api.setAttribute(field,"type","text")\n    field=other\nmutate()\ndom_api.setJsPropCstring(oldalias,"value","seed")\ndom_api.setJsPropCstring(other,"value","seed")\n', [(12, 'unresolved DOM privacy binding'), (13, 'unresolved DOM privacy binding')])

    def test_nim_compiled_capture_composition_local_reference_before_cell_rebind(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet oldalias=field\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nproc mutate()=\n  let snapshot=field\n  field=other\n  dom_api.setAttribute(snapshot,"type","text")\nmutate()\ndom_api.setJsPropCstring(oldalias,"value","seed")\ndom_api.setJsPropCstring(other,"value","seed")\n', [(12, 'unresolved DOM privacy binding')])

    def test_nim_capture_reference_snapshot_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor="receiver = state.get(effect[1]) if effect[0] == 'at-reference' else state.get(root)"
        self.assertEqual(scanner.count(anchor),1)
        directory=Path(self.temp.name)/'follow-cell-instead-of-copied-reference';directory.mkdir()
        (directory/'lint_nondet.py').write_text(scanner.replace(anchor,'receiver = state.get(root)'))
        (directory/'lint_privacy.py').write_text(helper)
        tests=Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
              'PROJECT = Path('+repr(str(PROJECT))+')',1)
        (directory/'test_lint_nondet.py').write_text(tests)
        command=[sys.executable,str(directory/'test_lint_nondet.py'),
                 'NimPrivacyTests.test_nim_compiled_capture_composition_local_reference_before_cell_rebind',
                 'NimPrivacyTests.test_nim_compiled_capture_uninvoked_binding',
                 'NimPrivacyTests.test_nim_compiled_capture_routine_local_shadow']
        self.retain_inputs(command)
        result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr)
        self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: test_nim_compiled_capture_composition_local_reference_before_cell_rebind',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/ordinary.nim',result.stderr)
        self.assertIn('unresolved DOM privacy binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)

    def test_nim_capture_choice_observation_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor='if not suppress_operation_observations:'
        self.assertEqual(scanner.count(anchor),1)
        directory=Path(self.temp.name)/'publish-provisional-choice-operations';directory.mkdir()
        (directory/'lint_nondet.py').write_text(scanner.replace(anchor,'if True:'))
        (directory/'lint_privacy.py').write_text(helper)
        tests=Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
              'PROJECT = Path('+repr(str(PROJECT))+')',1)
        (directory/'test_lint_nondet.py').write_text(tests)
        command=[sys.executable,str(directory/'test_lint_nondet.py'),
                 'NimPrivacyTests.test_nim_compiled_capture_composition_nested_overload_wrapper',
                 'NimPrivacyTests.test_nim_compiled_capture_uninvoked_binding',
                 'NimPrivacyTests.test_nim_compiled_capture_routine_local_shadow']
        self.retain_inputs(command)
        result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr)
        self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: test_nim_compiled_capture_composition_nested_overload_wrapper',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/ordinary.nim',result.stderr)
        self.assertIn('unresolved DOM privacy binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)

    def test_nim_capture_loop_written_join_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor='result[key] = any(vals)'
        self.assertEqual(scanner.count(anchor),1)
        directory=Path(self.temp.name)/'drop-written-cell-join-coordinate';directory.mkdir()
        (directory/'lint_nondet.py').write_text(scanner.replace(anchor,'result[key] = False'))
        (directory/'lint_privacy.py').write_text(helper)
        tests=Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
              'PROJECT = Path('+repr(str(PROJECT))+')',1)
        (directory/'test_lint_nondet.py').write_text(tests)
        command=[sys.executable,str(directory/'test_lint_nondet.py'),
                 'NimPrivacyTests.test_nim_compiled_capture_composition_loop_rebind_then_next_iteration_metadata',
                 'NimPrivacyTests.test_nim_compiled_capture_uninvoked_binding',
                 'NimPrivacyTests.test_nim_compiled_capture_routine_local_shadow']
        self.retain_inputs(command)
        result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr)
        self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: test_nim_compiled_capture_composition_loop_rebind_then_next_iteration_metadata',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/ordinary.nim',result.stderr)
        self.assertIn('unresolved DOM privacy binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)

    def test_nim_compiled_invocation_repeated_helper_replacement(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nlet oldalias=field\nproc helper()=dom_api.setAttribute(field,"type","text")\nproc wrapper()=\n  helper()\n  field=other\n  helper()\nwrapper()\ndom_api.setJsPropCstring(other,"value","seed")\n', [(13, 'unresolved DOM privacy binding')])

    def test_nim_compiled_invocation_repeated_helper_uninvoked(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nlet oldalias=field\nproc helper()=dom_api.setAttribute(field,"type","text")\nproc wrapper()=\n  helper()\n  field=other\n  helper()\ndom_api.setJsPropCstring(other,"value","seed")\n', [])

    def test_nim_compiled_invocation_repeated_helper_single(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nlet oldalias=field\nproc helper()=dom_api.setAttribute(field,"type","text")\nproc wrapper()=\n  helper()\nwrapper()\ndom_api.setJsPropCstring(other,"value","seed")\n', [])

    def test_nim_compiled_invocation_repeated_helper_readonly(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nlet oldalias=field\nproc helper()=discard field\nproc wrapper()=\n  helper()\n  field=other\n  helper()\nwrapper()\ndom_api.setJsPropCstring(other,"value","seed")\n', [])

    def test_nim_compiled_invocation_nested_wrapper(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nlet oldalias=field\nproc helper()=dom_api.setAttribute(field,"type","text")\nproc wrapper()=\n  helper()\n  field=other\n  helper()\nproc outer()=wrapper()\nouter()\ndom_api.setJsPropCstring(other,"value","seed")\n', [(14, 'unresolved DOM privacy binding')])

    def test_nim_compiled_invocation_irrelevant_id(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nlet oldalias=field\nproc helper()=dom_api.setAttribute(field,"id","safe")\nproc wrapper()=\n  helper()\n  field=other\n  helper()\nwrapper()\ndom_api.setJsPropCstring(other,"value","seed")\n', [])

    def test_nim_compiled_invocation_caller_shadow(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nlet oldalias=field\nproc helper()=dom_api.setAttribute(field,"type","text")\nproc wrapper()=\n  helper()\n  field=other\n  helper()\nblock:\n  let field=dom_api.createElement(dom_api.document,"button")\n  wrapper()\ndom_api.setJsPropCstring(other,"value","seed")\n', [(15, 'unresolved DOM privacy binding')])

    def test_nim_compiled_invocation_copied_reference(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nlet oldalias=field\nproc helper()=\n  let snapshot=field\n  dom_api.setAttribute(snapshot,"type","text")\nproc wrapper()=\n  helper()\n  field=other\n  helper()\nwrapper()\ndom_api.setJsPropCstring(other,"value","seed")\n', [(15, 'unresolved DOM privacy binding')])

    def test_nim_compiled_invocation_loop_same_callsite(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nlet oldalias=field\nproc helper()=dom_api.setAttribute(field,"type","text")\nproc wrapper()=\n  for i in 0..1:\n    helper()\n    field=other\nwrapper()\ndom_api.setJsPropCstring(other,"value","seed")\n', [(13, 'unresolved DOM privacy binding')])

    def test_nim_compiled_invocation_loop_same_callsite_copied_reference(self):
        self.compiled_control('import isonim/web/dom_api\nvar field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet other=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nlet oldalias=field\nproc helper()=\n  let snapshot=field\n  dom_api.setAttribute(snapshot,"type","text")\nproc wrapper()=\n  for i in 0..1:\n    helper()\n    field=other\nwrapper()\ndom_api.setJsPropCstring(other,"value","seed")\n', [(15, 'unresolved DOM privacy binding')])

    def test_nim_invocation_context_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor='execute_choices(env, invocation_program(identity[2], ts[0][2]))'
        self.assertEqual(scanner.count(anchor),1)
        directory=Path(self.temp.name)/'remove-authored-invocation-context';directory.mkdir()
        (directory/'lint_nondet.py').write_text(scanner.replace(anchor,'execute_choices(env, identity[2])'))
        (directory/'lint_privacy.py').write_text(helper)
        tests=Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
              'PROJECT = Path('+repr(str(PROJECT))+')',1)
        (directory/'test_lint_nondet.py').write_text(tests)
        command=[sys.executable,str(directory/'test_lint_nondet.py'),
                 'NimPrivacyTests.test_nim_compiled_invocation_repeated_helper_replacement',
                 'NimPrivacyTests.test_nim_compiled_invocation_repeated_helper_uninvoked',
                 'NimPrivacyTests.test_nim_compiled_invocation_repeated_helper_readonly']
        self.retain_inputs(command)
        result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr)
        self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn('FAIL: test_nim_compiled_invocation_repeated_helper_replacement',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/ordinary.nim',result.stderr)
        self.assertIn('unresolved DOM privacy binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)

    def test_nim_compiled_literal_reviewer_shadow_false(self):
        self.compiled_control('import isonim/web/dom_api\nlet false = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_literal_reviewer_string_false(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", "false")\nfield.textContent = "seed"\n', [])

    def test_nim_compiled_literal_reviewer_string_true(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", "true")\nfield.textContent = "seed"\n', [(4, 'free-text binding')])

    def test_nim_compiled_literal_reviewer_model(self):
        self.compiled_control('type Model = object\n  textContent: cstring\nlet false = cstring"true"\nvar field = Model()\nfield.textContent = false\n', [])

    def test_nim_compiled_literal_let_shadow_false(self):
        self.compiled_control('import isonim/web/dom_api\nlet false = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_literal_var_shadow_false(self):
        self.compiled_control('import isonim/web/dom_api\nvar false = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_literal_const_shadow_false(self):
        self.compiled_control('import isonim/web/dom_api\nconst false = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_literal_quoted_shadow_true(self):
        self.compiled_control('import isonim/web/dom_api\nlet `true` = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", `true`)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_literal_style_shadow_false(self):
        self.compiled_control('import isonim/web/dom_api\nlet fAl_se = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_literal_first_character_distinct(self):
        self.compiled_control('import isonim/web/dom_api\nlet False = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setJsPropBool(field, "contentEditable", false)\nfield.textContent = "seed"\n', [])

    def test_nim_compiled_literal_builtin_boolean_values(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setJsPropBool(field, "contentEditable", false)\nfield.textContent = "ordinary"\ndom_api.setJsPropBool(field, "contentEditable", `true`)\nfield.textContent = "seed"\n', [(6, 'free-text binding')])

    def test_nim_compiled_literal_shadow_constructor_tag(self):
        self.compiled_control('import isonim/web/dom_api\nlet false = cstring"input"\nlet field = dom_api.createElement(dom_api.document, false)\ndom_api.setJsPropCstring(field, "value", "seed")\n', [(4, 'unresolved DOM privacy binding')])

    def test_nim_compiled_literal_shadow_metadata_name(self):
        self.compiled_control('import isonim/web/dom_api\nlet false = cstring"type"\nlet field = dom_api.createElement(dom_api.document, "input")\ndom_api.setAttribute(field, "type", "checkbox")\ndom_api.setAttribute(field, false, "text")\ndom_api.setJsPropCstring(field, "value", "seed")\n', [(6, 'unresolved DOM privacy binding')])

    def test_nim_compiled_literal_shadow_metadata_value(self):
        self.compiled_control('import isonim/web/dom_api\nlet true = cstring"text"\nlet field = dom_api.createElement(dom_api.document, "input")\ndom_api.setAttribute(field, "type", "checkbox")\ndom_api.setAttribute(field, "type", true)\ndom_api.setJsPropCstring(field, "value", "seed")\n', [(6, 'free-text binding')])

    def test_nim_compiled_literal_formal_shadow(self):
        self.compiled_control('import isonim/web/dom_api\nproc component(false: cstring) =\n  let field = dom_api.createElement(dom_api.document, "div")\n  dom_api.setAttribute(field, "contenteditable", false)\n  field.textContent = "seed"\ncomponent("true")\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_literal_routine_shadow(self):
        self.compiled_control('import isonim/web/dom_api\ntemplate false: cstring = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_literal_sequential_shadow_and_restore(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setJsPropBool(field, "contentEditable", false)\nfield.textContent = "ordinary"\nblock:\n  let false = cstring"true"\n  dom_api.setAttribute(field, "contenteditable", false)\n  field.textContent = "seed"\ndom_api.setJsPropBool(field, "contentEditable", false)\nfield.textContent = "ordinary"\n', [(8, 'unresolved DOM privacy binding')])

    def test_nim_compiled_literal_noneditable_button_text_controls(self):
        self.compiled_control('import isonim/web/dom_api\nlet false = cstring"true"\nlet button = dom_api.createElement(dom_api.document, "button")\nbutton.textContent = "label"\nlet text = dom_api.createTextNode(dom_api.document, "label")\ntext.textContent = "ordinary"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", "false")\nfield.textContent = "ordinary"\n', [])

    def test_nim_compiled_literal_imported_symbol_shadow(self):
        helper = self.write('symbols.nim', 'let `false`* = cstring"true"\n')
        self.compiled_control('import isonim/web/dom_api\nfrom symbols import `false`\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", `false`)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])
        helper.unlink()

    def test_nim_compiled_literal_unknown_import_context(self):
        helper = self.write('symbols.nim', 'let `false`* = cstring"true"\n')
        self.compiled_control('import isonim/web/dom_api\nimport symbols\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", `false`)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])
        helper.unlink()

    def test_nim_literal_provenance_production_inverse(self):
        scanner=SCRIPT.read_text();helper=SCRIPT.with_name('lint_privacy.py').read_text()
        anchor="name in {'true', 'false'} and name not in env"
        self.assertEqual(scanner.count(anchor),1)
        directory=Path(self.temp.name)/'remove-literal-provenance-guard';directory.mkdir()
        (directory/'lint_nondet.py').write_text(scanner.replace(anchor,"name in {'true', 'false'}"))
        (directory/'lint_privacy.py').write_text(helper)
        tests=Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
              'PROJECT = Path('+repr(str(PROJECT))+')',1)
        (directory/'test_lint_nondet.py').write_text(tests)
        command=[sys.executable,str(directory/'test_lint_nondet.py'),
                 'NimPrivacyTests.test_nim_compiled_literal_reviewer_shadow_false',
                 'NimPrivacyTests.test_nim_compiled_literal_reviewer_string_false',
                 'NimPrivacyTests.test_nim_compiled_literal_reviewer_model']
        self.retain_inputs(command)
        result=subprocess.run(command,capture_output=True,text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr)
        self.retain_inputs(command)
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertEqual(result.stderr.count('\nFAIL: '),1)
        self.assertIn('FAIL: test_nim_compiled_literal_reviewer_shadow_false',result.stderr)
        self.assertIn('AssertionError: Lists differ',result.stderr)
        self.assertIn('site/src/ordinary.nim',result.stderr)
        self.assertIn('unresolved DOM privacy binding',result.stderr)
        self.assertIn('FAILED (failures=1)',result.stderr)
        self.assertNotIn('ERROR:',result.stderr)


    def test_nim_compiled_declaration_reviewer_model(self):
        self.compiled_control('type Model = object\n  textContent: cstring\nlet false, other = cstring"true"\nvar field = Model()\nfield.textContent = false\n', [])

    def test_nim_compiled_declaration_reviewer_grouped_shadow(self):
        self.compiled_control('import isonim/web/dom_api\nlet false, other = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_reviewer_single_shadow(self):
        self.compiled_control('import isonim/web/dom_api\nlet false = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_reviewer_string_false(self):
        self.compiled_control('import isonim/web/dom_api\nlet false = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", "false")\nfield.textContent = "seed"\n', [])

    def test_nim_compiled_declaration_reviewer_string_true(self):
        self.compiled_control('import isonim/web/dom_api\nlet false = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", "true")\nfield.textContent = "seed"\n', [(5, 'free-text binding')])

    def test_nim_compiled_declaration_group_last(self):
        self.compiled_control('import isonim/web/dom_api\nlet other, false = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_var_typed(self):
        self.compiled_control('import isonim/web/dom_api\nvar other, `fAl_se`: cstring = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_export_pragma(self):
        self.compiled_control('import isonim/web/dom_api\nlet false* {.used.}, other {.used.}: cstring = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_single_pragma(self):
        self.compiled_control('import isonim/web/dom_api\nlet false {.used.}: cstring = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_single_export(self):
        self.compiled_control('import isonim/web/dom_api\nlet false* = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_const_pragma(self):
        self.compiled_control('import isonim/web/dom_api\nconst false {.used.} = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_tuple(self):
        self.compiled_control('import isonim/web/dom_api\nlet (false, other) = (cstring"true", 1)\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_nested_tuple(self):
        self.compiled_control('import isonim/web/dom_api\nlet (other, (false, last)) = (1, (cstring"true", 2))\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_const_tuple(self):
        self.compiled_control('import isonim/web/dom_api\nconst (false, other) = (cstring"true", 1)\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_var_tuple_typed(self):
        self.compiled_control('import isonim/web/dom_api\nvar (false, other): (cstring, int) = (cstring"true", 1)\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_uninitialized_pragma(self):
        self.compiled_control('import isonim/web/dom_api\nvar false {.used.}: cstring\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_section_group(self):
        self.compiled_control('import isonim/web/dom_api\nlet\n  other, false = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setAttribute(field, "contenteditable", false)\nfield.textContent = "seed"\n', [(6, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_restore(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setJsPropBool(field,"contentEditable",false)\nfield.textContent="ordinary"\nblock:\n  let other, false = cstring"true"\n  dom_api.setAttribute(field,"contenteditable",false)\n  field.textContent="seed"\ndom_api.setJsPropBool(field,"contentEditable",false)\nfield.textContent="ordinary"\n', [(8, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_initializer_before_shadow(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "div")\nblock:\n  let false, other = (dom_api.setJsPropBool(field,"contentEditable",false); false)\n  field.textContent="seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_tuple_initializer_before_shadow(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document, "div")\nblock:\n  let (false, other) = (cstring"true", (dom_api.setJsPropBool(field,"contentEditable",false); 1))\n  field.textContent="ordinary"\n', [])

    def test_nim_compiled_declaration_genuine_boolean_group(self):
        self.compiled_control('import isonim/web/dom_api\nlet False, other = cstring"true"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setJsPropBool(field,"contentEditable",false)\nfield.textContent="ordinary"\ndom_api.setJsPropBool(field,"contentEditable",true)\nfield.textContent="seed"\n', [(7, 'free-text binding')])

    def test_nim_compiled_declaration_fresh_group(self):
        self.compiled_control('import isonim/web/dom_api\nlet a, b = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(a,"type","checkbox")\nif false: discard\ndom_api.setJsPropCstring(a,"value","ordinary")\ndom_api.setJsPropCstring(b,"value","seed")\n', [(6, 'free-text binding')])

    def test_nim_compiled_declaration_alias_group(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\nlet a, b = field\ndom_api.setAttribute(a,"type","checkbox")\ndom_api.setJsPropCstring(b,"value","ordinary")\ndom_api.setAttribute(b,"type","text")\ndom_api.setJsPropCstring(field,"value","seed")\n', [(7, 'free-text binding')])

    def test_nim_compiled_declaration_tuple_direct_alias(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\nlet (a, (b, n)) = (field,(field,1))\ndom_api.setAttribute(a,"type","checkbox")\ndom_api.setJsPropCstring(b,"value","ordinary")\ndom_api.setAttribute(b,"type","text")\ndom_api.setJsPropCstring(field,"value","seed")\n', [(7, 'free-text binding')])

    def test_nim_compiled_declaration_tuple_fresh_and_model(self):
        self.compiled_control('import isonim/web/dom_api\ntype Model = object\n  textContent: cstring\nvar (field, model) = (dom_api.createElement(dom_api.document,"input"), Model())\nmodel.textContent="ordinary"\ndom_api.setJsPropCstring(field,"value","seed")\n', [(6, 'free-text binding')])

    def test_nim_compiled_declaration_group_captured_rebind(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc replace(): int =\n  field = dom_api.createElement(dom_api.document,"input")\n  result = 1\nlet a, b = replace()\ndom_api.setJsPropCstring(field,"value","seed")\n', [(8, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_group_capture_alias(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nproc replace(): int =\n  let a, b = field\n  field = dom_api.createElement(dom_api.document,"input")\n  dom_api.setAttribute(b,"type","text")\n  result = 1\nlet old = field\ndiscard replace()\ndom_api.setJsPropCstring(old,"value","seed")\n', [(11, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_typed_rhs_not_binders(self):
        self.compiled_control('import isonim/web/dom_api\ntype false = cstring\nlet other, last: false = "ordinary"\nlet field = dom_api.createElement(dom_api.document, "div")\ndom_api.setJsPropBool(field,"contentEditable",true)\nfield.textContent="seed"\n', [(6, 'free-text binding')])

    def test_nim_declaration_binding_production_inverse(self):
        scanner = SCRIPT.read_text(); helper = SCRIPT.with_name('lint_privacy.py').read_text()
        start = scanner.index('        # DECLARATION-BINDING-START:')
        end = scanner.index('        # DECLARATION-BINDING-END', start)
        directory = Path(self.temp.name)/'remove-declaration-binding'; directory.mkdir()
        (directory/'lint_nondet.py').write_text(scanner[:start]+scanner[end:])
        (directory/'lint_privacy.py').write_text(helper)
        tests = Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
                'PROJECT = Path('+repr(str(PROJECT))+')', 1)
        (directory/'test_lint_nondet.py').write_text(tests)
        command = [sys.executable, str(directory/'test_lint_nondet.py'),
                   'NimPrivacyTests.test_nim_compiled_declaration_reviewer_grouped_shadow',
                   'NimPrivacyTests.test_nim_compiled_declaration_reviewer_string_false',
                   'NimPrivacyTests.test_nim_compiled_declaration_reviewer_string_true',
                   'NimPrivacyTests.test_nim_compiled_declaration_reviewer_model']
        self.retain_inputs(command)
        result = subprocess.run(command, capture_output=True, text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr)
        self.retain_inputs(command)
        self.assertEqual(result.returncode, 1, result.stdout+result.stderr)
        self.assertEqual(result.stderr.count('\nFAIL: '), 1)
        self.assertIn('FAIL: test_nim_compiled_declaration_reviewer_grouped_shadow', result.stderr)
        self.assertIn('AssertionError: Lists differ', result.stderr)
        self.assertIn('site/src/ordinary.nim', result.stderr)
        self.assertIn('unresolved DOM privacy binding', result.stderr)
        self.assertIn('FAILED (failures=1)', result.stderr)
        self.assertNotIn('ERROR:', result.stderr)

    def test_nim_compiled_declaration_tuple_capture_order(self):
        self.compiled_control('import isonim/web/dom_api\nlet old = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(old,"type","checkbox")\nvar field = old\nlet other = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nproc change() =\n  let (saved, ignored) = (field, (field = other; 0))\n  dom_api.setAttribute(saved,"type","text")\nchange()\ndom_api.setJsPropCstring(old,"value","seed")\ndom_api.setJsPropCstring(other,"value","ordinary")\n', [(11, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_tuple_capture_order_readonly(self):
        self.compiled_control('import isonim/web/dom_api\nlet old = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(old,"type","checkbox")\nvar field = old\nlet other = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(other,"type","checkbox")\nproc change() =\n  let (saved, ignored) = (field, (field = other; 0))\n  dom_api.setAttribute(saved,"id","label")\nchange()\ndom_api.setJsPropCstring(old,"value","seed")\ndom_api.setJsPropCstring(other,"value","ordinary")\n', [])

    def test_nim_declaration_order_production_inverses(self):
        scanner = SCRIPT.read_text(); helper = SCRIPT.with_name('lint_privacy.py').read_text()
        variants = [
            ('tuple-existing-obligation', 'return retain(shape)', 'return None',
             'test_nim_compiled_declaration_tuple_tracked_rhs',
             'test_nim_compiled_declaration_tuple_untracked_model'),
            ('tuple-reference-order',
             'if tuple_member: deps = declaration_reference(value, deps, shape, rhs[0][2], env)',
             'if False: deps = declaration_reference(value, deps, shape, rhs[0][2], env)',
             'test_nim_compiled_declaration_tuple_capture_order',
             'test_nim_compiled_declaration_tuple_capture_order_readonly'),
            ('group-fresh-identity',
             "if declaration_origins and origin[0] in {'site', 'call-binding'}",
             'if False',
             'test_nim_compiled_declaration_fresh_group',
             'test_nim_compiled_declaration_alias_group'),
        ]
        for label, anchor, replacement, failing, control in variants:
            with self.subTest(removed=label):
                self.assertEqual(scanner.count(anchor), 1)
                mutated = scanner.replace(anchor, replacement)
                directory = Path(self.temp.name)/label; directory.mkdir()
                (directory/'lint_nondet.py').write_text(mutated)
                (directory/'lint_privacy.py').write_text(helper)
                tests = Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
                        'PROJECT = Path('+repr(str(PROJECT))+')', 1)
                (directory/'test_lint_nondet.py').write_text(tests)
                command = [sys.executable, str(directory/'test_lint_nondet.py'),
                           'NimPrivacyTests.'+failing, 'NimPrivacyTests.'+control]
                self.retain_inputs(command)
                result = subprocess.run(command, capture_output=True, text=True)
                (directory/'inverse.log').write_text(result.stdout+result.stderr)
                self.retain_inputs(command)
                self.assertEqual(result.returncode, 1, result.stdout+result.stderr)
                self.assertEqual(result.stderr.count('\nFAIL: '), 1)
                self.assertIn('FAIL: '+failing, result.stderr)
                self.assertIn('AssertionError: Lists differ', result.stderr)
                self.assertIn('site/src/ordinary.nim', result.stderr)
                self.assertIn('FAILED (failures=1)', result.stderr)
                self.assertNotIn('ERROR:', result.stderr)

    def test_nim_compiled_declaration_tuple_tracked_rhs(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nlet pair = (field, 1)\nlet (saved, n) = pair\ndom_api.setAttribute(saved,"type","text")\ndom_api.setJsPropCstring(field,"value","seed")\n', [(7, 'unresolved DOM privacy binding')])

    def test_nim_compiled_declaration_tuple_untracked_model(self):
        self.compiled_control('type Model = object\n  textContent: cstring\nvar pair = (Model(), 1)\nvar (field, n) = pair\nfield.textContent="ordinary"\n', [])

    def test_nim_compiled_declaration_group_unknown_loop(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nfor i in 0..1:\n  let a, b = (field, 1)\n  discard a\n  discard b\ndom_api.setJsPropCstring(field,"value","ordinary")\n', [])


    def test_nim_compiled_authored_grouped_read(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\nlet a, b = field.textContent\n', [(3, 'free-text binding')])

    def test_nim_compiled_authored_single_read(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\nlet a = field.textContent\n', [(3, 'free-text binding')])

    def test_nim_compiled_authored_grouped_model(self):
        self.compiled_control('type Model = object\n  textContent: cstring\nvar field = Model()\nlet a, b = field.textContent\n', [])

    def test_nim_compiled_authored_separate_same_line(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\nlet a = field.textContent; let b = field.textContent\n', [(3, 'free-text binding'), (3, 'free-text binding')])

    def test_nim_compiled_authored_separate_physical_lines(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\nlet a = field.textContent\nlet b = field.textContent\n', [(3, 'free-text binding'), (4, 'free-text binding')])

    def test_nim_compiled_authored_grouped_getter(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\nlet a, b = dom_api.getJsProp(field,"value")\n', [(3, 'free-text binding')])

    def test_nim_compiled_authored_grouped_setter(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\nlet a, b = (dom_api.setJsPropCstring(field,"value","seed"); 1)\n', [(3, 'free-text binding')])

    def test_nim_compiled_authored_grouped_nested(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\nlet a, b = (discard (field.textContent); 1)\n', [(3, 'free-text binding')])

    def test_nim_compiled_authored_grouped_loop(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\nfor i in 0..1:\n  let a, b = field.textContent\n', [(4, 'free-text binding')])

    def test_nim_compiled_authored_grouped_loop_backedge(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nfor i in 0..1:\n  let a, b = field.textContent\n  dom_api.setAttribute(field,"type","text")\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_authored_grouped_later_finding(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nvar saved = field\nlet a, b = (saved = field; field = dom_api.createElement(dom_api.document,"textarea"); saved.textContent)\n', [(5, 'free-text binding')])

    def test_nim_compiled_authored_grouped_later_unknown(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\nlet a, b = (discard field.textContent; field = (field,1)[0]; 1)\n', [(3, 'unresolved DOM privacy binding')])

    def test_nim_compiled_authored_grouped_first_unknown(self):
        self.compiled_control('import isonim/web/dom_api\nvar field = dom_api.createElement(dom_api.document,"input")\nfield = (field,1)[0]\nlet a, b = (discard field.textContent; field = dom_api.createElement(dom_api.document,"textarea"); 1)\n', [(4, 'unresolved DOM privacy binding')])

    def test_nim_authored_span_production_inverse(self):
        scanner = SCRIPT.read_text(); helper = SCRIPT.with_name('lint_privacy.py').read_text()
        before = '    return list(authored.values())'
        self.assertEqual(scanner.count(before), 1)
        directory = Path(self.temp.name)/'remove-authored-aggregation'; directory.mkdir()
        (directory/'lint_nondet.py').write_text(scanner.replace(before,
                '    return [finding for _span, finding in findings]', 1))
        (directory/'lint_privacy.py').write_text(helper)
        tests = Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
                'PROJECT = Path('+repr(str(PROJECT))+')', 1)
        (directory/'test_lint_nondet.py').write_text(tests)
        command = [sys.executable, str(directory/'test_lint_nondet.py'),
                   'NimPrivacyTests.test_nim_compiled_authored_grouped_read',
                   'NimPrivacyTests.test_nim_compiled_authored_single_read',
                   'NimPrivacyTests.test_nim_compiled_authored_grouped_model',
                   'NimPrivacyTests.test_nim_compiled_authored_separate_same_line']
        self.retain_inputs(command)
        result = subprocess.run(command, capture_output=True, text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr)
        self.retain_inputs(command)
        self.assertEqual(result.returncode, 1, result.stdout+result.stderr)
        self.assertEqual(result.stderr.count('\nFAIL: '), 1)
        self.assertIn('FAIL: test_nim_compiled_authored_grouped_read', result.stderr)
        self.assertIn('AssertionError: Lists differ', result.stderr)
        self.assertIn('site/src/ordinary.nim', result.stderr)
        self.assertIn('free-text binding', result.stderr)
        self.assertIn('Ran 4 tests', result.stderr)
        self.assertIn('FAILED (failures=1)', result.stderr)
        self.assertNotIn('ERROR:', result.stderr)


    def test_nim_compiled_expression_scope_plain(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"div")\nlet ignored=(let false=cstring"true"; 0)\ndom_api.setAttribute(field,"contenteditable",false)\nfield.textContent="seed"\n', [(5, 'unresolved DOM privacy binding')])

    def test_nim_compiled_expression_scope_block(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"div")\nblock:\n  let ignored=(let false=cstring"true"; 0)\n  discard false\ndom_api.setJsPropBool(field,"contentEditable",false)\nfield.textContent="ordinary"\n', [])

    def test_nim_compiled_expression_scope_literal(self):
        self.compiled_control('import isonim/web/dom_api\nlet field = dom_api.createElement(dom_api.document,"div")\nlet ignored=(discard cstring"true"; 0)\ndom_api.setAttribute(field,"contenteditable","false")\nfield.textContent="ordinary"\n', [])

    def test_nim_compiled_expression_scope_model(self):
        self.compiled_control('type Model = object\n  textContent: cstring\nvar field = Model()\nlet ignored=(let false=cstring"true"; 0)\nfield.textContent="ordinary"\n', [])

    def test_nim_compiled_expression_scope_direct_dom(self):
        self.compiled_control('import isonim/web/dom_api\nlet ignored=(let field=dom_api.createElement(dom_api.document,"input");0)\nfield.textContent="seed"\n', [(3, 'free-text binding')])

    def test_nim_compiled_expression_scope_captured_dom(self):
        self.compiled_control('import isonim/web/dom_api\nlet ignored=(var field=dom_api.createElement(dom_api.document,"input");0)\ndom_api.setAttribute(field,"type","checkbox")\nproc change() =\n  dom_api.setAttribute(field,"type","text")\nchange()\nfield.textContent="seed"\n', [(7, 'unresolved DOM privacy binding')])

    def test_nim_compiled_expression_scope_scoped_dom(self):
        self.compiled_control('import isonim/web/dom_api\nlet field=dom_api.createElement(dom_api.document,"input")\ndom_api.setAttribute(field,"type","checkbox")\nblock:\n  let ignored=(let field=dom_api.createElement(dom_api.document,"textarea");0)\n  field.textContent="seed"\nfield.textContent="ordinary"\n', [(6, 'free-text binding')])

    def test_nim_expression_scope_production_inverse(self):
        scanner = SCRIPT.read_text(); helper = SCRIPT.with_name('lint_privacy.py').read_text()
        before = 'enclosing=True, prefixes=active_prefixes'
        self.assertEqual(scanner.count(before), 1)
        directory = Path(self.temp.name)/'restore-wrong-expression-scope'; directory.mkdir()
        (directory/'lint_nondet.py').write_text(scanner.replace(before,
                'scoped=True, prefixes=active_prefixes', 1))
        (directory/'lint_privacy.py').write_text(helper)
        tests = Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
                'PROJECT = Path('+repr(str(PROJECT))+')', 1)
        (directory/'test_lint_nondet.py').write_text(tests)
        command = [sys.executable, str(directory/'test_lint_nondet.py'),
                   'NimPrivacyTests.test_nim_compiled_expression_scope_plain',
                   'NimPrivacyTests.test_nim_compiled_expression_scope_block',
                   'NimPrivacyTests.test_nim_compiled_expression_scope_literal',
                   'NimPrivacyTests.test_nim_compiled_expression_scope_model']
        self.retain_inputs(command)
        result = subprocess.run(command, capture_output=True, text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr)
        self.retain_inputs(command)
        self.assertEqual(result.returncode, 1, result.stdout+result.stderr)
        self.assertEqual(result.stderr.count('\nFAIL: '), 1)
        self.assertIn('FAIL: test_nim_compiled_expression_scope_plain', result.stderr)
        self.assertIn('AssertionError: Lists differ', result.stderr)
        self.assertIn('site/src/ordinary.nim', result.stderr)
        self.assertIn('unresolved DOM privacy binding', result.stderr)
        self.assertIn('Ran 4 tests', result.stderr)
        self.assertIn('FAILED (failures=1)', result.stderr)
        self.assertNotIn('ERROR:', result.stderr)


    def test_nim_deferred_default_owner_production_inverse(self):
        scanner = SCRIPT.read_text(); helper = SCRIPT.with_name('lint_privacy.py').read_text()
        before = '                                body([], local, scoped=True, prefixes=active_prefixes,\n                                     expression_action=evaluate_default)'
        self.assertEqual(scanner.count(before), 1)
        directory = Path(self.temp.name)/'remove-deferred-default-owner'; directory.mkdir()
        (directory/'lint_nondet.py').write_text(scanner.replace(before,
                '                                evaluate_default()', 1))
        (directory/'lint_privacy.py').write_text(helper)
        tests = Path(__file__).read_text().replace('PROJECT = Path(__file__).resolve().parents[1]',
                'PROJECT = Path('+repr(str(PROJECT))+')', 1)
        (directory/'test_lint_nondet.py').write_text(tests)
        command = [sys.executable, str(directory/'test_lint_nondet.py'),
                   'NimPrivacyTests.test_nim_compiled_deferred_default_readonly_and_local_controls',
                   'NimPrivacyTests.test_nim_compiled_deferred_default_formal_shadow_control']
        self.retain_inputs(command)
        result = subprocess.run(command, capture_output=True, text=True)
        (directory/'inverse.log').write_text(result.stdout+result.stderr)
        self.retain_inputs(command)
        self.assertEqual(result.returncode, 1, result.stdout+result.stderr)
        self.assertEqual(result.stderr.count('\nFAIL: '), 1)
        self.assertIn('FAIL: test_nim_compiled_deferred_default_readonly_and_local_controls', result.stderr)
        self.assertIn('AssertionError: Lists differ', result.stderr)
        self.assertIn('site/src/ordinary.nim', result.stderr)
        self.assertIn('unresolved DOM privacy binding', result.stderr)
        self.assertIn('Ran 2 tests', result.stderr)
        self.assertIn('FAILED (failures=1)', result.stderr)
        self.assertNotIn('ERROR:', result.stderr)

if __name__ == '__main__':
    unittest.main()
