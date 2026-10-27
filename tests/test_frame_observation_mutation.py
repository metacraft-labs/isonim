"""Mutate the real compiled frame delivery, preserving browser/HTTP boundaries.

No browser API is faked: the suite delegates requestAnimationFrame and now to
Chromium. The controls prove ordinary facade execution survives the mutation;
the private timestamp oracle alone must reject dropped/substituted arguments.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
runner = ["node", "tests/test_nondet_browser.mjs"]
control = subprocess.run(runner, cwd=root, text=True, capture_output=True)
assert control.returncode == 0, control.stdout + control.stderr
source = (root / "tests/test_nondet_seams.js").read_text()
pattern = r"(some__\w+\()(ts_p0)(\))"
assert len(re.findall(pattern, source)) == 1, "expected one actual frame timestamp observation"
for name, replacement in [("dropped", "0"), ("fresh-clock", "performance.now()")]:
    with tempfile.TemporaryDirectory(prefix="isonim-frame-mutant-") as tmp:
        bundle = Path(tmp) / (name + ".js")
        bundle.write_text(re.sub(pattern, lambda match: match[1] + replacement + match[3], source))
        mutant = subprocess.run(runner, cwd=root, text=True, capture_output=True,
                                env={**os.environ, "ISONIM_NONDET_BUNDLE": str(bundle)})
        output = mutant.stdout + mutant.stderr
        assert mutant.returncode != 0, output
        assert "ordinary-browser-frame-facade: PASS" in output, output
        assert ("browser frame must preserve exact delivered timestamp bits" in output
                or (name == "fresh-clock" and "browser frame must not sample a second clock" in output)), output
        print(name + " frame timestamp mutant: REJECTED by fidelity oracle")
