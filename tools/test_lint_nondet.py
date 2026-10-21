#!/usr/bin/env python3
"""Real-file/CLI controls for the lexical gate; no mock scanner or subprocess.
Temporary source trees deliberately contain forbidden APIs: they are the input
under test, not fake implementations of production platform behavior.
"""
from collections import Counter
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import lint_nondet as lint

SCRIPT = Path(__file__).with_name('lint_nondet.py')
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

    def write(self, name, code):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(code)
        return path

    def cli(self, *args):
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


if __name__ == '__main__':
    unittest.main()
