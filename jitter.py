#!/usr/bin/env python3
"""Analyses frame jitter (smoothness) from the raw per-frame samples.

Percentiles describe how slow frames are; jitter describes how *inconsistent*
they are, which is what users actually perceive as stutter. This reports both
the overall spread and the frame-to-frame variation.
"""

import json
import pathlib
import statistics
import sys


def load(results_dir):
    runs = []
    for path in sorted(pathlib.Path(results_dir).glob("*.json")):
        if path.name.endswith(".meta.json"):
            continue
        with path.open() as handle:
            data = json.load(handle)
        renderer, _, rest = path.stem.partition("_")
        data["renderer"] = renderer
        data["load"] = rest.rsplit("_", 1)[0]
        runs.append(data)
    return runs


def percentile(values, q):
    ordered = sorted(values)
    if not ordered:
        return None
    idx = min(int(q / 100 * len(ordered)), len(ordered) - 1)
    return ordered[idx]


def jitter_metrics(samples, budget_us):
    """Computes dispersion and frame-to-frame variation for one run."""
    if len(samples) < 2:
        return None

    p50 = statistics.median(samples)
    deltas = [abs(b - a) for a, b in zip(samples, samples[1:])]

    return {
        # Overall spread: how wide the distribution is.
        "stddev": statistics.pstdev(samples),
        "iqr": percentile(samples, 75) - percentile(samples, 25),
        "p99_minus_p50": percentile(samples, 99) - p50,
        "max_minus_p50": max(samples) - p50,
        # Short-term variation: consecutive-frame change is what reads as
        # stutter, since a uniformly slow frame rate still looks smooth.
        "masd": statistics.fmean(deltas),
        "masd_p99": percentile(deltas, 99),
        # Frames whose work exceeded the presentation budget. For raster this
        # approximates dropped frames; for frame total it does not, because
        # build and raster pipeline across frames, so latency can exceed the
        # budget while still sustaining the full frame rate.
        "over_budget_pct": 100 * sum(1 for s in samples if s > budget_us)
        / len(samples),
    }


def aggregate(runs, load_level, renderer, field, budget_us):
    selected = [
        r for r in runs
        if r["load"] == load_level and r["renderer"] == renderer and field in r
    ]
    if not selected:
        return None

    per_run = [jitter_metrics(r[field], budget_us) for r in selected]
    per_run = [m for m in per_run if m]
    if not per_run:
        return None

    return {
        key: statistics.median([m[key] for m in per_run])
        for key in per_run[0]
    }


def main():
    results_dir = sys.argv[1] if len(sys.argv) > 1 else "results"
    runs = load(results_dir)
    if not runs:
        print(f"No results found in {results_dir}")
        return 1

    loads = []
    for r in runs:
        if r["load"] not in loads:
            loads.append(r["load"])

    metrics = [
        ("Std deviation (us)", "stddev"),
        ("IQR p75-p25 (us)", "iqr"),
        ("p99 - p50 (us)", "p99_minus_p50"),
        ("max - p50 (us)", "max_minus_p50"),
        ("Frame-to-frame (us)", "masd"),
        ("Frame-to-frame p99", "masd_p99"),
        ("Over 16.7ms", "over_budget_pct"),
    ]

    budget_us = 1_000_000 / 60

    for field, title in (("raster_samples", "RASTER"),
                         ("total_span_samples", "FRAME TOTAL")):
        print()
        print(f"################ {title} JITTER ################")
        for load_level in loads:
            gl = aggregate(runs, load_level, "opengl", field, budget_us)
            sub = aggregate(runs, load_level, "subsurface", field, budget_us)
            if not gl or not sub:
                continue
            shapes = next(r["shapes"] for r in runs if r["load"] == load_level)
            print()
            print(f"=== {load_level} ({shapes} shapes) ===")
            print(f"{'metric':<22}{'gtk opengl':>12}{'subsurface':>12}"
                  f"{'change':>20}")
            for label, key in metrics:
                a, b = gl[key], sub[key]
                if key == "over_budget_pct":
                    a_text, b_text = f"{a:.1f}%", f"{b:.1f}%"
                    change = f"{b - a:+.1f}pp"
                else:
                    a_text, b_text = f"{a:,.0f}", f"{b:,.0f}"
                    change = f"{(b - a) / a * 100:+.1f}%" if a else "n/a"
                    if abs((b - a) / a * 100) < 1:
                        change += " same"
                    elif b < a:
                        change += " better"
                    else:
                        change += " worse"
                print(f"{label:<22}{a_text:>12}{b_text:>12}{change:>20}")

    print()
    print("Lower is better throughout. Medians across repetitions.")
    print("'Frame-to-frame' is the mean absolute change between consecutive")
    print("frames -- a steady slow frame rate looks smooth, an erratic one")
    print("does not, so this tracks perceived stutter better than percentiles.")
    print("'Over 16.7ms' on FRAME TOTAL is a latency count, not dropped")
    print("frames: build and raster pipeline, so a frame can take longer than")
    print("the budget end-to-end while the frame rate stays at 60fps.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
