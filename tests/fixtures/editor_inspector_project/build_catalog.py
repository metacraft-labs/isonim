#!/usr/bin/env python3
"""Project-owned producer: compile actual Nim/SSR stories, then emit the catalog.

Build diagnostics are emitted on failure. Successful stdout is catalog JSON.
The source bridge invokes this configured producer inside the editor's dev shell.
"""
from pathlib import Path
import os
import subprocess
import sys
import time
import json

root = Path(__file__).resolve().parent
framework = Path(os.environ.get("ISONIM_SOURCE_FRAMEWORK", root.parent.parent)).resolve()
(root / ".isonim").mkdir(exist_ok=True)
output = root / ".isonim/catalog-producer"
# Source jobs are serialized by the real project adapter. Each disposable
# project owns its own cache; Nim must still recompile changed source and reject
# the actual compile-time constraint. Separate projects share no object files.
cache = root / ".isonim/native-cache"
started = time.monotonic()
compilation = subprocess.run(["nim", "c", "--hints:off", "--warnings:off",
    "--nimcache:" + str(cache), "--path:" + str(framework / "src"),
    "--out:" + str(output), str(root / "stories.nim")],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
with (root / ".isonim/compiler-timings.jsonl").open("a") as timings:
    timings.write(json.dumps({"seconds": time.monotonic() - started,
        "returncode": compilation.returncode}) + "\n")
if compilation.returncode:
    sys.stdout.write(compilation.stdout)
    sys.exit(compilation.returncode)
rendered = subprocess.run([str(output)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
sys.stdout.write(rendered.stdout)
sys.exit(rendered.returncode)
