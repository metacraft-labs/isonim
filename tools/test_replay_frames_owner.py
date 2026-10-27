#!/usr/bin/env python3
"""Mandatory actual native frame/owner integration and discriminating inverses.

Native callbacks/timestamps, owner codec/loop/checkpoints are real. Source mutants
compile their own copied source/fixture and cannot silently use selected sources.
Missing owner artifacts fail instead of skipping. See fixture/driver rationale.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
if not os.environ.get("CT_ARTIFACT"):
    raise SystemExit("CT_ARTIFACT required: actual owner frame integration cannot skip")
env = dict(os.environ)
env.setdefault("PLAYWRIGHT_CHROMIUM_EXECUTABLE", shutil.which("chromium") or "")


def compile_js(name, flags=(), source=None, fixture=None):
    output = root / "build" / (name + ".js")
    command = ["nim", "js", "-d:isonimInternalReplayReads", *flags]
    if source:
        command += ["--path:" + str(source), "--path:" + str(root.parent / "nim-everywhere/src")]
    command += ["--nimcache:" + str(root / "build/nimcache" / name),
                "--out:" + str(output), str(fixture or "tests/fixtures/replay_frames.nim")]
    subprocess.run(command, cwd=root, check=True)
    return output


native = compile_js("replay-frames-native")
for name, flags in [
    ("replay-frames", []),
    ("replay-frames-recordable", ["-d:isonimRecordable"]),
    ("replay-frames-release", ["-d:release"]),
    ("replay-frames-early", ["-d:replayTimersEarly"]),
]:
    bundle = compile_js(name, flags)
    subprocess.run(["node", "tests/test_replay_frames_owner.mjs"], cwd=root,
                   env={**env, "REPLAY_FRAMES_BUNDLE": str(bundle),
                        "REPLAY_FRAMES_NATIVE_BUNDLE": str(native),
                        "REPLAY_FRAMES_EARLY": "1" if "-d:replayTimersEarly" in flags else "0"}, check=True)

for mutation in ["raw", "registration", "clock", "bits", "namespace", "dispatch", "dispose"]:
    with tempfile.TemporaryDirectory(prefix="isonim-frames-" + mutation + "-") as directory:
        temporary = Path(directory)
        source = temporary / "src"
        shutil.copytree(root / "src", source)
        path = source / "isonim/core/private/replay_reads.nim"
        original = path.read_text()
        if mutation == "raw":
            path = source / "isonim/core/nondet.nim"
            original = path.read_text()
            old = "      if b.isReadReplay:\n        return readReplayFrame(b, proc(ts: float64) =\n          cb((browserTimestamp: some(ts))))"
            new = "      if b.isReadReplay: discard # restore actual platform branch"
        elif mutation == "registration":
            old = '\"#.registerTask(#,3,0)\"'
            new = '\"#.registerTask(#,3,1)\"'
        elif mutation == "clock":
            old = "let timestamp = clockRead[float64](selected.cursor, 4)"
            new = "let timestamp = clockRead[float64](selected.cursor, 2)"
        elif mutation == "bits":
            old = "        callback(timestamp)"
            new = '''        proc corruptFrameBits(value: float64): float64 {.importjs: "(function(v){var d=new DataView(new ArrayBuffer(8));d.setFloat64(0,v,true);d.setBigUint64(0,d.getBigUint64(0,true)^1n,true);return d.getFloat64(0,true);})(#)".}
        callback(corruptFrameBits(timestamp))'''
        elif mutation == "namespace":
            # Split only frames into a per-clock counter. Timers retain the
            # original namespace; second backend then mismatches genuine ID3.
            original = original.replace("    frameTasks: Table[int, JsObject]", "    frameTasks: Table[int, JsObject]\n    frameNamespaces: JsObject")
            old = "    let task = nextTimerTask(timerNamespaces, selected.cursor)"
            new = "    discard nextTimerTask(timerNamespaces, selected.cursor)\n    if selected.frameNamespaces.isNil: selected.frameNamespaces = newTimerNamespaces()\n    let task = nextTimerTask(selected.frameNamespaces, selected.cursor)"
        elif mutation == "dispatch":
            old = "      offTimer(selected.cursor, task)\n      selected.frameTasks.del(id)\n      selected.frameCancels.del(id)"
            new = "      discard # retain fired owner handler\n      selected.frameTasks.del(id)\n      selected.frameCancels.del(id)"
        else:
            old = "    for task in selected.frameTasks.values:\n      offTimer(selected.cursor, task)\n    selected.frameTasks.clear()\n    selected.frameCancels.clear()"
            new = "    discard # retain pending frame owner handler and maps"
        assert original.count(old) == 1, mutation + " must affect its named source exactly once"
        path.write_text(original.replace(old, new))
        fixtures = temporary / "tests/fixtures"
        fixtures.mkdir(parents=True)
        for name in ["replay_frames.nim", "replay_timers.nim", "replay_reads_bootstrap.nim"]:
            shutil.copyfile(root / "tests/fixtures" / name, fixtures / name)
        bundle = compile_js("replay-frames-inverse-" + mutation, [], source, fixtures / "replay_frames.nim")
        subprocess.run(["node", "tests/test_replay_frames_owner.mjs"], cwd=root,
                       env={**env, "REPLAY_FRAMES_BUNDLE": str(bundle),
                            "REPLAY_FRAMES_NATIVE_BUNDLE": str(native),
                            "REPLAY_FRAMES_INVERSE": mutation}, check=True)
