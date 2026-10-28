#!/usr/bin/env python3
"""Compile real env facade in both modes and reject omitted IANA metadata.

An isolated source tree holds the implementation mutation; no candidate source
or actual browser timezone/Intl implementation is replaced by the mutation.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
env = dict(os.environ)
env.setdefault("PLAYWRIGHT_CHROMIUM_EXECUTABLE", shutil.which("chromium") or "")


def compile_and_run(fixture, bundle, extra=(), paths=(), mutant=False):
    subprocess.run(["nim", "js", *extra, "--path:" + str(root / "src"),
                    "--path:" + str(root.parent / "nim-everywhere/src"), *paths,
                    "--out:" + str(bundle), str(fixture)], cwd=root, check=True)
    retained = None
    if paths:
        retained = root / 'build/source-snapshot-evidence' / 'test_environment_iana.py' / fixture.parent.name
        retained.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(fixture.parent / 'isonim/core/nondet.nim', retained / 'nondet.nim')
        shutil.copyfile(fixture.parent / 'isonim/core/private/rpc_http.nim', retained / 'rpc_http.nim')
        shutil.copyfile(bundle, retained / 'inverse.js')
    run_env = dict(env, ISONIM_ENV_BUNDLE=str(bundle))
    run = subprocess.run(["node", "tests/test_environment_iana.mjs"], cwd=root,
                         env=run_env, text=True, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT)
    if retained: (retained / 'browser.log').write_text(run.stdout)
    print(run.stdout, flush=True)
    if mutant:
        assert run.returncode != 0
        assert "IANA environment must retain actual platform zone" in run.stdout
        assert "legacy-environment-and-offset: PASS" in run.stdout
        print("omitted-IANA environment mutant: REJECTED", flush=True)
    else:
        assert run.returncode == 0
        assert "IANA-environment-cache: PASS" in run.stdout


fixture = root / "tests/fixtures/nondet_partial_window_boot.nim"
for extra, mode in [((), "default"), (("-d:isonimRecordable",), "dormant")]:
    compile_and_run(fixture, root / f"build/environment-{mode}.js", extra)
with tempfile.TemporaryDirectory(prefix="iana-mutant-") as temporary:
    tmp = Path(temporary)
    core = tmp / "isonim/core"
    shutil.copytree(root / "src/isonim/core", core)
    source = core / "nondet.nim"
    text = source.read_text()
    assert text.count("timeZone:z,") == 1
    source.write_text(text.replace("timeZone:z,", ""))
    mutant_fixture = tmp / fixture.name
    shutil.copyfile(fixture, mutant_fixture)
    compile_and_run(mutant_fixture, tmp / "mutant.js", paths=("--path:" + str(tmp),), mutant=True)
