#!/usr/bin/env python3
"""Assert actual provider-terminal resources and private /tmp isolation.

Official Harbor playback runs this reader as a real terminal command. The input
manifest names genuine editor helpers, public CLI, provider and role prompt with
host-computed SHA256 values. Every readable file must match exactly. A host-created
unbound /tmp sentinel must be absent in Linux's genuine private /tmp; a positive
sentinel inside the bound workspace must remain readable. No filesystem, process,
namespace, compiler, RPC or model tool result is mocked. Sentinel contents never
enter the model transcript or output; only booleans and counts are emitted.
"""
import hashlib
import json
import os
from pathlib import Path
import sys

manifest = json.loads(Path(sys.argv[1]).read_text())
checked = []
for filename, expected in manifest['resources'].items():
    actual = hashlib.sha256(Path(filename).read_bytes()).hexdigest()
    if actual != expected:
        raise AssertionError('Provider resource bytes changed: ' + filename)
    checked.append(filename)
positive = Path(manifest['boundSentinel'])
assert hashlib.sha256(positive.read_bytes()).hexdigest() == manifest['sentinelSha256']
if sys.platform == 'linux':
    assert not Path(manifest['unboundSentinel']).exists(), 'Private /tmp exposed an unbound host file'
result = {'readableResources': checked, 'boundSentinelReadable': True,
          'unboundTemporarySentinelHidden': sys.platform == 'linux',
          'mountNamespace': os.readlink('/proc/self/ns/mnt') if sys.platform == 'linux' else None,
          'privateTmpMount': [line for line in Path('/proc/self/mountinfo').read_text().splitlines()
                              if ' /tmp ' in line] if sys.platform == 'linux' else []}
Path(sys.argv[2]).write_text(json.dumps(result, indent=2))
print(json.dumps({'readableResourceCount': len(checked), 'boundSentinelReadable': True,
                  'unboundTemporarySentinelHidden': result['unboundTemporarySentinelHidden']}))
