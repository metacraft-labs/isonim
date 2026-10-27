#!/usr/bin/env python3
"""Mandatory stock Time/owner integration and three discriminating inverses.

Controlled native Date inputs preserve the previous full20-case diagnostic;
raw traps and source edits discriminate unrelated successes from real coverage.
No mocked cursor/provider, historical source or optional artifact skip.
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

def compile_js(name, flags=(), source=None, fixture=None):
    output = root / "build" / (name + ".js")
    command = ["nim", "js", "-d:isonimInternalReplayReads", *flags]
    if source:
        command += ["--path:" + str(source), "--path:" + str(root.parent / "nim-everywhere/src")]
    command += ["--nimcache:" + str(root / "build/nimcache" / name), "--out:" + str(output), str(fixture or "tests/fixtures/replay_wall.nim")]
    subprocess.run(command, cwd=root, check=True)
    return output

subprocess.run(["nim", "js", "--out:build/replay-reads-context.js", "--nimcache:build/nimcache/wall-context", "tests/fixtures/replay_reads_context.nim"], cwd=root, check=True)
real = compile_js("replay-wall-real", ["-d:replayWallLate"])
real_release = compile_js("replay-wall-real-release", ["-d:replayWallLate", "-d:release"])
for name, flags, late in [
    ("replay-wall", [], False),
    ("replay-wall-late", ["-d:replayWallLate"], True),
    ("replay-wall-recordable", ["-d:isonimRecordable"], False),
    ("replay-wall-recordable-late", ["-d:isonimRecordable", "-d:replayWallLate"], True),
    ("replay-wall-release", ["-d:release"], False),
]:
    bundle = compile_js(name, flags)
    subprocess.run(["node", "tests/test_replay_wall_owner.mjs"], cwd=root, env={**env,
        "REPLAY_WALL_BUNDLE": str(bundle), "REPLAY_WALL_REAL_BUNDLE": str(real_release if "-d:release" in flags else real),
        "REPLAY_WALL_LATE": "1" if late else "0"}, check=True)

for mutation in ["raw", "source", "normalized"]:
    with tempfile.TemporaryDirectory(prefix="isonim-wall-" + mutation + "-") as directory:
        temporary = Path(directory)
        source = temporary / "src"
        shutil.copytree(root / "src", source)
        path = source / "isonim/core/nondet.nim" if mutation == "raw" else source / "isonim/core/private/replay_reads.nim"
        original = path.read_text()
        if mutation == "raw":
            old = "      if b.isReadReplay: return readReplayWall(b)\n"
            new = "      if b.isReadReplay: discard\n"
        elif mutation == "source":
            old = "clockRead[int](ReadReplayClock(clock).cursor, 3)"
            new = "clockRead[int](ReadReplayClock(clock).cursor, 1)"
        else:
            old = """    initTime(convert(Milliseconds, Seconds, millis),
      convert(Milliseconds, Nanoseconds,
        millis mod convert(Seconds, Milliseconds, 1).int))"""
            new = "    fromUnixFloat(millis.float64 / 1000)"
        assert original.count(old) == 1, mutation + " must change only the intended source"
        path.write_text(original.replace(old, new))
        fixtures = temporary / "tests/fixtures"
        fixtures.mkdir(parents=True)
        for name in ["replay_wall.nim", "replay_reads_bootstrap.nim"]:
            shutil.copyfile(root / "tests/fixtures" / name, fixtures / name)
        bundle = compile_js("replay-wall-inverse-" + mutation, [], source, fixtures / "replay_wall.nim")
        subprocess.run(["node", "tests/test_replay_wall_owner.mjs"], cwd=root, env={**env,
            "REPLAY_WALL_BUNDLE": str(bundle), "REPLAY_WALL_REAL_BUNDLE": str(real), "REPLAY_WALL_INVERSE": mutation}, check=True)
