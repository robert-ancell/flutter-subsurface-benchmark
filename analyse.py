#!/usr/bin/env python3
"""Summarises the renderer A/B benchmark results.

Reads the per-run JSON files written by run_bench.sh and reports, for each load
level, the median-of-repetitions for each renderer plus the relative difference.
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
        load_level = rest.rsplit("_", 1)[0]
        data["renderer"] = renderer
        data["load"] = load_level

        meta_path = path.with_suffix(".meta.json")
        if meta_path.exists():
            with meta_path.open() as handle:
                data["meta"] = json.load(handle)
        runs.append(data)
    return runs


def summarise(runs, load_level, renderer):
    selected = [r for r in runs if r["load"] == load_level and r["renderer"] == renderer]
    if not selected:
        return None

    def med(fn):
        values = [fn(r) for r in selected if fn(r) is not None]
        return statistics.median(values) if values else None

    cpu_seconds = []
    first_frames = []
    for r in selected:
        meta = r.get("meta")
        if not meta:
            continue
        ticks = meta.get("cpu_ticks") or 0
        per_sec = meta.get("ticks_per_sec") or 100
        cpu_seconds.append(ticks / per_sec)
        latency = meta.get("first_frame_latency_us") or 0
        # Sanity guard: a first frame always takes between 1ms and 60s, so
        # anything outside that is a bad measurement rather than a slow start.
        if 1000 < latency < 60_000_000:
            first_frames.append(latency / 1000)

    return {
        "runs": len(selected),
        "fps": med(lambda r: r["effective_fps"]),
        "raster_p50": med(lambda r: r["raster"]["p50"]),
        "raster_p90": med(lambda r: r["raster"]["p90"]),
        "raster_p99": med(lambda r: r["raster"]["p99"]),
        "raster_mean": med(lambda r: r["raster"]["mean"]),
        "build_p50": med(lambda r: r["build"]["p50"]),
        "total_p50": med(lambda r: r["total_span"]["p50"]),
        "total_p90": med(lambda r: r["total_span"]["p90"]),
        "cpu_s": statistics.median(cpu_seconds) if cpu_seconds else None,
        "first_frame_ms": statistics.median(first_frames) if first_frames else None,
    }


def delta(subsurface, opengl):
    if subsurface is None or opengl is None or not opengl:
        return None
    return (subsurface - opengl) / opengl * 100


def fmt(value, suffix="", width=9):
    if value is None:
        return "n/a".rjust(width)
    return f"{value:,.1f}{suffix}".rjust(width)


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
        ("Effective FPS", "fps", "", False),
        ("Raster p50 (us)", "raster_p50", "", True),
        ("Raster p90 (us)", "raster_p90", "", True),
        ("Raster p99 (us)", "raster_p99", "", True),
        ("Raster mean (us)", "raster_mean", "", True),
        ("Build p50 (us)", "build_p50", "", True),
        ("Frame total p50 (us)", "total_p50", "", True),
        ("Frame total p90 (us)", "total_p90", "", True),
        ("CPU time (s)", "cpu_s", "", True),
        ("First frame (ms)", "first_frame_ms", "", True),
    ]

    for load_level in loads:
        gl = summarise(runs, load_level, "opengl")
        sub = summarise(runs, load_level, "subsurface")
        shapes = next(r["shapes"] for r in runs if r["load"] == load_level)
        n_runs = (gl or sub or {}).get("runs", 0)
        print()
        print(f"=== load: {load_level} ({shapes} shapes, {n_runs} runs each) ===")
        print(f"{'metric':<22}{'gtk opengl':>12}{'subsurface':>12}{'change':>12}")
        for title, key, suffix, lower_better in metrics:
            gl_value = gl.get(key) if gl else None
            sub_value = sub.get(key) if sub else None
            change = delta(sub_value, gl_value)
            if change is None:
                change_text = "n/a"
            else:
                better = (change < 0) if lower_better else (change > 0)
                marker = "better" if better else "worse"
                if abs(change) < 1:
                    marker = "same"
                change_text = f"{change:+.1f}% {marker}"
            print(
                f"{title:<22}{fmt(gl_value, suffix, 12)}{fmt(sub_value, suffix, 12)}"
                f"{change_text:>18}"
            )

    print()
    print("Lower is better for all metrics except effective FPS.")
    print("Values are medians across repetitions; runs alternated renderer order.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
