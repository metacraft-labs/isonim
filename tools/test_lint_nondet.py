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
