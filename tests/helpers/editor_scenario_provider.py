#!/usr/bin/env python3
"""Launch official Rust playback with real production scoped credentials.

Model decisions are in the shared Scenario-Format YAML. This wrapper only records
process launch identity and writes the allowed six production environment values
into a private snapshot for host-side authenticated observations. Actual ACP
terminal commands use the original production handoff from current session metadata.
No credential is placed in YAML, traces, system prompts or daemon-global env.
"""
import json
import os
from pathlib import Path
import sys

root, provider, scenario = map(Path, sys.argv[1:4])
private = root / 'private'
private.mkdir(mode=0o700, exist_ok=True)
keys = {'ISONIM_EDITOR_ENDPOINT','ISONIM_EDITOR_WORKSPACE','ISONIM_EDITOR_INSTANCE',
        'ISONIM_EDITOR_EPOCH','ISONIM_EDITOR_TOKEN','ISONIM_EDITOR_CLI_DIR'}
values = {key: os.environ[key] for key in keys}
filename = private / 'provider-scope.json'
temporary = private / '.provider-scope.pending'
fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as stream:
    json.dump(values, stream)
os.replace(temporary, filename)
with (root / 'provider-launch.jsonl').open('a') as stream:
    stream.write(json.dumps({'pid':os.getpid(),'provider':str(provider),'scenario':str(scenario),
                            'network_namespace':os.readlink('/proc/self/ns/net') if Path('/proc/self/ns/net').exists() else None,
                            'routes':Path('/proc/net/route').read_text() if Path('/proc/net/route').exists() else None})+'\n')
os.environ['MOCK_AGENT_PROMPT_TRACE'] = str(root / 'provider-prompts.jsonl')
argv=[str(provider),'--scenario',str(scenario),'--disable-follower','--log-file',str(root/'provider.log'),'--log-level','debug']
if sys.argv[4:]==['--observe-wire']:
    from editor_provider_wire import observe_provider
    sys.exit(observe_provider(root,provider,argv))
os.execv(str(provider),argv)
