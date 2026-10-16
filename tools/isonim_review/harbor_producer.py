"""Bridge a producer-owned Just build exposed through its Repro environment.

No compiler invocation, target-cache policy or toolchain flags are defined here.
The source snapshot is a receipt, not a replacement for Repro's build graph.
This module is embedded in the editor CLI, including its verification path.
"""
import hashlib
import json
import os
import re
from pathlib import Path, PureWindowsPath
import shutil
import stat
import subprocess
import sys
import tempfile

SCHEMA = 'isonim.harbor-own-producer.v1'
STAGE = Path('.repro/isonim-runtime/produced')
# These are producer/tool generated locations, not Git-ignore classifications.
# Tracked inputs are always retained, even below one of these paths.
GENERATED_ROOTS = tuple(Path(p) for p in (
    '.direnv', '.repro/build', '.repro/dev-env', '.repro/foreign-env',
    '.repro/isonim-runtime/.repro', str(STAGE), 'target', 'target-install',
    'build/m7-temp', 'build/nimcache-interface',
    'ah-lib/dist', 'packages/loop-driver/dist', 'packages/workflow-sdk/dist',
    'js-libs/rest-client/dist', 'js-libs/milestones-file/dist',
    'js-libs/sse-client/dist', 'js-libs/sdk/dist'))
# is_relative_to constructs every ancestor in supported Python versions. These
# policy roots are lexical and static; compare normalized components once per
# candidate while preserving Windows' case-insensitive path membership.
GENERATED_ROOT_PARTS = tuple(path.parts for path in GENERATED_ROOTS)
GENERATED_WINDOWS_ROOT_PARTS = tuple(
    tuple(part.lower() for part in PureWindowsPath(path.as_posix()).parts)
    for path in GENERATED_ROOTS)


def generated_location(path):
    if isinstance(path, PureWindowsPath):
        parts = tuple(part.lower() for part in path.parts)
        roots = GENERATED_WINDOWS_ROOT_PARTS
    else:
        parts = path.parts
        roots = GENERATED_ROOT_PARTS
    return any(parts[:len(root)] == root for root in roots)


GENERATED_RUNTIME_FILES = frozenset(
    '.repro/isonim-runtime/' + p for p in (
        'repro.nim', 'publish.py', 'harbor-executable', 'producer-interface.json',
        'producer-plan.json'))
GENERATED_CACHE_FILES = frozenset(('.cspellcache', '.lycheecache', '.yarn'))


def generated_input(repo, name):
    path = Path(name)
    if generated_location(path):
        return True
    if name in GENERATED_RUNTIME_FILES or name in GENERATED_CACHE_FILES:
        return True
    if name in ('build/bin/ah', 'build/bin/ah.exe') or (
            path.parent == Path('build/bin') and path.name.startswith('.ah-')):
        return True
    for index, part in enumerate(path.parts):
        parent = repo / Path(*path.parts[:index])
        if part == 'node_modules' and (parent / 'package.json').is_file():
            return True
        if part == '__pycache__' and index == len(path.parts) - 2:
            module = path.name.split('.cpython-', 1)[0]
            if path.name.endswith('.pyc') and (parent / (module + '.py')).is_file():
                return True
    # Cargo's crate-local target directory is generated only at a crate root.
    for index, part in enumerate(path.parts):
        if part == 'target' and (repo / Path(*path.parts[:index]) / 'Cargo.toml').is_file():
            return True
    return False


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def metadata(path):
    info = path.lstat()
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
            info.st_ctime_ns, info.st_mode]


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], timeout=30)


