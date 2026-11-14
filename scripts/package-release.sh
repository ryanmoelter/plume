#!/bin/bash
# Packages a Release build for other Macs: Developer ID signature, notarization,
# a drag-to-install DMG, a signed appcast.xml for Sparkle, and a draft GitHub
# release with the DMG attached.
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
# Usage: scripts/package-release.sh [--beta [--allow-branch]]
#
# Betas release from main. --beta on any other branch fails unless
# --allow-branch is passed, which needs the maintainer's explicit approval.
#
# --beta packages a beta: MARKETING_VERSION must be <version>-beta.<n>
# (0.20.0-beta.1), the draft is a prerelease, which GitHub's releases/latest
# never points at, and its appcast item is on Sparkle's "beta" channel.
#
# Every release writes out/feed/appcast.xml: the published appcast at SUFeedURL
# (Configuration/Info.plist) plus this release's item, trimmed by
# appcast_compose. Publish it with scripts/publish-feed.sh only after
# publishing the draft, since the enclosure URL 404s until then; the script
# prints both commands. A stable release also attaches the same file to its
# GitHub release as appcast.xml, for installs that still read
# releases/latest/download/appcast.xml (0.19.0 and older).
#
# A GitHub release is never changed once published, since immutable releases
# forbid it.
#
# Release notes come from CHANGELOG.md. Its top section must be this release
# (`## <MARKETING_VERSION> (<CURRENT_PROJECT_VERSION>)`); it becomes the
# GitHub release body and, unchanged, the appcast's markdown notes.
set -uo pipefail

BETA=false
ALLOW_BRANCH=false
for arg in "$@"; do
  case "$arg" in
    --beta) BETA=true ;;
    --allow-branch) ALLOW_BRANCH=true ;;
    *) echo "usage: $0 [--beta [--allow-branch]]" >&2; exit 2 ;;
  esac
done

# shellcheck source=lib/sign-bundle.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/sign-bundle.sh"
# shellcheck source=lib/scrcpy-server.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/scrcpy-server.sh"
# shellcheck source=lib/changelog.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/changelog.sh"
# shellcheck source=lib/appcast.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/appcast.sh"

LOG="${LOG:-/tmp/plume-package.log}"
NOTARY_PROFILE="${NOTARY_PROFILE:-plume-notary}"
OUT="${OUT:-$PWD/out}"

# The EdDSA private key used to sign updates for Sparkle's appcast. Lives in
# 1Password, never in the keychain and never on disk — read on stdin only.
SPARKLE_KEY_REF="${SPARKLE_KEY_REF:-op://Plume/Plume Sparkle EdDSA/private key}"
CHANGELOG="CHANGELOG.md"
FEED_URL="$(appcast_feed_url)"
# Where 0.19.0 and older read their feed. Until the hosted feed has been
# published once, it is also where the current appcast lives.
LEGACY_FEED_URL="https://github.com/ryanmoelter/plume/releases/latest/download/appcast.xml"

exec > >(tee -a "$LOG") 2>&1
echo "=== $(date) packaging ==="

fail() { echo "FAILED: $*"; exit 1; }

# --- 1. preflight -----------------------------------------------------------
# Every check here is a thing that otherwise fails much later with a worse
# message, after a multi-minute build or a notarization round trip.

[ -n "$FEED_URL" ] || fail "could not read SUFeedURL from $APPCAST_INFO_PLIST"
appcast_feed_url_is_placeholder "$FEED_URL" \
  && fail "SUFeedURL in $APPCAST_INFO_PLIST is still the placeholder $FEED_URL.
  Set it to the hosted appcast's URL before packaging; a release built with it
  can never find another update"
