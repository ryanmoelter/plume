#!/bin/bash
# Watches a running Plume for a pinned main thread: CPU at or above 90% for
# five consecutive seconds. Prints HANG with the hottest frames from `sample`,
# or OK with the peak CPU seen. Exit codes: 0 OK, 1 HANG, 2 not running,
# 3 the process exited during the watch.
#
# Usage: scripts/detect-chat-hang.sh [seconds] [pid]
set -uo pipefail

DURATION="${1:-40}"
PID="${2:-$(pgrep -f 'Plume.app/Contents/MacOS/Plume' | head -1)}"
THRESHOLD=90
NEEDED=5

if [ -z "$PID" ]; then
  echo "Plume isn't running." >&2
  exit 2
fi

peak=0
streak=0
for ((i = 0; i < DURATION; i++)); do
  cpu="$(ps -o %cpu= -p "$PID" | tr -d ' ')"
  if [ -z "$cpu" ]; then
    echo "EXITED: pid $PID is gone after ${i}s (peak ${peak}%)"
    exit 3
  fi
  cpu="${cpu%.*}"
  (( cpu > peak )) && peak=$cpu
  if (( cpu >= THRESHOLD )); then streak=$((streak + 1)); else streak=0; fi
  if (( streak >= NEEDED )); then
    echo "HANG: ${cpu}% CPU for ${NEEDED}s at t=${i}s (pid $PID)"
    echo "--- hottest SwiftUI/AppKit frames over a 3s sample ---"
    sample "$PID" 3 -mayDie 2>/dev/null \
      | grep -E 'SwiftUI|AppKit|Layout|Scroll|Plume' \
      | sed -E 's/^[ +!:|]*//; s/ \(in .*//' \
      | sort | uniq -c | sort -rn | head -30
    exit 1
  fi
  sleep 1
done
echo "OK: peak ${peak}% over ${DURATION}s (pid $PID)"
