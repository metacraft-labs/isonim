#!/usr/bin/env python3
"""Real compiler tagged positives and exact helper RawNondet negative controls.

Each own-tag-removal inverse must compile the unchanged ceiling fixture, so a
failure from unrelated source or fixtures cannot qualify. No mocked compiler.
All compiled inputs and diagnostics remain available for evidence archival.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
work = Path(tempfile.mkdtemp(prefix='rpc-raw-effects-'))
fixture = root / 'tests/rpc_projection_fixture.nim'


def compile_rpc(source, path, define, name):
    command = ['nim', 'js', '-d:isonimStrictNondet', '--hints:off',
               '--path:' + str(path / 'src'),
               '--path:' + str(root.parent / 'nim-everywhere/src'),
               '--out:' + str(work / (name + '.js')), '-d:' + define, str(source)]
    run = subprocess.run(command, capture_output=True, text=True)
    (work / (name + '.log')).write_text(run.stdout + run.stderr)
    assert run.returncode == 0, run.stdout + run.stderr


compile_rpc(fixture, root, 'extractedRpcComposition', 'tagged-positive')
native = work / 'native_import.nim'
native.write_text('import isonim/core/private/rpc_http\n'
                  'when declared(buildRpcRequestInitRaw) or declared(projectRpcResponseRaw):\n'
                  '  {.error: "JS-only raw RPC helpers leaked to native".}\n')
run = subprocess.run(['nim', 'c', '-d:isonimStrictNondet', '--hints:off',
                      '--nimcache:' + str(work / 'native-cache'),
                      '--path:' + str(root / 'src'),
                      '--out:' + str(work / 'native-import'), str(native)],
                     capture_output=True, text=True)
(work / 'native-import.log').write_text(run.stdout + run.stderr)
assert run.returncode == 0, run.stdout + run.stderr
for name, define in [('buildRpcRequestInitRaw', 'rawRpcInitEffectCeiling'),
                     ('projectRpcResponseRaw', 'rawRpcProjectEffectCeiling')]:
    command = ['nim', 'js', '-d:isonimStrictNondet', '--hints:off',
               '--path:' + str(root / 'src'),
               '--path:' + str(root.parent / 'nim-everywhere/src'),
               '--out:' + str(work / (name + '-negative.js')), '-d:' + define, str(fixture)]
    run = subprocess.run(command, capture_output=True, text=True)
    output = run.stdout + run.stderr
    (work / (name + '-negative.log')).write_text(output)
    assert run.returncode != 0 and 'can have an unlisted effect: RawNondet' in output, output
    assert name + '(' in output, output
    inverse = work / name
    shutil.copytree(root / 'src', inverse / 'src')
    (inverse / 'tests').mkdir()
    shutil.copyfile(fixture, inverse / 'tests/fixture.nim')
    helper = inverse / 'src/isonim/core/private/rpc_http.nim'
    text = helper.read_text()
    start = text.index('  proc ' + name + '*')
    tag = text.index('{.tags: [RawNondet].}', start)
    text = text[:tag] + text[tag:].replace('{.tags: [RawNondet].}', '{.tags: [].}', 1)
    helper.write_text(text)
    compile_rpc(inverse / 'tests/fixture.nim', inverse, define, name + '-own-tag-removal')
    no_access = work / (name + '_no_access.nim')
    no_access.write_text('import std/jsffi\n'
                         'import nim_everywhere/async_compat\n'
                         'import isonim/core/private/rpc_http\n' +
                         ('discard buildRpcRequestInitRaw("GET", nil, "", "", "", nil)\n'
                          if name == 'buildRpcRequestInitRaw' else
                          'discard projectRpcResponseRaw(PlatformFuture[JsObject](nil), nil)\n'))
    run = subprocess.run(['nim', 'js', '-d:isonimStrictNondet', '--hints:off',
                          '--path:' + str(root / 'src'),
                          '--path:' + str(root.parent / 'nim-everywhere/src'),
                          '--out:' + str(work / (name + '-no-access.js')), str(no_access)],
                         capture_output=True, text=True)
    output = run.stdout + run.stderr
    (work / (name + '-no-access.log')).write_text(output)
    assert run.returncode != 0 and 'type mismatch' in output and name in output and 'RawBackendAccess' in output, output
    print('PASS exact RawNondet and own-tag-removal ' + name)
print('retained RPC effect inputs/logs ' + str(work))
