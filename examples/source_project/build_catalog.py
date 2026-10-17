#!/usr/bin/env python3
"""Project-owned producer: compile actual Nim/SSR stories, then emit the catalog.

Build diagnostics are emitted on failure. Successful stdout is catalog JSON.
The source bridge invokes this configured producer inside the editor's dev shell.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent
framework = Path(os.environ.get("ISONIM_SOURCE_FRAMEWORK", root.parent.parent)).resolve()
(root / ".isonim").mkdir(exist_ok=True)
output = root / ".isonim/catalog-producer"
# Separate projects and repeated invocations must never share Nim object files.
# The cache is owned by this invocation and removed on success or failure.
with tempfile.TemporaryDirectory(prefix="catalog-nimcache-", dir=root / ".isonim") as cache:
    compilation = subprocess.run(["nim", "c", "--hints:off", "--warnings:off",
        "--nimcache:" + cache, "--path:" + str(framework / "src"),
        "--out:" + str(output), str(root / "stories.nim")],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
if compilation.returncode:
    sys.stdout.write(compilation.stdout)
    sys.exit(compilation.returncode)
rendered = subprocess.run([str(output)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
sys.stdout.write(rendered.stdout)
sys.exit(rendered.returncode)
