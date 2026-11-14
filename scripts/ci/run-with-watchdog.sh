#!/bin/bash
# Runs a command, and if it is still running after $WATCHDOG_MINUTES, saves a
# screenshot, the process tree and samples of the test processes to
# $DIAGNOSTICS_DIR before killing it. CI uses it so a hung test run leaves
# evidence instead of a bare timeout.
#
# $WATCHDOG_SAMPLE_AT, a list of seconds, also samples the test host at each of
# those points in a run that is still going, so a run that is only slow shows
# what its threads are waiting on.
set -u
minutes=${WATCHDOG_MINUTES:-25}
out=${DIAGNOSTICS_DIR:-.build/diagnostics}/${WATCHDOG_LABEL:-run}
mkdir -p "$out"

"$@" &
pid=$!
started=$(date +%s)
deadline=$(( started + minutes * 60 ))
pending_samples=${WATCHDOG_SAMPLE_AT:-}
while kill -0 "$pid" 2>/dev/null; do
  for at in $pending_samples; do
    [ $(( $(date +%s) - started )) -ge "$at" ] || continue
    pgrep -f 'Plume.app/Contents/MacOS/Plume' >/dev/null || { echo "no test host to sample at ${at}s"; }
    pending_samples=$(echo " $pending_samples " | sed "s/ $at / /")
    for host in $(pgrep -f 'Plume.app/Contents/MacOS/Plume'); do
      echo "::group::sample of $host at ${at}s"
      if sample "$host" 3 -file "$out/sample-at-$at.txt" >"$out/sample-at-$at.err" 2>&1; then
        sed '/^Binary Images:/,$d' "$out/sample-at-$at.txt"
      else
        cat "$out/sample-at-$at.err"
      fi
      echo "::endgroup::"
    done
  done
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
    # Everything the test host started, and which of them hold pipes, since
    # a child that keeps a pipe open is the usual reason a read never ends.
    descendants() { for c in $(pgrep -P "$1"); do echo "$c"; descendants "$c"; done; }
    for host in $(pgrep -f 'Plume.app/Contents/MacOS/Plume'); do
      echo "::group::children of $host"
      for c in $(descendants "$host"); do
        ps -o pid,ppid,etime,stat,command -p "$c" | tail -n +2
        lsof -p "$c" -a -d 0-20 2>/dev/null | tail -n +2
      done
      echo "::endgroup::"
      # A pipe's other end can be held by a process that is no longer a
      # descendant, once its parent exits and it is reparented to launchd.
      echo "::group::holders of $host's pipes"
      lsof -n -P > "$out/lsof.txt" 2>/dev/null
      lsof -n -P -p "$host" 2>/dev/null | grep PIPE
      for address in $(lsof -n -P -p "$host" 2>/dev/null | grep PIPE | grep -o '0x[0-9a-f]*' | sort -u); do
        awk -v a="$address" -v h="$host" '$2 != h && index($0, a)' "$out/lsof.txt"
      done | sort -u
      echo "::endgroup::"
    done
    echo "::group::processes that look related"
    grep -iE 'plume|git|xcrun' "$out/ps.txt" | grep -v grep
    echo "::endgroup::"
    for f in "$out"/sample-*.txt; do
      [ -f "$f" ] || continue
      echo "::group::$(basename "$f")"; sed '/^Binary Images:/,$d' "$f"; echo "::endgroup::"
    done
    echo "::group::log"; grep -v tccd "$out/log.txt" | tail -300; echo "::endgroup::"
    kill -TERM "$pid" 2>/dev/null; sleep 10; kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    exit 124
  fi
  sleep 5
done
wait "$pid"
