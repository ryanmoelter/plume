#!/bin/bash
# Packages a Release build for other Macs: Developer ID signature, notarization,
# a drag-to-install DMG, a signed appcast.xml for Sparkle, and a draft GitHub
# release with both attached.
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
#   - the Sparkle EdDSA private key in 1Password at SPARKLE_KEY_REF, and `op`
#     signed in (op signin)
#
# Usage: scripts/package-release.sh
#
# Release notes come from CHANGELOG.md. Its top section must be this release
# (`## <MARKETING_VERSION> (<CURRENT_PROJECT_VERSION>)`); it becomes the
# GitHub release body and, unchanged, the appcast's markdown notes.
set -uo pipefail

# shellcheck source=lib/sign-bundle.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/sign-bundle.sh"
# shellcheck source=lib/changelog.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/changelog.sh"

LOG="${LOG:-/tmp/plume-package.log}"
NOTARY_PROFILE="${NOTARY_PROFILE:-plume-notary}"
OUT="${OUT:-$PWD/out}"

# The EdDSA private key used to sign updates for Sparkle's appcast. Lives in
# 1Password, never in the keychain and never on disk — read on stdin only.
SPARKLE_KEY_REF="${SPARKLE_KEY_REF:-op://Plume/Plume Sparkle EdDSA/private key}"
CHANGELOG="CHANGELOG.md"

exec > >(tee -a "$LOG") 2>&1
echo "=== $(date) packaging ==="

fail() { echo "FAILED: $*"; exit 1; }

# A "]]>" inside release notes would close the CDATA section early, so split
# any occurrence across two sections — the standard CDATA-escaping trick.
cdata_escape() { sed 's/]]>/]]]]><![CDATA[>/g'; }

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

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

command -v op >/dev/null || fail "op (1Password CLI) missing — brew install 1password-cli"
op read "$SPARKLE_KEY_REF" >/dev/null \
  || fail "could not read Sparkle EdDSA key from $SPARKLE_KEY_REF — check 1Password access
  and SPARKLE_KEY_REF"

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
BUILD_NUMBER="$(awk '
  /CURRENT_PROJECT_VERSION/ { v=$3; gsub(/;/,"",v) }
  /PRODUCT_BUNDLE_IDENTIFIER = com\.ryanmoelter\.Plume;/ { print v; exit }
' Plume.xcodeproj/project.pbxproj)"
[ -n "$BUILD_NUMBER" ] || fail "could not read CURRENT_PROJECT_VERSION"

# Checked before the build, so missing notes don't cost a build and a
# notarization round trip.
changelog_top="$(grep -m1 '^## ' "$CHANGELOG" 2>/dev/null)"
case "$changelog_top" in
  "## Draft: "*) fail "$CHANGELOG's top section is still a draft (\"$changelog_top\") — review
  the notes, then remove \"Draft: \" from the heading and commit" ;;
esac
changelog_split "$CHANGELOG" "$(mktemp -d)" >/dev/null \
  || fail "$CHANGELOG has a malformed \"## \" heading — each must be \"## <version> (<build>)\""
