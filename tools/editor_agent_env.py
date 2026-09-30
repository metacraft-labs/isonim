#!/usr/bin/env python3
"""Launch a provider with its private, instance-scoped editor control environment."""
import argparse
import json
import os
import stat

ALLOWED = {
    "ISONIM_EDITOR_ENDPOINT", "ISONIM_EDITOR_WORKSPACE", "ISONIM_EDITOR_INSTANCE",
    "ISONIM_EDITOR_EPOCH", "ISONIM_EDITOR_TOKEN", "ISONIM_EDITOR_CLI_DIR",
}

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
    env["PATH"] = values["ISONIM_EDITOR_CLI_DIR"] + os.pathsep + env.get("PATH", "")
    os.execvpe(command[0], command, env)

if __name__ == "__main__":
    main()
