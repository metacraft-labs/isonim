"""Acquire the declared private literal-constant consumer fixture without writes.

Only a pinned, hash-checked source archive is used. CI must provision it through
ISONIM_SOURCE_PROVIDER_ARCHIVE or acquire the declared commit in the existing
sibling. There is no runtime fetch, current-source fallback or public vendoring.
The framework/compiler/SSR/source transactions remain real, not mocked.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

REPO = Path(__file__).resolve().parents[2]
DECLARATION = REPO / "tests/fixtures/native_literal_consumer/source.json"


def tracked_sources(root):
    if not root.exists():
        return ()
    listed = subprocess.run(["git", "-C", str(root), "ls-files", "-z"],
        capture_output=True, check=True)
    extensions = {".nim", ".nims", ".cfg", ".json", ".py", ".html", ".css", ".js", ".ts", ".md", ".toml"}
    return tuple(sorted(name.decode() for name in listed.stdout.split(b"\0")
        if name and Path(name.decode()).suffix in extensions))


def tree_hash(root, paths):
    digest = hashlib.sha256()
    for relative in paths:
        file = root / relative
        digest.update(relative.encode() + b"\0")
        if not file.exists() and not file.is_symlink():
            digest.update(b"<missing>")
            continue
        digest.update(str(file.lstat().st_mode).encode() + b"\0")
        if file.is_symlink():
            digest.update(os.readlink(file).encode())
        else:
            digest.update(file.read_bytes())
    return digest.hexdigest()


def acquire(test, directory):
    declared = json.loads(DECLARATION.read_text())
    protected = Path(os.environ.get("ISONIM_SOURCE_PROVIDER_PROJECT",
        REPO.parent / declared["repository"].split("/")[-1] / declared["projectPath"]))
    protected_paths = tracked_sources(protected)
    before = tree_hash(protected, protected_paths)
    test.addCleanup(lambda: test.assertEqual(tree_hash(protected, protected_paths), before,
        "The protected current project tree must remain unchanged."))
    supplied = os.environ.get("ISONIM_SOURCE_PROVIDER_ARCHIVE")
    if supplied:
        archive = Path(supplied).read_bytes()
    else:
        sibling = REPO.parent / declared["repository"].split("/")[-1]
        command = ["git", "-C", str(sibling), "archive", "--format=tar",
            declared["revision"], *[declared["projectPath"] + "/" + p for p in declared["paths"]]]
        obtained = subprocess.run(command, capture_output=True)
        if obtained.returncode:
            raise RuntimeError("Declared native literal fixture " + declared["revision"] +
                " is unavailable. Provision ISONIM_SOURCE_PROVIDER_ARCHIVE with SHA-256 " +
                declared["archiveSha256"] + ". Tests never fetch or substitute current source.")
        archive = obtained.stdout
    test.assertEqual(hashlib.sha256(archive).hexdigest(), declared["archiveSha256"],
        "The source archive must match its declared immutable provenance.")
    reference = directory / "reference"
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as source:
        source.extractall(reference, filter="data")
    prototype = reference / declared["projectPath"]
    text = (prototype / "src/components/styles.nim").read_text()
    for identity in ["const designTokens*", "const structureCss*",
        ".panel { border:1px solid var(--rule); border-radius:4px;", "--panel:#fbfbfc;"]:
        test.assertIn(identity, text)
    project = directory / "project"
    shutil.copytree(prototype, project)
    (project / ".isonim").mkdir()
    shutil.copyfile(REPO / "tests/helpers/native_literal_catalog.nim",
        project / ".isonim/emit_catalog.nim")
    manifest = {"catalog": ".isonim/catalog.json", "fixtures": [],
        "build": [sys.executable, str(REPO / "tests/helpers/native_literal_catalog_build.py"), str(project)]}
    (project / ".isonim/source-project.json").write_text(json.dumps(manifest))
    (directory / "fixture-provenance.json").write_text(json.dumps({**declared,
        "protectedCurrentTreeHash": before, "protectedSourceCount": len(protected_paths),
        "protectedCurrentTree": str(protected), "protectedSourcePaths": protected_paths}, indent=2))
    return prototype, project


if __name__ == "__main__":
    import unittest
    directory = Path(sys.argv[2]).resolve()
    if sys.argv[1] == "prepare":
        case = unittest.TestCase()
        prototype, project = acquire(case, directory)
        case.doCleanups()
        print(json.dumps({"prototype": str(prototype), "project": str(project)}))
    elif sys.argv[1] == "verify":
        provenance = json.loads((directory / "fixture-provenance.json").read_text())
        actual = tree_hash(Path(provenance["protectedCurrentTree"]), provenance["protectedSourcePaths"])
        if actual != provenance["protectedCurrentTreeHash"]:
            raise AssertionError("The protected current project tree must remain unchanged.")
    else:
        raise SystemExit("expected prepare or verify")
