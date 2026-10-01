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

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("provider command required")
    info = os.stat(args.environment)
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        parser.error("private environment file must be owned by this user with mode 0600")
    with open(args.environment, encoding="utf-8") as source:
        values = json.load(source)
    if set(values) != ALLOWED or not all(isinstance(value, str) for value in values.values()):
        parser.error("invalid scoped environment")
    env = dict(os.environ)
    env.pop("ISONIM_EDITOR_BROWSER_BOOTSTRAP", None)
    env.update(values)
    env["ISONIM_EDITOR_ENDPOINT"] = scoped_endpoint(values["ISONIM_EDITOR_ENDPOINT"])
    env["PATH"] = values["ISONIM_EDITOR_CLI_DIR"] + os.pathsep + env.get("PATH", "")
    os.execvpe(command[0], command, env)

if __name__ == "__main__":
    main()
