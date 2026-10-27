#!/usr/bin/env python3
"""Actual generator output/VM semantics and inverse-unconditional-emission.

All compiler/baseline bytes are real own generator output. VM mock rationale is
in the JS oracle; no browser artifact or historical git object is required.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent

def compile_scripts(label, fixture):
    scripts = []
    for variant, flags in [("ordinary", []), ("recordable", ["-d:isonimRecordable"]), ("internal", ["-d:isonimInternalReplayReads"])]:
        name = "replay-ssr-" + label + "-" + variant
        binary = root / "build" / name
        command = ["nim", "c", *flags, "--nimcache:" + str(root / "build/nimcache" / name), "--out:" + str(binary)]
        if fixture.is_absolute():
            command.append("--path:" + str(fixture.parents[2] / "src"))
        subprocess.run([*command, str(fixture)], cwd=root, check=True)
        output = subprocess.check_output([str(binary)], cwd=root)
        script = root / "build" / (name + ".js")
        script.write_bytes(output)
        scripts.append(str(script))
    return scripts

scripts = compile_scripts("current", Path("tests/fixtures/replay_reads_script.nim"))
subprocess.run(["node", "tests/test_replay_ssr_guard.mjs", *scripts], cwd=root, check=True)
with tempfile.TemporaryDirectory(prefix="isonim-ssr-guard-inverse-") as directory:
    temporary = Path(directory)
    shutil.copytree(root / "src", temporary / "src")
    fixtures = temporary / "tests/fixtures"
    fixtures.mkdir(parents=True)
    fixture = fixtures / "replay_reads_script.nim"
    shutil.copyfile(root / "tests/fixtures/replay_reads_script.nim", fixture)
    markers = temporary / "src/isonim/ssr/markers.nim"
    original = markers.read_text()
    guard = "  when defined(isonimInternalReplayReads):"
    assert original.count(guard) == 1, "inverse must target the actual guarded prefix"
    markers.write_text(original.replace(guard, "  if true:"))
    inverse = compile_scripts("unconditional", fixture)
    # Real internal positive controls remain green; exactly the ordinary guard
    # omission/behavior oracle must reject restoring unconditional emission.
    subprocess.run(["node", "tests/test_replay_ssr_guard.mjs", *inverse, "--internal-only"], cwd=root, check=True)
    for variant in ["ordinary", "recordable"]:
        result = subprocess.run(["node", "tests/test_replay_ssr_guard.mjs", *inverse, "--" + variant + "-only"], cwd=root, capture_output=True, text=True)
        print(result.stdout, end="")
        print(result.stderr, end="")
        assert result.returncode != 0, "unconditional SSR guard inverse escaped"
        assert variant + " SSR must not inspect private selector" in result.stderr, "wrong inverse failure"
        print("unconditional SSR guard inverse: REJECTED by " + variant + " omission oracle; internal controls PASS")
