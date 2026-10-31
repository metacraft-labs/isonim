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


def inject_terminal_scope(line, environment):
    """Keep terminal tools in the same scoped authority as their provider.

    Only the original private filename crosses the ACP tool boundary, never its
    contents. The existing descriptor-pinned wrapper supplies values and resolves
    the strict supported sandbox route at the actual terminal execution site.
    """
    if not environment:
        return line
    message = json.loads(line)
    if message.get("method") != "terminal/create":
        return line
    params = message.get("params", {})
    command = params.get("command")
    args = params.get("args", [])
    if not isinstance(command, str) or not command or not isinstance(args, list) or not all(isinstance(arg, str) for arg in args):
        raise ValueError("invalid scoped terminal command")
    wrapper = os.path.join(os.path.dirname(os.path.abspath(__file__)), "editor_agent_env.py")
    params["command"] = sys.executable
    params["args"] = [wrapper, "--environment", environment, "--", command] + args
    return json.dumps(message, separators=(",", ":")) + "\n"


class ModelSelectionBridge:
    """Adapt only an actually advertised model config; never hide rejection.

    Recent Claude ACP exposes session/set_config_option instead of the legacy
    model method used by Harbor. Session/new is the capability boundary; all
    unrelated metadata, provider requests and response bytes stay unchanged.
    """
    def __init__(self):
        self.sessions = set()
        self.new_requests = set()
        self.model_requests = set()
        self.lock = threading.Condition()
        self.failed = False

    def request(self, line):
        message = json.loads(line)
        if not isinstance(message, dict): return line
        with self.lock:
            if message.get("method") == "session/prompt" and self.model_requests:
                if not self.lock.wait_for(lambda: not self.model_requests or self.failed, timeout=30):
                    self.failed = True
                    raise RuntimeError("Explicit model selection acknowledgement timed out; input blocked")
            if self.failed:
                raise RuntimeError("Explicit model selection failed; provider input blocked")
            if message.get("method") == "session/new":
                self.new_requests.add(message.get("id"))
            elif message.get("method") == "session/set_model":
                self.model_requests.add(message.get("id"))
                params = message.get("params", {})
                if params.get("sessionId") in self.sessions:
                    message["method"] = "session/set_config_option"
                    message["params"] = dict(params)
                    message["params"]["configId"] = "model"
                    message["params"]["value"] = message["params"].pop("modelId")
                    return json.dumps(message, separators=(",", ":")) + "\n"
        return line

    def response(self, line):
        message = json.loads(line)
        if not isinstance(message, dict): return False
        with self.lock:
            request_id = message.get("id")
            if "method" in message:
                return False
            if request_id in self.new_requests:
                self.new_requests.remove(request_id)
                result = message.get("result", {})
                options = result.get("configOptions", []) if isinstance(result, dict) else []
                if isinstance(options, list) and any(isinstance(option, dict) and
                    option.get("id") == "model" and option.get("type") == "select" and
                    isinstance(option.get("options"), list) and option["options"] for option in options):
                    session = result.get("sessionId")
                    if isinstance(session, str) and session:
                        self.sessions.add(session)
            if request_id in self.model_requests:
                self.model_requests.remove(request_id)
                self.failed = "error" in message or "result" not in message
                self.lock.notify_all()
                return self.failed
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--instructions")
    parser.add_argument("--environment", default="")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("provider command required")
    instructions = ""
    if args.instructions:
        with open(args.instructions, encoding="utf-8") as source:
            instructions = source.read()
        if not instructions.strip():
            parser.error("role instructions are empty")
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def forward_signal(signum, _frame):
        if child.poll() is None:
            child.send_signal(signum)

    signal.signal(signal.SIGTERM, forward_signal)
    signal.signal(signal.SIGINT, forward_signal)
    errors = []
    models = ModelSelectionBridge()

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
                    transformed = (inject_instructions((line + b"\n").decode("utf-8"), instructions)
                                    if instructions else (line + b"\n").decode("utf-8"))
                    transformed = models.request(transformed)
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
    try:
        for line in child.stdout:
            model_rejected = models.response(line.decode("utf-8"))
            transformed = inject_terminal_scope(line.decode("utf-8"), args.environment)
            sys.stdout.buffer.write(transformed.encode("utf-8"))
            sys.stdout.buffer.flush()
            if model_rejected:
                raise RuntimeError("Explicit provider model selection rejected; configure a supported model/provider")
    except (BrokenPipeError, OSError):
        pass
    except Exception as error:
        errors.append(error)
        print(str(error), file=sys.stderr)
    finally:
        if errors and child.poll() is None: child.terminate()
    result = child.wait()
    child.stdout.close()
    return 1 if errors else (128 - result if result < 0 else result)


if __name__ == "__main__":
    sys.exit(main())
