#!/usr/bin/env python3
"""Mandatory real native callback/owner scheduling gates and source inverses.

The fixture observes actual RealClock scheduling, not simulated callbacks. Missing
owner artifacts fail rather than skip. Ordinary tests need neither artifact nor
historical source. Mutants compile their own isolated production source bytes.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
if not os.environ.get("CT_ARTIFACT"):
    raise SystemExit("CT_ARTIFACT required: actual owner timer integration cannot skip")
env = dict(os.environ)
env.setdefault("PLAYWRIGHT_CHROMIUM_EXECUTABLE", shutil.which("chromium") or "")


def compile_js(name, flags=(), source=None, fixture=None):
    output = root / "build" / (name + ".js")
    command = ["nim", "js", "-d:isonimInternalReplayReads", *flags]
    if source:
        command += ["--path:" + str(source), "--path:" + str(root.parent / "nim-everywhere/src")]
    command += ["--nimcache:" + str(root / "build/nimcache" / name),
                "--out:" + str(output), str(fixture or "tests/fixtures/replay_timers.nim")]
    subprocess.run(command, cwd=root, check=True)
    return output


native = compile_js("replay-timers-native")
for name, flags in [
    ("replay-timers", []),
    ("replay-timers-recordable", ["-d:isonimRecordable"]),
    ("replay-timers-release", ["-d:release"]),
    ("replay-timers-early", ["-d:replayTimersEarly"]),
]:
    bundle = compile_js(name, flags)
    subprocess.run(["node", "tests/test_replay_timers_owner.mjs"], cwd=root,
                   env={**env, "REPLAY_TIMERS_BUNDLE": str(bundle),
                        "REPLAY_TIMERS_NATIVE_BUNDLE": str(native),
                        "REPLAY_TIMERS_EARLY": "1" if "-d:replayTimersEarly" in flags else "0"}, check=True)

for mutation in ["raw", "dispatch", "interval", "counter"]:
    with tempfile.TemporaryDirectory(prefix="isonim-timers-" + mutation + "-") as directory:
        temporary = Path(directory)
        source = temporary / "src"
        shutil.copytree(root / "src", source)
        path = source / "isonim/core/private/replay_reads.nim"
        original = path.read_text()
        if mutation == "raw":
            old = "    registerTimer(clock.cursor, task, delay)"
            new = "    return procCall schedule(RealClock(), callback, delayMs)"
        elif mutation == "dispatch":
            old = "      offTimer(clock.cursor, task)"
            new = "      discard # inverse: retain fired owner callback"
        elif mutation == "interval":
            old = '"#.registerTask(#,1,#)"'
            new = '"(function(r,t,d){r.registerTask(t,d===4?2:1,d);})(#,#,#)"'
        else:
            old = "var n=m.get(r);if(n===undefined)n=1n;"
            new = "var n=1n;"
        assert original.count(old) == 1, mutation + " must affect its named source only"
        path.write_text(original.replace(old, new))
        fixtures = temporary / "tests/fixtures"
        fixtures.mkdir(parents=True)
        shutil.copyfile(root / "tests/fixtures/replay_timers.nim", fixtures / "replay_timers.nim")
        bundle = compile_js("replay-timers-inverse-" + mutation, [], source, fixtures / "replay_timers.nim")
        subprocess.run(["node", "tests/test_replay_timers_owner.mjs"], cwd=root,
                       env={**env, "REPLAY_TIMERS_BUNDLE": str(bundle),
                            "REPLAY_TIMERS_NATIVE_BUNDLE": str(native),
                            "REPLAY_TIMERS_INVERSE": mutation}, check=True)
