#!/usr/bin/env python3
"""Compile real env facade and falsify metadata loss in isolated source copies.

CT_ARTIFACT must be the actual installed owner package, never a fake provider.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import sys
root=Path(__file__).resolve().parent.parent
env=dict(os.environ)
integration_mode='owner' if '--owner' in sys.argv else 'platform'
if integration_mode=='owner':
    assert env.get('CT_ARTIFACT'), 'CT_ARTIFACT is required for owner integration'
    env['ISONIM_ENV_OWNER']='1'
else:
    env.pop('ISONIM_ENV_OWNER',None)
env.setdefault('PLAYWRIGHT_CHROMIUM_EXECUTABLE',shutil.which('chromium') or '')
fixture=root/'tests/fixtures/nondet_partial_window_boot.nim'
def run(fixture,bundle,extra=(),paths=(),failure=None):
    subprocess.run(['nim','js',*extra,'--path:'+str(root/'src'),'--path:'+str(root.parent/'nim-everywhere/src'),*paths,'--out:'+str(bundle),str(fixture)],cwd=root,check=True)
    retained = None
    if paths:
        retained = root / 'build/source-snapshot-evidence' / 'test_environment_metadata.py' / fixture.parent.name
        retained.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(fixture.parent / 'isonim/core/nondet.nim', retained / 'nondet.nim')
        shutil.copyfile(fixture.parent / 'isonim/core/private/rpc_http.nim', retained / 'rpc_http.nim')
        shutil.copyfile(bundle, retained / 'inverse.js')
    completed=subprocess.run(['node','tests/test_environment_metadata.mjs'],cwd=root,env={**env,'ISONIM_ENV_BUNDLE':str(bundle)},text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if retained: (retained / 'browser.log').write_text(completed.stdout)
    print(completed.stdout,flush=True)
    if failure:
        assert completed.returncode!=0
        assert failure in completed.stdout
        assert 'legacy-environment-values: PASS' in completed.stdout
        print('named metadata mutant: REJECTED '+failure,flush=True)
    else:
        assert completed.returncode==0
        assert 'environment-metadata-cache-'+integration_mode+': PASS' in completed.stdout
for extra,mode in [((),'default'),(('-d:isonimRecordable',),'dormant')]:
    run(fixture,root/f'build/environment-metadata-{mode}.js',extra)
for name,old,new,oracle in [
 ('omitted','snapshot.colorScheme=color;','', 'three-way environment color must distinguish light and no preference'),
 ('collapsed','if(q(\'(prefers-color-scheme: light)\'))color=1;', 'if(q(\'(prefers-color-scheme: light)\'))color=0;', 'three-way environment color must distinguish light and no preference'),
 ('full-referrer',"ref=origin;",'ref=r;', 'environment referrer must retain origin only')]:
    with tempfile.TemporaryDirectory(prefix='environment-'+name+'-') as temporary:
        tmp=Path(temporary);core=tmp/'isonim/core'
        shutil.copytree(root/'src/isonim/core',core)
        source=core/'nondet.nim';text=source.read_text();assert text.count(old)==1
        source.write_text(text.replace(old,new));copied=tmp/fixture.name;shutil.copyfile(fixture,copied)
        run(copied,tmp/'mutant.js',paths=('--path:'+str(tmp),),failure=oracle)
