import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys
import re
import shutil
import runpy

ROOT_LEXICAL = Path(sys.argv[1])
for part in [ROOT_LEXICAL, *ROOT_LEXICAL.parents]:
    if part.is_symlink():
        raise RuntimeError('Symlink in lexical owning source-root authority')
ROOT = ROOT_LEXICAL.resolve(strict=True)
EXPECTED_NATIVE = Path(sys.argv[2]).resolve(strict=True)
EXPECTED_LEGACY_NATIVE = Path(sys.argv[6]).resolve(strict=True)
EXPECTED_CONFIG = Path(sys.argv[7]).resolve(strict=True)
EXPECTED_LEGACY_CONFIG = Path(sys.argv[8]).resolve(strict=True)
MODE = sys.argv[3]
import tempfile

HOOK_NAMES = ('pre-commit','pre-push','post-commit','post-checkout','post-merge')
selected = os.environ.get('REPROBUILD_REPRO')
if not selected:
    raise RuntimeError('Explicit matching managed hook constructor is absent')
CONSTRUCTOR = Path(selected).resolve(strict=True)
if not CONSTRUCTOR.is_file() or not os.access(CONSTRUCTOR, os.X_OK):
    raise RuntimeError('Managed constructor is not an executable regular file')
CONSTRUCTOR_SHA = hashlib.sha256(CONSTRUCTOR.read_bytes()).hexdigest()
TEMPLATES_LEXICAL = Path(sys.argv[5])
for member in [TEMPLATES_LEXICAL, *TEMPLATES_LEXICAL.parents]:
    if member.is_symlink():
        raise RuntimeError('Selected Git template authority traverses a symlink')
TEMPLATES = TEMPLATES_LEXICAL.resolve(strict=True)
SELECTED_GIT = Path(shutil.which('git') or '').resolve(strict=True)
if SELECTED_GIT != (TEMPLATES.parents[2] / 'bin/git').resolve(strict=True):
    raise RuntimeError('Template authority differs from actual selected Git executable')
GIT_SHA = hashlib.sha256(SELECTED_GIT.read_bytes()).hexdigest()
SAMPLES = {}
for path in (TEMPLATES / 'hooks').iterdir():
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or not path.name.endswith('.sample'):
        raise RuntimeError('Unexpected selected Git template hook entry')
    SAMPLES[path.name] = [stat.S_IMODE(info.st_mode), hashlib.sha256(path.read_bytes()).hexdigest()]


def refuse_workspace_target(path):
    if (path / '.repro/workspace.toml').exists() or (path / '.repro-workspace.toml').exists():
        raise RuntimeError('Hook constructor target declares a workspace')


# Refuse inherited authority before the constructor's own temporary Git repo
# can inherit that foreign hooksPath and write outside its private hook root.
effective_initial = subprocess.run(['git', '-C', str(ROOT), 'config', '--get', 'core.hooksPath'], text=True, capture_output=True)
local_initial = subprocess.run(['git', '-C', str(ROOT), 'config', '--local', '--get', 'core.hooksPath'], text=True, capture_output=True)
if effective_initial.returncode not in (0, 1) or local_initial.returncode not in (0, 1):
    raise RuntimeError('Cannot resolve effective hook configuration')
if effective_initial.stdout.strip() and local_initial.returncode != 0:
    raise RuntimeError('Inherited hooksPath cannot be migrated by a local installer')

# Shared hooks belong to the registered common-directory worktrees. Only the
# current source and registered main worktree may supply exact managed bodies.
# Both must use this same reviewed flake; arbitrary same-token bodies are refused.
def selected_git_at(path, *args):
    return subprocess.check_output([str(SELECTED_GIT), '-C', str(path), *args])
common_authority = Path(selected_git_at(ROOT, 'rev-parse', '--path-format=absolute', '--git-common-dir').decode().strip()).resolve(strict=True)
worktree_report = selected_git_at(ROOT, 'worktree', 'list', '--porcelain', '-z')
registered = [Path(os.fsdecode(field[len(b'worktree '):]))
              for field in worktree_report.split(b'\0') if field.startswith(b'worktree ')]
if not registered or ROOT not in registered:
    raise RuntimeError('Owning source is not a registered worktree')
