#!/bin/bash
#
# Runs a command inside a nested headless weston and captures a screenshot with
# grim, which needs wlr-screencopy (Mutter does not provide it).
#
# Usage: weston_shot.sh <out.png> <settle-seconds> <command> [args...]

set -u

OUT="$1"
SETTLE="$2"
shift 2

SOCKET="weston-shot-$$"
WESTON_LOG="/tmp/$SOCKET.log"

weston --debug --backend=wayland --width=1280 --height=800 \
  --socket="$SOCKET" --idle-time=0 >"$WESTON_LOG" 2>&1 &
weston_pid=$!

# Wait for the nested compositor's socket to appear.
for _ in $(seq 1 40); do
  if [ -S "${XDG_RUNTIME_DIR}/$SOCKET" ]; then
    break
  fi
  sleep 0.25
done

if [ ! -S "${XDG_RUNTIME_DIR}/$SOCKET" ]; then
  echo "weston failed to start; log:" >&2
  cat "$WESTON_LOG" >&2
  /bin/kill "$weston_pid" 2>/dev/null
  exit 1
fi

WAYLAND_DISPLAY="$SOCKET" GDK_BACKEND=wayland "$@" \
  >"/tmp/$SOCKET.app.log" 2>&1 &
app_pid=$!

sleep "$SETTLE"

WAYLAND_DISPLAY="$SOCKET" weston-screenshooter && mv -f wayland-screenshot-*.png "$OUT" 2>/dev/null
shot_status=$?

/bin/kill "$app_pid" 2>/dev/null
wait "$app_pid" 2>/dev/null
/bin/kill "$weston_pid" 2>/dev/null
wait "$weston_pid" 2>/dev/null

echo "app log: /tmp/$SOCKET.app.log"
exit "$shot_status"
