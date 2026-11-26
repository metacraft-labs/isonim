#!/usr/bin/env python3
"""Summarise an interleaved A/B run of the js-framework-benchmark suite.

Reads the directory ``bench-ab.sh`` wrote (``meta.txt`` and
``rounds/r<N>/<framework>/*.json``, the runner's own result files), pools the
samples of every round per benchmark and framework, and prints one table:
median and spread of isonim-a, isonim-b and solid, the A->B delta of the
medians, and a verdict. It also writes ``report.md`` and ``report.json`` next
to the input.

Metrics: CPU benchmarks use the runner's ``total`` duration (ms); memory
benchmarks its MB figure; ``40_sizes`` yields compressed and uncompressed
size (kB, deterministic) and first paint (ms), the startup measure of the
runner.

Spread: the interquartile range (Q1..Q3) and min..max of the pooled samples,
plus the range of the per-round medians, which shows drift between rounds.

Verdict rule (mechanical, applied to B against A on every metric):
  * ``slower`` / ``faster``: a two-sided Mann-Whitney U test of the pooled
    samples gives p < ALPHA (0.01) AND the medians differ by at least
    FLOOR (5 %) of A's median;
  * ``noise`` otherwise.
The test asks whether the two sample sets come from one distribution; the
floor keeps a statistically clear but practically irrelevant shift (a few
tenths of a millisecond, which a long run will detect) from being reported.
Deterministic metrics (sizes) are compared exactly: any difference is
reported as ``larger`` / ``smaller``.
Exit status 1 when any metric is ``slower`` or ``larger``, else 0. Exit
status 2 when the input cannot support a verdict: no results at all, or a
metric selected by ``meta.txt``'s ``benchmarks`` with no samples for
isonim-a or isonim-b (a missing result must not read as "no regression").

Mann-Whitney U: https://en.wikipedia.org/wiki/Mann%E2%80%93Whitney_U_test
(normal approximation with tie correction; at the default settings of
bench-ab.sh every metric has 30 or more samples per side, where the
approximation is good).
"""

from __future__ import annotations

import glob
import json
import math
import os
import statistics
import sys

ALPHA = 0.01
FLOOR = 0.05
SIDES = ("isonim-a", "isonim-b", "solid")

# Benchmark id -> (label, unit, deterministic). The ids are the runner's.
METRICS = {
    "01_run1k": ("create rows", "ms", False),
    "02_replace1k": ("replace all rows", "ms", False),
    "03_update10th1k_x16": ("partial update", "ms", False),
    "04_select1k": ("select row", "ms", False),
    "05_swap1k": ("swap rows", "ms", False),
    "06_remove-one-1k": ("remove row", "ms", False),
    "07_create10k": ("create many rows", "ms", False),
    "08_create1k-after1k_x2": ("append rows to large table", "ms", False),
    "09_clear1k_x8": ("clear rows", "ms", False),
    "21_ready-memory": ("ready memory", "MB", False),
    "22_run-memory": ("run memory", "MB", False),
    "25_run-clear-memory": ("create/clear 1k rows x5, memory", "MB", False),
    "41_size-uncompressed": ("uncompressed size", "kB", True),
    "42_size-compressed": ("compressed size", "kB", True),
    "43_first-paint": ("first paint (startup)", "ms", False),
}


def expected_metrics(meta: dict[str, str]) -> list[str]:
    """The METRICS ids the run selected.

    bench-ab.sh passes each selector to the runner, which runs every benchmark
    whose id contains it; ``40_`` selects the size benchmark, which writes the
    ``41_``..``43_`` results.
    """
    selectors = meta.get("benchmarks", "").split()
    wanted = []
    for bench in METRICS:
        # The id the runner matches the selector against (lower-cased, as the
        # runner does): the size metrics all come from 40_sizes.
        runner_id = "40_sizes" if bench[:2] in ("41", "42", "43") else bench.lower()
        if any(sel in runner_id for sel in selectors):
            wanted.append(bench)
    return wanted


def read_meta(out_dir: str) -> dict[str, str]:
    meta: dict[str, str] = {}
    path = os.path.join(out_dir, "meta.txt")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if "=" in line:
                    key, value = line.rstrip("\n").split("=", 1)
                    meta[key] = value
    return meta


def sample_values(result: dict) -> list[float]:
    """The raw samples of one runner result file (CPU: ``total``)."""
    values = result.get("values", {})
    series = values.get("total") or values.get("DEFAULT")
    if series is None:
        raise ValueError(f"no total/DEFAULT series in {result.get('benchmark')}")
    return [float(v) for v in series["values"]]


def collect(out_dir: str) -> dict[str, dict[str, dict[int, list[float]]]]:
    """samples[benchmark][side][round] -> list of samples."""
    samples: dict[str, dict[str, dict[int, list[float]]]] = {}
    for path in sorted(glob.glob(os.path.join(out_dir, "rounds", "r*", "*", "*.json"))):
        round_no = int(os.path.basename(os.path.dirname(os.path.dirname(path)))[1:])
        side = os.path.basename(os.path.dirname(path))
        with open(path, encoding="utf-8") as fh:
            result = json.load(fh)
        bench = result["benchmark"]
        samples.setdefault(bench, {}).setdefault(side, {}).setdefault(round_no, []).extend(
            sample_values(result)
        )
    return samples


def quartiles(xs: list[float]) -> tuple[float, float]:
    if len(xs) < 2:
        return (xs[0], xs[0])
    q = statistics.quantiles(xs, n=4, method="inclusive")
    return (q[0], q[2])


