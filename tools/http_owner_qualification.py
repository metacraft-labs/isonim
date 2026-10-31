#!/usr/bin/env python3
"""Fixed private HTTP/RPC: compiled production, real HTTP/owner Replay and inverses.

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
REPLAY = bool(globals().get('REPLAY_HTTP', False))
MODE = 'replay' if REPLAY else 'record'
FIXTURE = 'tests/fixtures/'+MODE+'_http.nim'
ARTIFACT = Path(os.environ.get('CT_ARTIFACT', ''))
assert os.environ.get('CT_ARTIFACT'), 'CT_ARTIFACT required; owner gate cannot skip'
assert (ARTIFACT/'packages/boundary-shim/dist/browser/seams-net.js').is_file()
if REPLAY:
    assert (ARTIFACT/'packages/boundary-shim/dist/browser/replay/net.js').is_file(), 'installed owner Replay fetch factory required'
ENV = dict(os.environ)
ENV.pop('RECORD_HTTP_INVERSE', None)
ENV.pop('REPLAY_HTTP_INVERSE', None)
ENV.pop('REPLAY_HTTP_BUNDLE', None)
ENV.pop('REPLAY_HTTP_CASE', None)
ENV['PLAYWRIGHT_CHROMIUM_EXECUTABLE'] = ENV.get('PLAYWRIGHT_CHROMIUM_EXECUTABLE') or shutil.which('chromium') or ''
assert Path(ENV['PLAYWRIGHT_CHROMIUM_EXECUTABLE']).is_file(), 'actual Chromium required'
PARENT = ROOT/('build/'+MODE+'-http-qualification')
PARENT.mkdir(parents=True, exist_ok=True)
OUT = Path(tempfile.mkdtemp(prefix='run-', dir=PARENT))
print('retained qualification directory: '+str(OUT), flush=True)
MODULE = ROOT/('src/isonim/core/private/'+MODE+'_http.nim')
FLAGS = ['-d:isonimInternalReplayHttp', '-d:isonimInternalRecordHttp', '-d:isonimInternalRecordTimers'] if REPLAY else ['-d:isonimInternalRecordHttp', '-d:isonimInternalRecordTimers']
RECORD_FLAGS = ['-d:isonimInternalRecordHttp', '-d:isonimInternalRecordTimers']
record_bundle = None

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
dump_command = [str(nim),'dump','--dump.format:json','--hint:Conf:on',FIXTURE]
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
for path in [Path(__file__),ROOT/'tests/test_record_http_owner.mjs',ROOT/'tests/replay_http_controls.mjs',ROOT/'tools/test_record_http_owner.py',ROOT/'tools/test_replay_http_owner.py',ROOT/'Justfile',engine,*configs]:
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
    if REPLAY:
        env['REPLAY_HTTP_BUNDLE']=str(bundle)
        if expected: env['REPLAY_HTTP_INVERSE']=name
        if name.startswith('http-double-resolution'): env['REPLAY_HTTP_CASE']='constructed-null'
    if not REPLAY and expected and name=='raw-global': env['RECORD_HTTP_INVERSE']='raw-global'
    result = invoke(name+'-browser',['node','tests/test_record_http_owner.mjs'],env,candidate)
    if expected:
        assert result.returncode == 1 and 'AssertionError [ERR_ASSERTION]: '+expected in result.stdout, 'precise compiled semantic inverse: '+name
    else: result.check_returncode()

for name, flags in [('default',[]),('recordable',['-d:isonimRecordable']),('release',['-d:release']),('recordable-release',['-d:release','-d:isonimRecordable']),('strict',['-d:isonimStrictNondet'])]:
    js = compile_js(name,FIXTURE,[*FLAGS,*flags])
    browser(name,js)

for boundary in range(5):
    flags = [*FLAGS,'-d:isonimStrictNondet','-d:httpBoundary='+str(boundary)]
    compile_js('effect-'+str(boundary),'tests/fixtures/'+MODE+'_http_effect.nim',flags)
    command = ['nim','js',*flags,'-d:httpReject','--out:'+str(OUT/('reject-'+str(boundary)+'.js')),'tests/fixtures/'+MODE+'_http_effect.nim']
    result = invoke('reject-'+str(boundary),command)
    expected = (['prepare','fetchRaw','newInternalReplayHttp','replayHttp','replayBrowserFetch'] if REPLAY else ['prepare','fetchRaw','newInternalRecordHttp','recordHttp','recordBrowserFetch'])[boundary]
    assert result.returncode != 0 and 'RawNondet' in result.stdout and 'unlisted effect' in result.stdout and ('Error: '+expected+'(') in result.stdout, 'exact named RawNondet rejection '+expected

for name, flags in [('ordinary',[]),('recordable',['-d:isonimRecordable']),('release',['-d:release']),('direct',['-d:isonimDirectNondet'])]:
    normal = compile_js('omission-'+name,'tests/fixtures/'+MODE+'_http_omission.nim',flags)
    internal = compile_js('omission-'+name+'-internal','tests/fixtures/'+MODE+'_http_omission.nim',[*flags,*FLAGS])
    assert normal.read_bytes() == internal.read_bytes(), 'unused internal defines must leave public graph byte-identical'
    for token in ['ReplayHttpPrimitives' if REPLAY else 'RecordHttpPrimitives','module '+MODE+'_http\"','createFrameworkReplayFetch' if REPLAY else 'createRecordFetch','boundary-shim']:
        assert token not in normal.read_text(), 'ordinary private omission '+token
    invoke('omission-'+name+'-run',['node',str(normal)]).check_returncode()
    output = OUT/('native-'+name)
    invoke('native-'+name,['nim','c',*flags,*FLAGS,'--out:'+str(output),'tests/fixtures/'+MODE+'_http_omission.nim']).check_returncode()
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
    source = directory/('src/isonim/core/private/'+MODE+'_http.nim')
    source.write_text(text)
    fixture = directory/FIXTURE
    fixture.parent.mkdir(parents=True)
    shutil.copy2(ROOT/FIXTURE,fixture)
    if REPLAY: shutil.copy2(ROOT/'tests/fixtures/record_http.nim',fixture.with_name('record_http.nim'))
    differences = []
    for path in sorted((directory/'src').rglob('*')):
        if path.is_file():
            original_path = ROOT/'src'/path.relative_to(directory/'src')
            if sha(path) != sha(original_path): differences.append(str(path.relative_to(directory/'src')))
    assert differences == ([] if text==original else ['isonim/core/private/'+MODE+'_http.nim']), 'exact source-copy inverse'
    (directory/'SOURCE-BEFORE.json').write_text(json.dumps({'differences':differences,'fixture_sha256':sha(fixture),'source_sha256':sha(source)},indent=2)+'\n')
    # Project/parent configs otherwise re-add the original checkout before the
    # mutant. Preserve the actual compiler/stdlib configs and selected relevant
    # Nim defines, and pair with unchanged source under precisely these flags.
    command = ['nim','js','--skipParentCfg','--skipProjCfg','-d:nimOldCaseObjects',*FLAGS,
               '--path:'+str(directory/'src'),'--path:'+str(ROOT.parent/'nim-everywhere/src'),
               '--nimcache:'+str(directory/'nimcache'),'--out:'+str(directory/'fixture.js'),str(fixture)]
    invoke(name+'-compile',command,candidate=source).check_returncode()
    return source,directory/'fixture.js'

if REPLAY:
    mutations['raw-global']=(*mutations['raw-global'][:2], 'semantic: private Replay performs no native HTTP')
    mutations['http-outside-executor']=(*mutations['http-outside-executor'][:2], 'semantic: Replay HTTP synchronous owner fault becomes rejection')
    mutations['extra-continuation']=(*mutations['extra-continuation'][:2], 'semantic: no extra Replay continuation before public settlement')
    mutations['rpc-body']=(*mutations['rpc-body'][:2], 'semantic: private Replay body matches recorded request')
    mutations['rpc-abort']=(*mutations['rpc-abort'][:2], 'semantic: private Replay preserves abort projection')
def module_emission(js, source):
    # Exact compiler source-frame scope, not a JavaScript AST claim. Nim inlines
    # importjs at the HTTP executor and RPC call sites. Their F.filename binds
    # the emitted statements to the actual candidate module in this compilation.
    starts=[m.start() for m in re.finditer(r'^function ',js,re.M)]+[len(js)]
    rows=[]
    for start,end in zip(starts,starts[1:]):
        block=js[start:end]
        match=re.search(r'var F = \{procname: ("(?:[^"\\]|\\.)*"), prev: framePtr, filename: ("(?:[^"\\]|\\.)*")',block)
        if match and Path(json.loads(match.group(2))).resolve()==source.resolve():
            rows.append({'symbol':re.match(r'function ([A-Za-z0-9_]+)',block).group(1),'procname':json.loads(match.group(1)),'code':block})
    assert rows,'actual compiler module-qualified emission frames required: '+str(source)
    return rows

for name,(old,new,expected) in mutations.items():
    assert original.count(old) == 1, 'unique production source mutation '+name
    source,compiled = isolated(name,original.replace(old,new,1))
    companion_source,companion = isolated(name+'-companion',original)
    changed,positive = compiled.read_text(),companion.read_text()
    if name in ['raw-global','extra-continuation']:
        if REPLAY:
            changed_sites=module_emission(changed,source)
            companion_sites=module_emission(positive,companion_source)
            affected=[r for r in changed_sites if new in r['code']]
            unmodified=[r for r in companion_sites if old in r['code']]
            assert len(affected)==2 and len(unmodified)==2,'actual HTTP executor and RPC binding sites required'
            assert all(old not in r['code'] for r in changed_sites),'old binding absent from actual Replay module'
            assert all(new not in r['code'] for r in companion_sites),'mutant binding absent from companion Replay module'
            record_sites=module_emission(changed,source.with_name('record_http.nim'))
            assert sum(old in r['code'] for r in record_sites)==2 and all(new not in r['code'] for r in record_sites),'unchanged Record binding remains in combined graph'
            (source.parents[3]/'MODULE-QUALIFIED-EMITTED-SITES.json').write_text(json.dumps({'candidate':str(source),'companion':str(companion_source),'binding':'fetchRaw importjs inlined at actual module callers','changed_sites':affected,'companion_sites':unmodified,'record_sites':record_sites},indent=2)+'\n')
        else:
            assert new in changed and old not in changed, 'intended raw semantic change emitted'
            assert old in positive and new not in positive, 'unchanged raw call emitted in companion'
    else:
        # Function-local emitted code, including generated closures, must differ
        # after removing only compiler symbol/path identifiers. Source-only
        # difference is insufficient to establish an executed inverse.
        marker = ('function replayHttp__' if name=='http-outside-executor' else 'function replayBrowserFetch__') if REPLAY else ('function recordHttp__' if name=='http-outside-executor' else 'function recordBrowserFetch__')
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

# Focused exactly-once measurement control: actual production delegates to the
# actual projector, but its resolver calls the genuine facade resolver twice.
# The outward constructed-null result still looks correct; the count must not.
if REPLAY:
    old='      projectHttpResponseRaw(rawBackendAccess, pending, resolve)'
    new='      projectHttpResponseRaw(rawBackendAccess, pending, proc(response: HttpResponse) =\n        resolve(response)\n        resolve(response))'
    assert original.count(old)==1
    source,compiled=isolated('http-double-resolution',original.replace(old,new,1))
    companion_source,companion=isolated('http-double-resolution-companion',original)
    assert compiled.read_bytes()!=companion.read_bytes(),'actual compiled count-control source change emitted'
    browser('http-double-resolution-companion',companion,candidate=companion_source)
    browser('http-double-resolution',compiled,'semantic: private Replay HTTP resolves exactly once',source)

# Removing a raw binding's own effect tag must make the exact ceiling probe
# compile; tagged callers remain positive. This checks the negative test itself.
old = '})(#,#,#)", tags: [RawNondet].}'
assert original.count(old) == 1
mutant = OUT/'effect_mutant.nim'
mutant.write_text(original.replace(old,'})(#,#,#)".}',1))
fixture = OUT/'effect_mutant_fixture.nim'
text = (ROOT/('tests/fixtures/'+MODE+'_http_effect.nim')).read_text().replace('include ../../src/isonim/core/private/'+MODE+'_http','include "'+str(mutant)+'"')
# Relative sibling import in the included module must use its genuine owner file.
mutant.write_text(mutant.read_text().replace('import ./rpc_http','import isonim/core/private/rpc_http'))
fixture.write_text(text)
for reject in [[],['-d:httpReject']]:
    command = ['nim','js',*FLAGS,*reject,'-d:httpBoundary=1','--path:'+str(ROOT/'src'),'--path:'+str(ROOT.parent/'nim-everywhere/src'),'--out:'+str(OUT/('effect-inverse-'+str(bool(reject))+'.js')),str(fixture)]
    invoke('effect-inverse-'+str(bool(reject)),command,candidate=mutant).check_returncode()

for item in inputs:
    assert sha(Path(item['path'])) == item['sha256'], 'qualification input changed: '+item['path']
(OUT/'PASS.json').write_text(json.dumps({'result':'PASS','mode':MODE,'semantic_inverses':list(mutations),'effect_boundaries':5,'focused_count_inverse':'genuine resolver double-call' if REPLAY else None,'effect_inverse':'own raw tag removal','limits':'bounded '+MODE+' preparation, no selected IsoNim Replay/privacy/full milestone acceptance'},indent=2)+'\n')
print('PASS fixed '+('Replay' if REPLAY else 'Record')+' HTTP/RPC, actual owner Replay and compiled inverses',flush=True)