echo "feed: $FEED_URL"

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
# carry their own MARKETING_VERSION of 1.0. Xcode quotes a beta's version
# ("0.20.0-beta.1"), so the quotes go too.
VERSION="$(awk '
  /MARKETING_VERSION/ { v=$3; gsub(/[;"]/,"",v) }
  /PRODUCT_BUNDLE_IDENTIFIER = com\.ryanmoelter\.Plume;/ { print v; exit }
' Plume.xcodeproj/project.pbxproj)"
[ -n "$VERSION" ] || fail "could not read MARKETING_VERSION"
BUILD_NUMBER="$(awk '
  /CURRENT_PROJECT_VERSION/ { v=$3; gsub(/;/,"",v) }
  /PRODUCT_BUNDLE_IDENTIFIER = com\.ryanmoelter\.Plume;/ { print v; exit }
' Plume.xcodeproj/project.pbxproj)"
[ -n "$BUILD_NUMBER" ] || fail "could not read CURRENT_PROJECT_VERSION"

# The suffix is what keeps a beta's tag and DMG name apart from the stable
# release it leads up to.
if [ "$BETA" = true ] && ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*-beta\.[0-9]+$ ]]; then
  fail "--beta needs a MARKETING_VERSION like ${VERSION%%-*}-beta.1 (found $VERSION)"
fi
if [ "$BETA" = true ] && [ "$ALLOW_BRANCH" = false ]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ "$BRANCH" != "HEAD" ] || BRANCH=""
  [ "$BRANCH" = "main" ] \
    || fail "betas release from main, and this is ${BRANCH:-a detached HEAD}. Releasing a beta from
  another branch needs the maintainer's explicit approval; with it, pass --allow-branch"
fi
case "$BETA:$VERSION" in
  false:*-*) fail "MARKETING_VERSION $VERSION is a prerelease — package it with --beta" ;;
esac

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
echo "version: $VERSION  tag: $TAG  beta: $BETA"

git rev-parse "$TAG" >/dev/null 2>&1 \
  && echo "note: tag $TAG already exists" \
  || echo "note: tag $TAG does not exist yet — the script stops before the draft to let you make it"

check_scrcpy_server_source

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
# that doesn't outrun every item in the published appcast, beta or stable,
# would ship and never reach anyone. Step 7 builds the new appcast on top of
# this file.
echo "--- checking the published appcast ---"
BUILT_CFBUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SRC/Contents/Info.plist")"
PUBLISHED_APPCAST="$OUT/published-appcast.xml"

# Succeeds on a 200 and fails on a 404, leaving <dest> only on a 200. Any
# other failure would silently drop published items, so it stops the run.
fetch_appcast() {
  local url="$1" dest="$2" status
  status="$(curl -sSL -o "$dest" -w '%{http_code}' "$url")" \
    || fail "could not fetch $url (curl exit $?)"
  case "$status" in
    200) return 0 ;;
    404) rm -f "$dest"; return 1 ;;
    *) fail "fetching $url returned HTTP $status" ;;
  esac
}

# The hosted feed 404s until its first publish; the latest stable release's
# appcast is the published state before that.
if fetch_appcast "$FEED_URL" "$PUBLISHED_APPCAST"; then
  echo "published appcast: $FEED_URL"
elif fetch_appcast "$LEGACY_FEED_URL" "$PUBLISHED_APPCAST"; then
  echo "published appcast: $LEGACY_FEED_URL ($FEED_URL is not published yet)"
else
  echo "note: no published appcast at $FEED_URL or $LEGACY_FEED_URL — starting a new one"
fi
if [ -f "$PUBLISHED_APPCAST" ]; then
  xmllint --noout "$PUBLISHED_APPCAST" || fail "the published appcast is not well-formed XML"
fi

published_version="$(appcast_newest_version "$PUBLISHED_APPCAST")"
if [ -z "$published_version" ]; then
  echo "note: no published sparkle:version found — skipping the build number check"
elif ! [ "$BUILT_CFBUNDLE_VERSION" -gt "$published_version" ] 2>/dev/null; then
  fail "the built CFBundleVersion ($BUILT_CFBUNDLE_VERSION) is not greater than the published
  appcast's newest sparkle:version ($published_version). Build numbers rise across betas and
  stable releases alike, so bump CURRENT_PROJECT_VERSION in Plume.xcodeproj/project.pbxproj"
