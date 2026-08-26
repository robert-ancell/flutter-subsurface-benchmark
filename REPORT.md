# Linux subsurface renderer — performance benchmark

Comparison of the new Wayland **subsurface** view renderer against the previous
**GTK OpenGL** view renderer, for the "notable Flutter commits" video.

Subsurface renderer added in `706edcdc32f` — *Add FlViewRendererSubsurface (#191389)*.

## Headline

**Frame throughput is unchanged, but frames get markedly more consistent:
40-90% less jitter under load. ~20% of CPU work also moves off the GTK main
thread onto the raster thread, where it belongs.**

## Method

One engine build, both renderers, selected at runtime by a temporary env var so
the comparison is apples-to-apples (that override has since been reverted).

- Host: AMD Radeon 860M iGPU, Mesa 26.0.8, 16 cores, 57 GB RAM
- Session: Wayland, Mutter, 2560x1440 @ DPR 2
- Engine: `out/host_profile` (optimized), Impeller OpenGLES backend
- App: animated shapes benchmark, `FrameTiming` percentiles over 600 frames
  after a 180-frame warmup
- 5 repetitions per renderer per load level, **alternating renderer order** to
  cancel thermal drift
- Every run's actual renderer selection was verified from its log; 0 mismatches

Three load levels:

| Level | Shapes | Regime |
|---|---|---|
| light | 200 | vsync-bound — measures per-frame overhead |
| medium | 3000 | near the 60fps limit |
| heavy | 6000 | raster-bound — measures raw throughput |

## Results

### Throughput — no change

| Load | GTK OpenGL | Subsurface | Change |
|---|---|---|---|
| light | 60.0 fps | 60.0 fps | same |
| medium | 58.0 fps | 59.9 fps | **+3.2%** |
| heavy | 31.4 fps | 31.5 fps | same |

Both renderers hit vsync at light load and are GPU-bound at heavy load, as
expected. The medium-load gain is the one interesting throughput result: at the
load level where the pipeline is closest to saturation, subsurface holds 60fps
where the GTK path drops frames, and 90th-percentile frame time improves 8%
(21.7ms → 20.0ms).

### Frame jitter — the clearest win

Percentiles say how *slow* frames are; jitter says how *inconsistent* they are,
which is what users actually perceive as stutter. This is where the subsurface
renderer separates itself.

Frame-total jitter (median across 5 runs):

| Load | Metric | GTK OpenGL | Subsurface | Change |
|---|---|---|---|---|
| medium | std deviation | 2,447us | 1,371us | **−44%** |
| medium | frame-to-frame | 3,247us | 1,341us | **−59%** |
| heavy | std deviation | 10,405us | 4,995us | **−52%** |
| heavy | frame-to-frame | 5,464us | 3,216us | **−41%** |
| light | std deviation | 394us | 508us | +29% |
| light | frame-to-frame | 328us | 465us | +42% |

Raster-thread jitter at heavy load is the standout:

| Metric | GTK OpenGL | Subsurface | Change |
|---|---|---|---|
| Std deviation | 5,342us | 369us | **−93%** |
| IQR (p75−p25) | 8,487us | 441us | **−95%** |
| Frame-to-frame | 2,404us | 383us | **−84%** |
| Frame-to-frame p99 | 13,771us | 1,801us | **−87%** |

That is not a statistical artifact — the raw per-frame traces show it plainly.
First 30 raster times at heavy load, in milliseconds:

```
gtk opengl  30.2 31.0 18.8 19.0 32.7 29.0 31.3 26.3 24.6 21.2 20.3 26.6 31.0 ...
subsurface  31.4 31.9 31.6 31.2 31.5 31.1 31.2 31.1 31.1 31.6 31.3 31.0 31.4 ...
```

GTK swings between 17.5ms and 32.7ms; subsurface sits at 31.1–31.9ms. Both
deliver the same ~31.5fps, but one does it evenly and the other does it in
lurches. The effect reproduced in every repetition (GTK std dev 4,962–5,514us
vs subsurface 321–832us — the ranges don't come close to overlapping).

The likely cause is the same architectural change: in the GTK path the raster
thread and the main thread contend for the GPU, since the main thread runs its
own render pass to blit the frame. That contention is what shows up as
variance. With subsurface the raster thread owns presentation end to end, so
each frame costs the same as the last.

**The exception is light load**, where subsurface is consistently *more* jittery
(std dev 508us vs 394us). The absolute numbers are tiny — roughly 3% of a
16.7ms frame budget, on frames that are already comfortably inside it — so this
is unlikely to be visible. But it's consistent across all 5 runs, not noise.

One metric to read carefully: "over 16.7ms" on frame *total* counts latency, not
dropped frames. Build and raster pipeline across frames, so end-to-end latency
can exceed the budget while the frame rate stays pinned at 60fps. That's why
subsurface shows 83.3% vs 66.2% at medium load while simultaneously delivering
a *higher* frame rate (59.9 vs 58.0 fps).

### Where the CPU time goes

Raster-thread times look *worse* for subsurface (+20–40% at p50). Taken alone
that reads like a regression. It isn't — it's relocated work.

In the GTK path the raster thread only *composites* into an FBO; the GTK main
thread later blits that FBO to the screen in its own render pass. In the
subsurface path the raster thread does composite + blit + `eglSwapBuffers` +
`wl_surface.commit` itself, and the main thread does nothing.

Per-thread CPU, medium load, median of 3 runs:

| Thread | GTK OpenGL | Subsurface | Change |
|---|---|---|---|
| **Main / platform** | 8.98s | 7.17s | **−20.2%** |
| Raster | 6.48s | 7.43s | +14.7% |
| **Whole process** | **19.65s** | **19.04s** | **−3.1%** |

Whole-process CPU barely moves. The main thread — which handles input and
window management, and sits on the latency-critical path — is **20% freer**.

This is confirmed independently by the light-load and startup numbers, where
subsurface uses measurably *less* total CPU (−14.2% and −10.9%) while producing
exactly the same 60fps. Lower CPU for identical output means the frame is
taking a shorter path to the screen, not a longer one.

Note that `eglSwapInterval` is set to 0 on the subsurface EGL surface, so the
raster-thread increase is genuine work being done, not vsync blocking.

### Startup — no change

9 runs each: first frame at **199.3ms** (GTK OpenGL) vs **204.6ms**
(subsurface) — within run-to-run noise. Startup CPU is 10.9% lower for
subsurface, consistently across all 9 runs.

## How to read the raster numbers

`FrameTiming`'s raster metric measures work on the raster thread only. When an
architecture moves work *between* threads, that metric moves with it and stops
being comparable across the two designs. Total process CPU and per-thread CPU
are the meaningful comparison here, and both show the same thing: near-identical
total cost, better distribution.


## Conclusions

The subsurface renderer was written for a cleaner architecture rather than for
speed, and the measurements are consistent with that:

- **Frame rate is unchanged.** This is not a throughput optimisation.
- **Smoothness improves substantially under load**: 44-52% less frame time
  variance at medium and heavy load, and 93% less raster variance at heavy
  load. This is the clearest user-visible benefit.
- **The main thread does ~20% less work**, which matters for input latency and
  UI responsiveness.
- **Whole-process CPU is essentially flat** (−3%), and lower under light and
  idle workloads.
- **The design is simpler**: Flutter owns its own Wayland surface and presents
  directly, rather than routing every frame through GTK's widget render pass
  and frame clock.

In short, the change does not make Flutter draw frames faster; it makes it draw
them more evenly, by no longer routing presentation through GTK.

## Reproducing

See [BENCHMARKING.md](BENCHMARKING.md). Raw data is in `results/` (throughput),
`startup/` (first frame) and `thread_cpu/` (per-thread).
