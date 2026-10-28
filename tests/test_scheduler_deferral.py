#!/usr/bin/env python3
"""Prove the actual scheduler test detects premature execution on C and JS.

No scheduler/clock implementation is mocked. Each build uses a fresh copy of
actual repository source; the inverse adds one premature callback invocation.
The original named test is preserved verbatim from f014b2f2 as a counterfactual
fixture, avoiding any dependency on historical Git objects in a clean checkout.
Stock unittest supports named CLI filtering on C, but not on its JS target
(paramCount is unavailable there). Extract the exact current named test for BOTH
backends so unrelated cancellation failures cannot satisfy this oracle. The
normal full test_clock suite remains a separate mandatory focused gate.
Use the existing strict JS runner: stock JS unittest can print failures and
return zero. Its raw output and effective child exit are both retained.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
NAME = "requestCallback schedules and flushTasks executes"
HEADER = f'  test "{NAME}":\n'
BASELINE_SHA256 = "0bb4464c3ccb113d24fae0ca02cc6ccad7e74dbad0273b0cc91c4e5b3aac0de7"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def exact_test(source):
    assert source.count(HEADER) == 1, "named test missing or duplicated"
    start = source.index(HEADER)
    end = source.find("\n  test ", start + len(HEADER))
    assert end != -1, "test extraction boundary changed; review the extractor"
    return source[start:end] + "\n"


def run(command, destination, cwd):
    result = subprocess.run(command, cwd=cwd, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    destination.write_text(result.stdout)
    print(json.dumps({"command": command, "exit": result.returncode,
                      "log": str(destination)}), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", type=Path)
    args = parser.parse_args()
    logs = args.evidence_dir or Path(tempfile.mkdtemp(prefix="scheduler-deferral-logs-"))
    logs.mkdir(parents=True, exist_ok=True)
    original = ROOT / "tests/fixtures/scheduler_deferral/original_test.nim.txt"
    assert digest(original) == BASELINE_SHA256, "baseline counterfactual changed"
    corrected = exact_test((ROOT / "tests/test_clock.nim").read_text())
    assert "check executions == 0" in corrected
    assert "check order == newSeq[int]()" in corrected
    scheduler = ROOT / "src/isonim/core/scheduler.nim"
    before = digest(scheduler)
    ne = ROOT.parent / "nim-everywhere/src"
    assert ne.is_dir(), "required actual nim-everywhere sibling is absent"
    provenance = {"scheduler_sha256": before,
                  "test_clock_sha256": digest(ROOT / "tests/test_clock.nim"),
                  "baseline_sha256": digest(original),
                  "driver_sha256": digest(Path(__file__)),
                  "js_runner_sha256": digest(ROOT / "tools/run_nim_js_test.py"),
                  "nim": shutil.which("nim"), "node": shutil.which("node")}
    (logs / "inputs.json").write_text(json.dumps(provenance, indent=2) + "\n")
    for backend in ("c", "js"):
        for test_kind, body in (("original", original.read_text()),
                                ("corrected", corrected)):
            for inline in (False, True):
                label = f'{backend}-{test_kind}-{"inline" if inline else "unchanged"}'
                with tempfile.TemporaryDirectory(prefix="scheduler-deferral-source-") as temp:
                    work = Path(temp)
                    shutil.copytree(ROOT / "src", work / "src")
                    copied = work / "src/isonim/core/scheduler.nim"
                    source = copied.read_text()
                    if inline:
                        anchor = "  taskQueue.add(task)\n"
                        assert source.count(anchor) == 1
                        source = source.replace(anchor, "  fn(false)  # Source inverse: premature invocation.\n" + anchor)
                        copied.write_text(source)
                    (logs / (label + "-scheduler.nim.txt")).write_text(source)
                    fixture = work / "probe.nim"
                    fixture.write_text('import unittest\nimport isonim/core/[clock, scheduler]\n\nsuite "Scheduler":\n' + body)
                    (logs / (label + "-fixture.nim.txt")).write_text(fixture.read_text())
                    output = work / ("probe.js" if backend == "js" else "probe")
                    command = ["nim", backend, "--skipParentCfg", "--hints:off",
                               "--path:" + str(work / "src"), "--path:" + str(ne),
                               "--nimcache:" + str(work / "cache"),
                               "-o:" + str(output), str(fixture)]
                    compiled = run(command, logs / (label + "-compile.log"), work)
                    assert compiled.returncode == 0, f"{label}: compile failure is not a passing inverse"
                    command = ([sys.executable, str(ROOT / "tools/run_nim_js_test.py"), str(output)]
                               if backend == "js" else [str(output)])
                    result = run(command, logs / (label + "-run.log"), work)
                    statuses = re.findall(r"\[(OK|FAILED|SKIPPED)\] (.*)", result.stdout)
                    failure = inline and test_kind == "corrected"
                    expected = [("FAILED" if failure else "OK", NAME)]
                    assert statuses == expected, (label, statuses, result.stdout)
                    if failure:
                        assert result.returncode != 0
                        assert result.stdout.count("Check failed: executions == 0") == 2
                        premature_counts = re.findall(
                            r"Check failed: executions == 0\n\s+executions was (\d+)",
                            result.stdout)
                        assert premature_counts == ["1", "2"], premature_counts
                        assert result.stdout.count("Check failed: order == newSeq[int]()") == 2
                    else:
                        assert result.returncode == 0, (label, result.stdout)
                    print(f"PASS {label}: exact named oracle", flush=True)
    assert digest(scheduler) == before, "repository scheduler was modified"
    print("PASS scheduler deferral: 8 scoped actual-source runs, C and JS", flush=True)


if __name__ == "__main__":
    main()