def snapshot(root, previous=None):
    """Bind all tracked and nonignored inputs, recursively including gitlinks.

    Only identified producer/tool outputs are excluded from untracked inventory.
    Ignored authored additions outside identified generated locations are included. A trusted,
    content-addressed receipt may avoid rehashing identical file identities;
    ctime and mode accompany inode/device/mtime/size to detect restored-mtime edits.
    """
    files, revisions = {}, {}
    previous_files = (previous or {}).get('files', {})

    def visit(repo, prefix=''):
        revisions[prefix] = git(repo, 'rev-parse', 'HEAD').decode().strip()
        records = git(repo, 'ls-files', '--stage', '-z').split(b'\0')
        names, links = set(), set()
        for record in records:
            if not record:
                continue
            attributes, name = record.split(b'\t', 1)
            name = os.fsdecode(name)
            names.add(name)
            if attributes.split()[0] == b'160000':
                links.add(name)
        tracked_names = set(names)
        names.update(os.fsdecode(n) for n in git(repo, 'ls-files', '--others', '--exclude-standard', '-z').split(b'\0') if n)
        # Git ignores do not establish that an input is generated. Inventory
        # ignored authored assets anywhere, including compiler includes outside
        # src/crates. Only identified producer/tool outputs are excluded here.
        ignored = git(repo, 'ls-files', '--others', '--ignored', '--exclude-standard', '-z')
        names.update(os.fsdecode(n) for n in ignored.split(b'\0')
                      if n and not generated_input(repo, os.fsdecode(n)))
        for name in sorted(names):
            key = prefix + name
            if Path(key).is_relative_to(STAGE) and name not in tracked_names:
                continue
            path = repo / name
            if name in links:
                if not path.is_dir() or not (path / '.git').exists():
                    raise RuntimeError('Initialize selected Harbor submodule: ' + key)
                visit(path, key + '/')
                continue
            if not path.exists() and not path.is_symlink():
                files[key] = {'missing': True}
                continue
            current = metadata(path)
            old = previous_files.get(key, {})
            if old.get('metadata') == current:
                files[key] = old
                continue
            if path.is_symlink():
                target = path.resolve(strict=True)
                if target.is_dir():
                    # Internal directory aliases are covered by the same actual
                    # Git inventory, including new inputs. Bind the alias and
                    # resolved directory identity as well, without duplicating
                    # or accidentally traversing generated Cargo caches.
                    if not target.is_relative_to(root):
                        raise RuntimeError('Unsupported external directory source symlink: ' + key)
                    files[key] = {'metadata': current, 'link': os.readlink(path),
                        'directoryTarget': str(target.relative_to(root)),
                        'targetMetadata': metadata(target)}
                elif target.is_file():
                    files[key] = {'metadata': current, 'link': os.readlink(path),
                                  'targetMetadata': metadata(target), 'sha256': digest(target)}
                    if metadata(target) != files[key]['targetMetadata']:
                        raise RuntimeError('Harbor symlink target changed while being read: ' + key)
                else:
                    raise RuntimeError('Unsupported source symlink: ' + key)
            elif path.is_file():
                files[key] = {'metadata': current, 'sha256': digest(path)}
            else:
                raise RuntimeError('Unsupported Harbor source input: ' + key)
            if metadata(path) != current:
                raise RuntimeError('Harbor source changed while being read: ' + key)
    visit(root)
    # A symlink's own metadata does not change when its target is edited.
    for name, record in list(files.items()):
        if 'link' in record:
            target = (root / name).resolve(strict=True)
            current = metadata(target)
            if 'directoryTarget' in record:
                if not target.is_dir() or not target.is_relative_to(root):
                    raise RuntimeError('Changed directory source symlink: ' + name)
                record = dict(record, targetMetadata=current, directoryTarget=str(target.relative_to(root)))
                files[name] = record
            elif current != record['targetMetadata']:
                record = dict(record, targetMetadata=current, sha256=digest(target))
                if metadata(target) != current:
                    raise RuntimeError('Harbor symlink target changed while being read: ' + name)
                files[name] = record
    content = {'revisions': revisions, 'files': {name: {k: v for k, v in record.items()
        if k not in ('metadata', 'targetMetadata')} | ({'mode': record['metadata'][-1]} if 'metadata' in record else {}) |
        ({'targetMode': record['targetMetadata'][-1]} if 'targetMetadata' in record else {})
        for name, record in files.items()}}
    return {'revisions': revisions, 'files': files,
            'sha256': hashlib.sha256(json.dumps(content, sort_keys=True).encode()).hexdigest()}


def private_directory(path):
    if not path.exists():
        path.mkdir(mode=0o700)
    info = path.lstat()
    if path != path.resolve(strict=True):
        raise RuntimeError('Escaping private Harbor stage: ' + str(path))
    if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700 or (hasattr(os, 'getuid') and info.st_uid != os.getuid()):
        raise RuntimeError('Invalid private Harbor stage: ' + str(path))


