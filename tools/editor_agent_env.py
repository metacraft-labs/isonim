#!/usr/bin/env python3
"""Launch a provider with its private, instance-scoped editor control environment.

Harbor's supported Linux slirp sandbox has its own loopback and exposes the host
at its observed tap0 gateway. Translate only a loopback callback in that exact
route configuration. Ordinary host, macOS and explicit non-loopback endpoints
remain literal; missing/malformed routes never cause a guessed gateway.
"""
import argparse
import json
import os
import stat
import secrets
import sys
from urllib.parse import urlsplit, urlunsplit

ALLOWED = {
    "ISONIM_EDITOR_ENDPOINT", "ISONIM_EDITOR_WORKSPACE", "ISONIM_EDITOR_INSTANCE",
    "ISONIM_EDITOR_EPOCH", "ISONIM_EDITOR_TOKEN", "ISONIM_EDITOR_CLI_DIR",
}

def endpoint_for_routes(endpoint, route_text, platform):
    """Pure route recognition; OS observation happens only at launch."""
    if platform != "linux":
        return endpoint
    try:
        parsed = urlsplit(endpoint)
        if (parsed.scheme not in ("http", "https") or
            parsed.hostname not in ("127.0.0.1", "localhost", "::1") or
            parsed.port is None or parsed.username is not None):
            return endpoint
        lines = route_text.splitlines()
        if not lines or lines[0].split() != ["Iface", "Destination", "Gateway", "Flags", "RefCnt", "Use", "Metric", "Mask", "MTU", "Window", "IRTT"]:
            return endpoint
        rows = []
        for line in lines[1:]:
            fields = line.split()
            if len(fields) != 11:
                return endpoint
            rows.append((fields[0], int(fields[1], 16), int(fields[2], 16),
                          int(fields[3], 16), int(fields[7], 16)))
        defaults = [row for row in rows if row[1] == 0]
        if (len(defaults) != 1 or defaults[0] != ("tap0", 0, 0x0202000A, 3, 0) or
            ("tap0", 0x0002000A, 0, 1, 0x00FFFFFF) not in rows):
            return endpoint
        return urlunsplit(parsed._replace(netloc="10.0.2.2:" + str(parsed.port)))
    except (ValueError, TypeError):
        return endpoint

def scoped_endpoint(endpoint):
    try:
        with open("/proc/net/route", encoding="ascii") as routes:
            return endpoint_for_routes(endpoint, routes.read(), sys.platform)
    except (OSError, UnicodeError):
        return endpoint

def prepare_environment(filename, values):
    """Create only beneath our private application directory, without symlinks.

    Directory descriptors keep ancestor replacement from redirecting a write.
    A mode-0600 exclusive temporary file is atomically published in the pinned
    mode-0700 session directory. Existing unsafe directories fail closed.
    """
    if set(values) != ALLOWED or not all(isinstance(v, str) for v in values.values()):
        raise ValueError("invalid scoped environment")
    home = os.path.abspath(os.path.expanduser("~"))
    suffix = (["Library", "Application Support"] if sys.platform == "darwin"
              else [".local", "share"])
    base = os.path.join(home, *suffix, "isonim", "editor-control")
    filename = os.path.abspath(filename)
    relative = os.path.relpath(filename, base).split(os.sep)
    if (len(relative) != 2 or relative[1] != "environment.json" or
            not relative[0].startswith("isonim-control-") or
            not all(c.isascii() and (c.isalnum() or c == "-") for c in relative[0])):
        raise ValueError("invalid control environment path")
    descriptor = os.open(os.sep, os.O_RDONLY | os.O_DIRECTORY)
    temporary = None
    try:
        parts = base.strip(os.sep).split(os.sep) + relative[:1]
        private_start = len(parts) - 3
        home_index = len(home.strip(os.sep).split(os.sep)) - 1
        for index, part in enumerate(parts):
            try:
                os.mkdir(part, 0o700, dir_fd=descriptor)
            except FileExistsError:
                pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=descriptor)
            info = os.fstat(child)
            if ((index >= home_index and info.st_uid != os.getuid()) or
                    (index >= private_start and stat.S_IMODE(info.st_mode) != 0o700)):
                os.close(child)
                raise ValueError("private control directory must be owned with mode 0700")
            os.close(descriptor)
            descriptor = child
        temporary = ".environment-" + secrets.token_hex(16)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                      0o600, dir_fd=descriptor)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(values, stream)
        os.replace(temporary, "environment.json", src_dir_fd=descriptor, dst_dir_fd=descriptor)
        temporary = None
    finally:
        if temporary is not None:
            os.unlink(temporary, dir_fd=descriptor)
        os.close(descriptor)

def read_environment(filename):
    directory = os.path.dirname(os.path.abspath(filename))
    descriptor = os.open(os.sep, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in directory.strip(os.sep).split(os.sep):
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        info = os.fstat(descriptor)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError("private environment directory must be owned with mode 0700")
        fd = os.open(os.path.basename(filename), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptor)
        with os.fdopen(fd, "r", encoding="utf-8") as source:
            info = os.fstat(source.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                    stat.S_IMODE(info.st_mode) != 0o600):
                raise ValueError("private environment file must be owned by this user with mode 0600")
            values = json.load(source)
        if set(values) != ALLOWED or not all(isinstance(value, str) for value in values.values()):
            raise ValueError("invalid scoped environment")
        return values
    finally:
        os.close(descriptor)

def cleanup_environment(filename):
    """Remove the owned handoff only; never recurse through links or other data."""
    directory = os.path.dirname(os.path.abspath(filename))
    descriptor = os.open(os.sep, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in directory.strip(os.sep).split(os.sep):
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        info = info_dir = os.fstat(descriptor)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError("unsafe control directory")
        try:
            info = os.stat("environment.json", dir_fd=descriptor, follow_symlinks=False)
            if stat.S_ISDIR(info.st_mode):
                os.rmdir("environment.json", dir_fd=descriptor)
            else:
                os.unlink("environment.json", dir_fd=descriptor)
        except FileNotFoundError:
            pass
        # Hold the parent descriptor too so replacement cannot redirect removal.
        parent = os.open("..", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
        try:
            current = os.stat(os.path.basename(directory), dir_fd=parent, follow_symlinks=False)
            if (current.st_dev,current.st_ino) != (info_dir.st_dev,info_dir.st_ino):
                raise ValueError("control directory changed during cleanup")
            os.rmdir(os.path.basename(directory), dir_fd=parent)
        finally:
            os.close(parent)
    finally:
        os.close(descriptor)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--environment")
    mode.add_argument("--prepare")
    mode.add_argument("--cleanup")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.cleanup:
        try:
            cleanup_environment(args.cleanup)
        except FileNotFoundError:
            pass
        except (OSError, ValueError):
            parser.error("private control environment cleanup failed")
        return
    if args.prepare:
        try:
            prepare_environment(args.prepare, json.load(sys.stdin))
        except (OSError, ValueError):
            parser.error("private control environment preparation failed")
        return
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("provider command required")
    try:
        values = read_environment(args.environment)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    env = dict(os.environ)
    env.pop("ISONIM_EDITOR_BROWSER_BOOTSTRAP", None)
    env.update(values)
    env["ISONIM_EDITOR_ENDPOINT"] = scoped_endpoint(values["ISONIM_EDITOR_ENDPOINT"])
    env["PATH"] = values["ISONIM_EDITOR_CLI_DIR"] + os.pathsep + env.get("PATH", "")
    os.execvpe(command[0], command, env)

if __name__ == "__main__":
    main()
