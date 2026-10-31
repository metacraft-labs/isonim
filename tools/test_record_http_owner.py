#!/usr/bin/env python3
"""Fixed Record HTTP/RPC: compiled production, real HTTP/owner Replay and inverses.

Run in the documented dev shell with CT_ARTIFACT pointing to the installed owner
package. Tool discovery uses supported compiler metadata, never a store-layout
or architecture guess. No package/bootstrap provisioning occurs in this driver.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
ARTIFACT = Path(os.environ.get('CT_ARTIFACT', ''))
assert os.environ.get('CT_ARTIFACT'), 'CT_ARTIFACT required; owner gate cannot skip'
assert (ARTIFACT/'packages/boundary-shim/dist/browser/seams-net.js').is_file()
ENV = dict(os.environ)
ENV.pop('RECORD_HTTP_INVERSE', None)
ENV['PLAYWRIGHT_CHROMIUM_EXECUTABLE'] = ENV.get('PLAYWRIGHT_CHROMIUM_EXECUTABLE') or shutil.which('chromium') or ''
assert Path(ENV['PLAYWRIGHT_CHROMIUM_EXECUTABLE']).is_file(), 'actual Chromium required'
PARENT = ROOT/'build/record-http-qualification'
PARENT.mkdir(parents=True, exist_ok=True)
OUT = Path(tempfile.mkdtemp(prefix='run-', dir=PARENT))
print('retained qualification directory: '+str(OUT), flush=True)
MODULE = ROOT/'src/isonim/core/private/record_http.nim'
FLAGS = ['-d:isonimInternalRecordHttp', '-d:isonimInternalRecordTimers']

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def invoke(name, command, env=ENV, candidate=MODULE):
    (OUT/(name+'-BEFORE.json')).write_text(json.dumps({
        'command':command, 'cwd':str(ROOT), 'candidate':str(candidate),
        'sha256':sha(candidate), 'inputs':sha(OUT/'INPUTS-BEFORE.json')
    }, indent=2)+'\n')
    result = subprocess.run(command,cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (OUT/(name+'.log')).write_text(result.stdout)
    (OUT/(name+'-EXIT.json')).write_text(json.dumps({'exit':result.returncode})+'\n')
    print(name+': exit '+str(result.returncode),flush=True)
    if result.returncode: print(result.stdout,flush=True)
    return result

# Metadata discovery is administrative, bound independently before invoking it.
nim = Path(shutil.which('nim') or '')
assert nim.is_file(), 'actual Nim required'
dump_command = [str(nim),'dump','--dump.format:json','--hint:Conf:on','tests/fixtures/record_http.nim']
(OUT/'NIM-DUMP-BEFORE.json').write_text(json.dumps({'command':dump_command,'tool':str(nim.resolve()),'sha256':sha(nim.resolve())},indent=2)+'\n')
dump = subprocess.run(dump_command,cwd=ROOT,env=ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
(OUT/'nim-dump.stdout').write_text(dump.stdout)
(OUT/'nim-dump.stderr').write_text(dump.stderr)
assert dump.returncode == 0, 'supported Nim metadata discovery must succeed'
metadata = json.loads(dump.stdout)
engine, library = Path(metadata['nimExe']), Path(metadata['libpath'])
configs = [Path(p) for p in re.findall(r"used config file '([^']+)'",dump.stderr)]
inputs = []
for directory in [ROOT/'src',ROOT.parent/'nim-everywhere/src',ROOT/'tests/fixtures',
                  ROOT/'tests/browser/node_modules',ARTIFACT/'packages',
                  ARTIFACT/'node_modules/esbuild',ARTIFACT/'node_modules/@esbuild',library]:
    assert directory.is_dir(), 'required selected input '+str(directory)
    for path in sorted(directory.resolve().rglob('*')):
        if path.is_file() and (directory.name != 'packages' or (path.name == 'package.json' or ('dist' in path.parts and path.suffix in ['.js','.json']))):
            inputs.append({'path':str(path),'sha256':sha(path),'size':path.stat().st_size})
for path in [Path(__file__),ROOT/'tests/test_record_http_owner.mjs',ROOT/'Justfile',engine,*configs]:
    assert path.is_file(), str(path)+' required'
    inputs.append({'path':str(path),'sha256':sha(path),'size':path.stat().st_size})
for tool in ['nim','node','python3','chromium']:
    resolved = ENV['PLAYWRIGHT_CHROMIUM_EXECUTABLE'] if tool=='chromium' else shutil.which(tool)
    assert resolved, tool+' required'
    path = Path(resolved).resolve()
    inputs.append({'tool':tool,'path':str(path),'sha256':sha(path)})
# Installed artifacts may intentionally omit repository-root metadata. Bind
# existing root/lock metadata and record absence before any package consumer.
metadata_paths = [ARTIFACT/name for name in ['package.json','package-lock.json','pnpm-lock.yaml','yarn.lock','node_modules/.package-lock.json']]
(OUT/'PACKAGE-METADATA-BEFORE.json').write_text(json.dumps([
    {'path':str(path),'exists':path.is_file(),'sha256':sha(path) if path.is_file() else None}
    for path in metadata_paths],indent=2)+'\n')
for path in metadata_paths:
    if path.is_file(): inputs.append({'path':str(path),'sha256':sha(path),'size':path.stat().st_size})
(OUT/'INPUTS-BEFORE.json').write_text(json.dumps(inputs,indent=2)+'\n')

def compile_js(name, fixture, flags=(), candidate=MODULE):
    output = OUT/(name+'.js')
    command = ['nim','js',*flags,'--nimcache:'+str(OUT/'nimcache'/name),'--out:'+str(output),str(fixture)]
    invoke(name+'-compile',command,candidate=candidate).check_returncode()
    return output

def browser(name, bundle, expected=None, candidate=MODULE):
    env = {**ENV,'RECORD_HTTP_BUNDLE':str(bundle),'RECORD_HTTP_RESULTS':str(OUT/(name+'-results.json'))}
    if expected and name=='raw-global': env['RECORD_HTTP_INVERSE']='raw-global'
    result = invoke(name+'-browser',['node','tests/test_record_http_owner.mjs'],env,candidate)
    if expected:
        assert result.returncode == 1 and 'AssertionError [ERR_ASSERTION]: '+expected in result.stdout, 'precise compiled semantic inverse: '+name
    else: result.check_returncode()

for name, flags in [('default',[]),('recordable',['-d:isonimRecordable']),('release',['-d:release']),('recordable-release',['-d:release','-d:isonimRecordable']),('strict',['-d:isonimStrictNondet'])]:
    js = compile_js(name,'tests/fixtures/record_http.nim',[*FLAGS,*flags])
    browser(name,js)

for boundary in range(5):
    flags = [*FLAGS,'-d:isonimStrictNondet','-d:httpBoundary='+str(boundary)]
    compile_js('effect-'+str(boundary),'tests/fixtures/record_http_effect.nim',flags)
    command = ['nim','js',*flags,'-d:httpReject','--out:'+str(OUT/('reject-'+str(boundary)+'.js')),'tests/fixtures/record_http_effect.nim']
    result = invoke('reject-'+str(boundary),command)
    expected = ['prepare','fetchRaw','newInternalRecordHttp','recordHttp','recordBrowserFetch'][boundary]
    assert result.returncode != 0 and 'RawNondet' in result.stdout and 'unlisted effect' in result.stdout and ('Error: '+expected+'(') in result.stdout, 'exact named RawNondet rejection '+expected

for name, flags in [('ordinary',[]),('recordable',['-d:isonimRecordable']),('release',['-d:release']),('direct',['-d:isonimDirectNondet'])]:
    normal = compile_js('omission-'+name,'tests/fixtures/record_http_omission.nim',flags)
    internal = compile_js('omission-'+name+'-internal','tests/fixtures/record_http_omission.nim',[*flags,*FLAGS])
    assert normal.read_bytes() == internal.read_bytes(), 'unused internal defines must leave public graph byte-identical'
    for token in ['RecordHttpPrimitives','module record_http\"','createRecordFetch','boundary-shim']:
        assert token not in normal.read_text(), 'ordinary private omission '+token
    invoke('omission-'+name+'-run',['node',str(normal)]).check_returncode()
    output = OUT/('native-'+name)
    invoke('native-'+name,['nim','c',*flags,*FLAGS,'--out:'+str(output),'tests/fixtures/record_http_omission.nim']).check_returncode()
    invoke('native-'+name+'-run',[str(output)]).check_returncode()

# Each source mutation is compiled against real production imports. The fixture
# remains unchanged except for its include path in the dedicated effect inverse.
original = MODULE.read_text()
http_block = '''    result = newPromise proc(resolve: proc(response: HttpResponse)) =
      let init = buildHttpRequestInitRaw(rawBackendAccess, parts)
      let pending = fetchRaw(http.linkage, parts.url, init)
'''
mutations = {
 'raw-global': ('return c.fetch.call(c.window,u,i);','return globalThis.fetch(u,i);','semantic: one actual owner NetRequest'),
 'http-outside-executor': (http_block,'''    let init = buildHttpRequestInitRaw(rawBackendAccess, parts)
    let pending = fetchRaw(http.linkage, parts.url, init)
    result = newPromise proc(resolve: proc(response: HttpResponse)) =
''','semantic: HTTP synchronous fetch fault becomes rejection'),
 'extra-continuation': ('return c.fetch.call(c.window,u,i);','return c.fetch.call(c.window,u,i).then(function(v){return v;});','semantic: no extra private continuation before public settlement'),
 'rpc-body': ('rawBackendAccess, httpMethod, body, csrf,','rawBackendAccess, httpMethod, nil, csrf,','semantic: exact owning body/error projection'),
 'rpc-abort': ('pending, signal)','pending, nil)','semantic: exact buffered status'),
}
def isolated(name, text):
    directory = OUT/name
    shutil.copytree(ROOT/'src',directory/'src',symlinks=True)
    source = directory/'src/isonim/core/private/record_http.nim'
    source.write_text(text)
    fixture = directory/'tests/fixtures/record_http.nim'
    fixture.parent.mkdir(parents=True)
    shutil.copy2(ROOT/'tests/fixtures/record_http.nim',fixture)
    differences = []
    for path in sorted((directory/'src').rglob('*')):
        if path.is_file():
            original_path = ROOT/'src'/path.relative_to(directory/'src')
            if sha(path) != sha(original_path): differences.append(str(path.relative_to(directory/'src')))
    assert differences == ([] if text==original else ['isonim/core/private/record_http.nim']), 'exact source-copy inverse'
    (directory/'SOURCE-BEFORE.json').write_text(json.dumps({'differences':differences,'fixture_sha256':sha(fixture),'source_sha256':sha(source)},indent=2)+'\n')
    # Project/parent configs otherwise re-add the original checkout before the
    # mutant. Preserve the actual compiler/stdlib configs and selected relevant
    # Nim defines, and pair with unchanged source under precisely these flags.
    command = ['nim','js','--skipParentCfg','--skipProjCfg','-d:nimOldCaseObjects',*FLAGS,
               '--path:'+str(directory/'src'),'--path:'+str(ROOT.parent/'nim-everywhere/src'),
               '--nimcache:'+str(directory/'nimcache'),'--out:'+str(directory/'fixture.js'),str(fixture)]
    invoke(name+'-compile',command,candidate=source).check_returncode()
    return source,directory/'fixture.js'

for name,(old,new,expected) in mutations.items():
    assert original.count(old) == 1, 'unique production source mutation '+name
    source,compiled = isolated(name,original.replace(old,new,1))
    companion_source,companion = isolated(name+'-companion',original)
    changed,positive = compiled.read_text(),companion.read_text()
    if name in ['raw-global','extra-continuation']:
        assert new in changed and old not in changed, 'intended raw semantic change emitted'
        assert old in positive and new not in positive, 'unchanged raw call emitted in companion'
    else:
        # Function-local emitted code, including generated closures, must differ
        # after removing only compiler symbol/path identifiers. Source-only
        # difference is insufficient to establish an executed inverse.
        marker = 'function recordHttp__' if name=='http-outside-executor' else 'function recordBrowserFetch__'
        def body(js):
            pos=js.index(marker)
            end=js.index('\nfunction ',pos+1)
            return re.sub(r'__[A-Za-z0-9_]+','__SYMBOL',js[pos:end])
        assert body(changed) != body(positive), 'intended production function change emitted '+name
        if name=='http-outside-executor':
            assert 'buildHttpRequestInitRaw' in body(changed) and 'buildHttpRequestInitRaw' not in body(positive), 'builder moved outside executor in emitted production'
        if name=='rpc-body':
            assert re.search(r'buildRpcRequestInitRaw[^\n]*httpMethod_p1, null, csrf_p4',body(changed)), 'nil RPC body emitted'
        if name=='rpc-abort':
            assert re.search(r'projectRpcResponseRaw[^\n]*pending_[^,]+, null',body(changed)), 'nil abort signal emitted'
    (source.parents[3]/'EMITTED-PROOF.json').write_text(json.dumps({'compiled':str(compiled),'sha256':sha(compiled),'companion':str(companion),'companion_sha256':sha(companion),'semantic_site_verified':name},indent=2)+'\n')
    browser(name+'-companion',companion,candidate=companion_source)
    browser(name,compiled,expected,source)

# Removing a raw binding's own effect tag must make the exact ceiling probe
# compile; tagged callers remain positive. This checks the negative test itself.
old = '})(#,#,#)", tags: [RawNondet].}'
assert original.count(old) == 1
mutant = OUT/'effect_mutant.nim'
mutant.write_text(original.replace(old,'})(#,#,#)".}',1))
fixture = OUT/'effect_mutant_fixture.nim'
text = (ROOT/'tests/fixtures/record_http_effect.nim').read_text().replace('include ../../src/isonim/core/private/record_http','include "'+str(mutant)+'"')
# Relative sibling import in the included module must use its genuine owner file.
mutant.write_text(mutant.read_text().replace('import ./rpc_http','import isonim/core/private/rpc_http'))
fixture.write_text(text)
for reject in [[],['-d:httpReject']]:
    command = ['nim','js',*FLAGS,*reject,'-d:httpBoundary=1','--path:'+str(ROOT/'src'),'--path:'+str(ROOT.parent/'nim-everywhere/src'),'--out:'+str(OUT/('effect-inverse-'+str(bool(reject))+'.js')),str(fixture)]
    invoke('effect-inverse-'+str(bool(reject)),command,candidate=mutant).check_returncode()

for item in inputs:
    assert sha(Path(item['path'])) == item['sha256'], 'qualification input changed: '+item['path']
(OUT/'PASS.json').write_text(json.dumps({'result':'PASS','semantic_inverses':list(mutations),'effect_boundaries':5,'effect_inverse':'own raw tag removal','limits':'bounded Record preparation, no selected IsoNim Replay/privacy/full milestone acceptance'},indent=2)+'\n')
print('PASS fixed Record HTTP/RPC, actual owner Replay and compiled inverses',flush=True)
