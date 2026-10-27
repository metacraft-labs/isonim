#!/usr/bin/env python3
"""Mandatory media integration and current-source inverses; no mock cursor.

Real browser observations are recorded before traps. Inverses restore raw matching
and bypass native syntax normalization separately; positives stay mandatory.
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

def compile_js(name, flags=(), source=None, fixture="tests/fixtures/replay_media.nim"):
    output = root / "build" / (name + ".js")
    command = ["nim", "js", "-d:isonimInternalReplayReads", *flags]
    if source:
        command += ["--path:" + str(source), "--path:" + str(root.parent / "nim-everywhere/src")]
    command += ["--nimcache:" + str(root / "build/nimcache" / name), "--out:" + str(output), str(fixture)]
    subprocess.run(command, cwd=root, check=True)
    return output

subprocess.run(["nim", "js", "--nimcache:build/nimcache/media-context", "--out:build/replay-reads-context.js", "tests/fixtures/replay_reads_context.nim"], cwd=root, check=True)
for name, flags in [("replay-media", []), ("replay-media-recordable", ["-d:isonimRecordable"])]:
    bundle = compile_js(name, flags)
    subprocess.run(["node", "tests/test_replay_media_owner.mjs"], cwd=root, env={**env, "REPLAY_MEDIA_BUNDLE": str(bundle)}, check=True)

for mutation in ["raw", "serialization"]:
    with tempfile.TemporaryDirectory(prefix="isonim-media-" + mutation + "-") as directory:
        temporary = Path(directory)
        source = temporary / "src"
        shutil.copytree(root / "src", source)
        if mutation == "raw":
            path = source / "isonim/core/nondet.nim"
            original = path.read_text()
            old = '      of "matchMedia": return readReplayMedia(b, arg)\n'
            assert original.count(old) == 1, "inverse must restore only new media dispatch"
            path.write_text(original.replace(old, '      of "matchMedia": discard\n'))
        else:
            path = source / "isonim/core/private/replay_reads.nim"
            original = path.read_text()
            old = 'var media=new CSSStyleSheet({media:q}).media.mediaText;'
            assert original.count(old) == 1, "inverse must bypass only native serialization"
            path.write_text(original.replace(old, 'var media=q;'))
        fixtures = temporary / "tests/fixtures"
        fixtures.mkdir(parents=True)
        for name in ["replay_media.nim", "replay_reads_bootstrap.nim"]:
            shutil.copyfile(root / "tests/fixtures" / name, fixtures / name)
        bundle = compile_js("replay-media-" + mutation + "-restored", [], source, fixtures / "replay_media.nim")
        subprocess.run(["node", "tests/test_replay_media_owner.mjs"], cwd=root, env={**env, "REPLAY_MEDIA_BUNDLE": str(bundle), "REPLAY_MEDIA_MUTANT": mutation}, check=True)
