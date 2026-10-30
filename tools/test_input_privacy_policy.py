#!/usr/bin/env python3
"""Qualify private declaration policy with real C/JS compilers and boundaries.

No mocks: generated programs use the owning DSL parser through the thin fixture,
and runtime controls use shipped native rendering and SSR/FastStreams. This does
not activate ui privacy or certify sensitive events, bindings or recordings.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MODULE = Path('src/isonim/dsl/private/input_privacy.nim')

# Each failure has an independently compiled legal sibling. Outcomes are from
# the real policy, not inferred from an error code or a source-text search.
CASES = [
    *[(f'missing-{kind}', f'input(`type` = "{kind}")',
       f'input(`type` = "{kind}", public = true)', 'free-text input', 'ipPublic')
      for kind in ['text', 'search', 'email', 'tel', 'url']],
    ('bare-input', 'input', 'input(public = true)', 'free-text input', 'ipPublic'),
    ('missing-input', 'input()', 'input(public = true)', 'free-text input', 'ipPublic'),
    ('textarea', 'textarea()', 'textarea(sensitive = true)', 'free-text textarea', 'ipSensitive'),
    ('dynamic-type', 'input(`type` = dynamicType)',
     'input(`type` = dynamicType, public = true)', 'free-text input', 'ipPublic'),
    *[(f'editable-{index}', f'tdiv(contenteditable = {value})',
       f'tdiv(contenteditable = {value}, public = true)', 'free-text div', 'ipPublic')
      for index, value in enumerate(['"true"', '"TRUE"', '""', '"plaintext-only"',
                                     '"PlainText-Only"', 'true', 'dynamicEditable'])],
    ('both', 'input(public = true, sensitive = true)', 'input(public = true)',
     'choose exactly one', 'ipPublic'),
    ('dynamic-choice', 'input(public = dynamicChoice)', 'input(public = true)',
     'requires literal', 'ipPublic'),
    ('public-false', 'input(public = false)', 'input(public = true)',
     'requires public = true', 'ipPublic'),
    ('sensitive-false', 'textarea(sensitive = false)', 'textarea(sensitive = true)',
     'requires public = true', 'ipSensitive'),
    *[(f'password-{index}', f'input(`type` = "{value}", public = true)',
       f'input(`type` = "{value}")', 'credential input must be sensitive', 'ipSensitive')
      for index, value in enumerate(['password', 'PaSsWoRd'])],
    ('password-false', 'input(`type` = "password", sensitive = false)',
     'input(`type` = "password", sensitive = true)', 'credential input must be sensitive', 'ipSensitive'),
    *[(f'autocomplete-{index}', f'input(autocomplete = "{value}", public = true)',
       f'input(autocomplete = "{value}")', 'credential input must be sensitive', 'ipSensitive')
      for index, value in enumerate(['cc-number', 'section-shipping CC-name',
                                     'current-password', 'NEW-PASSWORD', 'one-time-code'])],
    ('duplicate', 'input(public = true, public = true)', 'input(public = true)',
     'duplicate input privacy attribute', 'ipPublic'),
    ('duplicate-case', 'input(`type` = "text", TYPE = "text", public = true)',
     'input(`type` = "text", public = true)', 'duplicate input privacy attribute', 'ipPublic'),
    *[(f'record-{value}', f'tdiv(record = {value})', 'tdiv()',
       'record is retired; choose public = true or sensitive = true', 'ipNone')
      for value in ['true', 'false']],
    *[(f'marker-{index}', f'input(`{name}` = "true")', 'input(public = true)',
       message, 'ipPublic') for index, (name, message) in enumerate([
           ('data-isonim-record', 'record is retired; choose public = true or sensitive = true'),
           ('data-isonim-public', 'use public = true or sensitive = true'),
           ('data-isonim-sensitive', 'use public = true or sensitive = true')])],
    ('ttype-is-not-attribute-alias', 'input(ttype = "password")',
     'input(ttype = "password", public = true)', 'free-text input', 'ipPublic'),
    *[(f'unsupported-type-{index}', f'input(`type` = "{value}", public = true)',
       'input(`type` = "text", public = true)', 'unsupported private input type', 'ipPublic')
      for index, value in enumerate(['', 'not-a-type'])],
    ('unsupported-editable', 'tdiv(contenteditable = "inherit", public = true)',
     'tdiv(contenteditable = "false")', 'unsupported private contenteditable state', 'ipNone'),
]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def artifact(path):
    stat = path.stat()
    return {'sha256': digest(path), 'size': stat.st_size,
            'mode': stat.st_mode, 'mtime_ns': stat.st_mtime_ns}


def prepare(directory: Path):
    """Materialize every fixture and inverse before any compiler consumes it."""
    directory.mkdir(parents=True, exist_ok=False)
    fixture_header = 'import input_privacy_policy_probe\n\n'
    rows = []
    for name, invalid, legal, diagnostic, choice in CASES:
        row = {'name': name, 'diagnostic': diagnostic, 'line': 3}
        for arm, element in [('invalid', invalid), ('legal', legal)]:
            path = directory / ((name + '_' + arm).replace('-', '_') + '.nim')
            assertion = f' == "{choice}"' if arm == 'legal' else ' == "unreachable"'
            path.write_text(fixture_header + f'static: doAssert privacyProbe({element}){assertion}\n')
            row[arm] = str(path)
        rows.append(row)
    (directory / 'dormant.nim').write_text(
        'import isonim/dsl/private/input_privacy\n'
        'static: doAssert not declared(InputPrivacy)\n'
        'static: doAssert not declared(requirePublicInputType)\n')
    original = (ROOT / MODULE).read_text()
    mutations = {
        'choice-default': ('if freeText and not (isPublic or isSensitive or credential):',
                           'if false:'),
        'type-guard': ('if lowered == "password":', 'if false:'),
        'autocomplete-guard': ('if credentialAutocomplete(value):', 'if false:'),
        'autocomplete-dispatch': (
            'of "autocomplete": return newCall(bindSym"requirePublicAutocomplete", value)',
            'of "autocomplete": discard'),
    }
    for name, (old, new) in mutations.items():
        assert original.count(old) == 1
        path = directory / name / MODULE
        path.parent.mkdir(parents=True)
        path.write_text(original.replace(old, new))
    (directory / 'CASES.json').write_text(json.dumps(rows, indent=2) + '\n')


def run(directory: Path, nim: str, node: str):
    rows = json.loads((directory / 'CASES.json').read_text())
    commands = []
    def command(label, argv, expected=0, diagnostic=None, location=None):
        completed = subprocess.run(argv, cwd=ROOT, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log = directory / (label + '.log')
        log.write_text(completed.stdout)
        commands.append({'label': label, 'argv': argv, 'exit': completed.returncode,
                         'log_sha256': digest(log)})
        (directory / 'COMMANDS.json').write_text(json.dumps(commands, indent=2) + '\n')
        if expected == 0:
            assert completed.returncode == 0, (label, completed.stdout)
        else:
            assert completed.returncode != 0, (label, 'required refusal did not occur')
        if diagnostic is not None:
            assert diagnostic in completed.stdout, (label, completed.stdout)
        if location is not None:
            assert location in completed.stdout, (label, 'wrong source location', completed.stdout)
        print(label, completed.returncode, flush=True)
        return completed

    for target in ['c', 'js']:
        common = [nim, target, '--verbosity:2', '--listFullPaths:on',
                  '--path:' + str(ROOT / 'src'), '--path:' + str(ROOT / 'tests'),
                  '--path:' + str(ROOT.parent / 'nim-everywhere/src'),
                  '--path:' + str(ROOT.parent / 'nim-faststreams'),
                  '--path:' + str(ROOT.parent / 'nim-stew'),
                  '-d:tailwindStylesPathOverride=' + str(ROOT / 'tests/dsl/tailwind/variant-styles.json')]
        for row in rows:
            for arm in ['invalid', 'legal']:
                label = target + '-' + row['name'] + '-' + arm
                command(label, [*common, '-d:isonimInternalInputPrivacy', '--compileOnly',
                    '--nimcache:' + str(directory / 'cache' / label),
                    '--out:' + str(directory / (label + '.out')), row[arm]],
                    expected=1 if arm == 'invalid' else 0,
                    diagnostic=row['diagnostic'] if arm == 'invalid' else None,
                    location=f'{row[arm]}({row["line"]},' if arm == 'invalid' else None)
        command(target + '-dormant', [*common, '--compileOnly',
            '--nimcache:' + str(directory / 'cache' / (target + '-dormant')),
            str(directory / 'dormant.nim')])
        for variant in ['original', 'type-guard', 'autocomplete-guard', 'autocomplete-dispatch']:
            label = target + '-runtime-' + variant
            output = directory / (label + ('.js' if target == 'js' else '.bin'))
            extra = [] if variant == 'original' else ['--path:' + str(directory / variant / 'src')]
            command(label + '-compile', [*common, *extra, '-d:isonimInternalInputPrivacy',
                '--nimcache:' + str(directory / 'cache' / label), '--out:' + str(output),
                str(ROOT / 'tests/test_input_privacy_policy.nim')])
            expected = 0 if variant == 'original' else 1
            marker = None if variant == 'original' else (
                'credential type must be refused before renderer write' if variant == 'type-guard'
                else 'credential autocomplete must be refused before renderer write')
            dispatch_location = None
            if variant == 'autocomplete-dispatch':
                source = ROOT / 'tests/test_input_privacy_policy.nim'
                assertion = '  doAssert refused, "autocomplete dispatch must refuse credential before renderer write"'
                lines = source.read_text().splitlines()
                assert lines.count(assertion) == 1
                line = lines.index(assertion) + 1
                marker = '`refused` autocomplete dispatch must refuse credential before renderer write [AssertionDefect]'
                dispatch_location = f'{source}({line}, 3)'
            emitted = artifact(output)
            (directory / (label + '-EMITTED-BEFORE.json')).write_text(
                json.dumps(emitted, indent=2) + '\n')
            command(label + '-execute', [node, str(output)] if target == 'js' else [str(output)],
                    expected=expected, diagnostic=marker, location=dispatch_location)
            assert artifact(output) == emitted, 'executed artifact changed'
        # This inverse compiles the exact originally rejected field using the
        # mutated production policy, then reaches its original named assertion.
        first = rows[0]
        label = target + '-choice-default-inverse'
        command(label, [*common, '--path:' + str(directory / 'choice-default/src'),
            '-d:isonimInternalInputPrivacy', '--compileOnly',
            '--nimcache:' + str(directory / 'cache' / label), first['invalid']],
            expected=1,
            diagnostic='`' + Path(first['invalid']).read_text().splitlines()[2].partition(
                'doAssert ')[2] + '`  [AssertionDefect]',
            location=f'{first["invalid"]}({first["line"]}, 9)')
        if target == 'c':
            label = 'c-faststreams'
            output = directory / (label + '.bin')
            command(label + '-compile', [*common, '-d:isonimInternalInputPrivacy',
                '--nimcache:' + str(directory / 'cache' / label), '--out:' + str(output),
                str(ROOT / 'tests/test_input_privacy_faststream.nim')])
            emitted = artifact(output)
            (directory / (label + '-EMITTED-BEFORE.json')).write_text(
                json.dumps(emitted, indent=2) + '\n')
            command(label + '-execute', [str(output)])
            assert artifact(output) == emitted, 'executed FastStreams artifact changed'
    (directory / 'RESULT.json').write_text(json.dumps({
        'status': 'PASS', 'private_only': True, 'cases': len(rows),
        'targets': ['c', 'js'], 'commands': len(commands),
        'commands_sha256': digest(directory / 'COMMANDS.json')}, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare', type=Path)
    parser.add_argument('--run', type=Path)
    parser.add_argument('--nim', default=shutil.which('nim'))
    parser.add_argument('--node', default=shutil.which('node'))
    args = parser.parse_args()
    if args.prepare:
        prepare(args.prepare)
    elif args.run:
        if not args.nim or not args.node: parser.error('real nim and node are required')
        run(args.run, args.nim, args.node)
    else:
        with tempfile.TemporaryDirectory(prefix='input-policy-') as name:
            directory = Path(name) / 'fixtures'
            prepare(directory)
            if not args.nim or not args.node: parser.error('real nim and node are required')
            run(directory, args.nim, args.node)


if __name__ == '__main__':
    main()
