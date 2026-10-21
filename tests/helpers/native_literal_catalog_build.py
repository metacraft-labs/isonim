"""Compile/run the disposable consumer's real SSR catalog adapter, never a stub."""
import os
import json
from pathlib import Path
import subprocess
import sys

project = Path(sys.argv[1]).resolve()
framework = Path(os.environ["ISONIM_SOURCE_FRAMEWORK"]).resolve()
output = project / ".isonim/catalog-producer"
compiled = subprocess.run([
    "nim", "c", "--hints:off", "--warnings:off",
    "--nimcache:" + str(project / ".isonim/native-cache"),
    "--path:" + str(framework / "src"),
    "--path:" + str(framework.parent / "nim-everywhere/src"),
    "--path:" + str(project / "src"), "--out:" + str(output),
    str(project / ".isonim/emit_catalog.nim"),
], cwd=project, capture_output=True, text=True)
if compiled.returncode:
    sys.stderr.write(compiled.stdout + compiled.stderr)
    sys.exit(compiled.returncode)
rendered = subprocess.run([str(output)], cwd=project, capture_output=True, text=True)
if rendered.returncode == 0:
    identity = json.loads(rendered.stdout)
    if not identity.get("workspace") or not identity.get("stories"):
        raise ValueError("The real workspace must publish a nonempty identity/catalog.")
    manifest_file = project / ".isonim/source-project.json"
    manifest = json.loads(manifest_file.read_text())
    manifest.update(workspace=identity["workspace"], title=identity["title"])
    manifest_file.write_text(json.dumps(manifest))
sys.stdout.write(rendered.stdout)
sys.stderr.write(rendered.stderr)
sys.exit(rendered.returncode)
