#!/usr/bin/env python3
"""Execute Nim JS unittest output with a reliable failing process status.

Nim 2.2 browser-target unittest does not reliably set the process exit code.
A caught test failure
can print [FAILED], or a helper Check failed diagnostic alongside [OK], yet
return zero; never accept either as a passing gate.
"""
import os
import subprocess
import sys
result = subprocess.run([os.environ.get("ISONIM_SCENARIO_NODE", "node"), sys.argv[1]], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
sys.stdout.write(result.stdout)
failure_markers = ("[FAILED]", "[SKIPPED]", "Check failed:", "Expect Failed", "Unhandled exception:")
if result.returncode or any(marker in result.stdout for marker in failure_markers) or "[OK]" not in result.stdout:
    sys.exit(result.returncode or 1)
