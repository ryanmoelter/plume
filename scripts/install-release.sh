#!/bin/bash
# Installs the built Release bundle into /Applications and relaunches it,
# then verifies what landed: version, signature, dylibs, process tree, and
# whether the store had to be moved aside.
#
# Build and test first (docs/releasing.md step 2) — this only installs.
#
# Usage: scripts/install-release.sh
#
# Releasing from a session hosted inside Plume is the case this exists for:
# quitting Plume kills the agent doing the release, so with PLUME set the
# script re-execs itself detached and returns immediately. Read the log for
# the outcome; the terminal that launched it is gone by then.
set -uo pipefail

LOG="${LOG:-/tmp/plume-install.log}"
DEST=/Applications/Plume.app

# Detached because killing Plume kills whatever Plume is hosting. nohup so the
# PTY's SIGHUP doesn't take it too.
if [ -n "${PLUME:-}" ] && [ -z "${PLUME_INSTALL_DETACHED:-}" ]; then
  echo "Running inside Plume — installing detached."
  echo "Plume will quit and reopen. Log: $LOG"
  PLUME_INSTALL_DETACHED=1 LOG="$LOG" nohup "$0" "$@" >/dev/null 2>&1 &
  exit 0
fi

exec >>"$LOG" 2>&1
echo "=== $(date) installing ==="

SRC="$(xcodebuild -scheme Plume -configuration Release -destination 'platform=macOS' \
  -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3; exit}')/Plume.app"

if [ ! -d "$SRC" ]; then
  echo "FAILED: no Release bundle at $SRC — build it first"
  exit 1
fi

# ps, not pgrep: `pgrep -x Plume` has come back empty while the installed app
# was running, and matches unrelated test bundles instead.
running_pids() {
  ps -ef | awk -v d="$DEST" 'index($0, d "/Contents/MacOS/Plume") && !/awk/ {print $2}'
}

for pid in $(running_pids); do
  echo "quitting installed Plume $pid"
  kill "$pid"
done

for _ in $(seq 1 30); do
  [ -z "$(running_pids)" ] && break
  sleep 1
done

# Overwriting a live bundle corrupts the running process, so refuse instead.
if [ -n "$(running_pids)" ]; then
  echo "FAILED: Plume still running: $(running_pids) — bundle NOT replaced"
  exit 1
fi
echo "installed Plume exited"

# Replaced rather than merged, so a file dropped from the bundle doesn't survive.
if ! (rm -rf "$DEST" && cp -R "$SRC" "$DEST"); then
  echo "FAILED: copy failed"
  exit 1
fi
echo "copied $SRC -> $DEST"

echo "--- version ---"
/usr/libexec/PlistBuddy -c Print "$DEST/Contents/Info.plist" \
  | grep -i 'CFBundleShortVersionString\|CFBundleVersion'
echo "--- codesign ---"
codesign --verify --deep --strict "$DEST" && echo "ok"
echo "--- non-system dylibs (expect none; Release links Ghostty statically) ---"
otool -L "$DEST/Contents/MacOS/Plume" | grep -v '/usr/lib\|/System/Library'

# The symlink points at a path inside the bundle, so replacing the bundle
# re-resolves it. It only breaks if the helper stopped shipping.
echo "--- plume-notify on PATH ---"
if [ -L "$HOME/.local/bin/plume-notify" ]; then
  if [ -x "$HOME/.local/bin/plume-notify" ]; then
    echo "ok -> $(readlink "$HOME/.local/bin/plume-notify")"
  else
    echo "BROKEN -> $(readlink "$HOME/.local/bin/plume-notify") — reinstall from Settings"
  fi
else
  echo "not installed (Settings → Command Line)"
fi

open "$DEST"
sleep 20

PID="$(running_pids | head -1)"
echo "--- relaunched as PID ${PID:-NONE} ---"
if [ -n "${PID:-}" ]; then
  for child in $(pgrep -P "$PID"); do
    echo "child $child: $(ps -o comm= -p "$child")"
    for grandchild in $(pgrep -P "$child"); do
      echo "  grandchild $grandchild: $(ps -o comm= -p "$grandchild")"
    done
  done
fi

# A schema change meets the installed store for the first time here.
echo "--- store moved aside, or faults? (expect none) ---"
/usr/bin/log show --predicate 'subsystem == "com.ryanmoelter.Plume"' --last 2m --info 2>/dev/null \
  | grep -i 'store.*bak\|fault' || echo "none"

echo "=== done $(date) ==="