main_worktree = registered[0]
checkout_helper = runpy.run_path(sys.argv[9])
CHECKOUT_TEMPLATES = checkout_helper['load_checkout_templates'](ROOT, common_authority)
constructor_contexts = list(dict.fromkeys([ROOT, main_worktree]))
context_source_authority = {}
for context in constructor_contexts:
    for ancestor in [context, *context.parents]:
        if ancestor.is_symlink():
            raise RuntimeError('Symlink in registered constructor context')
    if Path(selected_git_at(context, 'rev-parse', '--path-format=absolute', '--git-common-dir').decode().strip()).resolve(strict=True) != common_authority:
        raise RuntimeError('Registered constructor context has another common directory')
    if Path(selected_git_at(context, 'rev-parse', '--show-toplevel').decode().strip()) != context:
        raise RuntimeError('Registered constructor context is not its own Git source root')
    selected_git_at(context, 'ls-files', '--error-unmatch', '--', 'flake.nix')
    source = context / 'flake.nix'
    if source.is_symlink() or not source.is_file() or source.read_bytes() != (ROOT / 'flake.nix').read_bytes():
        raise RuntimeError('Registered constructor context has another flake authority')
    context_source_authority[str(context)] = hashlib.sha256(source.read_bytes()).hexdigest()
MANAGED_ACCEPTED = {}
for context in constructor_contexts:
    # The supported constructor supplies complete canonical bytes. No private
    # renderer imports, token normalization, or platform-store hash catalog.
    with tempfile.TemporaryDirectory(prefix='isonim-canonical-hook-factory-', dir=context) as directory:
        fixture = Path(directory)
        refuse_workspace_target(fixture)
        subprocess.run([str(SELECTED_GIT),'init','--template='+str(TEMPLATES),str(fixture)],check=True,stdout=subprocess.DEVNULL)
        initialized_samples = {}
        for sample in (fixture / '.git/hooks').iterdir():
            info = sample.lstat()
            digest = hashlib.sha256(sample.read_bytes()).hexdigest() if stat.S_ISREG(info.st_mode) else None
            if sample.name not in SAMPLES or digest != SAMPLES[sample.name][1]:
                raise RuntimeError('Selected Git initialized an unexpected template body')
            initialized_samples[sample.name] = [stat.S_IMODE(info.st_mode), digest]
        if set(initialized_samples) != set(SAMPLES):
            raise RuntimeError('Selected Git initialized an incomplete template inventory')
        SAMPLES = initialized_samples
        for sample in (fixture / '.git/hooks').iterdir():
            sample.unlink()
        factory_hooks = fixture / '.git/hooks'
        subprocess.run([str(SELECTED_GIT),'-C',str(fixture),'config','--local','core.hooksPath',str(factory_hooks)],check=True)
        actual_factory_hooks = subprocess.check_output([str(SELECTED_GIT),'-C',str(fixture),'rev-parse','--path-format=absolute','--git-path','hooks'],text=True).strip()
        if Path(actual_factory_hooks).resolve(strict=True) != factory_hooks.resolve(strict=True):
            raise RuntimeError('Canonical factory hooksPath escaped its owned directory')
        subprocess.run([str(CONSTRUCTOR),'hooks','ensure','--vcs',str(fixture)],cwd=context,check=True,stdout=subprocess.DEVNULL)
        hooks = fixture / '.git/hooks'
        expected_names = {name + suffix for name in HOOK_NAMES for suffix in ('','.repro-managed')}
        if {p.name for p in hooks.iterdir()} != expected_names:
            raise RuntimeError('Supported constructor emitted an unexpected inventory')
        constructed = {}
        for path in hooks.iterdir():
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o755:
                raise RuntimeError('Supported constructor emitted a noncanonical file mode')
            constructed[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    if context == ROOT:
        MANAGED = constructed
    for name, digest in constructed.items():
        MANAGED_ACCEPTED.setdefault(name, set()).add(digest)
if hashlib.sha256(SELECTED_GIT.read_bytes()).hexdigest() != GIT_SHA:
    raise RuntimeError('Selected Git changed during canonical factory execution')
if hashlib.sha256(CONSTRUCTOR.read_bytes()).hexdigest() != CONSTRUCTOR_SHA:
    raise RuntimeError('Constructor changed during canonical factory execution')



def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True).strip()