else
  echo "ok: $BUILT_CFBUNDLE_VERSION > $published_version"
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
check_scrcpy_server_bundled "$APP"

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
# sign_update reads the EdDSA key on stdin so it never touches disk or the
# keychain.
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
CHANNEL=""
[ "$BETA" = true ] && CHANNEL="$APPCAST_BETA_CHANNEL"
NEW_ITEM="$OUT/item.xml"
# Its file name is the asset name a stable release attaches it under.
APPCAST="$OUT/feed/appcast.xml"
mkdir -p "$(dirname "$APPCAST")"

appcast_item "$CHANNEL" "Plume $VERSION" "$PUB_DATE" "$CFBUNDLE_VERSION" \
  "$CFBUNDLE_SHORT_VERSION" "$MIN_SYSTEM_VERSION" "$NOTES_LINK" "$NOTES_FILE" \
  "$ENCLOSURE_URL" "$ED_SIGNATURE" "$DMG_LENGTH" >"$NEW_ITEM" \
  || fail "could not write the appcast item"
appcast_compose "$NEW_ITEM" "$PUBLISHED_APPCAST" >"$APPCAST" \
  || fail "could not build the appcast"
xmllint --noout "$APPCAST" || fail "the appcast at $APPCAST is not well-formed XML"
[ "$(appcast_newest_version "$APPCAST")" = "$CFBUNDLE_VERSION" ] \
  || fail "the appcast at $APPCAST does not carry this release's item ($CFBUNDLE_VERSION)"
echo "appcast: $APPCAST ($(grep -c '<item>' "$APPCAST") items)"

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
  PUSH_BRANCH=main
  [ "$BETA" = true ] && PUSH_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [ "$PUSH_BRANCH" = HEAD ]; then
    echo "  git push origin $TAG"
  else
    echo "  git push origin $PUSH_BRANCH $TAG"
  fi
  echo "  scripts/package-release.sh$([ "$BETA" = true ] && echo " --beta")$([ "$ALLOW_BRANCH" = true ] && echo " --allow-branch")"
  exit 0
fi

# A tag that predates the commit being packaged would ship the wrong source.
if [ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
  fail "tag $TAG points at $(git rev-parse --short "$TAG^{commit}"), not HEAD
  ($(git rev-parse --short HEAD)). Move the tag or package the tagged commit."
fi

# A stable release attaches the appcast for installs that read
# releases/latest/download/appcast.xml. A beta is a prerelease, which that URL
# never points at.
ASSETS=("$DMG")
[ "$BETA" = true ] || ASSETS+=("$APPCAST")

if gh release view "$TAG" >/dev/null 2>&1; then
  if [ "$(gh release view "$TAG" --json isDraft --jq .isDraft)" != "true" ]; then
    fail "release $TAG is already published, and a published release is never changed.
  Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION and release again"
  fi
  gh release upload "$TAG" "${ASSETS[@]}" --clobber \
    || fail "could not attach the release files"
  gh release edit "$TAG" --prerelease="$BETA" \
    || fail "could not set the prerelease flag"
  # Keeps the release body in step with the appcast's notes on a re-run,
  # since --clobber only replaces the attached files.
  gh release edit "$TAG" --notes-file "$NOTES_FILE" \
    || fail "could not update the release notes"
  echo "attached to the existing draft $TAG"
else
  gh release create "$TAG" "${ASSETS[@]}" \
    --draft --prerelease="$BETA" --title "$TAG" --verify-tag \
    --notes-file "$NOTES_FILE" || fail "could not create the draft release"
fi

URL="$(gh release view "$TAG" --json url --jq .url 2>/dev/null)"

echo
echo "=== done $(date) ==="
echo "DMG:     $DMG"
echo "Appcast: $APPCAST"
echo "Draft:   ${URL:-<none>}"
echo
echo "Review it, then publish the release and, after it, the feed:"
echo "  gh release edit $TAG --draft=false && scripts/publish-feed.sh $APPCAST"
