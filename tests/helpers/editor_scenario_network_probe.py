#!/usr/bin/env python3
"""Read-only evidence of actual Harbor tool namespace and callback reachability.

No credentials are emitted or sent. OPTIONS probes verify the actual editor
listener at the original loopback and documented slirp host gateway, preserving
its port. This is diagnostic evidence; it neither dispatches nor fabricates RPC.
"""
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request
scope=json.loads(Path(sys.argv[1]).read_text())
endpoint=urllib.parse.urlsplit(scope['ISONIM_EDITOR_ENDPOINT'])
result={'pid':os.getpid(),'namespace':os.readlink('/proc/self/ns/net') if Path('/proc/self/ns/net').exists() else None,
        'routes':Path('/proc/net/route').read_text() if Path('/proc/net/route').exists() else None,'probes':[]}
for host in [endpoint.hostname,'10.0.2.2']:
    uri=urllib.parse.urlunsplit((endpoint.scheme,host+':'+str(endpoint.port),'/api/agent/sessions','',''))
    try:
        with urllib.request.urlopen(urllib.request.Request(uri,method='OPTIONS'),timeout=2) as response:status=response.status
        result['probes'].append({'endpoint':uri,'status':status})
    except Exception as error:result['probes'].append({'endpoint':uri,'error':str(error)})
Path(sys.argv[2]).write_text(json.dumps(result,indent=2))
print(json.dumps(result))
