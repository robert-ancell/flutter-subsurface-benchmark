#!/usr/bin/env bash
# Measures per-thread CPU usage for each renderer.
#
# The GTK OpenGL path composites on the raster thread and blits to screen on
# the GTK main thread. The subsurface path does both on the raster thread. This
# script shows where the CPU time actually goes so the raster-time difference
# can be interpreted correctly.
set -u

APP="${1:?usage: thread_cpu.sh <app-binary> <out-dir> [reps]}"
OUT_DIR="${2:-thread_cpu}"
REPS="${3:-3}"
TICKS_PER_SEC=$(getconf CLK_TCK)

mkdir -p "$OUT_DIR"

sample_threads() {
  local pid="$1"
  for task in /proc/"$pid"/task/*; do
    [ -r "$task/stat" ] || continue
    local comm utime stime
    comm=$(sed -n 's/.*(\(.*\)).*/\1/p' "$task/stat" 2>/dev/null)
    read -r utime stime < <(
      sed 's/.*) //' "$task/stat" 2>/dev/null | awk '{print $12, $13}'
    )
    [ -n "${utime:-}" ] || continue
    echo "$comm $(( (utime + stime) ))"
  done
}

run_one() {
  local renderer="$1" rep="$2"
  local out="$OUT_DIR/${renderer}_${rep}"

  FLUTTER_LINUX_VIEW_RENDERER="$renderer" \
    BENCH_SHAPES="${BENCH_SHAPES:-3000}" \
    BENCH_FRAMES="${BENCH_FRAMES:-600}" \
    BENCH_WARMUP="${BENCH_WARMUP:-180}" \
    BENCH_LABEL="threadcpu-$renderer" \
    "$APP" >"$out.log" 2>"$out.err" &
  local pid=$!

  : >"$out.threads"
  while kill -0 "$pid" 2>/dev/null; do
    sample_threads "$pid" >"$out.threads.tmp" 2>/dev/null
    if [ -s "$out.threads.tmp" ]; then
      mv "$out.threads.tmp" "$out.threads"
    fi
    sleep 0.25
  done
  wait "$pid" 2>/dev/null
  rm -f "$out.threads.tmp"

  echo "== $renderer rep $rep =="
  awk -v tps="$TICKS_PER_SEC" \
    '{printf "  %-20s %6.2fs\n", $1, $2/tps}' "$out.threads" |
    sort -k2 -rn -t' '
}

for rep in $(seq 1 "$REPS"); do
  if [ $((rep % 2)) -eq 1 ]; then
    order="opengl subsurface"
  else
    order="subsurface opengl"
  fi
  for renderer in $order; do
    run_one "$renderer" "$rep"
  done
done
