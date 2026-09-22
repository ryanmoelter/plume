#!/bin/bash
# Installs the built Release bundle into /Applications, then verifies what
# landed: version, signature, notarization, the sleep helper, dylibs, and
# whether the store had to be moved aside. Reopening the app is left to you,
# except when the release was run from inside Plume and the session driving
# it needs the app back.
#
# Build and test first (docs/releasing.md step 2) — this only installs.
#
# Usage: scripts/install-release.sh
#
# The bundle is re-signed with Developer ID and notarized before it is
# installed. The sleep helper is a LaunchDaemon, and SMAppService only
# registers daemons out of a notarized app, so the local install has to go
# through Apple like a shared build does. Everything that can fail — the
# identity, the notary profile, the round trip — happens on a staged copy
# before the running app is touched, so a failure leaves the old install
# running.
#
# Releasing from a session hosted inside Plume is the case this exists for:
# quitting Plume kills the agent doing the release, so with PLUME set the
# script re-execs itself detached and returns immediately. Read the log for
# the outcome; the terminal that launched it is gone by then. Notarization
# reads the keychain, which can raise a Touch ID prompt — stay at the
# keyboard.
set -uo pipefail

LOG="${LOG:-/tmp/plume-install.log}"
NOTARY_PROFILE="${NOTARY_PROFILE:-plume-notary}"
DEST=/Applications/Plume.app
STAGE_DIR=/tmp/plume-install-stage
APP="$STAGE_DIR/Plume.app"
HELPER_NAME=PlumeSleepHelper
DAEMON_PLIST=com.ryanmoelter.Plume.SleepHelper.plist

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

fail() { echo "FAILED: $*"; exit 1; }

# --- 1. preflight -----------------------------------------------------------

SRC="$(xcodebuild -scheme Plume -configuration Release -destination 'platform=macOS' \
  -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3; exit}')/Plume.app"
[ -d "$SRC" ] || fail "no Release bundle at $SRC — build it first"

IDENTITY="$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
[ -n "$IDENTITY" ] || fail "no Developer ID Application identity. Xcode → Settings →
  Accounts → Manage Certificates → + → Developer ID Application."
echo "identity: $IDENTITY"

notary_check="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1)"
if [ $? -ne 0 ]; then
  echo "$notary_check"
  fail "could not read notary profile '$NOTARY_PROFILE' — see docs/releasing.md"
fi

# --- 2. stage, sign, notarize -----------------------------------------------

rm -rf "$STAGE_DIR"; mkdir -p "$STAGE_DIR"
cp -R "$SRC" "$APP" || fail "could not stage the bundle"

HELPER="$APP/Contents/MacOS/$HELPER_NAME"
[ -x "$HELPER" ] || fail "sleep helper missing at $HELPER"
[ -f "$APP/Contents/Library/LaunchDaemons/$DAEMON_PLIST" ] \
  || fail "daemon plist missing from Contents/Library/LaunchDaemons"

# Inside out: the outer signature seals the helper, so the helper goes first.
# Without --deep codesign leaves nested code alone, and notarization rejects
# a helper still carrying the build's Apple Development signature.
echo "--- re-signing ---"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$HELPER" \
  || fail "codesign of the helper failed"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP" \
  || fail "codesign of the app failed"
codesign -d --verbose=4 "$APP" 2>&1 | grep -iE 'Authority=|flags=|Timestamp='
codesign --verify --deep --strict "$APP" || fail "signature does not verify"

