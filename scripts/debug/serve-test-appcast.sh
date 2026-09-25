#!/bin/bash
# Serves a local Sparkle appcast pointing at a version-bumped copy of the
# built Debug app, so both update paths — the installer swap and the
# scheduled background check — are testable without cutting a real release.
#
# Usage:
#   scripts/debug/serve-test-appcast.sh [version] [build]
#   scripts/debug/serve-test-appcast.sh 1.2.3 42
#
# version defaults to 99.0.0, build to 9999. PORT overrides the default 8765.
# OLDER_RELEASES adds notes sections for releases between the running build
# and the update, as space-separated version:build pairs (default
# "98.0.0:9998"; set it empty for none). The notes also get a section for the
# running build itself, which both Sparkle and Plume should hide.
#
# Requires a Debug build already on disk
# (xcodebuild -scheme Plume -destination 'platform=macOS' build) and the
# Sparkle EdDSA private key in 1Password, read via `op` — never written to
# disk or the keychain.
#
# What it does:
#   1. Copies the built Debug Plume.app to a temp dir and bumps its
#      CFBundleVersion/CFBundleShortVersionString.
#   2. Re-signs the copy with the same identity the original carries.
#   3. Zips it, signs the zip with sign_update, and writes an appcast.xml
#      whose enclosure points at the zip.
#   4. Points the Debug build's PlumeUpdateFeedURLOverride default at that
#      appcast, and serves the temp dir over http://localhost:$PORT.
#
# Launch the Debug build and use Settings ▸ Debug — "Check in
# Background Now", or wait for Sparkle's own scheduled check. Installing the
# update replaces the DerivedData Debug app with this bumped copy; rebuild to
# restore the real one.
#
# Ctrl-C (or any exit) removes the temp dir and deletes the feed override
# default, so a plain debug launch afterward goes back to not starting the
# updater at all.
set -euo pipefail

VERSION="${1:-99.0.0}"
BUILD="${2:-9999}"
PORT="${PORT:-8765}"
OLDER_RELEASES="${OLDER_RELEASES-98.0.0:9998}"
BUNDLE_ID="com.ryanmoelter.Plume.debug"
FEED_KEY="PlumeUpdateFeedURLOverride"

# The EdDSA private key used to sign updates for Sparkle's appcast. Lives in
# 1Password, never in the keychain and never on disk — read on stdin only.
SPARKLE_KEY_REF="${SPARKLE_KEY_REF:-op://Plume/Plume Sparkle EdDSA/private key}"

fail() { echo "FAILED: $*" >&2; exit 1; }

# shellcheck source=../lib/cumulative-notes.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/cumulative-notes.sh"

# A "]]>" inside the notes would close the CDATA section early, so split any
# occurrence across two sections — the standard CDATA-escaping trick.
cdata_escape() { sed 's/]]>/]]]]><![CDATA[>/g'; }

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# --- 1. preflight -------------------------------------------------------

command -v op >/dev/null || fail "op (1Password CLI) missing — brew install 1password-cli"
op read "$SPARKLE_KEY_REF" >/dev/null \
  || fail "could not read Sparkle EdDSA key from $SPARKLE_KEY_REF — check 1Password access
  and SPARKLE_KEY_REF"

echo "--- locating the Debug build ---"
SRC="$(xcodebuild -scheme Plume -configuration Debug -destination 'platform=macOS' \
  -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3; exit}')/Plume.app"
[ -d "$SRC" ] || fail "no Debug bundle at $SRC — build Debug first:
  xcodebuild -scheme Plume -destination 'platform=macOS' build"
echo "app: $SRC"

# sign_update ships inside the Sparkle SwiftPM package, which SPM resolves
# into DerivedData rather than the app bundle. BUILD_DIR is
# <DerivedData>/Build/Products; the resolved packages live two levels up, in
# <DerivedData>/SourcePackages.
BUILD_DIR="$(xcodebuild -scheme Plume -configuration Debug -destination 'platform=macOS' \
  -showBuildSettings 2>/dev/null | awk '$1 == "BUILD_DIR" {print $3; exit}')"
[ -n "$BUILD_DIR" ] || fail "could not read BUILD_DIR from xcodebuild"
SOURCE_PACKAGES_DIR="$(cd "$BUILD_DIR/../.." && pwd)/SourcePackages"
SIGN_UPDATE="$SOURCE_PACKAGES_DIR/artifacts/sparkle/Sparkle/bin/sign_update"
if [ ! -x "$SIGN_UPDATE" ]; then
  SIGN_UPDATE="$(find "$SOURCE_PACKAGES_DIR/artifacts" -type f -name sign_update \
    -path '*/bin/sign_update' 2>/dev/null | head -1)"
fi
[ -n "$SIGN_UPDATE" ] && [ -x "$SIGN_UPDATE" ] || fail "sign_update not found under
  $SOURCE_PACKAGES_DIR/artifacts — build Debug first so SPM resolves the Sparkle package"
echo "sign_update: $SIGN_UPDATE"

IDENTITY="$(codesign -dvv "$SRC" 2>&1 | sed -n 's/^Authority=\(.*\)$/\1/p' | head -1)"
[ -n "$IDENTITY" ] || fail "could not read a signing identity from $SRC"
echo "identity: $IDENTITY"

# --- 2. stage a version-bumped, re-signed copy ---------------------------

