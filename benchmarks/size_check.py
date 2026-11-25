#!/usr/bin/env python3
"""Bundle-size check for the js-framework-benchmark app.

Builds `benchmarks/keyed/isonim/src/main.nim` exactly as `just bench-build`
does (`nim js -d:danger`, then terser with `--compress --mangle`), prints the
raw, minified and gzip byte counts, and compares the gzip size with the
baseline recorded in `benchmarks/baseline.json`.

The check fails (exit 1) when the gzip size grows past the baseline by more
than the budget the baseline file states (`size.budget_gzip_bytes`). The
reactive core must stay small for pages that do not use its newer features,
so growth is held to an explicit, small allowance measured against a fixed
starting point rather than against the previous commit, where many small
increases could each pass.

A second check holds for every build: the app must not link the modules a
page that does not use them must not pay for (`UNLINKED_MODULES`: the
injected-service layer, including the async value primitive, and the clock
of nim-everywhere). The compiler lists every module the build read
(`--genScript`, which for the JS backend only adds a `.deps` file beside
its intermediate files), and the check fails (exit 1) when one of them is linked. The
byte budget alone cannot show this: an import that costs a hundred bytes
passes it while budget is left, and this check fails on the import itself.

The gzip count is computed in-process (level 9, no file name, mtime 0), so it
depends only on the minified bytes and is reproducible between hosts.

Usage:
  python3 benchmarks/size_check.py            # build, print, compare
  python3 benchmarks/size_check.py --record   # build, print, and write the
                                              # size section of the baseline

`--record` stores the counts together with the commit, host and load they
were measured at; it is meant to be run once, on the commit the baseline
names, and reviewed like any other change to the file.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import gzip
import json
import os
import socket
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
APP_SRC = REPO / "benchmarks/keyed/isonim/src/main.nim"
DIST = REPO / "benchmarks/keyed/isonim/dist"
RAW_JS = DIST / "main.raw.js"
MIN_JS = DIST / "main.js"
BASELINE = REPO / "benchmarks/baseline.json"
TERSER = REPO / "node_modules/.bin/terser"
DEFAULT_BUDGET = 1024
# The compiler's dependency list for the build, written with `--genScript`.
NIMCACHE = REPO / "build/size-check-nimcache"
DEPS = NIMCACHE / "main.deps"
# Modules the app must not link, as path suffixes (a trailing "/" names a
# directory). The app uses only the reactive core and the web renderer, so
# none of these may reach it through an import from the core, `rxcore` or
# the renderer: they are opt-in, and a page that does not use them must
# carry none of their code or module-level state.
UNLINKED_MODULES = (
    "src/isonim/services/",               # injected services: futures, streams,
                                          # readiness marks, async values
    "src/nim_everywhere/time.nim",        # the clock the services schedule on
)


class SizeCheckError(Exception):
    """A build step failed or the baseline is unusable."""


def run(cmd: list[str]) -> None:
    proc = subprocess.run(cmd, cwd=REPO)
    if proc.returncode != 0:
        raise SizeCheckError(f"command failed ({proc.returncode}): {' '.join(cmd)}")


def build() -> dict[str, int]:
    """Build the app and return its byte counts."""
    if not TERSER.exists():
        raise SizeCheckError(
            f"{TERSER.relative_to(REPO)} is missing; run `just node-deps` "
            "(terser is a devDependency pinned by yarn.lock)")
    DIST.mkdir(parents=True, exist_ok=True)
    NIMCACHE.mkdir(parents=True, exist_ok=True)
    if DEPS.exists():
        DEPS.unlink()
    # `--genScript` and `--nimcache` change where the compiler writes its
    # intermediate files and its dependency list, not the JavaScript.
    run(["nim", "js", "-d:danger", "--hints:off",
         f"--path:{REPO.parent / 'nim-everywhere/src'}",
         "--genScript:on", f"--nimcache:{NIMCACHE}",
         f"-o:{RAW_JS}", str(APP_SRC)])
    run([str(TERSER), str(RAW_JS), "--compress", "--mangle", "-o", str(MIN_JS)])
    minified = MIN_JS.read_bytes()
    gz = gzip.compress(minified, compresslevel=9, mtime=0)
    return {"raw": RAW_JS.stat().st_size, "minified": len(minified), "gzip": len(gz)}


def linked_unwanted_modules() -> list[str]:
    """The modules of `UNLINKED_MODULES` the build linked, as paths."""
    if not DEPS.exists():
        raise SizeCheckError(
            f"the compiler wrote no dependency list at {DEPS.relative_to(REPO)}")
    linked = []
    for line in DEPS.read_text().splitlines():
        path = line.strip().replace("\\", "/")
        if not path:
            continue
        for unwanted in UNLINKED_MODULES:
            if unwanted.endswith("/"):
                if unwanted in path:
                    linked.append(path)
            elif path.endswith(unwanted):
                linked.append(path)
    return sorted(set(linked))


def git_head() -> str:
    out = subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO,
                         capture_output=True, text=True, check=True)
    return out.stdout.strip()


def inputs_are_committed() -> bool:
    """True when the app and the library it is built from have no local edits.

    A recorded baseline names a commit, so it must measure that commit's
    bytes and not uncommitted changes on top of it."""
    out = subprocess.run(
        ["git", "status", "--porcelain", "--", "src", "benchmarks/keyed/isonim/src"],
        cwd=REPO, capture_output=True, text=True, check=True)
    return out.stdout.strip() == ""


def load_average() -> str:
    try:
        return " ".join(f"{x:.2f}" for x in os.getloadavg())
    except OSError:
        return "unknown"


def read_baseline() -> dict:
    try:
        return json.loads(BASELINE.read_text())
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as err:
        raise SizeCheckError(f"{BASELINE.relative_to(REPO)} is not valid JSON: {err}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--record", action="store_true",
                        help="write the measured size into the baseline file")
    args = parser.parse_args(argv)

    try:
        if args.record and not inputs_are_committed():
            raise SizeCheckError(
                "refusing to record: src/ or the benchmark app has uncommitted "
                "changes, so the size would not be the commit's")
        sizes = build()
        print(f"size-check raw={sizes['raw']} minified={sizes['minified']} "
              f"gzip={sizes['gzip']}")
        unwanted = linked_unwanted_modules()
        if unwanted:
            print("size-check unlinked-modules FAIL", file=sys.stderr)
            for path in unwanted:
                print(f"size-check: the app links {path}, which a page that "
                      "does not use it must not carry", file=sys.stderr)
            return 1
        print(f"size-check unlinked-modules ok ({len(UNLINKED_MODULES)} "
              "module groups not linked)")
        baseline = read_baseline()

        if args.record:
            size = baseline.get("size", {})
            size.update(sizes)
            size.setdefault("budget_gzip_bytes", DEFAULT_BUDGET)
            size["commit"] = git_head()
            size["host"] = socket.gethostname()
            size["load_average"] = load_average()
            size["measured_at"] = _dt.datetime.now(_dt.timezone.utc).isoformat(
                timespec="seconds")
            baseline["size"] = size
            BASELINE.write_text(json.dumps(baseline, indent=2) + "\n")
            print(f"size-check recorded baseline at {size['commit'][:10]}")
            return 0

        size = baseline.get("size")
        if not size or "gzip" not in size:
            raise SizeCheckError(
                f"{BASELINE.relative_to(REPO)} has no size.gzip; record one with --record")
        base = int(size["gzip"])
        budget = int(size.get("budget_gzip_bytes", DEFAULT_BUDGET))
        growth = sizes["gzip"] - base
        verdict = "ok" if growth <= budget else "FAIL"
        print(f"size-check baseline_gzip={base} growth={growth:+d} "
              f"budget={budget} baseline_commit={str(size.get('commit', '?'))[:10]} "
              f"{verdict}")
        if growth > budget:
            print(f"size-check: gzip size grew {growth} bytes over the baseline, "
                  f"more than the {budget}-byte budget", file=sys.stderr)
            return 1
        return 0
    except SizeCheckError as err:
        print(f"size-check: {err}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