[ "$changelog_top" = "## $VERSION ($BUILD_NUMBER)" ] \
  || fail "$CHANGELOG must start with a \"## $VERSION ($BUILD_NUMBER)\" section for this
  release (found \"${changelog_top:-nothing}\")"

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

SU_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$SRC/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$SU_PUBLIC_KEY" ] || fail "no SUPublicEDKey in the built Info.plist — Configuration/Info.plist must carry it"

# Sparkle decides an update exists by comparing sparkle:version, so a build
# that doesn't outrun the live appcast would ship and never reach anyone.
# `curl -f` fails on a 404, which is expected for the very first
# Sparkle-enabled release — there's no appcast yet to compare against.
echo "--- checking live appcast version ---"
BUILT_CFBUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SRC/Contents/Info.plist")"
live_appcast="$(curl -fsSL https://github.com/ryanmoelter/plume/releases/latest/download/appcast.xml 2>/dev/null)"
if [ -z "$live_appcast" ]; then
  echo "note: no live appcast found (first Sparkle-enabled release?) — skipping version check"
else
  live_version="$(sed -n 's#.*<sparkle:version>\([^<]*\)</sparkle:version>.*#\1#p' <<<"$live_appcast" | head -1)"
  if [ -z "$live_version" ]; then
    echo "note: could not parse sparkle:version from the live appcast — skipping version check"
  elif ! [ "$BUILT_CFBUNDLE_VERSION" -gt "$live_version" ] 2>/dev/null; then
    fail "the built CFBundleVersion ($BUILT_CFBUNDLE_VERSION) is not greater than the live
  appcast's sparkle:version ($live_version) — Sparkle compares this to decide an update
  exists, so bump CURRENT_PROJECT_VERSION in Plume.xcodeproj/project.pbxproj"
  else
    echo "ok: $BUILT_CFBUNDLE_VERSION > $live_version"
  fi
fi

# sign_update ships inside the Sparkle SwiftPM package, which SPM resolves
# into DerivedData rather than the app bundle — so it's only findable once the
# build above has run. BUILD_DIR is <DerivedData>/Build/Products; the
# resolved packages live two levels up, in <DerivedData>/SourcePackages.
BUILD_DIR="$(xcodebuild -scheme Plume -configuration Release -destination 'platform=macOS' \
  -showBuildSettings 2>/dev/null | awk '$1 == "BUILD_DIR" {print $3; exit}')"
[ -n "$BUILD_DIR" ] || fail "could not read BUILD_DIR from xcodebuild"
SOURCE_PACKAGES_DIR="$(cd "$BUILD_DIR/../.." && pwd)/SourcePackages"
SIGN_UPDATE="$SOURCE_PACKAGES_DIR/artifacts/sparkle/Sparkle/bin/sign_update"
if [ ! -x "$SIGN_UPDATE" ]; then
  SIGN_UPDATE="$(find "$SOURCE_PACKAGES_DIR/artifacts" -type f -name sign_update \
    -path '*/bin/sign_update' 2>/dev/null | head -1)"
fi
[ -n "$SIGN_UPDATE" ] && [ -x "$SIGN_UPDATE" ] || fail "sign_update not found under
  $SOURCE_PACKAGES_DIR/artifacts — expected the Sparkle SwiftPM package's bin/sign_update"
echo "sign_update: $SIGN_UPDATE"

APP="$OUT/Plume.app"
cp -R "$SRC" "$APP" || fail "could not stage the bundle"

# --- 3. re-sign with Developer ID -------------------------------------------
# The build signs with whatever automatic signing picked (an Apple Development
# identity), so re-sign over it. --timestamp is what the local install path
# lacks and notarization requires; --options runtime keeps the hardened runtime
# the build already enables.
echo "--- re-signing ---"
sign_bundle "$IDENTITY" "$APP"

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

# --- 7. sign the update and build the appcast --------------------------------
# The app's feed URL is a fixed GitHub release asset
# (releases/latest/download/appcast.xml), so every release has to publish one
# describing itself. sign_update reads the EdDSA key on stdin so it never
# touches disk or the keychain.
echo "--- signing update for Sparkle ---"
sign_output="$(op read "$SPARKLE_KEY_REF" | "$SIGN_UPDATE" --ed-key-file - "$DMG")" \
  || fail "sign_update failed"
sig_line="$(grep '^sparkle:edSignature=' <<<"$sign_output")"
[ -n "$sig_line" ] || fail "sign_update produced no signature: $sign_output"
ED_SIGNATURE="$(sed -n 's/^sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$sig_line")"
DMG_LENGTH="$(sed -n 's/.* length="\([0-9]*\)".*/\1/p' <<<"$sig_line")"
[ -n "$ED_SIGNATURE" ] && [ -n "$DMG_LENGTH" ] \
  || fail "could not parse sign_update output: $sig_line"

