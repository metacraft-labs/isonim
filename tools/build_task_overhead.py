#!/usr/bin/env python3
"""Build real historical/current task apps using ONE installed compiler.

No renderer, transport or recorder is mocked. Git archives keep unfinished
working-copy features out of these artifacts. Run from the normal dev shell.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

M5 = "df230a07a493993fa7306970bc00f21e7d24968f"
FIXTURE = "tests/fixtures/stable_ids/task_app.nim"
SUFFIX = "\nwhen defined(js):\n  proc taskOverheadCalls(): int {.exportc.} = calls\n"


def run(args, cwd=None):
    return subprocess.check_output(args, cwd=cwd).decode()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def input_manifest(everywhere, styles):
    owner = Path(run(["git", "rev-parse", "--show-toplevel"], everywhere).strip())
    return {
        "nim_everywhere_owner": str(owner),
        "commit": run(["git", "rev-parse", "HEAD"], owner).strip(),
        "dirty": run(["git", "status", "--porcelain=v1", "--untracked-files=all"], owner),
        "source_root": str(everywhere),
        "source_sha256": {str(p.relative_to(everywhere)): digest(p)
                          for p in sorted(everywhere.rglob("*")) if p.is_file()},
        "style_path": str(styles), "style_sha256": digest(styles),
    }


def build(repo, output, candidate, everywhere, styles):
    output.mkdir(parents=True, exist_ok=False)
    wrapper = Path(shutil.which("nim") or "")
    if not wrapper.is_file():
        raise RuntimeError("installed Nim compiler missing")
    # The installed wrapper's dump declares its real default library; do not
    # override --lib, including for the historical source build.
    dump = json.loads(run([str(wrapper), "dump", "--dump.format:json", FIXTURE], repo))
    library = Path(dump["libpath"])
    engine = library.parent / "bin/nim"
    provenance = {
        "wrapper": str(wrapper), "wrapper_sha256": digest(wrapper),
        "engine": str(engine), "engine_sha256": digest(engine),
        "library": str(library),
        "system_sha256": digest(library / "system.nim"),
        "macros_sha256": digest(library / "core/macros.nim"),
        "observation_suffix_sha256": hashlib.sha256(SUFFIX.encode()).hexdigest(),
        "css": "none",
        "tailwind_map_sha256": digest(styles),
        "build_driver_sha256": digest(__file__),
        "library_tree_sha256": hashlib.sha256("\n".join(
            str(p.relative_to(library)) + ":" + digest(p)
            for p in sorted(library.rglob("*.nim"))).encode()).hexdigest(),
    }
    inputs = input_manifest(everywhere, styles)
    provenance["shared_inputs"] = inputs
    fixtures = []
    for label, revision in [("m5", M5), ("current", candidate)]:
        before = input_manifest(everywhere, styles)
        if before != inputs:
            raise RuntimeError("shared build inputs changed before " + label)
        commit = run(["git", "rev-parse", revision], repo).strip()
        source = output / (label + "-source")
        source.mkdir()
        archive = subprocess.check_output(["git", "archive", commit], cwd=repo)
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            tar.extractall(source, filter="data")
        fixture = source / FIXTURE
        original = fixture.read_bytes()
        fixtures.append(original)
        fixture.write_bytes(original + SUFFIX.encode())
        arm = output / label
        arm.mkdir()
        common = ["--hints:off", "-d:release", "--stackTrace:off",
                  "--lineTrace:off", "--path:src", "--path:" + str(everywhere),
                  "-d:tailwindStylesPathOverride=" + str(styles)]
        commands = []
        for backend in ["c", "js"]:
            target = arm / ("ssr" if backend == "c" else "app.js")
            cmd = [str(wrapper), backend, *common, "--out:" + str(target)]
            if backend == "c":
                cmd.append("-d:isServer")
            cmd.append(FIXTURE)
            subprocess.run(cmd, cwd=source, check=True)
            commands.append(cmd)
        after = input_manifest(everywhere, styles)
        if after != inputs:
            raise RuntimeError("shared build inputs changed during " + label)
        markup = run([str(arm / "ssr")])
        html = ('<!doctype html><div id="root">' + markup +
                '</div><script>globalThis.overheadSsrNodes='
                '[...document.querySelectorAll("input,button,form")];</script>'
                '<script src="app.js"></script>')
        (arm / "index.html").write_text(html)
        provenance[label] = {
            "shared_inputs_before": before, "shared_inputs_after": after,
            "commit": commit, "tree": run(["git", "rev-parse", commit + "^{tree}"], repo).strip(),
            "fixture_sha256": hashlib.sha256(original).hexdigest(),
            "observed_fixture_sha256": digest(fixture),
            "html_sha256": digest(arm / "index.html"),
            "js_sha256": digest(arm / "app.js"),
            "ssr_sha256": digest(arm / "ssr"), "commands": commands,
            "mode": "ordinary-default-no-activation",
        }
    if fixtures[0] != fixtures[1]:
        raise RuntimeError("task fixture differs: comparison requires identical app bytes")
    (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--candidate", default="HEAD")
    parser.add_argument("--nim-everywhere", type=Path, required=True)
    parser.add_argument("--tailwind-map", type=Path, required=True,
                        help="one real generated Tailwind style map, shared by both builds")
    args = parser.parse_args()
    build(Path.cwd(), args.output.resolve(), args.candidate,
          args.nim_everywhere.resolve(), args.tailwind_map.resolve())
