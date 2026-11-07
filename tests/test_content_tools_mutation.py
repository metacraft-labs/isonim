#!/usr/bin/env python3
"""Run production mutations in disposable source copies, never the live tree.

Every mutant must compile and fail the named existing semantic test. Real Nix
CLIs remain mandatory. No mock replaces positive rendering or a failure gate.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
for key in ("ISONIM_KATEX", "ISONIM_D2", "ISONIM_DOT"):
    if not os.environ.get(key):
        raise SystemExit(f"{key} not configured; enter nix develop .#content-tools")
MUTANTS = [
    ("arrow-paint", "ext/diagrams.nim", 'property == "edge"', 'property == "unused-edge"',
      [("diagrams", "real marker and edge arrowheads keep foreground paint over renderer classes")]),
    ("standalone-source", "ext/diagrams.nim",
      'if language == "d2": requireStandaloneD2(source, location)', 'discard',
      [("diagrams", "absolute D2 imports are refused before and after cache population")]),
    ("exit-status", "ext/tool_runner.nim", "if status != 0:", "if false:",
      [("math", "valid real MathML with nonzero status is rejected with diagnostics"),
      ("diagrams", "valid real SVG with nonzero status is rejected and never cached")]),
    ("cache-read", "ext/diagrams.nim", "if fileExists(cache):", "if false:",
      [("diagrams", "cache hits avoid the real CLI and source and executable changes invalidate")]),
    ("mask-role", "ext/diagrams.nim", 'return "var(--diagram-mask-visible)"',
      'return "var(--diagram-mask-hidden)"',
      [("diagrams", "D2 structural masks stay fixed while palette colors remain inherited")]),
    ("inline-style", "ext/diagrams.nim", '      node.attrs.del("style")', '      discard',
      [("diagrams", "normalized SVG carries no style attribute, only one generated stylesheet")]),
    ("specificity", "ext/diagrams.nim", "mostClasses + 1", "mostClasses",
      [("diagrams", "generated rules outrank every renderer stylesheet rule")]),
    ("second-id", "ext/diagrams.nim", "part.count('#') > 1", "part.count('#') > 2",
      [("diagrams", "renderer output that would defeat the generated stylesheet is refused")]),
    ("empty-style", "ext/diagrams.nim", 'node.attrs.hasKey("style")', 'node.attr("style").len > 0',
      [("diagrams", "an empty renderer style attribute is dropped, not refused")]),
    # The stylesheet reader before CDATA was read: D2's sheets come out empty.
    ("cdata-read", "fragments.nim", "    of xnText, xnCData: result.add child.text",
      "    of xnText: result.add child.text\n    of xnCData: discard",
      [("diagrams", "D2's CDATA stylesheet keeps shape and palette rules and drops embedded fonts"),
      ("diagrams", "D2 code blocks show only their light variant"),
      ("diagrams", "CDATA and text in one renderer stylesheet are read in order")]),
    ("font-family-kept", "ext/diagrams.nim", "      if onlyDropped:", "      if false:",
      [("diagrams", "D2's CDATA stylesheet keeps shape and palette rules and drops embedded fonts")]),
    ("mono-lost", "ext/diagrams.nim", 'if "mono" in tokens: result.add "font-family:monospace"', "discard",
      [("diagrams", "D2's CDATA stylesheet keeps shape and palette rules and drops embedded fonts")]),
    ("bold-lost", "ext/diagrams.nim", 'result.add "font-weight:bold"', "discard",
      [("diagrams", "D2's CDATA stylesheet keeps shape and palette rules and drops embedded fonts")]),
    ("renderer-sheet-kept", "ext/diagrams.nim", "        node.delete(c)\n", "        inc c\n",
      [("diagrams", "D2's CDATA stylesheet keeps shape and palette rules and drops embedded fonts")]),
    ("important", "ext/diagrams.nim", 'if "!" in value:', "if false:",
      [("diagrams", "hostile renderer CSS in a CDATA stylesheet is refused before cache publication")]),
    ("css-comment", "ext/diagrams.nim",
      'if "/*" in css: raise newException(ValueError, "CSS comments are not supported in SVG stylesheets")',
      "discard",
      [("diagrams", "hostile renderer CSS in a CDATA stylesheet is refused before cache publication")]),
    ("style-media", "ext/diagrams.nim", 'if key != "type" or value != "text/css":', "if false:",
      [("diagrams", "hostile renderer CSS in a CDATA stylesheet is refused before cache publication")]),
    ("hash-bytes", "fragments.nim", 'for forbidden in ["&", "<", ">", "\\0", "/*"]:',
      'for forbidden in ["<", "\\0", "/*"]:',
      [("diagrams", "hostile renderer CSS in a CDATA stylesheet is refused before cache publication")]),
    ("text-decoration", "fragments.nim", '          "text-decoration",\n', "",
      [("diagrams", "D2 underlined labels keep their text decoration")]),
]
reports = ROOT / "build/content-mutation-reports"
reports.mkdir(parents=True, exist_ok=True)
for name, source, old, new, cases in MUTANTS:
    with tempfile.TemporaryDirectory(prefix="content-mutant-", dir=ROOT / "build") as temp:
        scratch = Path(temp)
        for directory in ("content", "static"):
            shutil.copytree(ROOT / "src/isonim" / directory, scratch / "src/isonim" / directory)
        (scratch / "src/isonim/ssr").mkdir(parents=True)
        shutil.copy2(ROOT / "src/isonim/ssr/escape.nim", scratch / "src/isonim/ssr/escape.nim")
        (scratch / "helpers").mkdir()
        shutil.copy2(ROOT / "tests/helpers/content_tool_fixture.nim", scratch / "helpers")
        target = scratch / "src/isonim/content" / source
        text = target.read_text()
        if text.count(old) != 1:
            raise SystemExit(f"{name}: mutation site is no longer unique")
        target.write_text(text.replace(old, new, 1))
        for suite, assertion in cases:
            test = f"test_content_{suite}.nim"
            shutil.copy2(ROOT / "tests" / test, scratch / test)
            binary = scratch / f"{name}-{suite}"
            compile_log = reports / f"{name}-{suite}-compile.log"
            run_log = reports / f"{name}-{suite}-run.log"
            with compile_log.open("w") as output:
                built = subprocess.run(["nim", "c", f"--path:{scratch / 'src'}",
                    f"--out:{binary}", f"--nimcache:{ROOT / 'build/nimcache/content-mutations' / name / suite}",
                    str(scratch / test)], stdout=output, stderr=subprocess.STDOUT)
            if built.returncode:
                raise SystemExit(f"{name}: compile failure is NOT mutation evidence: {compile_log}")
            with run_log.open("w") as output:
                run = subprocess.run([str(binary)], stdout=output, stderr=subprocess.STDOUT)
            if run.returncode == 0 or f"[FAILED] {assertion}" not in run_log.read_text():
                raise SystemExit(f"{name}: required semantic assertion did not fail: {run_log}")
            print(f"PASS: {name}/{suite} compiled; named assertion failed (exit {run.returncode})", flush=True)
