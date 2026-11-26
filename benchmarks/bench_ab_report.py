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
    samples gives a raw p, the raw p values of all non-deterministic metrics
    of the run are Holm-Bonferroni adjusted, and the metric's adjusted p is
    < ALPHA (0.01) AND the medians differ by at least FLOOR (5 %) of A's
    median;
  * ``noise`` otherwise.
The test asks whether the two sample sets come from one distribution; the
floor keeps a statistically clear but practically irrelevant shift (a few
tenths of a millisecond, which a long run will detect) from being reported.
Deterministic metrics (sizes) are compared exactly: any difference is
reported as ``larger`` / ``smaller``. They take no part in the adjustment.

Why the adjustment: one run compares about thirteen timing and memory
metrics, and the run fails when any one of them is flagged. Testing each at
p < 0.01 on its own gives an identical pair of builds roughly a 1 - 0.99^13
(about 12 %) chance of at least one false "slower" or "faster", more where
the metrics are not independent of host load; a real A/A run of the suite
did flag one (create many rows, +16 %, p 0.0081). Holm's step-down method
keeps the probability of any false flag in the run (the familywise error
rate) at or below ALPHA for any dependence between the metrics, and rejects
at least as much as a plain Bonferroni correction. Both p values are
reported. Holm, "A Simple Sequentially Rejective Multiple Test Procedure",
Scandinavian Journal of Statistics 6 (2), 1979, 65-70,
https://www.jstor.org/stable/4615733 ; summary:
https://en.wikipedia.org/wiki/Holm%E2%80%93Bonferroni_method
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


def holm_adjust(pvalues: list[float]) -> list[float]:
    """Holm-Bonferroni adjusted p values, in the order given.

    With the m raw p values sorted ascending, p(1) <= ... <= p(m), the
    adjusted value of the k-th is max over j <= k of min(1, (m - j + 1) p(j)).
    Rejecting every hypothesis whose adjusted p is below alpha is Holm's
    step-down procedure at familywise level alpha (see the module docstring).
    """
    m = len(pvalues)
    order = sorted(range(m), key=lambda i: pvalues[i])
    adjusted = [1.0] * m
    running = 0.0
    for rank, i in enumerate(order):
        running = max(running, min(1.0, (m - rank) * pvalues[i]))
        adjusted[i] = running
    return adjusted


def delta_of(a: dict, b: dict) -> float:
    return (b["median"] - a["median"]) / a["median"] if a["median"] else 0.0


def size_verdict(a: dict, b: dict) -> str:
    """Deterministic metrics: any difference counts."""
    if b["median"] > a["median"]:
        return "larger"
    if b["median"] < a["median"]:
        return "smaller"
    return "equal"


def timing_verdict(delta: float, p_adjusted: float) -> str:
    if p_adjusted < ALPHA and abs(delta) >= FLOOR:
        return "slower" if delta > 0 else "faster"
    return "noise"


def score(rows: list[dict]) -> None:
    """Fill each row's ``delta``, ``p``, ``p_adjusted`` and ``verdict``.

    The Holm family is every non-deterministic row of the run; sizes are
    compared exactly and carry no p value (None).
    """
    tested = [r for r in rows if not r["deterministic"]]
    for row in rows:
        row["delta"] = delta_of(row["stats"]["isonim-a"], row["stats"]["isonim-b"])
    raw = [mann_whitney_p(r["stats"]["isonim-a"]["samples"], r["stats"]["isonim-b"]["samples"]) for r in tested]
    for row, p, p_adj in zip(tested, raw, holm_adjust(raw)):
        row["p"] = p
        row["p_adjusted"] = p_adj
        row["verdict"] = timing_verdict(row["delta"], p_adj)
    for row in rows:
        if row["deterministic"]:
            row["p"] = None
            row["p_adjusted"] = None
            row["verdict"] = size_verdict(row["stats"]["isonim-a"], row["stats"]["isonim-b"])


def fmt(s: dict | None) -> str:
    if s is None:
        return "-"
    return (
        f"{s['median']:.1f} [IQR {s['q1']:.1f}-{s['q3']:.1f}; "
        f"{s['min']:.1f}-{s['max']:.1f}; n={s['n']}]"
    )


def fmt_p(p: float | None) -> str:
    return "-" if p is None else f"{p:.2g}"


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
        rows.append(
            {
                "benchmark": bench,
                "label": label,
                "unit": unit,
                "deterministic": deterministic,
                "stats": stats,
            }
        )
    score(rows)

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
        f"rule: slower/faster when the Holm-adjusted Mann-Whitney p < {ALPHA} "
        f"(familywise, over the {sum(1 for r in rows if not r['deterministic'])} timing and memory metrics) "
        f"and |delta| >= {FLOOR:.0%}; sizes exact",
        "",
        "| benchmark | unit | isonim-a median [IQR; min-max; n] | isonim-b | solid | delta B/A | p raw | p Holm | round medians A / B | verdict |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for row in rows:
        s = row["stats"]
        rm = (
            f"{s['isonim-a']['round_median_min']:.1f}-{s['isonim-a']['round_median_max']:.1f} / "
            f"{s['isonim-b']['round_median_min']:.1f}-{s['isonim-b']['round_median_max']:.1f}"
        )
        lines.append(
            f"| {row['benchmark']} {row['label']} | {row['unit']} | {fmt(s['isonim-a'])} | "
            f"{fmt(s['isonim-b'])} | {fmt(s.get('solid'))} | {row['delta']:+.1%} | "
            f"{fmt_p(row['p'])} | {fmt_p(row['p_adjusted'])} | {rm} | "
            f"{row['verdict']} |"
        )
    text = "\n".join(lines) + "\n"
    print(text, end="")
    with open(os.path.join(out_dir, "report.md"), "w", encoding="utf-8") as fh:
        fh.write(text)
    with open(os.path.join(out_dir, "report.json"), "w", encoding="utf-8") as fh:
        json.dump(
            {"meta": meta, "alpha": ALPHA, "floor": FLOOR, "correction": "holm", "rows": rows},
            fh,
            indent=1,
        )
    return 1 if any(r["verdict"] in ("slower", "larger") for r in rows) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