TMP="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP"
  defaults delete "$BUNDLE_ID" "$FEED_KEY" >/dev/null 2>&1 || true
  echo "cleaned up: removed $TMP, cleared $FEED_KEY"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

APP="$TMP/Plume.app"
cp -R "$SRC" "$APP" || fail "could not stage the bundle"

echo "--- bumping version to $VERSION ($BUILD) ---"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

# Only the outer bundle needs re-signing. Sparkle.framework and the sleep
# helper are untouched by the plist edit above, and nested code is sealed by
# reference to its own already-valid signature rather than by content hash —
# codesign --verify --deep --strict below confirms that holds, so --deep on
# the signing step itself would only re-sign content that's already correct.
echo "--- re-signing ---"
codesign --force --sign "$IDENTITY" --options runtime "$APP" \
  || fail "codesign of the staged app failed"
codesign --verify --strict "$APP" || fail "signature does not verify"
codesign --verify --deep --strict "$APP" || fail "nested signatures do not verify"

# --- 3. zip, sign the update, and build the appcast -----------------------

ZIP="$TMP/Plume-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP" || fail "ditto failed"

echo "--- signing update for Sparkle ---"
sign_output="$(op read "$SPARKLE_KEY_REF" | "$SIGN_UPDATE" --ed-key-file - "$ZIP")" \
  || fail "sign_update failed"
sig_line="$(grep '^sparkle:edSignature=' <<<"$sign_output")"
[ -n "$sig_line" ] || fail "sign_update produced no signature: $sign_output"
ED_SIGNATURE="$(sed -n 's/^sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$sig_line")"
ZIP_LENGTH="$(sed -n 's/.* length="\([0-9]*\)".*/\1/p' <<<"$sig_line")"
[ -n "$ED_SIGNATURE" ] && [ -n "$ZIP_LENGTH" ] \
  || fail "could not parse sign_update output: $sig_line"

MIN_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
  "$APP/Contents/Info.plist" 2>/dev/null)"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-26.2}"
PUB_DATE="$(LC_ALL=C date -u +'%a, %d %b %Y %H:%M:%S %z')"
ENCLOSURE_URL="http://localhost:$PORT/$(basename "$ZIP")"
APPCAST="$TMP/appcast.xml"

HOST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SRC/Contents/Info.plist")"
HOST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Contents/Info.plist")"

# A synthetic CHANGELOG.md, run through the same path a real release takes.
test_section() {
  cat <<NOTES

## $1 ($2)

This is **local test build $1** served by \`scripts/debug/serve-test-appcast.sh\`.
- Not a real release — the version and build number are made up.
- Confirms Sparkle can find, verify, and install an update end to end.
NOTES
}
CHANGELOG="$TMP/CHANGELOG.md"
{
  printf '# Changelog\n'
  test_section "$VERSION" "$BUILD"
  for release in $OLDER_RELEASES; do
    test_section "${release%%:*}" "${release##*:}"
  done
  test_section "$HOST_VERSION" "$HOST_BUILD"
} >"$CHANGELOG"

mkdir -p "$TMP/notes"
DESCRIPTION_FILE="$TMP/appcast-notes.html"
cumulative_notes "$CHANGELOG" "$TMP/notes" >"$DESCRIPTION_FILE" \
  || fail "could not build the appcast notes"

echo "--- building appcast ---"
{
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>'
  printf '%s\n' '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
  printf '  <channel>\n'
  printf '    <title>Plume</title>\n'
  printf '    <item>\n'
  printf '      <title>%s</title>\n' "$(xml_escape <<<"Plume $VERSION (test)")"
  printf '      <pubDate>%s</pubDate>\n' "$PUB_DATE"
  printf '      <sparkle:version>%s</sparkle:version>\n' "$BUILD"
  printf '      <sparkle:shortVersionString>%s</sparkle:shortVersionString>\n' "$VERSION"
  printf '      <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>\n' "$MIN_SYSTEM_VERSION"
  printf '      <description sparkle:format="html"><![CDATA[\n'
  cdata_escape <"$DESCRIPTION_FILE"
  printf '\n]]></description>\n'
  printf '      <enclosure url="%s" sparkle:edSignature="%s" length="%s" type="application/octet-stream" />\n' \
    "$(xml_escape <<<"$ENCLOSURE_URL")" "$ED_SIGNATURE" "$ZIP_LENGTH"
  printf '    </item>\n'
  printf '  </channel>\n'
  printf '</rss>\n'
} >"$APPCAST"
[ -s "$APPCAST" ] || fail "appcast.xml was not written"

# --- 4. point the Debug build at it, and serve -----------------------------

defaults write "$BUNDLE_ID" "$FEED_KEY" "http://localhost:$PORT/appcast.xml"

echo
echo "=== serving on http://localhost:$PORT ==="
echo "appcast: http://localhost:$PORT/appcast.xml"
echo "update:  $ENCLOSURE_URL"
echo
echo "Launch the Debug build, then Settings ▸ Debug:"
echo "  - \"Check in Background Now\" exercises the scheduled/gentle path."
echo "  - Or wait for Sparkle's own scheduled check."
echo
echo "Installing the update replaces the DerivedData Debug app"
echo "  ($SRC)"
echo "with this bumped copy ($VERSION build $BUILD). Rebuild to restore it."
echo
echo "Ctrl-C to stop and clean up."
echo

cd "$TMP"
python3 -m http.server "$PORT"
