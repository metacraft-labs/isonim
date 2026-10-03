#!/usr/bin/env python3
"""Observe actual Claude ACP bytes and child lifecycle without substituting it.

Only this test-owned observer records private wire evidence. JSON-RPC lines,
provider decisions, tool requests/results and model replies pass unchanged.
Scoped authority is copied privately for authenticated test observations; it is
never inserted into wire traces/system instructions or public proofs. The actual
provider/Claude SDK and Harbor terminal/filesystem/compiler boundaries stay real.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
from editor_sdk_runtime import authenticate, observe_environment

root, provider = map(Path, sys.argv[1:3])
private = root / 'private'
private.mkdir(mode=0o700, exist_ok=True)
keys = {'ISONIM_EDITOR_ENDPOINT','ISONIM_EDITOR_WORKSPACE','ISONIM_EDITOR_INSTANCE',
        'ISONIM_EDITOR_EPOCH','ISONIM_EDITOR_TOKEN','ISONIM_EDITOR_CLI_DIR'}
filename = private / 'provider-scope.json'
fd = os.open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as output:
    json.dump({key: os.environ[key] for key in keys}, output)
if len(sys.argv)!=4: raise AssertionError('Explicit mounted owning SDK manifest required')
manifest=Path(sys.argv[3])
if manifest.parent.resolve()!=private.resolve(): raise AssertionError('SDK manifest must be in the existing mounted private directory')
runtime=authenticate(manifest, provider)
from editor_provider_wire import observe_provider
sys.exit(observe_provider(root,provider,[str(provider)],observe_environment(private,runtime)))
