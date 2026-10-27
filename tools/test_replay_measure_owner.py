#!/usr/bin/env python3
"""Mandatory real registered-IID/Recorder/cursor integration and source inverses.

Uses one genuine compiled renderer/DSL runtime, real Chromium geometry and the
actual owner. Platform traps and source mutations discriminate forbidden fallback;
they never replace the cursor, registry or target resolution with test adapters.
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
def compile_js(name, flags=(), source=None, fixture="tests/fixtures/replay_measure.nim"):
    output = root / "build" / (name + ".js")
    command = ["nim", "js", "-d:isonimInternalReplayReads", "-d:isonimStableIds", *flags]
    if source:
        command += ["--path:" + str(source), "--path:" + str(root.parent / "nim-everywhere/src")]
    command += ["--nimcache:" + str(root / "build/nimcache" / name), "--out:" + str(output), str(fixture)]
    subprocess.run(command, cwd=root, check=True)
    return output
# The ONE moved implementation remains exactly the previous lookup expression.
lookup = root / "src/isonim/core/private/iid_lookup.nim"
expression = '((iid) => { globalThis.__isonimValidateIids(iid); return globalThis.__isonimIids.get(iid)?.deref() || null; })(#)'
assert lookup.read_text().count(expression) == 1
assert expression not in (root / "src/isonim/web/web_renderer.nim").read_text()
subprocess.run(["nim", "js", "--nimcache:build/nimcache/measure-context", "--out:build/replay-reads-context.js", "tests/fixtures/replay_reads_context.nim"], cwd=root, check=True)
for name, flags in [("replay-measure", []), ("replay-measure-recordable", ["-d:isonimRecordable"])]:
    bundle = compile_js(name, flags)
    subprocess.run(["node", "tests/test_replay_measure_owner.mjs"], cwd=root, env={**env, "REPLAY_MEASURE_BUNDLE": str(bundle)}, check=True)
for mutation in ["raw", "identity"]:
    with tempfile.TemporaryDirectory(prefix="isonim-measure-" + mutation + "-") as directory:
        temporary = Path(directory)
        source = temporary / "src"
        shutil.copytree(root / "src", source)
        if mutation == "raw":
            path = source / "isonim/core/nondet.nim"
            old = '          return asRect(readReplayMeasure(currentClock, el))'
            new = '          return asRect(parseJson($rawRead("measure", "", el)))'
        else:
            path = source / "isonim/core/private/replay_reads.nim"
            old = 'if not sameElement(el, resolveIidLookup(iid)):'
            new = 'if false:'
        original = path.read_text()
        assert original.count(old) == 1, "inverse must change only the relevant implementation seam"
        path.write_text(original.replace(old, new))
        fixtures = temporary / "tests/fixtures"
        fixtures.mkdir(parents=True)
        shutil.copyfile(root / "tests/fixtures/replay_measure.nim", fixtures / "replay_measure.nim")
        bundle = compile_js("replay-measure-" + mutation + "-restored", [], source, fixtures / "replay_measure.nim")
        subprocess.run(["node", "tests/test_replay_measure_owner.mjs"], cwd=root, env={**env, "REPLAY_MEASURE_BUNDLE": str(bundle), "REPLAY_MEASURE_MUTANT": mutation}, check=True)
