"""Authenticate the owning dev-shell ACP closure before any human/model input.

Only supported immutable Nix wrappers are decoded; shell text is never executed
by this resolver. Arbitrary caller manifests are rederived from the selected
executable by both host and provider. Missing or incompatible closure is fatal.
This is test instrumentation, with no additional production authority or mounts.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import sys

ROOT = Path(__file__).resolve().parents[2]

def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def immutable(path):
    path = Path(path).resolve(strict=True)
    if not str(path).startswith('/nix/store/') or not path.is_file():
        raise AssertionError('Supported immutable dev-shell runtime required: '+str(path))
    return path

def resolve(provider=None):
    command = provider or os.environ.get('ISONIM_REAL_CLAUDE_ACP') or shutil.which('claude-agent-acp')
    if not command: raise AssertionError('Actual supported Claude ACP provider required in owning dev shell')
    provider = immutable(command)
    current = provider
    wrappers = []
    native_command = None
    for _ in range(5):
        text = current.read_text()
        wrappers.append(current)
        # The owning outer wrapper pins native Claude. Respect the actual inner
        # wrapper default only if no outer wrapper fixed it.
        declaration = re.search(r"export CLAUDE_CODE_EXECUTABLE='([^']+)'", text)
        default = re.search(r"export CLAUDE_CODE_EXECUTABLE=\$\{CLAUDE_CODE_EXECUTABLE-'([^']+)'\}", text)
        if declaration: native_command = immutable(declaration[1])
        elif default and native_command is None:
            native_command = immutable(os.environ.get('CLAUDE_CODE_EXECUTABLE',default[1]))
        exec_lines = [line for line in text.splitlines() if line.startswith('exec ')]
        if len(exec_lines)!=1: raise AssertionError('Unsupported ACP owning wrapper shape')
        words = shlex.split(exec_lines[0])[1:]
        if words[:2]==['-a','$0']: words=words[2:]
        if not words or words[-1]!='$@': raise AssertionError('Unsupported ACP wrapper arguments')
        next_path = immutable(words[0])
        if next_path.name=='node':
            if len(words)!=3: raise AssertionError('Unsupported ACP Node entry arguments')
            node,entry = next_path,immutable(words[1]);break
        if len(words)!=2: raise AssertionError('Unsupported ACP forwarding arguments')
        current=next_path
    else: raise AssertionError('Unsupported ACP wrapper depth')
    if native_command is None: raise AssertionError('Native Claude pin absent from owning wrapper')
    native=immutable(native_command.with_name('.claude-wrapped'))
    if str(native).encode() not in native_command.read_bytes():
        raise AssertionError('Native binary wrapper does not reference declared loaded executable')
    package=entry.parent.parent
    metadata=json.loads((package/'package.json').read_text())
    if metadata['name']!='@agentclientprotocol/claude-agent-acp': raise AssertionError('Unsupported ACP package')
    converter=immutable(entry.parent/'acp-agent.js')
    sdk=immutable(package/'node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs')
    sdk_metadata=json.loads((sdk.parent/'package.json').read_text())
    if sdk_metadata['name']!='@anthropic-ai/claude-agent-sdk': raise AssertionError('Unsupported SDK package')
    # Require actual exported converter and the actual SDK's documented stream
    # process/initialize and native NODE_OPTIONS stripping implementation.
    if 'promptToClaude' not in converter.read_text() or 'delete c.NODE_OPTIONS' not in sdk.read_text():
        raise AssertionError('Unsupported observer/converter runtime API')
    paths={'provider':provider,'node':node,'entry':entry,'converter':converter,'sdk':sdk,
           'nativeCommand':native_command,'native':native}
    files=sorted(set(wrappers+[node,entry,converter,sdk,native_command,native,
        immutable(package/'package.json'),immutable(sdk.parent/'package.json')]))
    return {'schema':1,'paths':{key:str(value) for key,value in paths.items()},
            'files':{str(path):digest(path) for path in files},
            'versions':{'acp':metadata['version'],'sdk':sdk_metadata['version']}}

def authenticate(filename, provider=None):
    declared=json.loads(Path(filename).read_text())
    actual=resolve(provider or declared['paths']['provider'])
    if declared!=actual: raise AssertionError('Declared SDK runtime differs from actual owning closure')
    return actual

def materialize(private, provider=None):
    private=Path(private)
    runtime=resolve(provider)
    filename=private/'sdk-runtime.json'
    fd=os.open(filename,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as output: json.dump(runtime,output,indent=2)
    return filename,runtime

def observe_environment(private, runtime):
    """Restore original parent options in preload; SDK strips native options."""
    private=Path(private)
    observer=private/'editor_sdk_native_observer.mjs'
    shutil.copyfile(ROOT/'tests/helpers/editor_sdk_native_observer.mjs',observer);observer.chmod(0o600)
    expected=(private/'instructions.md').read_bytes()
    directory=private/'sdk-native';directory.mkdir(mode=0o700)
    old={'present':'NODE_OPTIONS' in os.environ,'value':os.environ.get('NODE_OPTIONS')}
    config={'directory':str(directory),'expected':{'sha256':hashlib.sha256(expected).hexdigest(),'utf8Bytes':len(expected)},
            'commands':[runtime['paths']['nativeCommand'],runtime['paths']['native']],
            'loadedExecutable':runtime['paths']['native'],'loadedSha256':runtime['files'][runtime['paths']['native']],
            'originalNodeOptions':old}
    filename=private/'sdk-observer-config.json'
    fd=os.open(filename,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as output: json.dump(config,output)
    env=dict(os.environ)
    env['ISONIM_SDK_OBSERVER_CONFIG']=str(filename)
    env['NODE_OPTIONS']=((old['value']+' ') if old['present'] and old['value'] else '')+'--import '+shlex.quote(str(observer))
    return env

if __name__=='__main__':
    if len(sys.argv)==2:
        destination=Path(sys.argv[1]);destination.parent.mkdir(parents=True,exist_ok=True)
        destination.write_text(json.dumps(resolve(),indent=2)+'\n')
    else: raise SystemExit('usage: editor_sdk_runtime.py OUTPUT')
