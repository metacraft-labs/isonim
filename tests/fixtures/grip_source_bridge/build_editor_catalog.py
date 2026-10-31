"""Compile and execute the disposable GRIP copy's genuine story/SSR exporter."""
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
framework = Path(os.environ["ISONIM_SOURCE_FRAMEWORK"]).resolve()
output = root / ".isonim/catalog-producer"
command = ["nim", "c", "--hints:off", "--warnings:off", "--mm:orc",
    "--path:" + str(root / "src"), "--path:" + str(framework / "src"),
    "--path:" + str(framework.parent / "nim-everywhere/src"),
    "--nimcache:" + str(root / ".isonim/native-cache"),
    "--out:" + str(output), str(root / ".isonim/catalog.nim")]
compiled = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
if compiled.returncode:
    sys.stdout.buffer.write(compiled.stdout)
    sys.exit(compiled.returncode)
sys.exit(subprocess.call([str(output)]))
