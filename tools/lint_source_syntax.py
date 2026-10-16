#!/usr/bin/env python3
"""Parse maintained Python, JavaScript and shell sources without executing them."""
import ast
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
root = parser.parse_args().root.resolve()
paths = subprocess.check_output(
    ["git", "ls-files", "-z", "--", "tools", "scripts", "tests"], cwd=root
).split(b"\0")
for raw in paths:
    if not raw:
        continue
    relative = raw.decode("utf-8", "surrogateescape")
    path = root / relative
    if path.suffix == ".py":
        ast.parse(path.read_bytes(), filename=relative)
    elif path.suffix in {".js", ".mjs", ".cjs"}:
        subprocess.run(["node", "--check", str(path)], cwd=root, check=True)
    elif path.suffix == ".sh":
        subprocess.run(["bash", "-n", str(path)], cwd=root, check=True)
