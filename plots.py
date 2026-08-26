#!/usr/bin/env python3
"""Generates the charts used in README.md.

Writes SVG into docs/. Run after changing the data:

    python3 plots.py
"""

import json
import pathlib
import statistics
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

GL = "#8c8c8c"
SUB = "#0553b1"
GL_LABEL = "GTK OpenGL"
SUB_LABEL = "Subsurface"

OUT_DIR = pathlib.Path("docs")
LOADS = ["light", "medium", "heavy"]
SHAPES = {"light": 200, "medium": 3000, "heavy": 6000}


def load_runs(results_dir):
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


def pick(runs, load, renderer):
    return [r for r in runs if r["load"] == load and r["renderer"] == renderer]


def style(ax):
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.grid(axis="y", color="#e6e6e6", linewidth=0.8)
    ax.set_axisbelow(True)


def save(fig, name):
    OUT_DIR.mkdir(exist_ok=True)
    path = OUT_DIR / name
    fig.savefig(path, format="svg", bbox_inches="tight", transparent=False)
    plt.close(fig)
    print(f"wrote {path}")


def plot_frame_trace(runs):
    """The single clearest picture: consecutive frame times at heavy load."""
    fig, ax = plt.subplots(figsize=(9, 3.6))

    for renderer, colour, label, width in (
        ("opengl", GL, GL_LABEL, 1.2),
        ("subsurface", SUB, SUB_LABEL, 1.6),
    ):
        samples = pick(runs, "heavy", renderer)[0]["raster_samples"][:120]
        ax.plot([s / 1000 for s in samples], color=colour, label=label,
                linewidth=width)

    ax.set_title("Raster time per frame, heavy load (6000 shapes)\n"
                 "Both average ~31.5fps -- one delivers it evenly",
                 fontsize=11, loc="left")
    ax.set_xlabel("frame")
    ax.set_ylabel("raster time (ms)")
    ax.set_ylim(bottom=0)
    ax.legend(frameon=False, ncol=2)
    style(ax)
    save(fig, "frame-trace.svg")


def plot_jitter(runs):
    """Frame-time standard deviation: lower means smoother."""
    fig, ax = plt.subplots(figsize=(7, 3.8))

    x = range(len(LOADS))
    bar = 0.36

    def stddevs(renderer):
        out = []
        for load in LOADS:
            per_run = [
                statistics.pstdev(r["total_span_samples"]) / 1000
                for r in pick(runs, load, renderer)
            ]
            out.append(statistics.median(per_run))
        return out

    gl_vals = stddevs("opengl")
    sub_vals = stddevs("subsurface")

    ax.bar([i - bar / 2 for i in x], gl_vals, bar, label=GL_LABEL, color=GL)
    ax.bar([i + bar / 2 for i in x], sub_vals, bar, label=SUB_LABEL, color=SUB)

    for i, (g, s) in enumerate(zip(gl_vals, sub_vals)):
        change = (s - g) / g * 100
        ax.text(i + bar / 2, s, f" {change:+.0f}%", ha="center",
                va="bottom", fontsize=9,
                color=SUB if change < 0 else "#b00020")

    ax.set_title("Frame time variability (lower is smoother)",
                 fontsize=11, loc="left")
    ax.set_ylabel("frame time std deviation (ms)")
    ax.set_xticks(list(x))
    ax.set_xticklabels([f"{l}\n{SHAPES[l]} shapes" for l in LOADS])
    ax.legend(frameon=False)
    style(ax)
    save(fig, "jitter.svg")


def plot_thread_cpu():
    """Where CPU time is spent: main thread vs raster thread."""
    ticks_per_sec = 100
    totals = {}
    for renderer in ("opengl", "subsurface"):
        main, raster = [], []
        for path in sorted(pathlib.Path("thread_cpu").glob(f"{renderer}_*.threads")):
            per_thread = {}
            for line in path.read_text().splitlines():
                parts = line.rsplit(" ", 1)
                if len(parts) != 2:
                    continue
                per_thread[parts[0]] = per_thread.get(parts[0], 0) + int(parts[1])
            # The platform thread is the process's own main thread; its comm is
            # the (truncated) executable name rather than a Flutter thread name.
            main.append(sum(v for k, v in per_thread.items()
                            if k.startswith("subsurface_benc")) / ticks_per_sec)
            raster.append(sum(v for k, v in per_thread.items()
                              if k.startswith("io.flutter.rast")) / ticks_per_sec)
        totals[renderer] = (statistics.median(main), statistics.median(raster))

    fig, ax = plt.subplots(figsize=(7, 3.4))
    # Reversed so GTK OpenGL reads on top, matching the other charts.
    labels = [SUB_LABEL, GL_LABEL]
    main_vals = [totals["subsurface"][0], totals["opengl"][0]]
    raster_vals = [totals["subsurface"][1], totals["opengl"][1]]

    ax.barh(labels, main_vals, 0.5, label="main thread", color="#f2a900")
    ax.barh(labels, raster_vals, 0.5, left=main_vals, label="raster thread",
            color=SUB)

    for i, (m, r) in enumerate(zip(main_vals, raster_vals)):
        ax.text(m / 2, i, f"{m:.1f}s", ha="center", va="center", fontsize=9)
        ax.text(m + r / 2, i, f"{r:.1f}s", ha="center", va="center",
                fontsize=9, color="white")

    ax.set_title("CPU time on the two busiest threads, medium load\n"
                 "Roughly 19% less work on the main thread",
                 fontsize=11, loc="left")
    ax.set_xlabel("CPU seconds")
    ax.set_xlim(0, max(m + r for m, r in zip(main_vals, raster_vals)) * 1.12)
    ax.legend(frameon=False, ncol=2, loc="upper center",
              bbox_to_anchor=(0.5, -0.28))
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.grid(axis="x", color="#e6e6e6", linewidth=0.8)
    ax.set_axisbelow(True)
    save(fig, "thread-cpu.svg")


def plot_distribution(runs):
    """Frame time distributions at medium load, where the difference matters."""
    fig, ax = plt.subplots(figsize=(7, 3.6))

    for renderer, colour, label in (("opengl", GL, GL_LABEL),
                                    ("subsurface", SUB, SUB_LABEL)):
        samples = []
        for r in pick(runs, "medium", renderer):
            samples.extend(s / 1000 for s in r["total_span_samples"])
        ax.hist(samples, bins=70, range=(8, 32), histtype="stepfilled",
                color=colour, alpha=0.25)
        ax.hist(samples, bins=70, range=(8, 32), histtype="step",
                color=colour, linewidth=1.6, label=label)

    ax.set_title("Frame time distribution, medium load (3000 shapes)\n"
                 "Subsurface is narrower and more predictable",
                 fontsize=11, loc="left")
    ax.set_xlabel("frame time (ms)")
    ax.set_ylabel("frames")
    ax.legend(frameon=False)
    style(ax)
    save(fig, "distribution.svg")


def main():
    results = sys.argv[1] if len(sys.argv) > 1 else "results"
    runs = load_runs(results)
    if not runs:
        print(f"No results found in {results}")
        return 1

    plot_frame_trace(runs)
    plot_jitter(runs)
    plot_distribution(runs)
    plot_thread_cpu()
    return 0


if __name__ == "__main__":
    sys.exit(main())
