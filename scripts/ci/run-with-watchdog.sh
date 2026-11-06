#!/bin/bash
# Runs a command, and if it is still running after $WATCHDOG_MINUTES, saves a
# screenshot, the process tree and samples of the test processes to
# $DIAGNOSTICS_DIR before killing it. CI uses it so a hung test run leaves
# evidence instead of a bare timeout.
set -u
minutes=${WATCHDOG_MINUTES:-25}
out=${DIAGNOSTICS_DIR:-.build/diagnostics}/${WATCHDOG_LABEL:-run}
mkdir -p "$out"

"$@" &
pid=$!
deadline=$(( $(date +%s) + minutes * 60 ))
while kill -0 "$pid" 2>/dev/null; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "::error::Still running after $minutes minutes; saving diagnostics and stopping"
    screencapture -x "$out/screen.png" 2>"$out/screencapture.err" || true
    ps -axo pid,ppid,etime,%cpu,stat,command > "$out/ps.txt"
    for p in $(pgrep -f 'Plume.app/Contents/MacOS/Plume|xctest|testmanagerd|xcodebuild'); do
      sample "$p" 5 -file "$out/sample-$p.txt" >/dev/null 2>&1 || true
    done
    /usr/bin/log show --last 10m --style compact \
      --predicate 'process == "Plume" OR subsystem == "com.ryanmoelter.Plume" OR process == "testmanagerd" OR process == "tccd"' \
      > "$out/log.txt" 2>&1 || true
    grep -E 'Plume|xctest|testmanagerd' "$out/ps.txt" || true
    for f in "$out"/sample-*.txt; do
      [ -f "$f" ] || continue
      echo "::group::$(basename "$f")"; sed '/^Binary Images:/,$d' "$f"; echo "::endgroup::"
    done
    echo "::group::log"; grep -v tccd "$out/log.txt" | tail -300; echo "::endgroup::"
    kill -TERM "$pid" 2>/dev/null; sleep 10; kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    exit 124
  fi
  sleep 15
done
wait "$pid"
