#!/usr/bin/env python3
"""Real compiler/browser falsifiers, using copied sources and no mock bridge."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
paths = [Path("isonim/editor/views/component_detail.nim"),
         Path("isonim/editor/views/component_edit.nim")]
output = root / "build/editor-generation/fixture.js"
saved = output.read_bytes()
logs = root / "build/editor-generation/mutants"
logs.mkdir(exist_ok=True)

with tempfile.TemporaryDirectory(prefix="preview-generation-mutants-") as directory:
    work = Path(directory)
    shutil.copytree(root / "src", work / "src", symlinks=True)
    (work / "build").mkdir()
    shutil.copyfile(root / "build/tailwind-styles.json",
                    work / "build/tailwind-styles.json")
    # A fixture left in the original tests directory loads that directory's
    # config and resolves the original modules. Keep its relative src lookup
    # inside the copied tree; retain the real declared sibling/vendor inputs.
    fixture = work / "tests/test_editor_component_generation_fixture.nim"
    fixture.parent.mkdir()
    shutil.copyfile(root / "tests" / fixture.name, fixture)
    config = (root / "tests/config.nims").read_text()
    config = config.replace("$projectDir/../../", root.parent.as_posix() + "/")
    config = config.replace("$projectDir/../vendor/", (root / "vendor").as_posix() + "/")
    config = config.replace("$projectDir/../demos/", (root / "demos").as_posix() + "/")
    (fixture.parent / "config.nims").write_text(config)
    original = {path: (work / "src" / path).read_text() for path in paths}
    try:
        for name, path, signal in [("detail", paths[0], "detailSrcdocGeneration"),
                                   ("edit", paths[1], "srcdocGeneration")]:
            needle = f"{signal}.update(proc(previous: int): int = previous + 1)"
            assert original[path].count(needle) == 1
            variants = [
                ("self", f"{signal}.val = {signal}.val + 1",
                 "generation notification must not re-enter the document producer"),
                ("silent", "discard",
                 "each later generation notifies the restoration consumer exactly once"),
            ]
            for kind, replacement, marker in variants:
                for candidate, source in original.items():
                    (work / "src" / candidate).write_text(source)
                (work / "src" / path).write_text(
                    original[path].replace(needle, replacement, 1))
                subprocess.run([
                    "nim", "js", "--hints:off", "--path:" + str(work / "src"),
                    "--nimcache:" + str(work / "nimcache"), "--out:" + str(output),
                    str(fixture),
                ], cwd=root, check=True)
                run = subprocess.run(["node", "tests/test_editor_component_generation.mjs"],
                                     cwd=root, text=True, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT)
                (logs / f"{name}-{kind}.log").write_text(run.stdout)
                assert run.returncode != 0 and marker in run.stdout, run.stdout
                print(f"preview generation {name}-{kind}: REJECTED", flush=True)
    finally:
        output.write_bytes(saved)

# The output artifact must also be usable after the mutation boundary.
subprocess.run(["node", "tests/test_editor_component_generation.mjs"], cwd=root, check=True)
