#!/bin/bash
# Packages a Release build for other Macs: Developer ID signature, notarization,
# a drag-to-install DMG, and a draft GitHub release with the DMG attached.
#
# This is the distribution path. scripts/install-release.sh is the local one and
# stays separate — it quits and replaces /Applications/Plume.app, which
# packaging must never do.
#
# The release is left as a DRAFT. Nothing is public until you publish it.
#
# One-time setup (see docs/releasing.md):
#   - a Developer ID Application certificate in the keychain
#   - xcrun notarytool store-credentials plume-notary ...
#   - brew install create-dmg
#
# Usage: scripts/package-release.sh
set -uo pipefail

LOG="${LOG:-/tmp/plume-package.log}"
NOTARY_PROFILE="${NOTARY_PROFILE:-plume-notary}"
OUT="${OUT:-$PWD/out}"

exec > >(tee -a "$LOG") 2>&1
echo "=== $(date) packaging ==="

fail() { echo "FAILED: $*"; exit 1; }

# --- 1. preflight -----------------------------------------------------------
# Every check here is a thing that otherwise fails much later with a worse
# message, after a multi-minute build or a notarization round trip.

IDENTITY="$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
if [ -z "$IDENTITY" ]; then
  fail "no Developer ID Application identity. Xcode → Settings → Accounts →
  Manage Certificates → + → Developer ID Application. An Apple Development
  identity cannot ship to other Macs."
fi
echo "identity: $IDENTITY"

# Reading the stored credential can raise a Touch ID prompt, which nobody
# answers if this is running detached — so the failure here is as often an
# unattended run as a missing profile. Notarization itself reads it again
# later, so stay at the keyboard for the whole run.
notary_check="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1)"
if [ $? -ne 0 ]; then
  echo "$notary_check"
  fail "could not read notary profile '$NOTARY_PROFILE'.
  If a Touch ID prompt appeared and timed out, run this in the foreground and
  stay at the keyboard. If the profile does not exist, create it with:
  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id <team> --password <app-specific>"
fi

command -v gh >/dev/null || fail "gh missing — brew install gh"
gh auth status >/dev/null 2>&1 || fail "gh not authenticated — gh auth login"

# A dirty tree means the artifact can't be traced back to a commit.
[ -z "$(git status --porcelain)" ] || fail "working tree dirty — commit or stash first"

# MARKETING_VERSION sorts before PRODUCT_BUNDLE_IDENTIFIER inside each config
# block, so buffer it and emit only when the block proves to be the app
# target's. The trailing semicolon rules out .debug and the test targets, which
# carry their own MARKETING_VERSION of 1.0.
VERSION="$(awk '
  /MARKETING_VERSION/ { v=$3; gsub(/;/,"",v) }
  /PRODUCT_BUNDLE_IDENTIFIER = com\.ryanmoelter\.Plume;/ { print v; exit }
' Plume.xcodeproj/project.pbxproj)"
[ -n "$VERSION" ] || fail "could not read MARKETING_VERSION"

TAG="v$VERSION"
DMG="$OUT/Plume-$VERSION.dmg"
echo "version: $VERSION  tag: $TAG"

git rev-parse "$TAG" >/dev/null 2>&1 \
  && echo "note: tag $TAG already exists" \
  || echo "note: tag $TAG does not exist yet — the script stops before the draft to let you make it"

rm -rf "$OUT"; mkdir -p "$OUT"

# --- 2. build ---------------------------------------------------------------
echo "--- building Release ---"
xcodebuild -scheme Plume -configuration Release -destination 'platform=macOS' \
  clean build || fail "build failed"

SRC="$(xcodebuild -scheme Plume -configuration Release -destination 'platform=macOS' \
  -showBuildSettings 2>/dev/null | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3; exit}')/Plume.app"
[ -d "$SRC" ] || fail "no Release bundle at $SRC"

APP="$OUT/Plume.app"
cp -R "$SRC" "$APP" || fail "could not stage the bundle"

# --- 3. re-sign with Developer ID -------------------------------------------
# The build signs with whatever automatic signing picked (an Apple Development
# identity), so re-sign over it. --timestamp is what the local install path
# lacks and notarization requires; --options runtime keeps the hardened runtime
# the build already enables.
echo "--- re-signing ---"
# Inside out: without --deep codesign leaves nested code alone, and the outer
# signature seals the helper, so the helper has to carry Developer ID first.
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
  "$APP/Contents/MacOS/PlumeSleepHelper" || fail "codesign of the helper failed"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP" \
  || fail "codesign failed"

codesign -d --verbose=4 "$APP" 2>&1 | grep -iE 'Authority=|flags=|Timestamp='
codesign --verify --deep --strict "$APP" || fail "signature does not verify"

# --- 4. notarize the app ----------------------------------------------------
# ditto, not zip: plain zip mangles bundle metadata. This zip only carries the
# app to Apple — the DMG is what ships.
echo "--- notarizing app (a few minutes) ---"
ZIP="$OUT/Plume-submit.zip"
ditto -c -k --keepParent "$APP" "$ZIP" || fail "ditto failed"

