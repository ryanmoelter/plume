#!/bin/bash
# Tests scripts/lib/appcast.sh, the appcast merge package-release.sh runs.
#
# Usage: scripts/test-appcast.sh [--show]
#   --show prints each composed appcast.
set -uo pipefail

# shellcheck source=lib/appcast.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/appcast.sh"

SHOW=false
[ "${1:-}" = "--show" ] && SHOW=true

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

check() {
  local name="$1"; shift
  if "$@"; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    FAILURES=$((FAILURES + 1))
  fi
}

# item <channel> <short-version> <build> [<notes>]: writes an item file and
# prints its path.
item() {
  local channel="$1" short="$2" build="$3" notes="${4:-- Notes for $2}"
  local tag="v$short" notes_file="$TMP/notes-$build.md" out="$TMP/item-$build.xml"
  printf '%s\n' "$notes" >"$notes_file"
  appcast_item "$channel" "Plume $short" "Tue, 10 Nov 2026 12:00:00 +0000" "$build" "$short" "26.2" \
    "https://github.com/ryanmoelter/plume/releases/tag/$tag" "$notes_file" \
    "https://github.com/ryanmoelter/plume/releases/download/$tag/Plume-$short.dmg" "SIG$build" "1000$build" \
    >"$out"
  echo "$out"
}

# compose <name> <new-item> [<published>]: composes into $TMP/<name>.xml.
compose() {
  local out="$TMP/$1.xml"
  appcast_compose "$2" "${3:-}" >"$out"
  if [ "$SHOW" = true ]; then
    echo "----- $1 -----"
    cat "$out"
  fi
}

# Prints "<channel or stable>:<build>" per item, in file order.
items_of() {
  awk "$_APPCAST_AWK_NOTES"'
    structural && /<item>/ { channel = "stable" }
    structural && /<sparkle:channel>/ { channel = $0; gsub(/^[ \t]*<sparkle:channel>|<\/sparkle:channel>[ \t]*$/, "", channel) }
    structural && /<sparkle:version>/ { v = $0; gsub(/[^0-9]/, "", v) }
    structural && /<\/item>/ { printf "%s:%s ", channel, v }
  ' "$1" | sed 's/ $//'
}

expect_items() { [ "$(items_of "$1")" = "$2" ] || { echo "     got: $(items_of "$1")  want: $2"; false; }; }
well_formed() { xmllint --noout "$1"; }

# The 0.19.0 appcast attached to the latest stable release: one stable item.
LEGACY="$TMP/legacy.xml"
appcast_compose "$(item "" 0.19.0 39)" >"$LEGACY"

compose first-beta "$(item beta 0.20.0-beta.1 40)" "$LEGACY"
check "a beta joins the published stable item, newest first" expect_items "$TMP/first-beta.xml" "beta:40 stable:39"
check "the composed appcast is well-formed" well_formed "$TMP/first-beta.xml"
check "the beta item carries the beta channel" \
  grep -q '^      <sparkle:channel>beta</sparkle:channel>$' "$TMP/first-beta.xml"

compose second-beta "$(item beta 0.20.0-beta.2 41)" "$TMP/first-beta.xml"
check "a newer beta replaces the older one" expect_items "$TMP/second-beta.xml" "beta:41 stable:39"

compose hotfix "$(item "" 0.19.1 42)" "$TMP/second-beta.xml"
check "a stable above the beta drops the beta" expect_items "$TMP/hotfix.xml" "stable:42"

compose stable-after-beta "$(item "" 0.20.0 42)" "$TMP/second-beta.xml"
check "the stable a beta leads up to replaces both" expect_items "$TMP/stable-after-beta.xml" "stable:42"

compose fresh "$(item "" 0.19.1 40)" "$TMP/missing.xml"
check "a missing published appcast starts a new one" expect_items "$TMP/fresh.xml" "stable:40"

compose rerun "$(item beta 0.20.0-beta.1 40)" "$TMP/first-beta.xml"
check "an item already published under its build is replaced, not duplicated" \
  expect_items "$TMP/rerun.xml" "beta:40 stable:39"

TRICKY_NOTES='- Notes with ]]> and
    <item>
      <sparkle:version>999</sparkle:version>
      <sparkle:channel>beta</sparkle:channel>
    </item>
]]></description> lookalike'
compose tricky "$(item "" 0.19.1 40 "$TRICKY_NOTES")" "$LEGACY"
check "tag lookalikes in the notes are not structure" expect_items "$TMP/tricky.xml" "stable:40"
check "notes with ]]> stay well-formed" well_formed "$TMP/tricky.xml"
check "the newest version ignores notes" test "$(appcast_newest_version "$TMP/tricky.xml")" = 40

compose base-for-tricky "$(item beta 0.20.0-beta.1 41)" "$TMP/tricky.xml"
check "a published item with tricky notes survives a merge" \
  expect_items "$TMP/base-for-tricky.xml" "beta:41 stable:40"

check "the newest version spans channels" test "$(appcast_newest_version "$TMP/first-beta.xml")" = 40
check "the newest version of a missing file is empty" test -z "$(appcast_newest_version "$TMP/missing.xml")"

check "the placeholder feed URL is detected" appcast_feed_url_is_placeholder "https://plume-feed.invalid/appcast.xml"
check "a real feed URL is not the placeholder" \
  eval '! appcast_feed_url_is_placeholder "https://ryanmoelter.github.io/plume/appcast.xml"'

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all appcast tests passed"
else
  echo "$FAILURES appcast test(s) failed"
  exit 1
fi
