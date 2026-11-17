#!/bin/bash
# Measures scroll hitches in the chat list with the control server's
# `scrollChat`, against a scratch instance seeded with a copy of a transcript.
#
# Usage:
#   scripts/debug/measure-chat-scroll.sh <transcript.jsonl> [passes=3] [speed=4000]
#   EXTRA_ENV="A=1 B=2" ...   # extra environment for the app
#   DISTANCE=30000 ...        # scroll this many points per pass instead of to the ends
#   KEEP=1 ...                # leave the app running afterwards
#   CLOCK=<auto|timer> ...    # scrollChat's frame clock; default timer (repeatable)
#
# Prints one compact JSON result per line, prefixed `up <n>` or `down <n>`.
# Each pass's maxSeconds follows from its distance and the speed; a pass that
# still times out prints a warning, and the script exits 3 after the last.
# Build the Debug app first. docs/control-server.md ("Measuring a scroll")
# explains the fields.
set -euo pipefail

if [ $# -lt 1 ]; then
  sed -n '2,16p' "$0" >&2
  exit 2
fi
TRANSCRIPT="$1"
PASSES="${2:-3}"
SPEED="${3:-4000}"
CLOCK="${CLOCK:-timer}"
[ -f "$TRANSCRIPT" ] || { echo "no transcript at $TRANSCRIPT" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTROL="$ROOT/scripts/debug/plume-control.py"
PRODUCTS="$(cd "$ROOT" && xcodebuild -scheme Plume -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3}')"
APP="$PRODUCTS/Plume.app"
[ -d "$APP" ] || { echo "no Debug build at $APP; build first" >&2; exit 1; }

SCRATCH="$(mktemp -d)"
SOCKET="/tmp/plume-scroll-$$.sock"
PID=""
cp "$TRANSCRIPT" "$SCRATCH/transcript.jsonl"

cleanup() {
  if [ "${KEEP:-0}" = "1" ] && [ -n "$PID" ]; then
    echo "left running: pid $PID, socket $SOCKET, scratch $SCRATCH" >&2
    return
  fi
  if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; fi
  rm -rf "$SCRATCH"
  rm -f "$SOCKET"
}
trap cleanup EXIT

ENV_ARGS=(
  --env "PLUME_APP_SUPPORT=$SCRATCH/support"
  --env "PLUME_CONTROL_SOCKET=$SOCKET"
  --env "PLUME_SEED_TASKS=1"
  --env "PLUME_SEED_TRANSCRIPT_PATH=$SCRATCH/transcript.jsonl"
)
for pair in ${EXTRA_ENV:-}; do
  ENV_ARGS+=(--env "$pair")
done

BEFORE="$(pgrep -f "^$APP/Contents/MacOS/Plume" || true)"
# No -j: a hidden window has no display link.
env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDECODE open -g -n "${ENV_ARGS[@]}" "$APP"
for _ in $(seq 1 50); do
  for candidate in $(pgrep -f "^$APP/Contents/MacOS/Plume" || true); do
    if ! grep -qx "$candidate" <<<"$BEFORE"; then PID="$candidate"; fi
  done
  [ -n "$PID" ] && break
  sleep 0.2
done
[ -n "$PID" ] || { echo "the app did not start" >&2; exit 1; }
echo "pid $PID, socket $SOCKET" >&2

c() { "$CONTROL" --socket "$SOCKET" "$@"; }
c --wait 60 tasks >/dev/null

# A large transcript takes a while to parse before the list has rows.
deadline=$((SECONDS + 180))
until c readText target='{"kind":"chatList"}' 2>/dev/null \
  | python3 -c 'import json, sys; sys.exit(0 if json.load(sys.stdin)["result"].get("rows") else 1)' 2>/dev/null; do
  if [ $SECONDS -ge $deadline ]; then
    echo "the chat list showed no rows within 180 s" >&2
    exit 1
  fi
  sleep 1
done
sleep 3

TIMED_OUT=0
# Prints the result and records a timeout, since a truncated pass reads like
# a short, smooth one.
compact() {
  local line
  line="$(python3 -c '
import json, sys
response = json.load(sys.stdin)
result = response.get("result", response)
print(sys.argv[1], json.dumps(result, separators=(",", ":")))
if result.get("timedOut"):
    seconds = result.get("durationMs", 0) / 1000
    print(f"warning: {sys.argv[1]} timed out after {seconds:.1f} s, short of its destination", file=sys.stderr)
    sys.exit(3)
' "$1")" || TIMED_OUT=1
  echo "$line"
}

# The list opens at the bottom, so its offset is the whole scrollable height.
# Rows that measure taller than their estimates grow it, hence the slack.
if [ -n "${DISTANCE:-}" ]; then
  SPAN="$DISTANCE"
else
  SPAN="$(c scrollChat by=0 settle=0 worst=0 | python3 -c 'import json, sys; print(json.load(sys.stdin)["result"]["startOffset"])')"
fi
MAX_SECONDS="$(python3 -c 'import sys; print(min(300, round(abs(float(sys.argv[1])) / float(sys.argv[2]) * 2 + 10, 1)))' "$SPAN" "$SPEED")"
echo "maxSeconds $MAX_SECONDS per pass" >&2

# Not a pipeline, so `compact` runs in this shell and its TIMED_OUT sticks.
run_pass() {
  local label="$1" result
  shift
  result="$(c scrollChat "$@" speed="$SPEED" worst=8 clock="$CLOCK" maxSeconds="$MAX_SECONDS")"
  compact "$label" <<<"$result"
}

for pass in $(seq 1 "$PASSES"); do
  if [ -n "${DISTANCE:-}" ]; then
    run_pass "up $pass" by="-$DISTANCE"
    run_pass "down $pass" by="$DISTANCE"
  else
    run_pass "up $pass" to=top
    run_pass "down $pass" to=bottom
  fi
done

if [ "${KEEP:-0}" = "1" ]; then
  echo "KEEP=1: pid $PID, socket $SOCKET" >&2
fi
if [ "$TIMED_OUT" = "1" ]; then
  echo "at least one pass timed out; its numbers cover only part of the scroll" >&2
  exit 3
fi
