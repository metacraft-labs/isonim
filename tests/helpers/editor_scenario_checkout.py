#!/usr/bin/env python3
"""Run genuine Harbor acceptance from a readable compiler checkout.

Harbor gives the agent a private /tmp and carries only its bound project across
that boundary. A compiler checkout under /tmp therefore cannot supply the real
editor helpers/CLI. This test-only runner snapshots the current authored files,
including tracked edits and new source files, in an owned 0700 directory outside
/tmp. It uses genuine Git repositories, existing sibling sources and the same
owning build/test recipe. No sandbox flag, provider behavior, credential, user
configuration or test assertion is replaced. Failed fixtures and provenance are
retained for inspection; no unrelated directory is removed.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from editor_workspace_roles import workspace_root, workspace_report, declared_role

ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOTS = {'src', 'tests', 'tools', 'examples', 'prompts', 'db', 'vendor', 'docs'}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(*args, cwd):
    return subprocess.check_output(['git', *args], cwd=cwd)


def temporary_checkout(path):
    # Linux's Harbor /tmp isolation concerns the canonical path, not a symlink's
    # spelling or TMPDIR (which may itself name a subdirectory under /tmp).
    return sys.platform == 'linux' and path.resolve().is_relative_to(Path('/tmp'))


def snapshot(root):
    parent = Path.home() / '.local/share/isonim-test-fixtures'
    parent.mkdir(parents=True, exist_ok=True)
    location = Path(tempfile.mkdtemp(prefix='harbor-checkout-', dir=parent))
    location.chmod(0o700)
    if temporary_checkout(location):
        raise RuntimeError('Harbor test fixture home must resolve outside private /tmp')
    workspace = location / 'workspace'
    workspace.mkdir(mode=0o700)
    destination = workspace / root.name
    subprocess.run(['git', 'clone', '--no-hardlinks', '--no-checkout', str(root), str(destination)],
                    check=True)
    head = git('rev-parse', 'HEAD', cwd=root).decode().strip()
    subprocess.run(['git', 'checkout', '--detach', head], cwd=destination, check=True)
    tracked = git('ls-files', '-z', cwd=root).decode().split('\0')
    new = git('ls-files', '--others', '--exclude-standard', '-z', cwd=root).decode().split('\0')
    paths = {name for name in tracked if name}
    executable_magic = (b'\x7fELF', b'MZ', b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
                        b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xce')
    for name in new:
        if not name or Path(name).parts[0] not in SOURCE_ROOTS:
            continue
        source = root / name
        # Include extensionless scripts and binary authored assets. Actual
        # compiler executables are generated artifacts, not candidate sources.
        if source.is_file() and not source.read_bytes()[:4].startswith(executable_magic):
            paths.add(name)
    sources = {}
    for name in sorted(paths):
        source, target = root / name, destination / name
        if source.is_dir():
            continue  # genuine submodules are cloned below
        if not source.exists() and not source.is_symlink():
            target.unlink(missing_ok=True)  # preserve a local tracked deletion
            sources[name] = {'deleted': True}
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.unlink(missing_ok=True)
        if source.is_symlink():
            target.symlink_to(os.readlink(source))
            sources[name] = {'symlink': os.readlink(source)}
        else:
            shutil.copy2(source, target)
            sources[name] = {'sha256': sha(source)}
    # Existing real source siblings stay outside the copied project. They are
    # compiler dependencies, not agent-writable additions to the bound project.
    siblings = {}
    workspace_metadata = {}
    source_workspace = workspace_root(root)
    if source_workspace is not None:
        # Preserve actual manifest definitions/state, without inventing aliases
        # for nested source paths or changing the original active project set.
        for name in git('ls-files', '-z', cwd=source_workspace).decode().split('\0'):
            if not name or Path(name).suffix != '.toml':
                continue
            source, target = source_workspace / name, workspace / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            workspace_metadata[name] = sha(source)
        state = Path('.repro/workspace.toml')
        if (source_workspace / state).is_file():
            (workspace / state).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_workspace / state, workspace / state)
            workspace_metadata[str(state)] = sha(source_workspace / state)
        report = workspace_report(root, source_workspace)
        for row in report['repos']:
            if row.get('enabled') is not True:
                continue
            source = declared_role(report, source_workspace, row['repo'])
            if source in (root.resolve(), source_workspace.resolve()):
                continue
            relative = Path(row['path'])
            target = workspace / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(source, target_is_directory=True)
            siblings[str(relative)] = {'path': str(source),
                'head': git('rev-parse', 'HEAD', cwd=source).decode().strip(),
                'trackedDiffSha256': hashlib.sha256(git('diff', 'HEAD', cwd=source)).hexdigest()}
    else:
        for source in root.parent.iterdir():
            if source.name != root.name and source.is_dir() and (source / '.git').exists():
                (workspace / source.name).symlink_to(source.resolve(), target_is_directory=True)
                siblings[source.name] = {'path': str(source.resolve()),
                    'head': git('rev-parse', 'HEAD', cwd=source).decode().strip(),
                    'trackedDiffSha256': hashlib.sha256(git('diff', 'HEAD', cwd=source)).hexdigest()}
    yoga = root / 'src/isonim/layout/yoga'
    if not (yoga / '.git').exists():
        raise RuntimeError('Initialize the genuine Yoga Git submodule before Harbor acceptance')
    target = destination / 'src/isonim/layout/yoga'
    # The clone checkout leaves an empty gitlink directory.
    target.rmdir()
    subprocess.run(['git', 'clone', '--no-hardlinks', str(yoga), str(target)], check=True)
    yoga_head = git('rev-parse', 'HEAD', cwd=yoga).decode().strip()
    subprocess.run(['git', 'checkout', '--detach', yoga_head], cwd=target, check=True)
    yoga_changes = git('diff', 'HEAD', '--binary', cwd=yoga)
    if yoga_changes:
        subprocess.run(['git', 'apply', '--binary', '-'], cwd=target, input=yoga_changes, check=True)
    if (root / 'node_modules').is_dir():
        (destination / 'node_modules').symlink_to((root / 'node_modules').resolve(), target_is_directory=True)
    generated = {}
    for name in ('tailwind.css', 'tailwind-styles.json'):
        source = root / 'build' / name
        if source.exists():
            (destination / 'build').mkdir(exist_ok=True)
            shutil.copy2(source, destination / 'build' / name)
            generated[name] = {'source': str(source), 'sha256': sha(source)}
    manifest = {'source': str(root), 'head': head, 'trackedDiffSha256':
                hashlib.sha256(git('diff', 'HEAD', cwd=root)).hexdigest(),
                'snapshot': str(destination), 'sources': sources, 'siblings': siblings,
                'workspaceMetadata': workspace_metadata,
                'yogaHead': yoga_head, 'yogaTrackedDiffSha256': hashlib.sha256(yoga_changes).hexdigest(),
                'generated': generated, 'tailwindInvokedBySnapshot': False,
                'sandboxConfigurationUnchanged': True}
    provenance = location / 'source-provenance.json'
    provenance.write_text(json.dumps(manifest, indent=2)); provenance.chmod(0o600)
    return destination, location


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: editor_scenario_checkout.py <owning-internal-recipe>')
    recipes = {'_editor-scenarios-native', '_editor-scenarios-gui',
                '_editor-scenarios-stress', '_editor-harbor-scenario', '_editor-harbor-output-modes'}
    recipe = sys.argv[1]
    if recipe not in recipes:
        raise SystemExit('Unknown Harbor acceptance recipe')
    root, location = ROOT, None
    if temporary_checkout(root):
        root, location = snapshot(root)
        print('Harbor acceptance compiler snapshot: ' + str(root), flush=True)
    environment = dict(os.environ)
    provider = environment.get('ISONIM_HARBOR_SCENARIO_PROVIDER')
    if location and provider and temporary_checkout(Path(provider)):
        original = Path(provider).resolve()
        # Preserve genuine provider bytes outside private /tmp, without changing
        # the scenario decisions or substituting a different executable.
        target = location / 'official-provider'
        shutil.copy2(original, target)
        if sha(target) != sha(original):
            raise RuntimeError('Official provider copy changed bytes')
        environment['ISONIM_HARBOR_SCENARIO_PROVIDER'] = str(target)
        provenance = location / 'provider-provenance.json'
        provenance.write_text(json.dumps({'source': str(original), 'copy': str(target), 'sha256': sha(original)}))
        provenance.chmod(0o600)
    result = subprocess.run(['just', recipe], cwd=root, env=environment)
    if location:
        result_file = location / 'result.json'
        result_file.write_text(json.dumps({'recipe': recipe, 'exit': result.returncode})); result_file.chmod(0o600)
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
