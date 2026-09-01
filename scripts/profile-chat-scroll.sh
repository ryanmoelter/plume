#!/bin/bash
# Records an Instruments trace of the chat view while you scroll it.
#
# Usage:
#   scripts/profile-chat-scroll.sh [seconds]        # SwiftUI template (default)
#   TEMPLATE="Animation Hitches" scripts/profile-chat-scroll.sh 20
#
# Launch Plume yourself first, open a chat tab with a long transcript, then run
# this and scroll for the whole recording window. The trace lands in
# /tmp/plume-traces and the path is printed at the end — open it in Instruments
# or hand the path back to Claude.
set -euo pipefail

SECONDS_TO_RECORD="${1:-15}"
TEMPLATE="${TEMPLATE:-SwiftUI}"
OUT_DIR="/tmp/plume-traces"
mkdir -p "$OUT_DIR"
TRACE="$OUT_DIR/chat-scroll-$(date +%H%M%S).trace"

PID="$(pgrep -f 'Plume.app/Contents/MacOS/Plume' | head -1 || true)"
if [ -z "$PID" ]; then
  echo "Plume isn't running. Launch it, open a chat tab, then re-run this." >&2
  exit 1
fi

echo "Recording '$TEMPLATE' from pid $PID for ${SECONDS_TO_RECORD}s."
echo "==> Scroll the chat view continuously until this finishes."
sleep 2

xcrun xctrace record \
  --template "$TEMPLATE" \
  --attach "$PID" \
  --time-limit "${SECONDS_TO_RECORD}s" \
  --output "$TRACE" \
  >/dev/null 2>&1

echo "Trace: $TRACE"
echo "Open with:  open '$TRACE'"
