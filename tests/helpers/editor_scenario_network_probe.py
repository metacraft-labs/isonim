#!/usr/bin/env python3
"""Read-only evidence of actual Harbor tool namespace and callback reachability.

No credentials are emitted or sent. OPTIONS probes verify the actual editor
listener at the original loopback and documented slirp host gateway, preserving
its port. This is diagnostic evidence; it neither dispatches nor fabricates RPC.
"""
import json
import importlib.util
import stat
import os
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request
metadata=json.loads(Path(sys.argv[3]).read_text())
filename=Path(metadata['environment'])
spec=importlib.util.spec_from_file_location('production_editor_agent_env',sys.argv[4])
wrapper=importlib.util.module_from_spec(spec);spec.loader.exec_module(wrapper)
original=wrapper.read_environment(str(filename))
scope=json.loads(Path(sys.argv[1]).read_text())
assert set(original)==wrapper.ALLOWED
assert {key:value for key,value in original.items() if key!='ISONIM_EDITOR_ENDPOINT'} == {
    key:value for key,value in scope.items() if key!='ISONIM_EDITOR_ENDPOINT'}
assert wrapper.scoped_endpoint(original['ISONIM_EDITOR_ENDPOINT'])==scope['ISONIM_EDITOR_ENDPOINT']
info=filename.stat();parent=filename.parent.stat()
assert stat.S_IMODE(info.st_mode)==0o600 and stat.S_IMODE(parent.st_mode)==0o700
endpoint=urllib.parse.urlsplit(scope['ISONIM_EDITOR_ENDPOINT'])
result={'pid':os.getpid(),'namespace':os.readlink('/proc/self/ns/net') if Path('/proc/self/ns/net').exists() else None,
        'routes':Path('/proc/net/route').read_text() if Path('/proc/net/route').exists() else None,'probes':[], 'original_handoff':{'session':metadata['session'],'path':str(filename),
        'allowed_keys':sorted(original),'provider_scope_matches':True,'file_mode':'0600','directory_mode':'0700'}}
for host in [endpoint.hostname,'10.0.2.2']:
    uri=urllib.parse.urlunsplit((endpoint.scheme,host+':'+str(endpoint.port),'/api/agent/sessions','',''))
    try:
        with urllib.request.urlopen(urllib.request.Request(uri,method='OPTIONS'),timeout=2) as response:status=response.status
        result['probes'].append({'endpoint':uri,'status':status})
    except Exception as error:result['probes'].append({'endpoint':uri,'error':str(error)})
Path(sys.argv[2]).write_text(json.dumps(result,indent=2))
print(json.dumps(result))
