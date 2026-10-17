#!/usr/bin/env python3
"""Publish a successful opt-in project's own native build/catalog output."""
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
manifest = json.loads((root / ".isonim/source-project.json").read_text())
catalog = (root / manifest["catalog"]).resolve()
if not catalog.is_relative_to(root):
    raise ValueError("Catalog path escapes project")
result = subprocess.run(manifest["build"], cwd=root, text=True, stdout=subprocess.PIPE)
if result.returncode:
    sys.stdout.write(result.stdout)
    sys.exit(result.returncode)
json.loads(result.stdout)
temporary = catalog.with_suffix(".tmp")
temporary.write_text(result.stdout)
temporary.replace(catalog)
