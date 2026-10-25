"""Compile and execute real native privacy/correlation controls, without mocks.

Each isolated source mutation must compile, then fail its named runtime oracle.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class TraceparentMutations(unittest.TestCase):
    def test_required_behaviors(self):
        source = ROOT / "src/isonim/server/context.nim"
        mutations = [
            ("forward", "ctx.resolvedTraceparent = canonicalTraceparent(incoming)",
             'ctx.resolvedTraceparent = ""',
             "forward header names in any case"),
            ("reuse", "if ctx.resolvedTraceparent.len == 0:\n      var count",
             "if true:\n      ctx.resolvedTraceparent = \"\"\n      var count",
             "request-local reuse survives header changes"),
            ("validation", "if value.len < 55 or value[2] != '-': return \"\"",
             "return value\n    if value.len < 55 or value[2] != '-': return \"\"",
             "malformed, duplicate and forbidden inputs"),
            ("fixed-mint", "let bytes = urandom(byteCount)",
             "let bytes = newSeq[byte](byteCount).mapIt(1.byte)",
             "request-local reuse survives header changes"),
        ]
        for name, before, after, oracle in mutations:
            with self.subTest(mutation=name), tempfile.TemporaryDirectory(
                prefix="isonim-traceparent-"
            ) as temporary:
                root = Path(temporary)
                target = root / "src/isonim/server/context.nim"
                shutil.copytree(ROOT / "src/isonim/server", target.parent)
                shutil.copytree(ROOT / "src/isonim/routing", root / "src/isonim/routing")
                text = source.read_text()
                self.assertEqual(text.count(before), 1)
                text = text.replace(before, after)
                if name == "fixed-mint":
                    text = text.replace("import std/[asyncdispatch,", "import std/[sequtils, asyncdispatch,")
                target.write_text(text)
                binary = root / "test"
                compiled = subprocess.run(
                    ["nim", "c", "--hints:off", "--skipParentCfg", "--skipProjCfg",
                     "--mm:arc", f"--path:{root / 'src'}", f"--nimcache:{root / 'cache'}",
                     f"--out:{binary}", str(ROOT / "tests/test_traceparent_meta.nim")],
                    text=True, capture_output=True,
                )
                self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
                executed = subprocess.run([str(binary)], text=True, capture_output=True)
                self.assertNotEqual(executed.returncode, 0, executed.stdout + executed.stderr)
                self.assertIn("[FAILED] " + oracle, executed.stdout)


if __name__ == "__main__":
    unittest.main()
