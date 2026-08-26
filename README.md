# Flutter Linux subsurface renderer benchmark

Benchmarks the Wayland **subsurface** view renderer added to Flutter in
[#191389](https://github.com/flutter/flutter/pull/191389)
(`Add FlViewRendererSubsurface`) against the previous **GTK OpenGL** renderer.

Everything needed to reproduce the numbers is here: the benchmark app, the
runner scripts, the analysis scripts, and the complete raw per-frame data.

## Findings in one table

| | GTK OpenGL | Subsurface | |
|---|---|---|---|
| Frame rate (light / medium / heavy) | 60.0 / 58.0 / 31.4 fps | 60.0 / 59.9 / 31.5 fps | ~unchanged |
| Frame-time std dev (medium load) | 2,447us | 1,371us | **−44%** |
| Frame-time std dev (heavy load) | 10,405us | 4,995us | **−52%** |
| Raster std dev (heavy load) | 5,342us | 369us | **−93%** |
| Main-thread CPU | 8.89s | 7.18s | **−19%** |
| Total process CPU | 16.57s | 16.42s | −0.9% |
| First frame | 199ms | 205ms | ~unchanged |

**Throughput is unchanged; frame delivery becomes much more consistent under
load, and ~19% of CPU work moves off the GTK main thread onto the raster
thread.**

The clearest illustration — raster times for 30 consecutive frames at heavy
load, in milliseconds:

```
gtk opengl  30.2 31.0 18.8 19.0 32.7 29.0 31.3 26.3 24.6 21.2 20.3 26.6 31.0 ...
subsurface  31.4 31.9 31.6 31.2 31.5 31.1 31.2 31.1 31.1 31.6 31.3 31.0 31.4 ...
```

Both average ~31.5fps. One delivers it evenly, the other in lurches.

Full analysis, caveats and methodology: **[REPORT.md](REPORT.md)**.

## Always verify the window visually

`FrameTiming` only measures up to raster completion, so it **cannot tell you
whether frames actually reached the screen**. A renderer that composites
perfectly but fails to present will still report entirely healthy timings.

Check the window with your own eyes before trusting any renderer benchmark.
`weston_shot.sh` automates this on Wayland, where screenshotting is otherwise
awkward.

## Contents

| Path | What |
|---|---|
| `REPORT.md` | Full write-up: method, results, caveats, conclusions. |
| `analyse.py` | Throughput / latency / CPU summary. |
| `jitter.py` | Frame jitter (smoothness) summary. |
| `run_bench.sh` | A/B runner; alternates renderers, writes per-run JSON. |
| `thread_cpu.sh` | Per-thread CPU sampler (main vs raster split). |
| `weston_shot.sh` | Nested-weston screenshot capture. |
| `renderer-override.patch` | Engine patch enabling runtime renderer selection. |
| `results/` | 30 throughput runs (3 loads x 2 renderers x 5 reps). |
| `startup/` | 18 first-frame latency runs. |
| `thread_cpu/` | 6 per-thread CPU traces. |
| `shots/` | Screenshot of the benchmark app. |
| `subsurface_bench/` | The benchmark app. |
| `default_app/` | Stock `flutter create` app, used as a control. |

## Re-running the analysis

The raw data is committed, so every number in the report regenerates with no
build required:

```sh
python3 analyse.py results     # throughput, latency, CPU
python3 jitter.py  results     # smoothness / jitter
python3 analyse.py startup     # first-frame latency
```

Each run's JSON keeps its full per-frame sample arrays, so the data can be
re-sliced without re-running anything.

## Re-running the benchmark

Requires a local Flutter engine build. The two renderers are selected at runtime
from a single build, which keeps the comparison apples-to-apples:

```sh
cd path/to/flutter
git apply /path/to/renderer-override.patch
# build the engine, e.g. OUT=out/host_profile ./build.sh
```

Build the app against that engine, then:

```sh
APP=subsurface_bench/build/linux/x64/profile/bundle/subsurface_bench

BENCH_SHAPES=200  BENCH_FRAMES=600 BENCH_LABEL=light  ./run_bench.sh $APP results 5 _light
BENCH_SHAPES=3000 BENCH_FRAMES=600 BENCH_LABEL=medium ./run_bench.sh $APP results 5 _medium
BENCH_SHAPES=6000 BENCH_FRAMES=300 BENCH_LABEL=heavy  ./run_bench.sh $APP results 5 _heavy
./thread_cpu.sh $APP thread_cpu 3
```

### Gotchas

- `FLUTTER_LINUX_RENDERER` is a **pre-existing** engine variable (software vs
  OpenGL). The override patch deliberately uses `FLUTTER_LINUX_VIEW_RENDERER`
  to avoid the collision — reusing the former silently ignores your setting.
- Use a **profile/optimized** engine build. Debug-unopt numbers are meaningless.
- Runs alternate renderer order to cancel thermal drift; keep that if you edit
  the runner.
- Each run prints `FLUTTER_VIEW_RENDERER=...` so you can verify it actually used
  the renderer you asked for. Check this — a silent fallback invalidates the run.
- Screenshotting on Wayland is awkward: `grim` needs `wlr-screencopy` (neither
  Mutter nor Weston provide it) and GNOME's D-Bus screenshot returns
  `AccessDenied`. `weston_shot.sh` works around this with a nested
  `weston --debug --backend=wayland` plus `weston-screenshooter`.

## Test environment

The numbers here were measured on:

- AMD Radeon 860M integrated GPU, Mesa 26.0.8
- 16 cores, 57 GB RAM
- Wayland session under Mutter, 2560x1440 at device pixel ratio 2
- Optimized (profile) engine build, Impeller OpenGLES backend

Results on discrete GPUs, other drivers or other compositors may differ —
particularly the GPU contention effect that drives the jitter improvement.
Reports from other hardware are welcome.

## Interpreting the raster numbers

Raster times look *worse* for the subsurface renderer in the percentile tables.
That is relocated work, not extra work: the GTK path composites on the raster
thread and blits to screen on the main thread, while the subsurface path does
both on the raster thread. `FrameTiming`'s per-thread metrics stop being
comparable when an architecture moves work between threads — which is why this
repo measures per-thread and total process CPU as well.

## Licence

BSD-3-Clause, matching flutter/flutter. The app directories originate from
`flutter create` templates.
