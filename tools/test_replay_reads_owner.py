#!/usr/bin/env python3
"""Mandatory installed-owner integration, including a discriminating inverse.

Uses real browser/Recorder/strict codec/runtime; no optional artifact skip. The
inverse restores only storage dispatch, retaining positive clock/context paths.
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

def compile_js(name, flags=(), source=None, fixture="tests/fixtures/replay_reads.nim"):
    output = root / "build" / (name + ".js")
    command = ["nim", "js", "-d:isonimInternalReplayReads", *flags]
    if source:
        command += ["--path:" + str(source), "--path:" + str(root.parent / "nim-everywhere/src")]
    command += ["--nimcache:" + str(root / "build/nimcache" / name), "--out:" + str(output), str(fixture)]
    subprocess.run(command, cwd=root, check=True)
    return output

subprocess.run(["nim", "c", "-d:isonimInternalReplayReads", "--nimcache:build/nimcache/replay-script", "--out:build/replay-script", "tests/fixtures/replay_reads_script.nim"], cwd=root, check=True)
script = subprocess.check_output([str(root / "build/replay-script")], cwd=root)
(root / "build/replay-reads-capture-script.txt").write_bytes(script)
subprocess.run(["nim", "js", "--nimcache:build/nimcache/replay-context", "--out:build/replay-reads-context.js", "tests/fixtures/replay_reads_context.nim"], cwd=root, check=True)
subprocess.run(["nim", "js", "-d:isonimRecordable", "--nimcache:build/nimcache/replay-context-recordable", "--out:build/replay-reads-context-recordable.js", "tests/fixtures/replay_reads_context.nim"], cwd=root, check=True)
for name, flags in [("replay-reads", []), ("replay-reads-recordable", ["-d:isonimRecordable"]), ("replay-reads-stable-early", ["-d:isonimStableIds"])]:
    bundle = compile_js(name, flags)
    subprocess.run(["node", "tests/test_replay_reads_owner.mjs"], cwd=root, env={**env, "REPLAY_READS_BUNDLE": str(bundle)}, check=True)

with tempfile.TemporaryDirectory(prefix="isonim-read-restoration-") as directory:
    source = Path(directory) / "src"
    shutil.copytree(root / "src", source)
    path = source / "isonim/core/nondet.nim"
    original = path.read_text()
    block = '''  when defined(js) and defined(isonimInternalReplayReads):
    if b.isReadReplay:
      case name
      of "storageGet": return readReplayStorage(b, 1, arg)
      of "cookieGet": return readReplayStorage(b, 3, "")
      of "viewport": return readReplayViewport(b)
      of "matchMedia": return readReplayMedia(b, arg)
      else: refuseReadReplay(b, name)
'''
    assert original.count(block) == 1, "inverse must restore the actual read dispatch"
    # Restore storage ONLY: newly supported viewport dispatch remains intact.
    restored = block.replace('      of "storageGet": return readReplayStorage(b, 1, arg)\n', '      of "storageGet": discard\n').replace('      of "cookieGet": return readReplayStorage(b, 3, "")\n', '      of "cookieGet": discard\n')
    path.write_text(original.replace(block, restored))
    fixtures = Path(directory) / "tests/fixtures"
    fixtures.mkdir(parents=True)
    for name in ["replay_reads.nim", "replay_reads_bootstrap.nim"]:
        shutil.copyfile(root / "tests/fixtures" / name, fixtures / name)
    bundle = compile_js("replay-reads-restored", ["-d:replayReadMutant"], source, fixtures / "replay_reads.nim")
    subprocess.run(["node", "tests/test_replay_reads_owner.mjs"], cwd=root, env={**env, "REPLAY_READS_BUNDLE": str(bundle), "REPLAY_READS_MUTANT": "1"}, check=True)

# Restore ONLY the nil predicate in isolated own source. The exact nil oracle
# remains mandatory in the artifact-free driver; here the same transformation
# must retain actual-owner active Replay/35-entry/cursor/context positives.
with tempfile.TemporaryDirectory(prefix="isonim-owner-nil-inverse-") as directory:
    temporary = Path(directory)
    source = temporary / "src"
    shutil.copytree(root / "src", source)
    predicate = source / "isonim/core/private/replay_reads.nim"
    original = predicate.read_text()
    assert original.count("clock != nil and clock of ReadReplayClock") == 1
    predicate.write_text(original.replace("clock != nil and clock of ReadReplayClock", "clock of ReadReplayClock"))
    fixtures = temporary / "tests/fixtures"
    fixtures.mkdir(parents=True)
    for name in ["replay_reads.nim", "replay_reads_bootstrap.nim"]:
        shutil.copyfile(root / "tests/fixtures" / name, fixtures / name)
    bundle = compile_js("replay-reads-nil-restored-active", [], source, fixtures / "replay_reads.nim")
    subprocess.run(["node", "tests/test_replay_reads_owner.mjs"], cwd=root, env={**env, "REPLAY_READS_BUNDLE": str(bundle), "REPLAY_READS_NIL_INVERSE": "1"}, check=True)
    print("nil-check restoration: active actual-owner Replay/35-entry controls PASS")
