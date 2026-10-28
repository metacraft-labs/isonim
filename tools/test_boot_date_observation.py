#!/usr/bin/env python3
"""Real compiled same-instance Date metadata; isolated implementation mutants.
Normal mode needs only platform/browser. --owner additionally requires the real
installed recorder artifact and never substitutes or skips that integration.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
root=Path(__file__).resolve().parent.parent
env=dict(os.environ)
owner='--owner' in sys.argv
if owner:
    assert env.get('CT_ARTIFACT'), 'CT_ARTIFACT is required for boot Date owner integration'
    env['ISONIM_BOOT_DATE_OWNER']='1'
else:
    env.pop('ISONIM_BOOT_DATE_OWNER',None)
env.setdefault('PLAYWRIGHT_CHROMIUM_EXECUTABLE',shutil.which('chromium') or '')
fixture=root/'tests/fixtures/nondet_partial_window_boot.nim'
def run(fixture,bundle,extra=(),paths=(),failure=None):
    subprocess.run(['nim','js',*extra,'--path:'+str(root/'src'),'--path:'+str(root.parent/'nim-everywhere/src'),*paths,'--nimcache:'+str(bundle.parent/(bundle.stem+'-cache')),'--out:'+str(bundle),str(fixture)],cwd=root,check=True)
    retained = None
    if paths:
        retained = root / 'build/source-snapshot-evidence' / 'test_boot_date_observation.py' / fixture.parent.name
        retained.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(fixture.parent / 'isonim/core/nondet.nim', retained / 'nondet.nim')
        shutil.copyfile(fixture.parent / 'isonim/core/private/rpc_http.nim', retained / 'rpc_http.nim')
        shutil.copyfile(bundle, retained / 'inverse.js')
    completed=subprocess.run(['node','tests/test_boot_date_observation.mjs'],cwd=root,env={**env,'ISONIM_BOOT_DATE_BUNDLE':str(bundle)},text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if retained: (retained / 'browser.log').write_text(completed.stdout)
    print(completed.stdout,flush=True)
    if failure:
        assert completed.returncode!=0
        assert failure in completed.stdout
        assert 'legacy-boot-Date-offset: PASS' in completed.stdout
        print('named boot Date mutant: REJECTED '+failure,flush=True)
    else:
        assert completed.returncode==0
        assert 'boot-Date-'+('owner' if owner else 'platform')+': PASS' in completed.stdout
for extra,mode in [((),'default'),(('-d:isonimRecordable',),'dormant')]:
    run(fixture,root/f'build/boot-date-{mode}.js',extra)
for name,old,new,oracle in [
 ('dropped','snapshot.bootDateEpochMs=epoch;','', 'boot Date epoch must retain same-instance metadata or explicit null'),
 ('fresh','var getTime=bootDate&&bootDate.getTime;', 'bootDate=new Date();var getTime=bootDate&&bootDate.getTime;', 'same-instance boot Date must not construct another clock')]:
    with tempfile.TemporaryDirectory(prefix='boot-date-'+name+'-') as temporary:
        tmp=Path(temporary);core=tmp/'isonim/core'
        shutil.copytree(root/'src/isonim/core',core)
        source=core/'nondet.nim';text=source.read_text();assert text.count(old)==1
        source.write_text(text.replace(old,new));copied=tmp/fixture.name;shutil.copyfile(fixture,copied)
        run(copied,tmp/'mutant.js',paths=('--path:'+str(tmp),),failure=oracle)