def census():
    if Path(git('rev-parse', '--show-toplevel')).resolve(strict=True) != ROOT:
        raise RuntimeError('Foreign Git source root')
    lexical_common = Path(git('rev-parse', '--path-format=absolute', '--git-common-dir'))
    for part in [lexical_common, *lexical_common.parents]:
        if part.is_symlink():
            raise RuntimeError('Symlink in lexical common-directory ownership')
    common = lexical_common.resolve(strict=True)
    worktrees = git('worktree', 'list', '--porcelain').splitlines()
    registered = [Path(line[len('worktree '):]).resolve(strict=True) for line in worktrees if line.startswith('worktree ')]
    if ROOT not in registered or not registered or common != registered[0] / '.git':
        raise RuntimeError('Unregistered primary/worktree common-directory ownership')
    hooks = common / 'hooks'
    if hooks.is_symlink() or not hooks.is_dir():
        raise RuntimeError('Hooks directory is not an owned regular directory')
    effective = subprocess.run(['git', '-C', str(ROOT), 'config', '--get', 'core.hooksPath'], text=True, capture_output=True)
    if effective.returncode not in (0, 1):
        raise RuntimeError('Cannot resolve effective hook configuration')
    value = effective.stdout.strip()
    local = subprocess.run(['git', '-C', str(ROOT), 'config', '--local', '--get', 'core.hooksPath'], text=True, capture_output=True)
    if local.returncode not in (0, 1) or (value and local.returncode != 0):
        raise RuntimeError('Inherited hooksPath cannot be migrated by a local installer')
    if value and value != '.git/hooks':
        selected = Path(value) if os.path.isabs(value) else ROOT / value
        if selected.resolve(strict=True) != hooks.resolve(strict=True):
            raise RuntimeError('Unknown effective hooksPath')
    legacy_linked = value == '.git/hooks' and ROOT != registered[0] and local.returncode == 0
    if not legacy_linked:
        actual_hook_path = Path(git('rev-parse', '--path-format=absolute', '--git-path', 'hooks'))
        if actual_hook_path.resolve(strict=True) != hooks.resolve(strict=True):
            raise RuntimeError('Effective Git hook path differs from qualified common hooks')
    native = {name: hashlib.sha256((EXPECTED_NATIVE / name).read_bytes()).hexdigest() for name in ('pre-commit','pre-push')}
    legacy_native = {name: hashlib.sha256((EXPECTED_LEGACY_NATIVE / name).read_bytes()).hexdigest() for name in ('pre-commit','pre-push')}
    refuse_workspace_target(ROOT)
    generated_config = ROOT / '.pre-commit-config.nix.yaml'
    config_identity = None
    if generated_config.exists() or generated_config.is_symlink():
        if not generated_config.is_symlink():
            raise RuntimeError('Unknown non-symlink generated hook configuration')
        config_target = generated_config.resolve(strict=True)
        permitted = {EXPECTED_CONFIG}
        if MODE in ('prepare','before','tool','snapshot','rollback'):
            permitted.add(EXPECTED_LEGACY_CONFIG)
        if config_target not in permitted:
            raise RuntimeError('Unknown generated hook configuration target')
        config_identity = {'target':str(config_target),'sha256':hashlib.sha256(config_target.read_bytes()).hexdigest(),'lexicalTarget':os.readlink(generated_config)}
    elif MODE in ('native','after'):
        raise RuntimeError('Expected genuine generated hook configuration is absent')
    result = {}
    for path in sorted(hooks.iterdir()):
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode):
            raise RuntimeError('Unknown nonregular hook entry: ' + path.name)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        mode = stat.S_IMODE(info.st_mode)
        if path.name.endswith('.sample'):
            if (SAMPLES.get(path.name) != [mode, digest] and
                (CHECKOUT_TEMPLATES is None or CHECKOUT_TEMPLATES['samples'].get(path.name) != [mode, digest])):
                raise RuntimeError('Unknown selected Git sample body or mode: ' + path.name)
        else:
            known = set()
            if path.name in MANAGED:
                known.update(MANAGED_ACCEPTED[path.name])
            for hook in native:
                if path.name in (hook, hook + '.repro-local'):
                    known.add(native[hook])
            if MODE in ('prepare','before','tool','snapshot','rollback'):
                for hook in legacy_native:
                    if path.name in (hook, hook + '.repro-local'):
                        known.add(legacy_native[hook])
            for hook in native:
                if path.name == hook + '.legacy':
                    known.update(MANAGED_ACCEPTED[hook])
            if digest not in known or mode != 0o755:
                raise RuntimeError('Unknown hook body or mode: ' + path.name)
        result[path.name] = [mode, digest]
    missing = set(MANAGED) - set(result)
    if MODE != 'rollback' and missing and not (MODE in ('prepare','snapshot') and missing == set(MANAGED) and all(name.endswith('.sample') for name in result)):
        raise RuntimeError('Missing managed hook entries: ' + ','.join(sorted(missing)))
    selected = os.environ.get('REPROBUILD_REPRO') or shutil.which('repro')
    if not selected:
        raise RuntimeError('Matching managed hook tool is absent')
    actual = Path(selected).resolve(strict=True)
    if not actual.is_file() or not os.access(actual, os.X_OK):
        raise RuntimeError('Managed hook tool is not executable')
    for hook in ('pre-commit','pre-push','post-commit','post-checkout','post-merge'):
        if hook + '.repro-managed' not in result:
            continue
        body = (hooks / (hook + '.repro-managed')).read_text()
        tokens = set(re.findall(r'reprobuild\.managed-hook\.v1\.[a-z-]+\.[0-9a-f]+', body))
        if len(tokens) != 1:
            raise RuntimeError('Missing or ambiguous managed hook contract')
        subprocess.run([str(actual),'hooks','protocol','--require=2','--hook-contract='+tokens.pop()],check=True,stdout=subprocess.DEVNULL)
    return {'generatedConfig':config_identity,'entries':result,'repro':[str(actual),hashlib.sha256(actual.read_bytes()).hexdigest()], 'git':[str(SELECTED_GIT),GIT_SHA], 'gitTemplates':{'path':str(TEMPLATES),'samples':SAMPLES}, 'checkoutGitTemplates':CHECKOUT_TEMPLATES}


