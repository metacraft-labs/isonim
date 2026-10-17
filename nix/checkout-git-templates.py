"""Bind inert CI checkout templates without changing owning hook constructors.

Only a Linux or macOS CI job's explicitly observed, immutable Nix Git package supplies
this additional sample authority. It never supplies active hook bodies.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys


def read_regular(path, *, immutable=False, private=False, limit=128 * 1024 * 1024):
    for ancestor in [path.parent, *path.parent.parents]:
        if ancestor.is_symlink():
            raise RuntimeError('Symlink in checkout-template authority ancestry')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise RuntimeError('Nonregular checkout-template authority')
        mode = stat.S_IMODE(info.st_mode)
        if immutable and (info.st_uid != 0 or mode & 0o222):
            raise RuntimeError('Mutable checkout Git package authority')
        if private and (info.st_uid != os.geteuid() or mode != 0o600):
            raise RuntimeError('Foreign checkout-template receipt ownership or mode')
        if info.st_size > limit:
            raise RuntimeError('Checkout-template authority exceeds its read bound')
        chunks = []
        retained = 0
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            retained += len(chunk)
            if retained > limit:
                raise RuntimeError('Checkout-template authority grew beyond its read bound')
            chunks.append(chunk)
        after = os.fstat(fd)
        if (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns
        ):
            raise RuntimeError('Checkout-template authority changed while reading')
        body = b''.join(chunks)
        return body, {'device': info.st_dev, 'inode': info.st_ino, 'uid': info.st_uid,
                      'mode': mode, 'SHA256': hashlib.sha256(body).hexdigest()}
    finally:
        os.close(fd)


def job_binding(root, common):
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_OS') not in ('Linux', 'macOS'):
        raise RuntimeError('Checkout-template receipt is limited to Linux or macOS GitHub jobs')
    if os.environ.get('GITHUB_WORKSPACE') != str(root):
        raise RuntimeError('Checkout-template receipt has another owning workspace')
    names = ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_JOB', 'GITHUB_SHA')
    values = {name: os.environ.get(name, '') for name in names}
    if any(not re.fullmatch(r'[A-Za-z0-9_-]+', value) for value in values.values()):
        raise RuntimeError('Missing or invalid checkout job identity')
    return {'root': str(root), 'commonDirectory': str(common), 'runnerOS': os.environ['RUNNER_OS'], 'job': values}


def package_inventory(git_path):
    # No caller-supplied template directory and no GIT_TEMPLATE_DIR/config lookup.
    if not re.fullmatch(r'/nix/store/[a-z0-9]{32}-git-[^/]+/bin/git', str(git_path)):
        raise RuntimeError('Checkout Git is not an explicit immutable Nix Git role')
    package_root = git_path.parent.parent
    for directory in (package_root, git_path.parent):
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o222:
            raise RuntimeError('Mutable checkout Git package directory')
    _, git_identity = read_regular(git_path, immutable=True)
    templates = git_path.parent.parent / 'share/git-core/templates/hooks'
    if templates.is_symlink() or not templates.is_dir():
        raise RuntimeError('Missing regular checkout Git template directory')
    samples = {}
    for path in sorted(templates.iterdir()):
        if not re.fullmatch(r'[a-z0-9-]+\.sample', path.name):
            raise RuntimeError('Unexpected checkout Git template name')
        _, identity = read_regular(path, immutable=True, limit=1024 * 1024)
        samples[path.name] = identity
        if len(samples) > 64:
            raise RuntimeError('Checkout Git sample inventory exceeds its bound')
    if not samples:
        raise RuntimeError('Empty checkout Git template authority')
    return {'gitPath': str(git_path), 'gitIdentity': git_identity,
            'templateDirectory': str(templates), 'templates': samples}


def receipt_path(common, binding):
    job = binding['job']
    suffix = '-'.join(job[key] for key in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_JOB'))
    return common / ('isonim-checkout-git-templates-' + suffix + '.json')


def load_checkout_templates(root, common):
    selected = os.environ.get('ISONIM_CHECKOUT_GIT_RECEIPT')
    if not selected:
        return None
    binding = job_binding(root, common)
    path = receipt_path(common, binding)
    if selected != str(path):
        raise RuntimeError('Checkout-template receipt escaped its owning common directory/job')
    body, identity = read_regular(path, private=True, limit=2 * 1024 * 1024)
    receipt = json.loads(body)
    if set(receipt) != {'binding', 'package', 'initializedSampleMode'}:
        raise RuntimeError('Unknown checkout-template receipt schema')
    if receipt['binding'] != binding or type(receipt['initializedSampleMode']) is not int or receipt['initializedSampleMode'] != 0o755:
        raise RuntimeError('Checkout-template receipt binding or sample mode differs')
    package = package_inventory(Path(receipt['package']['gitPath']))
    if json.dumps(receipt['package'], sort_keys=True) != json.dumps(package, sort_keys=True):
        raise RuntimeError('Checkout Git package differs from the captured authority')
    return {'receiptPath': str(path), 'receiptIdentity': identity, 'binding': binding,
            'package': package, 'samples': {name: [0o755, row['SHA256']]
                                          for name, row in package['templates'].items()}}


def capture():
    if 'ISONIM_CHECKOUT_GIT_RECEIPT' in os.environ:
        raise RuntimeError('Inherited checkout-template receipt authority')
    root = Path.cwd()
    if root.is_symlink() or root != root.resolve(strict=True):
        raise RuntimeError('Noncanonical checkout source directory')
    selected = shutil.which('git')
    if not selected:
        raise RuntimeError('Checkout Git is absent')
    git_path = Path(selected).resolve(strict=True)
    package = package_inventory(git_path)
    def git(*args):
        return subprocess.check_output([str(git_path), '-C', str(root), *args]).decode().strip()
    if git('rev-parse', '--show-toplevel') != str(root):
        raise RuntimeError('Checkout Git source root differs')
    common = Path(git('rev-parse', '--path-format=absolute', '--git-common-dir'))
    if common != root / '.git' or common.is_symlink() or not common.is_dir():
        raise RuntimeError('Checkout capture requires its own regular common directory')
    binding = job_binding(root, common)
    if git('rev-parse', 'HEAD') != binding['job']['GITHUB_SHA']:
        raise RuntimeError('Checkout HEAD differs from the actual GitHub event revision')
    receipt = {'binding': binding, 'package': package, 'initializedSampleMode': 0o755}
    path = receipt_path(common, binding)
    payload = (json.dumps(receipt, sort_keys=True, indent=2) + '\n').encode()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    stream = None
    primary = None
    secondary = []
    try:
        stream = os.fdopen(fd, 'wb')
        fd = None
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
    except BaseException as exc:
        primary = exc
    finally:
        if stream is not None:
            owned_stream, stream = stream, None
            try:
                owned_stream.close()
            except BaseException as exc:
                secondary.append(repr(exc))
        if fd is not None:
            owned_fd, fd = fd, None
            try:
                os.close(owned_fd)
            except BaseException as exc:
                secondary.append(repr(exc))
    if primary is not None:
        if secondary:
            primary.add_note('Receipt close errors: ' + repr(secondary))
        raise primary
    if secondary:
        raise RuntimeError('Receipt close errors: ' + repr(secondary))
    # A retained receipt is not an activation: only the next shell's guard may
    # accept exact inert samples. No hook, Git config or index is changed here.
    env_path = Path(os.environ['GITHUB_ENV'])
    env_fd = os.open(env_path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(env_fd, 'a') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise RuntimeError('GitHub environment output is not an owned regular file')
        stream.write('ISONIM_CHECKOUT_GIT_RECEIPT=' + str(path) + '\n')
    print(json.dumps({'receiptPath': str(path), 'SHA256': hashlib.sha256(payload).hexdigest(),
                      'git': package['gitPath'], 'scope': 'inert templates only'}, sort_keys=True))


if __name__ == '__main__':
    if sys.argv[1:] != ['capture']:
        raise SystemExit('usage: checkout-git-templates.py capture')
    capture()