echo "--- notarizing (a few minutes) ---"
ZIP="$STAGE_DIR/Plume-submit.zip"
ditto -c -k --keepParent "$APP" "$ZIP" || fail "ditto failed"
submit_output="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
echo "$submit_output"
if ! grep -q "status: Accepted" <<<"$submit_output"; then
  id="$(sed -n 's/^ *id: \([0-9a-f-]*\).*/\1/p' <<<"$submit_output" | head -1)"
  [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"
  fail "notarization rejected"
fi
xcrun stapler staple "$APP" || fail "stapling failed"
rm -f "$ZIP"

# spctl's verdict is on stderr and its exit status is what matters.
assess_output="$(spctl -a -vvv --type execute "$APP" 2>&1)"; assess_status=$?
echo "$assess_output" | grep -iE 'accepted|rejected|source='
[ $assess_status -eq 0 ] || fail "spctl rejected the staged app"
grep -qi 'source=Notarized Developer ID' <<<"$assess_output" \
  || fail "accepted but not notarized — expected source=Notarized Developer ID"

# --- 3. replace the installed app -------------------------------------------

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
  fail "Plume still running: $(running_pids) — bundle NOT replaced"
fi
echo "installed Plume exited"

# Plume exiting does not guarantee its agents went with it. One that survives
# keeps writing its transcript, and the relaunched app resumes that same
# session — two writers on one file, forking it, each blind to the other's
# turns. Matched on the settings path Plume launches agents with, which no
# other `claude` carries.
agent_pids() {
  ps -Ao pid=,command= \
    | awk '/claude/ && index($0, "Application Support/Plume/hooks/settings.json") {print $1}'
}

for _ in $(seq 1 10); do
  [ -z "$(agent_pids)" ] && break
  sleep 1
done

if [ -n "$(agent_pids)" ]; then
  echo "agents outlived Plume, ending them: $(agent_pids | tr '\n' ' ')"
  for pid in $(agent_pids); do kill "$pid" 2>/dev/null || true; done
  sleep 2
  for pid in $(agent_pids); do kill -9 "$pid" 2>/dev/null || true; done
fi

if [ -n "$(agent_pids)" ]; then
  fail "agents still running: $(agent_pids | tr '\n' ' ') — bundle NOT replaced"
fi

# Replaced rather than merged, so a file dropped from the bundle doesn't survive.
if ! (rm -rf "$DEST" && cp -R "$APP" "$DEST"); then
  fail "copy failed"
fi
echo "copied $APP -> $DEST"
rm -rf "$STAGE_DIR"

# --- 4. verify what landed --------------------------------------------------

echo "--- version ---"
/usr/libexec/PlistBuddy -c Print "$DEST/Contents/Info.plist" \
  | grep -i 'CFBundleShortVersionString\|CFBundleVersion'
echo "--- codesign ---"
codesign --verify --deep --strict "$DEST" && echo "ok"
xcrun stapler validate "$DEST" | tail -1
echo "--- sleep helper ---"
codesign -d --verbose=2 "$DEST/Contents/MacOS/$HELPER_NAME" 2>&1 \
  | grep -iE '^Identifier=|Authority=Developer ID|flags='
/usr/libexec/PlistBuddy -c 'Print :BundleProgram' \
  "$DEST/Contents/Library/LaunchDaemons/$DAEMON_PLIST"
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

# Only relaunched when the release was run from inside Plume, where quitting
# the app killed the session driving it and reopening is what brings the
# conversation back. Otherwise the app is left for you to open yourself.
#
# `env -u` because whatever ran this script is inherited by the app and then
# by every terminal tab it spawns. A release driven by an agent would
# otherwise hand `CLAUDE_CODE_CHILD_SESSION` to each tab's `claude`, which
# reads it as a nested session and stops writing its transcript — the chat UI
# then has no source at all.
if [ -n "${PLUME:-}" ]; then
  env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDECODE open "$DEST"
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
else
  echo "--- not relaunched; open $DEST yourself ---"
fi

# A schema change meets the installed store for the first time here.
echo "--- store moved aside, or faults? (expect none) ---"
/usr/bin/log show --predicate 'subsystem == "com.ryanmoelter.Plume"' --last 2m --info 2>/dev/null \
  | grep -i 'store.*bak\|fault' || echo "none"

echo "=== done $(date) ==="
