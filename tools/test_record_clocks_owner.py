#!/usr/bin/env python3
"""Mandatory actual private Nim Record/owner/public Replay primitive proof.

Native Date controls delegate to original instances; actual owner writer, codec,
cursor, loop and checkpoint run unchanged. Each source inverse is compiled from
an isolated production copy and must hit its specifically named semantic oracle.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
if not os.environ.get("CT_ARTIFACT"):
    raise SystemExit("CT_ARTIFACT required: actual installed owner integration cannot skip")
env = dict(os.environ)
env.setdefault("PLAYWRIGHT_CHROMIUM_EXECUTABLE", shutil.which("chromium") or "")

for operation in [[], ["-d:recordClockWallEffect"]]:
    command = ["nim", "js", "-d:isonimInternalRecordClocks", *operation,
               "--out:build/record-clock-effect.js", "tests/fixtures/record_clocks_effect.nim"]
    subprocess.run(command, cwd=root, check=True)
    rejected = subprocess.run(command[:2] + ["-d:recordClockRejectRaw"] + command[2:],
                              cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(rejected.stdout, flush=True)
    assert rejected.returncode != 0 and "RawNondet" in rejected.stdout and "unlisted effect" in rejected.stdout, "specific RawNondet effect rejection required"


def compile_js(name, fixture, flags=(), source=None):
    output = root / "build" / (name + ".js")
    command = ["nim", "js", *flags]
    if source:
        command += ["--path:" + str(source), "--path:" + str(root.parent / "nim-everywhere/src")]
    command += ["--nimcache:" + str(root / "build/nimcache" / name),
                "--out:" + str(output), str(fixture)]
    subprocess.run(command, cwd=root, check=True)
    return output


lazy = compile_js("record-clocks-import-only", "tests/fixtures/record_clocks_import.nim",
                  ["-d:isonimInternalRecordClocks"])
text = lazy.read_text()
assert "function rcDeliberateUncalled(" in text and "boundary-shim/dist/browser/recorder.js" in text, "real constructor/owner require must remain in artifact"
# Artifact-free Node has no Window or resolvable owner package. If import
# executes the retained constructor/require rather than just defining it, fail.
subprocess.run(["node", str(lazy)], cwd=root, check=True)


# Explicit empty-module imports cannot expose the type, owner require or state.
# Nim still emits its ordinary empty-module debug frames; the shipped public
# import graph below must remain EXACTLY byte-identical with this unused define.
for name, flags in [("ordinary", []), ("dormant", ["-d:isonimRecordable"])]:
    output = compile_js("record-clocks-omission-" + name,
                        "tests/fixtures/record_clocks_omission.nim", flags)
    text = output.read_text()
    for marker in ["RecordClockPrimitives", "newInternalRecordClocks", "boundary-shim"]:
        assert marker not in text, (name, marker)
    subprocess.run(["node", str(output)], cwd=root, check=True)
    ordinary = compile_js("record-clocks-public-" + name, "tests/test_nondet_seams.nim", flags)
    internal = compile_js("record-clocks-public-internal-" + name, "tests/test_nondet_seams.nim",
                          [*flags, "-d:isonimInternalRecordClocks"])
    assert ordinary.read_bytes() == internal.read_bytes(), name + " unchanged public emitted bytes"
    for marker in ["RecordClockPrimitives", "record_clocks.nim", "boundary-shim"]:
        assert marker not in ordinary.read_text(), (name, marker)
    subprocess.run(["python3", "tools/run_nim_js_test.py", str(ordinary)], cwd=root, check=True)

compile_js("replay-reads-context", "tests/fixtures/replay_reads_context.nim")
replay = compile_js("record-clocks-replay", "tests/fixtures/record_clocks_replay.nim",
                    ["-d:isonimInternalReplayReads"])
for name, flags in [("default", []), ("recordable", ["-d:isonimRecordable"]),
                    ("release", ["-d:release"]),
                    ("both", ["-d:isonimInternalReplayReads"])]:
    bundle = compile_js("record-clocks-" + name, "tests/fixtures/record_clocks.nim",
                        ["-d:isonimInternalRecordClocks", *flags])
    matching_replay = compile_js("record-clocks-replay-" + name, "tests/fixtures/record_clocks_replay.nim",
                                 ["-d:isonimInternalReplayReads", *flags])
    subprocess.run(["node", "tests/test_record_clocks_owner.mjs"], cwd=root,
                   env={**env, "RECORD_CLOCK_BUNDLE": str(bundle),
                        "RECORD_CLOCK_REPLAY": str(matching_replay)}, check=True)

for mutation in ["omit", "source", "extra", "value"]:
    with tempfile.TemporaryDirectory(prefix="isonim-record-clock-" + mutation + "-") as directory:
        temporary = Path(directory)
        source = temporary / "src"
        shutil.copytree(root / "src", source)
        path = source / "isonim/core/private/record_clocks.nim"
        original = path.read_text()
        if mutation == "omit":
            old = "c.rec.guard(function(){c.rec.emit('Clock',{src:2,bits:c.numberToBits(value)});});"
            new = "void value;"
        elif mutation == "source":
            old, new = "src:2,bits:c.numberToBits(value)", "src:1,bits:c.numberToBits(value)"
        elif mutation == "extra":
            old = "var value=c.performanceNow.call(c.performance);"
            new = old + "c.performanceNow.call(c.performance);"
        else:
            old, new = "return value;})(#)\", tags:", "return value+1;})(#)\", tags:"
        count = 2 if mutation == "value" else 1
        assert original.count(old) == count, mutation + " exact inverse source required"
        path.write_text(original.replace(old, new, 1))
        fixtures = temporary / "tests/fixtures"
        fixtures.mkdir(parents=True)
        fixture = fixtures / "record_clocks.nim"
        shutil.copyfile(root / "tests/fixtures/record_clocks.nim", fixture)
        bundle = compile_js("record-clocks-inverse-" + mutation, fixture,
                            ["-d:isonimInternalRecordClocks"], source)
        subprocess.run(["node", "tests/test_record_clocks_owner.mjs"], cwd=root,
                       env={**env, "RECORD_CLOCK_BUNDLE": str(bundle),
                            "RECORD_CLOCK_REPLAY": str(replay),
                            "RECORD_CLOCK_INVERSE": mutation}, check=True)

with tempfile.TemporaryDirectory(prefix="isonim-record-clock-effect-") as directory:
    temporary = Path(directory)
    source = temporary / "src"
    shutil.copytree(root / "src", source)
    path = source / "isonim/core/private/record_clocks.nim"
    original = path.read_text()
    assert original.count("tags: [RawNondet]") == 4
    path.write_text(original.replace(", tags: [RawNondet]", "").replace(" {.tags: [RawNondet].}", ""))
    fixtures = temporary / "tests/fixtures"
    fixtures.mkdir(parents=True)
    fixture = fixtures / "record_clocks_effect.nim"
    shutil.copyfile(root / "tests/fixtures/record_clocks_effect.nim", fixture)
    for name, operation in [("mono", []), ("wall", ["-d:recordClockWallEffect"])]:
        compile_js("record-clocks-untagged-" + name, fixture,
                   ["-d:isonimInternalRecordClocks", "-d:recordClockRejectRaw", *operation], source)
    print("removed RawNondet tags REJECTED: both prohibited callers compile; tagged positive controls retain original diagnostics", flush=True)