def mann_whitney_p(a: list[float], b: list[float]) -> float:
    """Two-sided p of the Mann-Whitney U test, normal approximation, ties corrected."""
    n1, n2 = len(a), len(b)
    if n1 == 0 or n2 == 0:
        return 1.0
    pooled = sorted([(v, 0) for v in a] + [(v, 1) for v in b])
    ranks = [0.0] * len(pooled)
    tie_term = 0.0
    i = 0
    while i < len(pooled):
        j = i
        while j + 1 < len(pooled) and pooled[j + 1][0] == pooled[i][0]:
            j += 1
        rank = (i + j) / 2 + 1
        for k in range(i, j + 1):
            ranks[k] = rank
        t = j - i + 1
        tie_term += t**3 - t
        i = j + 1
    r1 = sum(r for r, (_, g) in zip(ranks, pooled) if g == 0)
    u1 = r1 - n1 * (n1 + 1) / 2
    n = n1 + n2
    mu = n1 * n2 / 2
    var = n1 * n2 / 12 * ((n + 1) - tie_term / (n * (n - 1)))
    if var <= 0:
        return 1.0
    z = (abs(u1 - mu) - 0.5) / math.sqrt(var)  # continuity correction
    return min(1.0, math.erfc(max(z, 0.0) / math.sqrt(2)))


def summarise(per_round: dict[int, list[float]]) -> dict:
    pooled = [v for r in sorted(per_round) for v in per_round[r]]
    q1, q3 = quartiles(pooled)
    round_medians = [statistics.median(per_round[r]) for r in sorted(per_round)]
    return {
        "n": len(pooled),
        "rounds": len(per_round),
        "median": statistics.median(pooled),
        "q1": q1,
        "q3": q3,
        "min": min(pooled),
        "max": max(pooled),
        "round_median_min": min(round_medians),
        "round_median_max": max(round_medians),
        "samples": pooled,
    }


def verdict(a: dict, b: dict, deterministic: bool) -> tuple[str, float, float]:
    delta = (b["median"] - a["median"]) / a["median"] if a["median"] else 0.0
    if deterministic:
        if b["median"] > a["median"]:
            return "larger", delta, 0.0
        if b["median"] < a["median"]:
            return "smaller", delta, 0.0
        return "equal", delta, 1.0
    p = mann_whitney_p(a["samples"], b["samples"])
    if p < ALPHA and abs(delta) >= FLOOR:
        return ("slower" if delta > 0 else "faster"), delta, p
    return "noise", delta, p


def fmt(s: dict | None) -> str:
    if s is None:
        return "-"
    return (
        f"{s['median']:.1f} [IQR {s['q1']:.1f}-{s['q3']:.1f}; "
        f"{s['min']:.1f}-{s['max']:.1f}; n={s['n']}]"
    )


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <bench-ab output dir>", file=sys.stderr)
        return 2
    out_dir = argv[1]
    meta = read_meta(out_dir)
    samples = collect(out_dir)
    if not samples:
        print(f"no results under {out_dir}/rounds", file=sys.stderr)
        return 2

    missing = [
        f"{bench} ({side})"
        for bench in expected_metrics(meta)
        for side in ("isonim-a", "isonim-b")
        if side not in samples.get(bench, {})
    ]
    if missing:
        print("missing results, no verdict: " + ", ".join(missing), file=sys.stderr)
        return 2

    rows = []
    for bench, (label, unit, deterministic) in METRICS.items():
        if bench not in samples:
            continue
        stats = {side: summarise(samples[bench][side]) for side in SIDES if side in samples[bench]}
        if "isonim-a" not in stats or "isonim-b" not in stats:
            continue
        word, delta, p = verdict(stats["isonim-a"], stats["isonim-b"], deterministic)
        rows.append(
            {
                "benchmark": bench,
                "label": label,
                "unit": unit,
                "verdict": word,
                "delta": delta,
                "p": p,
                "stats": stats,
            }
        )

    header = (
        f"A = {meta.get('rev_a', '?')} ({meta.get('rev_a_arg', '')}), "
        f"B = {meta.get('rev_b', '?')} ({meta.get('rev_b_arg', '')})"
        + (f" plus {meta['patch_b']}" if meta.get("patch_b") else "")
        + f"; rounds {meta.get('rounds', '?')}, count {meta.get('count', '?')}, "
        f"host {meta.get('host', '?')}, {meta.get('chrome', '')}, runner {meta.get('runner', '?')[:10]}, "
        f"identical bundles: {meta.get('same_bundle', '?')}"
    )
    lines = [
        header,
        f"rule: slower/faster when Mann-Whitney p < {ALPHA} and |delta| >= {FLOOR:.0%}; sizes exact",
        "",
        "| benchmark | unit | isonim-a median [IQR; min-max; n] | isonim-b | solid | delta B/A | p | round medians A / B | verdict |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for row in rows:
        s = row["stats"]
        rm = (
            f"{s['isonim-a']['round_median_min']:.1f}-{s['isonim-a']['round_median_max']:.1f} / "
            f"{s['isonim-b']['round_median_min']:.1f}-{s['isonim-b']['round_median_max']:.1f}"
        )
        lines.append(
            f"| {row['benchmark']} {row['label']} | {row['unit']} | {fmt(s['isonim-a'])} | "
            f"{fmt(s['isonim-b'])} | {fmt(s.get('solid'))} | {row['delta']:+.1%} | {row['p']:.2g} | {rm} | "
            f"{row['verdict']} |"
        )
    text = "\n".join(lines) + "\n"
    print(text, end="")
    with open(os.path.join(out_dir, "report.md"), "w", encoding="utf-8") as fh:
        fh.write(text)
    with open(os.path.join(out_dir, "report.json"), "w", encoding="utf-8") as fh:
        json.dump({"meta": meta, "alpha": ALPHA, "floor": FLOOR, "rows": rows}, fh, indent=1)
    return 1 if any(r["verdict"] in ("slower", "larger") for r in rows) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
