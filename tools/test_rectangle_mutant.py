#!/usr/bin/env python3
"""Real Chromium must reject a compiled dropped-corner observation.

Only the implementation snapshot is mutated; platform geometry stays real.
An isolated module tree prevents mutation of the candidate working copy.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="rectangle-mutant-") as temporary:
    tmp = Path(temporary)
    core = tmp / "isonim/core"
    core.mkdir(parents=True)
    for path in (root / "src/isonim/core").glob("*.nim"):
        shutil.copyfile(path, core / path.name)
    testing = tmp / "isonim/testing"
    testing.mkdir()
    shutil.copyfile(root / "src/isonim/testing/test_utils.nim", testing / "test_utils.nim")
    source = core / "nondet.nim"
    text = source.read_text()
    before = ",top:r.top,right:r.right,bottom:r.bottom,left:r.left"
    assert text.count(before) == 1
    source.write_text(text.replace(before, ""))
    test = tmp / "test_nondet_seams.nim"
    shutil.copyfile(root / "tests/test_nondet_seams.nim", test)
    bundle = tmp / "rectangle-mutant.js"
    subprocess.run(["nim", "js", "--path:" + str(root / "src"),
                    "--path:" + str(root.parent / "nim-everywhere/src"),
                    "--path:" + str(tmp), "--out:" + str(bundle), str(test)],
                   cwd=root, check=True)
    env = dict(os.environ, ISONIM_NONDET_BUNDLE=str(bundle))
    env.setdefault("PLAYWRIGHT_CHROMIUM_EXECUTABLE", shutil.which("chromium") or "")
    result = subprocess.run(["node", "tests/test_nondet_browser.mjs"], cwd=root,
                            env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    print(result.stdout)
    assert result.returncode != 0
    assert "eight-field rectangle observation missing top" in result.stdout
    assert "four-field-browser-rectangle: PASS" in result.stdout
    print("dropped-corner rectangle mutant: REJECTED")
