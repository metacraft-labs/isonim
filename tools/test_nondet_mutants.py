#!/usr/bin/env python3
"""Positive control: the seam suite must reject synchronous real timers.

Compile an isolated copy so concurrent test runs never see a mutated worktree.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="nondet-mutant-") as tmp:
    tmp = Path(tmp)
    core = tmp / "isonim/core"
    core.mkdir(parents=True)
    for name in ["clock.nim", "nondet.nim"]:
        shutil.copyfile(root / "src/isonim/core" / name, core / name)
    testing = tmp / "isonim/testing"
    testing.mkdir()
    shutil.copyfile(root / "src/isonim/testing/test_utils.nim", testing / "test_utils.nim")
    path = core / "clock.nim"
    text = path.read_text()
    start = text.index("method schedule*(clock: RealClock;")
    end = text.index("method cancel*(clock: RealClock;", start)
    text = text[:start] + '''method schedule*(clock: RealClock; callback: proc(); delayMs: float64): int =
  callback()
  0

''' + text[end:]
    path.write_text(text)
    test = tmp / "test_nondet_seams.nim"
    shutil.copyfile(root / "tests/test_nondet_seams.nim", test)
    completed = subprocess.run([
        "nim", "c", "-r", "--path:" + str(tmp),
        "--path:" + str(root.parent / "nim-everywhere/src"),
        "--nimcache:" + str(root / ".nimcache/nondet-mutant"), str(test)
    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=root)
    assert completed.returncode != 0, completed.stdout
    assert "[FAILED] real clock schedules asynchronously in deadline order" in completed.stdout, completed.stdout
    print("synchronous-real-clock mutant: REJECTED")
