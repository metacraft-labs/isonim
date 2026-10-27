"""Restore the lossy platform read in the actual compiled browser seam suite.

Only the tested getItem expression changes. Chromium, Storage and the HTTP
fixture remain real; the normal suite must pass before its mutant is accepted
as a falsifier. No production checkout is mutated.
"""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
runner = ["node", "tests/test_nondet_browser.mjs"]
control = subprocess.run(runner, cwd=root, text=True, capture_output=True)
assert control.returncode == 0, control.stdout + control.stderr
source = (root / "tests/test_nondet_seams.js").read_text()
needle = "return localStorage.getItem(a);"
assert source.count(needle) == 2, "expected both compiler-inlined rawRead sites"
with tempfile.TemporaryDirectory(prefix="isonim-storage-mutant-") as tmp:
    bundle = Path(tmp) / "lossy.js"
    bundle.write_text(source.replace(needle, "return localStorage.getItem(a)||'';"))
    mutant = subprocess.run(runner, cwd=root, text=True, capture_output=True,
                            env={**os.environ, "ISONIM_NONDET_BUNDLE": str(bundle)})
    output = mutant.stdout + mutant.stderr
    assert mutant.returncode != 0, output
    assert "storage absence must survive the browser read" in output, output
print("lossy storage observation mutant: REJECTED by absence oracle")
