#!/usr/bin/env python3
"""Real C/Node/browser initialization and isolated published-source restoration.

Existing supported TestClock/FakeAsyncContext controls are intentional; no fake
owner cursor or network server stands in for the actual bridge APIs. Actual
owner-runtime integration is a separate mandatory gate with an explicit artifact.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
root=Path(__file__).resolve().parent.parent
env=dict(os.environ)
env.setdefault('PLAYWRIGHT_CHROMIUM_EXECUTABLE',shutil.which('chromium') or '')
fixture=root/'tests/fixtures/nondet_bridge_initialization.nim'
variants=[('early',['-d:bridgePreselect']),('early-explicit',['-d:bridgePreselect','-d:bridgeExplicit']),('default-explicit',['-d:bridgeExplicit']),('late',[]),('clear',['-d:bridgeClear']),('early-dormant',['-d:bridgePreselect','-d:isonimRecordable'])]

def compile_one(target,name,flags,fixture=fixture,paths=()):
    output=root/'build'/('bridge-'+name+('.js' if target=='js' else '-native'))
    subprocess.run(['nim',target,*flags,'--path:'+str(root/'src'),'--path:'+str(root.parent/'nim-everywhere/src'),*paths,'--nimcache:'+str(root/'build/nimcache'/('bridge-'+name)),'--out:'+str(output),str(fixture)],cwd=root,check=True)
    return output

for name,flags in variants:
    native=compile_one('c',name,flags)
    subprocess.run([str(native)],cwd=root,check=True)
    node=compile_one('js',name+'-node',['-d:nodejs',*flags])
    subprocess.run(['node',str(node)],cwd=root,check=True)
    browser=compile_one('js',name+'-browser',flags)
    subprocess.run(['node','tests/test_nondet_bridge.mjs'],cwd=root,env={**env,'ISONIM_BRIDGE_BUNDLE':str(browser)},check=True)

# Restore the actual old production source in an isolated copy. This is a
# current-source inverse mutation, not a historical git object dependency.
with tempfile.TemporaryDirectory(prefix='bridge-restoration-') as temporary:
    tmp=Path(temporary);core=tmp/'isonim/core';core.mkdir(parents=True)
    for path in (root/'src/isonim/core').glob('*.nim'):shutil.copyfile(path,core/path.name)
    source=core/'nondet.nim';text=source.read_text()
    needle='  elif currentBackendHook == nil: install(currentClock)\n'
    assert text.count(needle)==1;text=text.replace(needle,'')
    needle='if currentBackendHook == nil: installBridge()\n'
    assert text.count(needle)==1;text=text.replace(needle,'')
    source.write_text(text)
    copied=tmp/fixture.name;shutil.copyfile(fixture,copied)
    shutil.copyfile(fixture.parent/'nondet_bridge_bootstrap.nim',tmp/'nondet_bridge_bootstrap.nim')
    for target,extra in [('c',[]),('js',['-d:nodejs'])]:
        output=compile_one(target,'restored-'+target,[*extra,'-d:bridgePreselect'],copied,('--path:'+str(tmp),))
        result=subprocess.run(['node',str(output)] if target=='js' else [str(output)],cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        print(result.stdout,flush=True)
        assert result.returncode!=0
        assert 'nondet initialization must register a lazy forwarding bridge' in result.stdout
    print('published bridge behavior restored: REJECTED on C/JS',flush=True)