notarize() {
  local target="$1" label="$2" submit_output id
  submit_output="$(xcrun notarytool submit "$target" \
    --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
  echo "$submit_output"
  if ! grep -q "status: Accepted" <<<"$submit_output"; then
    # A bare "Invalid" says nothing actionable; the log names the offending file.
    id="$(sed -n 's/^ *id: \([0-9a-f-]*\).*/\1/p' <<<"$submit_output" | head -1)"
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"
    fail "$label notarization rejected"
  fi
}

notarize "$ZIP" "app"
xcrun stapler staple "$APP" || fail "stapling the app failed"
rm -f "$ZIP"

# --- 5. DMG -----------------------------------------------------------------
# hdiutil rather than create-dmg. create-dmg mounts a read-write image, styles
# the Finder window with AppleScript, ejects, then converts — and on macOS 26
# that conversion fails with "Resource temporarily unavailable", because the
# ejected image is left pointing at a backing store that no longer exists
# (CBSDBackingStore::newProbe stat() failed). The window it produces is nicer,
# but nothing recovers the intermediate once it is broken.
#
# The cost is an unstyled window: the app and an /Applications symlink, with no
# positioned icons. Dragging one onto the other still installs it.
echo "--- building DMG ---"
STAGE="$OUT/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Plume.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Plume $VERSION" -srcfolder "$STAGE" -ov -format UDZO \
  "$DMG" || fail "hdiutil could not create the DMG"

[ -f "$DMG" ] || fail "no DMG produced at $DMG"
rm -rf "$STAGE"

# hdiutil does not sign, so do it here — the DMG is notarized next and
# Gatekeeper evaluates its signature on download.
codesign --force --sign "$IDENTITY" --timestamp "$DMG" \
  || fail "could not sign the DMG"

# --- 6. notarize the DMG ----------------------------------------------------
# Separately from the app. Gatekeeper evaluates the downloaded DMG itself, so a
# stapled app inside an unnotarized DMG still warns on first open — and that
# failure is invisible on the machine that built it.
echo "--- notarizing DMG ---"
notarize "$DMG" "DMG"
xcrun stapler staple "$DMG" || fail "stapling the DMG failed"

# --- 7. verify --------------------------------------------------------------
# The only local checks that answer "will this launch on someone else's Mac".
echo "--- verifying ---"

# spctl's verdict is on stderr and its exit status is what matters, so capture
# once and report both rather than piping (a pipe would mask the status).
assess() {
  local label="$1"; shift
  local output status
  output="$(spctl -a -vvv "$@" 2>&1)"; status=$?
  echo "$output" | grep -iE 'accepted|rejected|source=|origin='
  [ $status -eq 0 ] || fail "spctl rejected the $label"
  grep -qi 'source=Notarized Developer ID' <<<"$output" \
    || fail "$label is accepted but not notarized — expected source=Notarized Developer ID"
}

assess "app" --type execute "$APP"
assess "DMG" --type open --context context:primary-signature "$DMG"

xcrun stapler validate "$APP" || fail "app ticket does not validate"
xcrun stapler validate "$DMG" || fail "DMG ticket does not validate"

# --- 8. draft release -------------------------------------------------------
# The tag is made by hand, annotated, after the artifacts are known good — so
# packaging never leaves a tag behind for a build that failed to notarize.
# gh would create a lightweight one silently, so require it up front.
echo "--- draft release ---"

if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  echo
  echo "Artifacts are built, notarized and verified:"
  echo "  $DMG"
  echo
  echo "Tag this commit, push it, then re-run to attach the DMG to a draft:"
  echo "  git tag -a $TAG -m \"$TAG\""
  echo "  git push origin main $TAG"
  echo "  scripts/package-release.sh"
  exit 0
fi

# A tag that predates the commit being packaged would ship the wrong source.
if [ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
  fail "tag $TAG points at $(git rev-parse --short "$TAG^{commit}"), not HEAD
  ($(git rev-parse --short HEAD)). Move the tag or package the tagged commit."
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  # An existing release may already be published, and re-running should never
  # quietly replace a shipped artifact.
  if [ "$(gh release view "$TAG" --json isDraft --jq .isDraft)" != "true" ]; then
    fail "release $TAG is already published. Bump MARKETING_VERSION, or attach by
  hand with: gh release upload $TAG $DMG --clobber"
  fi
  gh release upload "$TAG" "$DMG" --clobber || fail "could not attach the DMG"
  echo "attached to the existing draft $TAG"
else
  gh release create "$TAG" "$DMG" \
    --draft --title "$TAG" --verify-tag \
    --notes "Plume $VERSION for macOS.

Open the DMG and drag Plume to Applications. Signed and notarized, so it opens
normally — no right-click needed.

On first launch macOS asks for a few permissions, since Plume spawns terminals
and reads your Claude Code sessions." || fail "could not create the draft release"
fi

URL="$(gh release view "$TAG" --json url --jq .url 2>/dev/null)"

echo
echo "=== done $(date) ==="
echo "DMG:   $DMG"
echo "Draft: ${URL:-<none>}"
echo
echo "Review it, then publish with:"
echo "  gh release edit $TAG --draft=false"
