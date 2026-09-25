# Re-signs a built Plume.app with Developer ID: Sparkle's nested code, the
# sleep helper, then the outer bundle. Sourced by install-release.sh and
# package-release.sh, which each already run under `set -uo pipefail` and
# define fail() — sign_bundle calls it on any failure.
#
# Inside out, and each target signed explicitly: codesign without --deep
# leaves nested code alone, and the outer signature seals everything beneath
# it, so a nested binary still carrying the build's Apple Development
# signature fails notarization.

sign_bundle() {
  local identity="$1" app="$2"
  local sparkle="$app/Contents/Frameworks/Sparkle.framework"
  local versions="$sparkle/Versions/B"
  local helper="$app/Contents/MacOS/PlumeSleepHelper"

  [ -d "$sparkle" ] || fail "Sparkle.framework missing from $app/Contents/Frameworks"

  codesign --force --sign "$identity" --options runtime --timestamp \
    "$versions/XPCServices/Installer.xpc" \
    || fail "codesign of Sparkle's Installer.xpc failed"
  codesign --force --sign "$identity" --options runtime --timestamp \
    --preserve-metadata=entitlements \
    "$versions/XPCServices/Downloader.xpc" \
    || fail "codesign of Sparkle's Downloader.xpc failed"
  codesign --force --sign "$identity" --options runtime --timestamp \
    "$versions/Autoupdate" \
    || fail "codesign of Sparkle's Autoupdate failed"
  codesign --force --sign "$identity" --options runtime --timestamp \
    "$versions/Updater.app" \
    || fail "codesign of Sparkle's Updater.app failed"
  codesign --force --sign "$identity" --options runtime --timestamp \
    "$sparkle" \
    || fail "codesign of Sparkle.framework failed"

  [ -x "$helper" ] || fail "sleep helper missing at $helper"
  codesign --force --sign "$identity" --options runtime --timestamp "$helper" \
    || fail "codesign of the helper failed"

  codesign --force --sign "$identity" --options runtime --timestamp "$app" \
    || fail "codesign of the app failed"
}