def verify(root, binary):
    root, binary = root.resolve(strict=True), binary.absolute()
    stage = root / STAGE
    # Canonical spelling alone must not admit a symlinked staging directory.
    if binary != binary.resolve(strict=True) or not binary.is_relative_to(stage):
        raise RuntimeError('Escaping Harbor stage')
    relative = binary.relative_to(stage)
    if len(relative.parts) != 3 or relative.parts[-1] != ('ah.exe' if os.name == 'nt' else 'ah'):
        raise RuntimeError('Unexpected Harbor stage layout')
    for part in [relative.parts[0], relative.parts[1]]:
        if len(part) != 64 or any(c not in '0123456789abcdef' for c in part):
            raise RuntimeError('Invalid Harbor stage identity')
    for directory in [stage, binary.parent.parent, binary.parent]:
        private_directory(directory)
    receipt_path = binary.parent / 'receipt.json'
    info = receipt_path.lstat()
    if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1 or (hasattr(os, 'getuid') and info.st_uid != os.getuid()):
        raise RuntimeError('Invalid Harbor producer receipt')
    # Pin receipt bytes before using any cached metadata from them.
    if digest(receipt_path) != relative.parts[1]:
        raise RuntimeError('Changed Harbor producer receipt')
    receipt = json.loads(receipt_path.read_text())
    if receipt['schema'] != SCHEMA or receipt['repository'] != str(root) or receipt['source']['sha256'] != relative.parts[0] or receipt['producer'] != ['./dev-bin/just', 'build-rust-unit-test-binaries']:
        raise RuntimeError('Unexpected Harbor producer provenance')
    source = snapshot(root, receipt['source'])
    if source['sha256'] != receipt['source']['sha256']:
        raise RuntimeError('Selected Harbor source changed after build')
    current = metadata(binary)
    if not stat.S_ISREG(current[-1]) or stat.S_IMODE(current[-1]) != 0o700 or binary.stat().st_nlink != 1:
        raise RuntimeError('Invalid staged Harbor executable')
    if current != receipt['artifactMetadata'] and digest(binary) != receipt['artifactSha256']:
        raise RuntimeError('Changed staged Harbor executable')
    return binary


