#!/usr/bin/env python3
"""Mandatory actual-owner viewport integration and source restoration control.

The real browser supplies recorded observations. Perturbed native getters reveal
raw fallback; no substitute cursor/provider or historical git object is used.
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

def compile_js(name, flags=(), source=None, fixture="tests/fixtures/replay_viewport.nim"):
    output = root / "build" / (name + ".js")
    command = ["nim", "js", "-d:isonimInternalReplayReads", *flags]
    if source:
        command += ["--path:" + str(source), "--path:" + str(root.parent / "nim-everywhere/src")]
    command += ["--nimcache:" + str(root / "build/nimcache" / name), "--out:" + str(output), str(fixture)]
    subprocess.run(command, cwd=root, check=True)
    return output

subprocess.run(["nim", "js", "--nimcache:build/nimcache/viewport-context", "--out:build/replay-reads-context.js", "tests/fixtures/replay_reads_context.nim"], cwd=root, check=True)
for name, flags in [("replay-viewport", []), ("replay-viewport-recordable", ["-d:isonimRecordable"])]:
    bundle = compile_js(name, flags)
    subprocess.run(["node", "tests/test_replay_viewport_owner.mjs"], cwd=root, env={**env, "REPLAY_VIEWPORT_BUNDLE": str(bundle)}, check=True)

with tempfile.TemporaryDirectory(prefix="isonim-viewport-restoration-") as directory:
    temporary = Path(directory)
    source = temporary / "src"
    shutil.copytree(root / "src", source)
    path = source / "isonim/core/nondet.nim"
    original = path.read_text()
    line = '      of "viewport": return readReplayViewport(b)\n'
    assert original.count(line) == 1, "inverse must restore only new viewport dispatch"
    # Retain storage/Clock2/context and every existing guard. Let viewport
    # proceed through the unchanged ordinary platform branch for this inverse.
    path.write_text(original.replace(line, '      of "viewport": discard\n'))
    fixtures = temporary / "tests/fixtures"
    fixtures.mkdir(parents=True)
    for name in ["replay_viewport.nim", "replay_reads_bootstrap.nim"]:
        shutil.copyfile(root / "tests/fixtures" / name, fixtures / name)
    bundle = compile_js("replay-viewport-restored", [], source, fixtures / "replay_viewport.nim")
    subprocess.run(["node", "tests/test_replay_viewport_owner.mjs"], cwd=root, env={**env, "REPLAY_VIEWPORT_BUNDLE": str(bundle), "REPLAY_VIEWPORT_MUTANT": "1"}, check=True)