echo "--- building appcast ---"
NOTES_DIR="$OUT/notes"
mkdir -p "$NOTES_DIR"
changelog_split "$CHANGELOG" "$NOTES_DIR" >/dev/null \
  || fail "could not read the release notes from $CHANGELOG"
# changelog_split numbers sections from 1, newest first.
NOTES_FILE="$NOTES_DIR/1.md"

# The version in the appcast comes from the built app's own Info.plist, not
# MARKETING_VERSION, so it agrees with what the running app reports.
CFBUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
CFBUNDLE_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Info.plist")"
MIN_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
  "$APP/Contents/Info.plist" 2>/dev/null)"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-26.2}"

PUB_DATE="$(LC_ALL=C date -u +'%a, %d %b %Y %H:%M:%S %z')"
ENCLOSURE_URL="https://github.com/ryanmoelter/plume/releases/download/$TAG/$(basename "$DMG")"
NOTES_LINK="https://github.com/ryanmoelter/plume/releases/tag/$TAG"
APPCAST="$OUT/appcast.xml"

# Plain CDATA (not xml_escape) so the markdown reaches Sparkle unescaped —
# only a literal "]]>" inside the notes needs guarding.
{
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>'
  printf '%s\n' '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
  printf '  <channel>\n'
  printf '    <title>Plume</title>\n'
  printf '    <item>\n'
  printf '      <title>%s</title>\n' "$(xml_escape <<<"Plume $VERSION")"
  printf '      <pubDate>%s</pubDate>\n' "$PUB_DATE"
  printf '      <sparkle:version>%s</sparkle:version>\n' "$CFBUNDLE_VERSION"
  printf '      <sparkle:shortVersionString>%s</sparkle:shortVersionString>\n' "$CFBUNDLE_SHORT_VERSION"
  printf '      <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>\n' "$MIN_SYSTEM_VERSION"
  printf '      <sparkle:fullReleaseNotesLink>%s</sparkle:fullReleaseNotesLink>\n' "$NOTES_LINK"
  printf '      <description sparkle:format="markdown"><![CDATA[\n'
  cdata_escape <"$NOTES_FILE"
  printf '\n]]></description>\n'
  printf '      <enclosure url="%s" sparkle:edSignature="%s" length="%s" type="application/octet-stream" />\n' \
    "$(xml_escape <<<"$ENCLOSURE_URL")" "$ED_SIGNATURE" "$DMG_LENGTH"
  printf '    </item>\n'
  printf '  </channel>\n'
  printf '</rss>\n'
} >"$APPCAST"
[ -s "$APPCAST" ] || fail "appcast.xml was not written"
echo "appcast: $APPCAST"

# --- 8. verify --------------------------------------------------------------
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

# --- 9. draft release -------------------------------------------------------
# The tag is made by hand, annotated, after the artifacts are known good — so
# packaging never leaves a tag behind for a build that failed to notarize.
# gh would create a lightweight one silently, so require it up front.
echo "--- draft release ---"

if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  echo
  echo "Artifacts are built, notarized and verified:"
  echo "  $DMG"
  echo "  $APPCAST"
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
  hand with: gh release upload $TAG $DMG $APPCAST --clobber"
  fi
  gh release upload "$TAG" "$DMG" "$APPCAST" --clobber \
    || fail "could not attach the DMG and appcast"
  # Keeps the release body in step with the appcast's notes on a re-run,
  # since --clobber only replaces the attached files.
  gh release edit "$TAG" --notes-file "$NOTES_FILE" \
    || fail "could not update the release notes"
  echo "attached to the existing draft $TAG"
else
  gh release create "$TAG" "$DMG" "$APPCAST" \
    --draft --title "$TAG" --verify-tag \
    --notes-file "$NOTES_FILE" || fail "could not create the draft release"
fi

URL="$(gh release view "$TAG" --json url --jq .url 2>/dev/null)"

echo
echo "=== done $(date) ==="
echo "DMG:     $DMG"
echo "Appcast: $APPCAST"
echo "Draft:   ${URL:-<none>}"
echo
echo "Review it, then publish with:"
echo "  gh release edit $TAG --draft=false"