def select(root, publication):
    root = root.resolve(strict=True)
    has_git = (root/'.git').exists()
    before = snapshot(root) if has_git else {'sha256': digest(root/'repro.nim')}
    launcher=root/'dev-bin/just'
    command=['repro','exec','--','./dev-bin/just','--show','build-rust-unit-test-binaries']
    interface='export'
    if launcher.is_file():
        query=subprocess.run(command,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        sys.stderr.write(query.stderr)
        if query.returncode==0:
            interface='own'
        elif query.returncode==1 and re.search(r"(?m)^error: [Jj]ustfile does not contain recipe `build-rust-unit-test-binaries`$",query.stderr):
            # This exact command-interface diagnostic is absence before build.
            # Parse errors, activation errors and selected build failures refuse.
            interface='export'
        else:
            raise RuntimeError('Owning Harbor producer interface query failed')
    after=snapshot(root,before) if has_git else {'sha256':digest(root/'repro.nim')}
    if after['sha256']!=before['sha256']:
        raise RuntimeError('Selected Harbor source changed during producer query')
    data={'interface':interface,'sourceSha256':after['sha256'],'query':command if launcher.is_file() else [],
          'proof':'supported own command interface; exported workflow only when own entry is genuinely absent'}
    fd,temporary=tempfile.mkstemp(prefix='producer-interface-',dir=publication.parent)
    try:
        with os.fdopen(fd,'w') as output:json.dump(data,output,sort_keys=True)
        os.replace(temporary,publication)
    finally:
        if os.path.exists(temporary):os.unlink(temporary)


def build(root, publication, owned_transient=None):
    root = root.resolve(strict=True)
    before = snapshot(root)
    selection = publication.parent/'producer-interface.json'
    if selection.exists():
        interface = json.loads(selection.read_text())
        if interface['interface'] != 'own' or interface['sourceSha256'] != before['sha256']:
            raise RuntimeError('Selected Harbor source changed after producer query')
    producer = ['./dev-bin/just', 'build-rust-unit-test-binaries']
    # Repro owns activation; the upstream launcher owns all actual build flags.
    subprocess.run(['repro', 'exec', '--', *producer], cwd=root, check=True)
    query = subprocess.run(['repro', 'exec', '--', './dev-bin/just', '--evaluate', 'target_dir'],
                            cwd=root, check=True, stdout=subprocess.PIPE, text=True)
    reported = query.stdout.strip()
    if not reported or '\n' in reported:
        raise RuntimeError('Producer did not report exactly one target directory')
    target = Path(reported)
    if not target.is_absolute():
        target = root / target
    target = target.resolve(strict=True)
    output = target / 'debug' / ('ah.exe' if os.name == 'nt' else 'ah')
    if output.is_symlink() or output.resolve(strict=True).parent != (target / 'debug').resolve(strict=True) or not output.is_file() or not os.access(output, os.X_OK):
        raise RuntimeError('Producer reported an escaping or missing Harbor output')
    after = snapshot(root, before)
    if after['sha256'] != before['sha256']:
        raise RuntimeError('Selected Harbor source changed during build')
    output_hash = digest(output)
    stage = root / STAGE
    stage.parent.mkdir(parents=True, exist_ok=True)
    if stage.parent != stage.parent.resolve(strict=True):
        raise RuntimeError('Escaping Harbor stage parent')
    private_directory(stage)
    generation = stage / after['sha256']
    private_directory(generation)
    # Existing immutable copies are reused only after the real producer ran and
    # matched this source state and these produced bytes. Never an installed ah.
    for candidate in generation.glob('*/ah' + ('.exe' if os.name == 'nt' else '')):
        try:
            admitted = verify(root, candidate)
            receipt = json.loads((candidate.parent / 'receipt.json').read_text())
            if receipt['artifactSha256'] == output_hash:
                publish(publication, admitted)
                return
        except (OSError, ValueError, KeyError, RuntimeError):
            continue
    transient = owned_transient or Path(tempfile.mkdtemp(prefix='pending-', dir=stage))
    if transient != transient.resolve(strict=True) or transient.parent != stage or not transient.name.startswith('pending-'):
        raise RuntimeError('Invalid owned Harbor transient')
    private_directory(transient)
    try:
        binary = transient / output.name
        shutil.copyfile(output, binary)
        binary.chmod(0o700)
        if digest(binary) != output_hash or digest(output) != output_hash:
            raise RuntimeError('Producer output changed while staging')
        final_source = snapshot(root, after)
        if final_source['sha256'] != after['sha256']:
            raise RuntimeError('Selected Harbor source changed while staging')
        receipt = {'schema': SCHEMA, 'repository': str(root), 'producer': producer,
                    'source': final_source, 'producerArtifact': str(output),
                    'artifactSha256': output_hash, 'artifactMetadata': metadata(binary)}
        receipt_path = transient / 'receipt.json'
        receipt_path.write_text(json.dumps(receipt, sort_keys=True)); receipt_path.chmod(0o600)
        destination = generation / digest(receipt_path)
        transient.rename(destination)
        verify(root, destination / output.name)
        publish(publication, destination / output.name)
    finally:
        # Reclaim only the unfinished directory this invocation created. Immutable
        # generations may be in use by another instance and remain untouched.
        if transient.exists():
            shutil.rmtree(transient)


def publish(path, binary):
    fd, temporary = tempfile.mkstemp(prefix='harbor-executable-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            output.write(str(binary) + '\n')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == '__main__':
    try:
        operation, repository, argument = sys.argv[1:4]
        if operation == 'build':
            build(Path(repository), Path(argument), Path(sys.argv[4]) if len(sys.argv) == 5 else None)
        elif operation == 'select':
            select(Path(repository), Path(argument))
        elif operation == 'verify':
            verify(Path(repository), Path(argument))
        elif operation == 'stage':
            root = Path(repository).resolve(strict=True)
            stage = Path(argument).absolute()
            if stage != root / STAGE:
                raise RuntimeError('Unexpected private Harbor stage')
            private_directory(stage)
        else:
            raise RuntimeError('Unknown Harbor producer operation')
    except Exception as error:
        print('IsoNim Harbor producer: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
