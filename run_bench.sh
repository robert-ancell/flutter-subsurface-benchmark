#!/bin/bash
#
# Runs the subsurface benchmark app alternately under each Linux view renderer
# and stores one JSON result file per run.
#
# Usage: run_bench.sh <app-binary> <output-dir> <reps> [label-suffix]

set -u -o pipefail

APP="$1"
OUTDIR="$2"
REPS="${3:-5}"
SUFFIX="${4:-}"

mkdir -p "$OUTDIR"

TICKS_PER_SEC=$(getconf CLK_TCK)

cpu_ticks() {
  local pid="$1"
  if [ ! -r "/proc/$pid/stat" ]; then
    return
  fi
  # Fields 14/15 are utime/stime. Skip the comm field, which may contain spaces.
  awk '{ n = index($0, ") "); $0 = substr($0, n + 2); print $12 + $13 }' \
    "/proc/$pid/stat" 2>/dev/null
}

run_once() {
  local renderer="$1"
  local rep="$2"
  local out="$OUTDIR/${renderer}${SUFFIX}_$rep"

  local launch_us
  launch_us=$(( $(date +%s%N) / 1000 ))

  FLUTTER_LINUX_VIEW_RENDERER="$renderer" "$APP" >"$out.log" 2>"$out.err" &
  local pid=$!

  local cpu=0
  local last_cpu=0
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    last_cpu=$(cpu_ticks "$pid")
    if [ -n "$last_cpu" ]; then
      cpu="$last_cpu"
    fi
    sleep 0.25
    waited=$((waited + 1))
    if [ "$waited" -gt 960 ]; then
      echo "TIMEOUT: $renderer rep $rep" >&2
      kill "$pid" 2>/dev/null
      break
    fi
  done
  wait "$pid" 2>/dev/null

  local end_us
  end_us=$(( $(date +%s%N) / 1000 ))

  if ! grep -q '^BENCH_RESULT:' "$out.log"; then
    echo "$renderer rep $rep: NO RESULT (see $out.log / $out.err)" >&2
    return 1
  fi

  local first_frame_epoch
  first_frame_epoch=$(grep '^BENCH_FIRST_FRAME_EPOCH_US:' "$out.log" | head -1 |
    cut -d: -f2)
  local first_frame_latency=0
  if [ -n "$first_frame_epoch" ]; then
    first_frame_latency=$((first_frame_epoch - launch_us))
  fi

  grep '^BENCH_RESULT:' "$out.log" | sed 's/^BENCH_RESULT://' >"$out.json"
  cat >"$out.meta.json" <<EOF
{"renderer": "$renderer", "rep": $rep, "cpu_ticks": $cpu,
 "ticks_per_sec": $TICKS_PER_SEC, "wall_us": $((end_us - launch_us)),
 "first_frame_latency_us": $first_frame_latency}
EOF

  local selected
  selected=$(grep -o 'FLUTTER_VIEW_RENDERER=[a-z]*' "$out.err" | head -1)
  echo "$renderer rep $rep: ${selected:-unknown}" \
    "cpu=$(echo "$cpu $TICKS_PER_SEC" | awk '{printf "%.2fs", $1/$2}')" \
    "first_frame=$((first_frame_latency / 1000))ms"
}

for rep in $(seq 1 "$REPS"); do
  # Alternate the order so any thermal or scheduler drift affects both equally.
  if [ $((rep % 2)) -eq 1 ]; then
    run_once opengl "$rep"
    run_once subsurface "$rep"
  else
    run_once subsurface "$rep"
    run_once opengl "$rep"
  fi
done

echo "Done. Results in $OUTDIR"