import json
for context, digest in context_source_authority.items():
    if hashlib.sha256((Path(context) / 'flake.nix').read_bytes()).hexdigest() != digest:
        raise RuntimeError('Registered constructor context source changed')
before = census()
if MODE == 'prepare':
    initial = before
    if not any(name in before['entries'] for name in MANAGED):
        subprocess.run([str(CONSTRUCTOR),'hooks','ensure','--vcs',str(ROOT)],check=True,stdout=sys.stderr)
        MODE = 'before'
        before = census()
        for name, identity in initial['entries'].items():
            if before['entries'].get(name) != identity:
                raise RuntimeError('Canonical bootstrap changed an original template sample')
        before['initialEmptyInventory'] = initial
    print(json.dumps(before, sort_keys=True))
elif MODE in ('before','snapshot','rollback'):
    print(json.dumps(before, sort_keys=True))
elif MODE == 'native':
    for hook in ('pre-commit','pre-push'):
        if before['entries'].get(hook) != [0o755, hashlib.sha256((EXPECTED_NATIVE / hook).read_bytes()).hexdigest()]:
            raise RuntimeError('Expected actual native main hook is absent: ' + hook)
    print(json.dumps(before, sort_keys=True))
elif MODE == 'tool':
    print(before['repro'][0])
elif MODE == 'after':
    original = json.loads(Path(sys.argv[4]).read_text())
    for hook in ('pre-commit','pre-push'):
        if before['entries'].get(hook + '.repro-local') != [0o755, hashlib.sha256((EXPECTED_NATIVE / hook).read_bytes()).hexdigest()]:
            raise RuntimeError('Expected actual native local hook is absent: ' + hook)
    if original['repro'] != before['repro'] or original['git'] != before['git'] or original['gitTemplates'] != before['gitTemplates'] or original['checkoutGitTemplates'] != before['checkoutGitTemplates']:
        raise RuntimeError('Managed hook tool changed during installation')
    for name in set(original['entries']) | set(before['entries']):
        if name in ('pre-commit.legacy','pre-push.legacy') and name not in original['entries']:
            main = name.removesuffix('.legacy')
            if before['entries'].get(name) != original['entries'].get(main) or before['entries'].get(name, [None, None])[0] != 0o755 or before['entries'].get(name, [None, None])[1] not in MANAGED_ACCEPTED[main]:
                raise RuntimeError('Unexpected newly produced legacy backup: ' + name)
            continue
        if name not in ('pre-commit.repro-local', 'pre-push.repro-local') and original['entries'].get(name) != before['entries'].get(name):
            previous = original['entries'].get(name)
            current = before['entries'].get(name)
            if name not in MANAGED or previous is None or previous[0] != 0o755 or previous[1] not in MANAGED_ACCEPTED[name] or current != [0o755, MANAGED[name]]:
                raise RuntimeError('Installer changed another hook entry: ' + name)
    print(json.dumps(before, sort_keys=True))
else:
    raise RuntimeError('Unknown guard mode')
