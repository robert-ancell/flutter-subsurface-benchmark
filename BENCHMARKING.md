# Running the benchmark

How to reproduce the measurements yourself. If you only want to re-derive the
numbers from the data already committed here, see
[Re-running the analysis](#re-running-the-analysis) — that needs no build at
all.

## Re-running the analysis

All raw data is committed, so every number in [REPORT.md](REPORT.md)
regenerates with nothing but Python:

```sh
python3 analyse.py results     # throughput, latency, CPU
python3 jitter.py  results     # smoothness / jitter
python3 analyse.py startup     # first-frame latency
python3 plots.py               # regenerate the charts in docs/
```

Each run's JSON keeps its full per-frame sample arrays, so you can re-slice the
data — different percentiles, windowed jitter, histograms — without re-running
anything.

## Re-running the benchmark

### 1. Patch and build the engine

The point of the patch is that **both renderers come from a single engine
build**, selected at runtime. Building two engines and comparing them would
introduce differences unrelated to the renderer.

```sh
cd path/to/flutter
git apply /path/to/renderer-override.patch
```

Then build an **optimized (profile)** engine, e.g.:

```sh
OUT=out/host_profile ./build.sh
```

Debug-unoptimized numbers are meaningless for this comparison.

### 2. Build the benchmark app against that engine

```sh
cd subsurface_bench
flutter build linux --profile \
  --local-engine-src-path path/to/flutter/engine/src \
  --local-engine host_profile \
  --local-engine-host host_profile
```

### 3. Run it

```sh
APP=subsurface_bench/build/linux/x64/profile/bundle/subsurface_bench

BENCH_SHAPES=200  BENCH_FRAMES=600 BENCH_LABEL=light  ./run_bench.sh $APP results 5 _light
BENCH_SHAPES=3000 BENCH_FRAMES=600 BENCH_LABEL=medium ./run_bench.sh $APP results 5 _medium
BENCH_SHAPES=6000 BENCH_FRAMES=300 BENCH_LABEL=heavy  ./run_bench.sh $APP results 5 _heavy

./thread_cpu.sh $APP thread_cpu 3
```

`run_bench.sh <app> <out-dir> <reps> <suffix>` alternates renderer order between
repetitions so thermal drift affects both equally. Keep that behaviour if you
modify it.

## Load levels

| Level | Shapes | Regime | What it tells you |
|---|---|---|---|
| light | 200 | vsync-bound | per-frame overhead |
| medium | 3000 | near the 60fps limit | behaviour under pressure |
| heavy | 6000 | raster-bound | raw throughput |

The medium level is the most informative: close enough to saturation that
scheduling differences show up, but not so far past it that everything is
GPU-limited.

If your GPU is faster or slower than the reference machine, adjust
`BENCH_SHAPES` so light sits comfortably at 60fps, medium hovers right at the
limit, and heavy is clearly below it.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `BENCH_SHAPES` | 3000 | Animated shapes per frame; the load knob. |
| `BENCH_FRAMES` | 600 | Frames measured after warmup. |
| `BENCH_WARMUP` | 180 | Warmup frames, discarded. |
| `BENCH_LABEL` | — | Label recorded in the JSON and window title. |
| `FLUTTER_LINUX_VIEW_RENDERER` | auto | `opengl` or `subsurface` (needs the patch). |

## Output format

Each run writes, into the output directory:

- `<renderer>_<label>_<rep>.json` — metrics plus full per-frame sample arrays
- `<renderer>_<label>_<rep>.meta.json` — CPU ticks, wall time, first-frame latency
- `<renderer>_<label>_<rep>.log` / `.err` — stdout and stderr

`thread_cpu.sh` writes `<renderer>_<rep>.threads`, one `name ticks` line per
thread.

## Test environment

The committed results were measured on:

- AMD Radeon 860M integrated GPU, Mesa 26.0.8
- 16 cores, 57 GB RAM
- Wayland session under Mutter, 2560x1440 at device pixel ratio 2
- Optimized (profile) engine build, Impeller OpenGLES backend

Results on discrete GPUs, other drivers or other compositors may well differ,
particularly the GPU-contention effect that drives the jitter improvement.
Reports from other hardware are welcome.
