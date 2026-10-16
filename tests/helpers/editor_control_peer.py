#!/usr/bin/env python3
"""Controlled ACP peer for the real editor-control launch acceptance.

Agent decisions/text are substituted. On the actual first provider prompt,
execute production isonim CLI with actual launch environment, filesystem and
network. Record state/args without credential values. Official Harbor scenarios
remain EAC-M5's behavioral gate; this peer proves the direct ACP launch seam.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    reply = {}
    try:
        if method == "initialize":
            reply = {"protocolVersion": 1, "agentCapabilities": {"streaming": True, "text": True}}
        elif method == "session/new":
            reply = {"sessionId": "scope-" + hashlib.sha256(os.environ["ISONIM_EDITOR_TOKEN"].encode()).hexdigest()[:16]}
        elif method == "session/prompt":
            # Opt-in scenario barrier scripts when this agent proposes a command.
            # The mounted GUI can settle real human focus and intercept delivery
            # before releasing the real CLI, avoiding a stale-revision false pass.
            gate = Path(os.environ["CONTROL_PROBE_DIR"], "queue-gate-" + os.environ["ISONIM_EDITOR_INSTANCE"])
            if gate.exists():
                gate.with_name("waiting-" + os.environ["ISONIM_EDITOR_INSTANCE"]).write_text("waiting")
                deadline = time.monotonic() + 15
                while gate.exists():
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Controlled agent queue barrier was not released")
                    time.sleep(0.02)
            result = subprocess.run(["isonim", "editor", "state"], capture_output=True, text=True, timeout=5)
            operation_id = "scoped-" + request["params"]["sessionId"]
            proposed = subprocess.run(["isonim", "editor", "viewport", "wide", "--command-id", operation_id],
                                      capture_output=True, text=True, timeout=5)
            record = {"args": sys.argv[1:], "bootstrapPresent": "ISONIM_EDITOR_BROWSER_BOOTSTRAP" in os.environ,
                      "tokenPresent": bool(os.environ.get("ISONIM_EDITOR_TOKEN")),
                      "cliStatus": result.returncode, "state": json.loads(result.stdout),
                      "proposalStatus": proposed.returncode, "operationId": operation_id}
            Path(os.environ["CONTROL_PROBE_DIR"], "probe-" + os.environ["ISONIM_EDITOR_INSTANCE"] + ".json").write_text(json.dumps(record))
            print(json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": request["params"]["sessionId"], "update": {"sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": "CONTROL_SCOPE_OK"}}}}), flush=True)
            reply = {"stopReason": "end_turn"}
        elif method == "session/cancel":
            continue
        if "id" in request:
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": reply}), flush=True)
    except Exception as error:
        print(json.dumps({"jsonrpc": "2.0", "id": request.get("id"), "error": {"code": -32000, "message": str(error)}}), flush=True)
