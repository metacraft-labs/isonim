#!/usr/bin/env python3
"""Compile actual history seams in both modes and reject URL-loss mutations.

Only isolated source copies are mutated; real Chromium History resolves URLs.
The ordinary facade/call controls must pass before the reflected-URL rejection.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
env = dict(os.environ)
env.setdefault("PLAYWRIGHT_CHROMIUM_EXECUTABLE", shutil.which("chromium") or "")
fixture = root / "tests/fixtures/nondet_history.nim"


def run(fixture, bundle, extra=(), paths=(), mutant=False):
    subprocess.run(["nim", "js", *extra, "--path:" + str(root / "src"),
                    "--path:" + str(root.parent / "nim-everywhere/src"), *paths,
                    "--out:" + str(bundle), str(fixture)], cwd=root, check=True)
    retained = None
    if paths:
        retained = root / 'build/source-snapshot-evidence' / 'test_history_observation.py' / fixture.parent.name
        retained.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(fixture.parent / 'isonim/core/nondet.nim', retained / 'nondet.nim')
        shutil.copyfile(fixture.parent / 'isonim/core/private/rpc_http.nim', retained / 'rpc_http.nim')
        shutil.copyfile(bundle, retained / 'inverse.js')
    completed = subprocess.run(["node", "tests/test_history_observation.mjs"], cwd=root,
                               env={**env, "ISONIM_HISTORY_BUNDLE": str(bundle)},
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if retained: (retained / 'browser.log').write_text(completed.stdout)
    print(completed.stdout, flush=True)
    if mutant:
        assert completed.returncode != 0
        assert "ordinary-history-void-pathname-one-call: PASS" in completed.stdout
        assert "full-reflected-history-URL must equal same successful native action" in completed.stdout
        print("history URL mutant rejected by reflected URL oracle", flush=True)
    else:
        assert completed.returncode == 0
        assert "partial-history-availability-and-error-order: PASS" in completed.stdout


for flags, mode in [((), "default"), (("-d:isonimRecordable",), "dormant")]:
    run(fixture, root / f"build/history-{mode}.js", flags)
for name, replacement in [("pathname", "l.pathname"), ("input-echo", "u")]:
    with tempfile.TemporaryDirectory(prefix="history-mutant-") as temporary:
        tmp = Path(temporary)
        core = tmp / "isonim/core"
        shutil.copytree(root / "src/isonim/core", core)
        source = core / "nondet.nim"
        text = source.read_text()
        assert text.count("h=l&&l.href;") == 1
        source.write_text(text.replace("h=l&&l.href;", "h=" + replacement + ";"))
        mutant_fixture = tmp / fixture.name
        shutil.copyfile(fixture, mutant_fixture)
        run(mutant_fixture, tmp / (name + ".js"), paths=("--path:" + str(tmp),), mutant=True)
