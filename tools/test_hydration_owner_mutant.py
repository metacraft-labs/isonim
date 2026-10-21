#!/usr/bin/env python3
"""The real-browser cleanup regression must fail without parent ownership."""
from pathlib import Path
import shutil
import subprocess
import tempfile
root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='hydration-owner-mutant-') as directory:
    tmp=Path(directory)
    shutil.copytree(root/'src',tmp/'src',symlinks=True)
    (tmp/'build').mkdir()
    shutil.copyfile(root/'build/tailwind-styles.json',tmp/'build/tailwind-styles.json')
    path=tmp/'src/isonim/web/hydration.nim'
    source=path.read_text()
    for statement in ['if getOwner() != nil: onCleanup(dispose)','if getOwner() != nil: onCleanup(disposeHydrated)']:
        assert source.count(statement)==1
        source=source.replace(statement,'discard')
    path.write_text(source)
    fixture=tmp/'tests/fixtures/hydration_owner.nim'
    fixture.parent.mkdir(parents=True)
    shutil.copyfile(root/'tests/fixtures/hydration_owner.nim',fixture)
    output=root/'build/hydration_owner.js'
    saved=output.read_bytes()
    try:
        subprocess.run(['nim','js','--hints:off','--path:'+str(tmp/'src'),
          '--path:'+str(root.parent/'nim-everywhere/src'),'--out:'+str(output),str(fixture)],cwd=root,check=True)
        run=subprocess.run(['node','tests/test_hydration_owner.mjs'],cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        assert run.returncode!=0 and '0 !== 1' in run.stdout,run.stdout
        print('missing parent hydration cleanup mutant: REJECTED')
    finally:
        output.write_bytes(saved)
