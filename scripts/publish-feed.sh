#!/bin/bash
# Publishes the appcast package-release.sh wrote to the hosted feed at
# SUFeedURL (Configuration/Info.plist). Run it only after publishing the
# release's draft, since the appcast's enclosure URL 404s until then.
#
# Usage: scripts/publish-feed.sh [out/feed/appcast.xml]
#
# Hosting is not chosen yet, so this only checks its input and fails.
set -uo pipefail

# shellcheck source=lib/appcast.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/appcast.sh"

fail() { echo "FAILED: $*" >&2; exit 1; }

APPCAST="${1:-out/feed/appcast.xml}"
[ -s "$APPCAST" ] || fail "no appcast at $APPCAST — run scripts/package-release.sh first"
xmllint --noout "$APPCAST" || fail "$APPCAST is not well-formed XML"

FEED_URL="$(appcast_feed_url)"
if [ -z "$FEED_URL" ] || appcast_feed_url_is_placeholder "$FEED_URL"; then
  fail "hosting not configured yet: SUFeedURL in $APPCAST_INFO_PLIST is ${FEED_URL:-unset}"
fi

fail "hosting not configured yet: nothing publishes to $FEED_URL. Upload $APPCAST there by
  hand, or implement this script for the chosen host"
