#!/usr/bin/env python3
"""Inject IsoNim instructions into Claude ACP session/new metadata behind Harbor REST."""
import argparse
import json
import os
import signal
import subprocess
import sys
import threading


def inject_instructions(line, instructions):
    message = json.loads(line)
    if message.get("method") != "session/new":
        return line
    meta = message.setdefault("params", {}).setdefault("_meta", {})
    existing = meta.get("systemPrompt")
    if isinstance(existing, str):
        meta["systemPrompt"] = existing + "\n\n" + instructions
    elif existing is None or isinstance(existing, dict):
        prompt = dict(existing or {})
        prompt["append"] = (prompt.get("append", "") + "\n\n" + instructions).lstrip()
        meta["systemPrompt"] = prompt
    else:
        raise ValueError("unsupported existing systemPrompt metadata")
    return json.dumps(message, separators=(",", ":")) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--instructions", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("provider command required")
    with open(args.instructions, encoding="utf-8") as source:
        instructions = source.read()
    child = subprocess.Popen(command, stdin=subprocess.PIPE)

    def forward_signal(signum, _frame):
        if child.poll() is None:
            child.send_signal(signum)

    signal.signal(signal.SIGTERM, forward_signal)
    signal.signal(signal.SIGINT, forward_signal)
    errors = []

    def forward_input():
        try:
            pending = b""
            while True:
                chunk = os.read(sys.stdin.fileno(), 65536)
                if not chunk:
                    break
                pending += chunk
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    transformed = inject_instructions((line + b"\n").decode("utf-8"), instructions)
                    child.stdin.write(transformed.encode("utf-8"))
                    child.stdin.flush()
        except (BrokenPipeError, OSError):
            pass
        except Exception as error:
            errors.append(error)
            print(str(error), file=sys.stderr)
        finally:
            child.stdin.close()
            if child.poll() is None:
                child.terminate()

    threading.Thread(target=forward_input, daemon=True).start()
    result = child.wait()
    return 1 if errors else (128 - result if result < 0 else result)


if __name__ == "__main__":
    sys.exit(main())
