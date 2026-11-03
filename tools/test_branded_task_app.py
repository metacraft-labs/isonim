#!/usr/bin/env python3
"""Compile the real branded app, drive Chromium, and reject owner-source inverses.

Run in the documented dev shell after build-tailwind. No package provisioning,
substitute renderer/app, ignored browser mode or accepted unittest failure exists.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import argparse
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--style', action='store_true', help='hard-failing intended-font gate, separately from functional qualification')
ARGS = parser.parse_args()
ROOT = Path(__file__).resolve().parent.parent
MODULE = Path('isonim/components/branded_controls.nim')
PARENT = ROOT / 'build/branded-task-app'
PARENT.mkdir(parents=True, exist_ok=True)
OUT = Path(tempfile.mkdtemp(prefix='run-', dir=PARENT))
print('retained ' + str(OUT), flush=True)
SOURCE_ROOT = Path(tempfile.mkdtemp(prefix='xr-branded-source-'))
(OUT / 'SOURCE-ROOT.json').write_text(json.dumps({'path':str(SOURCE_ROOT)}) + '\n')
ENV = dict(os.environ)
ENV['PLAYWRIGHT_CHROMIUM_EXECUTABLE'] = ENV.get('PLAYWRIGHT_CHROMIUM_EXECUTABLE') or shutil.which('chromium') or ''
assert Path(ENV['PLAYWRIGHT_CHROMIUM_EXECUTABLE']).is_file(), 'required Chromium missing'
MINIMUM = int(ENV.get('ISONIM_TEST_MIN_AVAILABLE_BYTES', '0'))
REFERENCE_NONOWNER = None


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(name, argv, inputs):
    tool_paths = [Path(shutil.which(name)) for name in ['nim', 'node', 'python3']]
    # Nix's Nim launcher names the actual immutable compiler; bind its bytes too.
    launcher = tool_paths[0].read_bytes()
    if launcher.startswith(b'#!'):
        engine = re.search(r'^exec "([^"]+)"', launcher.decode(), re.MULTILINE)
        if engine:
            tool_paths.append(Path(engine.group(1)))
    tool_paths.append(Path(ENV['PLAYWRIGHT_CHROMIUM_EXECUTABLE']))
    tool_paths += [ROOT / 'tools/test_branded_task_app.py', ROOT / 'node_modules/playwright/package.json', ROOT / 'node_modules/playwright-core/package.json']
    before = {str(path): sha(path) for path in [*inputs, *tool_paths]}
    stat = os.statvfs(OUT)
    disk = stat.f_bavail * stat.f_frsize
    memory = None
    if Path('/proc/meminfo').is_file():
        memory = next(int(line.split()[1]) * 1024 for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith('MemAvailable:'))
    assert disk >= MINIMUM and (MINIMUM == 0 or memory is not None and memory >= MINIMUM), 'BLOCKED: resource admission'
    receipt = dict(argv=argv, cwd=str(ROOT), disk_available_bytes=disk, MemAvailable_bytes=memory, minimum_bytes=MINIMUM, inputs=before)
    (OUT / (name + '-BEFORE.json')).write_text(json.dumps(receipt, indent=2) + '\n')
    result = subprocess.run(argv, cwd=ROOT, env=ENV, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (OUT / (name + '.log')).write_text(result.stdout)
    receipt['exit'] = result.returncode
    receipt['inputs_after'] = {str(path): sha(path) for path in [*inputs, *tool_paths]}
    assert receipt['inputs_after'] == before, 'actual inputs changed during execution'
    (OUT / (name + '-RESULT.json')).write_text(json.dumps(receipt, indent=2) + '\n')
    print(name + ': ' + str(result.returncode), flush=True)
    if result.returncode:
        print(result.stdout, flush=True)
    return result


def compile_app(name, source=ROOT / 'src'):
    global REFERENCE_NONOWNER
    project = source.parent
    fixture = project / 'tests/fixtures/branded_task_app_browser.nim'
    # Preserve the normal project/config stack. Each isolated project contains
    # byte-identical configs/entry/styles; only the named owner module changes.
    launcher = Path(shutil.which('nim')).read_bytes()
    engine = re.search(r'^exec "([^"]+)"', launcher.decode(), re.MULTILINE) if launcher.startswith(b'#!') else None
    lib = (Path(engine.group(1)) if engine else Path(shutil.which('nim')).resolve()).parent.parent / 'lib'
    candidates = [fixture, project / 'config.nims', project / 'tests/config.nims', project / 'tests/fixtures/config.nims', project / 'build/tailwind-styles.json']
    store_source = Path(ENV['NIM_EVERYWHERE_SRC']) / 'src'
    sibling_source = project.parent / 'nim-everywhere/src'
    directories = [source, lib, store_source, Path(shutil.which('nim')).parent.parent / 'etc/nim']
    if sibling_source.is_dir():
        # Normal unchanged configs legitimately select this locked sibling.
        # Admit its paths BEFORE compilation, only after exact source parity.
        for path in sibling_source.rglob('*'):
            if path.is_file():
                reference = store_source / path.relative_to(sibling_source)
                assert reference.is_file() and sha(path) == sha(reference), 'sibling differs from locked immutable source'
        directories.append(sibling_source)
    for directory in directories:
        candidates.extend(path for path in directory.rglob('*') if path.is_file() and '.git' not in path.parts and 'yoga' not in path.parts)
    before = {str(path.resolve()): sha(path) for path in candidates}
    (OUT / (name + '-SOURCE-BEFORE.json')).write_text(json.dumps(before, indent=2) + '\n')
    bundle = OUT / (name + '.js')
    cache = OUT / ('cache-' + name)
    cache.mkdir(parents=True, exist_ok=True)
    argv = ['nim', 'js', '--genScript:on', '--nimcache:' + str(cache), '--path:' + str(source), '--path:' + ENV['NIM_EVERYWHERE_SRC'] + '/src', '--out:' + str(bundle), str(fixture)]
    result = run(name + '-compile', argv, [source / MODULE, fixture, project / 'config.nims', project / 'tests/config.nims', project / 'tests/fixtures/config.nims'])
    after = {str(path.resolve()): sha(path) for path in candidates}
    assert after == before, 'source closure changed during compile'
    (OUT / (name + '-SOURCE-AFTER.json')).write_text(json.dumps(after, indent=2) + '\n')
    if result.returncode == 0:
        dependencies = [Path(path) for path in (cache / (fixture.stem + '.deps')).read_text().splitlines() if path]
        assert dependencies and all(str(path.resolve()) in before for path in dependencies), 'unbound actual compiler input'
        assert (source / MODULE).resolve() in [path.resolve() for path in dependencies], 'wrong actual owner module'
        actual = {str(path.resolve()): sha(path) for path in dependencies}
        assert all(before[path] == digest for path, digest in actual.items())
        # Compare actual nonowner inputs by role and bytes across normal and
        # isolated builds, retaining original physical paths in actual above.
        equivalent = {}
        for raw, digest in actual.items():
            path = Path(raw)
            if path.is_relative_to(project):
                relative = path.relative_to(project)
                identity = 'project/' + str(relative)
                if relative != Path('src') / MODULE:
                    assert sha(ROOT / relative) == digest, 'nonowner project input differs'
            elif path.is_relative_to(sibling_source) or path.is_relative_to(store_source):
                context = sibling_source if path.is_relative_to(sibling_source) else store_source
                relative = path.relative_to(context)
                identity = 'nim-everywhere/src/' + str(relative)
                assert sha(store_source / relative) == digest, 'nonowner platform input differs'
            else:
                identity = 'external/' + raw
            assert identity not in equivalent, 'duplicate actual input identity'
            equivalent[identity] = digest
        equivalent.pop('project/src/' + str(MODULE))
        if REFERENCE_NONOWNER is None:
            REFERENCE_NONOWNER = equivalent
        assert equivalent == REFERENCE_NONOWNER, 'actual nonowner compiler closure differs'
        (OUT / (name + '-ACTUAL-INPUTS.json')).write_text(json.dumps({'compiler_dependencies':actual, 'nonowner_equivalence':equivalent, 'generated_js_sha256':sha(bundle)}, indent=2) + '\n')
        assert str(source / MODULE) in bundle.read_text(), 'generated artifact does not name selected owner'
    return result, bundle


def browser(name, bundle, source=ROOT / 'src'):
    ENV['BRANDED_TASK_STYLE'] = '1' if ARGS.style else '0'
    ENV['BRANDED_TASK_BUNDLE'] = str(bundle)
    ENV['BRANDED_TASK_RESULTS'] = str(OUT / (name + '-assertions.json'))
    return run(name + '-browser', ['node', 'tests/test_branded_task_app.mjs'], [source / MODULE, bundle, ROOT / 'tests/test_branded_task_app.mjs', ROOT / 'build/tailwind.css'])


def isolated_project(name, source_text, original):
    selected = SOURCE_ROOT / name / 'isonim'
    shutil.copytree(ROOT / 'src', selected / 'src', symlinks=True)
    (selected / 'src' / MODULE).write_text(source_text)
    sibling = ROOT.parent / 'nim-everywhere'
    if sibling.is_dir():
        shutil.copytree(sibling, selected.parent / 'nim-everywhere', symlinks=True,
                        ignore=shutil.ignore_patterns('.git', '.nimcache', 'build', 'node_modules'))
    for relative in ['config.nims', 'tests/config.nims', 'tests/fixtures/config.nims', 'tests/fixtures/branded_task_app_browser.nim', 'build/tailwind-styles.json']:
        destination = selected / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / relative, destination)
        assert sha(destination) == sha(ROOT / relative)

    differences = [str(path.relative_to(selected / 'src')) for path in (selected / 'src').rglob('*')
                   if path.is_file() and sha(path) != sha(ROOT / 'src' / path.relative_to(selected / 'src'))]
    assert differences == ([] if source_text == original else [str(MODULE)]), 'unrelated source mutation'
    return selected


result, bundle = compile_app('ordinary')
result.check_returncode()
browser('ordinary', bundle).check_returncode()
if ARGS.style:
    original = (ROOT / 'src' / MODULE).read_text()
    anchor = 'r.setStyle(input, "font-size", "16px")'
    assert original.count(anchor) == 1, 'input font production inverse anchor drift'
    changed = original.replace(anchor, 'r.setStyle(input, "font-size", "16")')
    for kind, source_text in [('companion', original), ('mutant', changed)]:
        name = 'input-font-' + kind
        selected = isolated_project(name, source_text, original)
        result, bundle = compile_app(name, selected / 'src')
        result.check_returncode()
        result = browser(name, bundle, selected / 'src')
        if kind == 'companion':
            result.check_returncode()
        else:
            assert result.returncode == 1 and 'semantic: intended-input-font-assigned' in result.stdout, 'precise inline font inverse refusal missing'
            evidence = json.loads((OUT / (name + '-assertions.json')).read_text())
            assert evidence['checks'][-1] == {'name':'intended-input-font-assigned', 'actual':'', 'expected':'16px'}, 'wrong inline assertion killed inverse'
            input_style = evidence['observations']['boxStyles']['input']
            assert input_style['inline']['font-size'] == '' and input_style['computed']['font-size'] == '16px', 'native invalid-font/inherited-default witness missing'
    print('PASS intended native styles and input-font production inverse with samepath companion', flush=True)
    raise SystemExit(0)

# MockRenderer provides transport-only companion coverage on both Nim backends.
# JS execution goes through the repository's failure-marker-aware runner.
for test in ['test_branded_task_app', 'test_loop_accessors', 'test_keyed_effect_lifetime',
             'test_signals', 'test_effects', 'test_dsl']:
    fixture = ROOT / ('tests/' + test + '.nim')
    for backend in ['c', 'js']:
        name = test + '-' + backend
        output = OUT / (name + ('.js' if backend == 'js' else '.exe'))
        argv = ['nim', backend, '--path:' + str(ROOT / 'src'),
                '--path:' + ENV['NIM_EVERYWHERE_SRC'] + '/src', '--out:' + str(output)]
        if backend == 'c':
            argv.append('-r')
        result = run(name + '-compile', [*argv, str(fixture)], [ROOT / 'src' / MODULE, fixture])
        result.check_returncode()
        if backend == 'js':
            run(name + '-execute', ['python3', 'tools/run_nim_js_test.py', str(output)],
                [ROOT / 'src' / MODULE, fixture, output, ROOT / 'tools/run_nim_js_test.py']).check_returncode()
        else:
            assert '[OK]' in result.stdout and not any(marker in result.stdout for marker in ['[FAILED]', '[SKIPPED]', 'Check failed:']), 'native unittest failure'

original = (ROOT / 'src' / MODULE).read_text()
mutations = {
    'styled-text': (original.replace('let plusIcon = r.createElement("span")\n  r.setTextContent(plusIcon, "+")', 'let plusIcon = r.createTextNode("+")'),
                    'Expression: setStyle(r, plusIcon', None),
    'old-getter': (original.replace('let text = r.inputValue(input)', 'let text = r.textContent(input)'),
                   "undeclared routine: 'textContent'", None),
    'wrong-clear': (original.replace('r.setInputValue(input, "")', 'r.setTextContent(input, "")'),
                    None, 'cleared-current-value'),
    'stale-attribute': (original.replace('let text = r.inputValue(input)', 'let text = r.getAttribute(input, "value")'),
                        None, 'submitted-current-value'),
}
for name, (changed, diagnostic, semantic) in mutations.items():
    assert changed != original, 'production inverse missing anchor'
    for kind, source_text in [('companion', original), ('mutant', changed)]:
        selected = isolated_project(name + '-' + kind, source_text, original)
        result, bundle = compile_app(name + '-' + kind, selected / 'src')
        if kind == 'mutant' and diagnostic:
            assert result.returncode == 1 and diagnostic in result.stdout and str(selected / 'src' / MODULE) in result.stdout, 'precise expected compiler refusal missing'
            continue
        result.check_returncode()
        result = browser(name + '-' + kind, bundle, selected / 'src')
        if kind == 'companion':
            result.check_returncode()
        else:
            assert result.returncode == 1 and 'semantic: ' + semantic in result.stdout, 'precise semantic refusal missing'
            evidence = json.loads((OUT / (name + '-' + kind + '-assertions.json')).read_text())
            add = evidence['observations']['firstAdd']
            assert len(add['tasks']) == 1 and add['tasks'][0]['text'] in add['text'], 'actual callback/row positive witness missing'
            if name == 'stale-attribute':
                assert add['defaultValue'] == 'old default' and add['tasks'][0]['text'] == 'old default', 'nonempty stale default witness missing'
print('PASS full production app, Mock C/JS, existing focused suites and four production inverses', flush=True)
