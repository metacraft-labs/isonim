#!/usr/bin/env python3
"""Explicit actual-owner Recorder/runtime/cursor gate; missing artifact is fatal.
No copied codec/reference framework or fake cursor is an accepted substitute.
"""
from pathlib import Path
import os
import shutil
import subprocess
root=Path(__file__).resolve().parent.parent
env=dict(os.environ)
assert env.get('CT_ARTIFACT'),'CT_ARTIFACT is required for actual-owner bridge integration'
env.setdefault('PLAYWRIGHT_CHROMIUM_EXECUTABLE',shutil.which('chromium') or '')
for name,flags in [('default',['-d:bridgeCursorDefault']),('same_module',['-d:bridgeCursorSame']),('early',[]),('late',['-d:bridgeCursorLate'])]:
    subprocess.run(['nim','js',*flags,'--path:'+str(root/'src'),'--path:'+str(root.parent/'nim-everywhere/src'),'--nimcache:'+str(root/'build/nimcache'/('bridge-owner-'+name)),'--out:'+str(root/'build'/('bridge-owner-'+name+'.js')),str(root/'tests/fixtures/nondet_bridge_cursor.nim')],cwd=root,check=True)
subprocess.run(['node','tests/test_nondet_bridge_owner.mjs'],cwd=root,env=env,check=True)
