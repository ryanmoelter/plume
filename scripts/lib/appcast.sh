# Writes and reads Plume's appcast: one file holding stable and beta items,
# each tag alone on its own line. A beta item carries
# <sparkle:channel>beta</sparkle:channel>; a stable item carries no channel.
# Sourced by package-release.sh and scripts/test-appcast.sh.
#
# Release notes sit in a CDATA section that opens at the end of the
# <description> line and closes on a line that is exactly
# "]]></description>". appcast_cdata_escape rewrites every "]]>" in the notes,
# so no notes line can equal that closing line. Lines between the two are
# notes, never structure, however much they look like tags.
_APPCAST_AWK_NOTES='
  { structural = !in_notes }
  structural && /^[ \t]*<description[^>]*><!\[CDATA\[$/ { in_notes = 1 }
  in_notes && /^\]\]><\/description>$/ { in_notes = 0 }
'

APPCAST_BETA_CHANNEL="beta"

# SUFeedURL is the one place the feed's URL lives; the scripts read it here.
APPCAST_INFO_PLIST="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/Configuration/Info.plist"
APPCAST_PLACEHOLDER_HOST="plume-feed.invalid"

appcast_feed_url() {
  /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APPCAST_INFO_PLIST" 2>/dev/null
}

appcast_feed_url_is_placeholder() {
  case "$1" in
    *"://$APPCAST_PLACEHOLDER_HOST/"*) return 0 ;;
    *) return 1 ;;
  esac
}

# A "]]>" inside release notes would close the CDATA section early, so split
# any occurrence across two sections — the standard CDATA-escaping trick.
appcast_cdata_escape() { sed 's/]]>/]]]]><![CDATA[>/g'; }

appcast_xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# appcast_newest_version <appcast>: prints the highest sparkle:version in
# <appcast> across every channel, or nothing when it has none or the file is
# missing.
appcast_newest_version() {
  [ -s "$1" ] || return 0
  awk "$_APPCAST_AWK_NOTES"'
    structural && /^[ \t]*<sparkle:version>[0-9]+<\/sparkle:version>[ \t]*$/ {
      v = $0; gsub(/[^0-9]/, "", v); print v
    }
  ' "$1" | sort -n | tail -1
}

# appcast_item <channel> <title> <pub-date> <version> <short-version>
#   <minimum-system-version> <notes-link> <notes-file> <enclosure-url>
#   <ed-signature> <length>
# Prints one <item>. An empty <channel> posts it to the default channel.
# The notes go in as plain CDATA, not XML-escaped, so the markdown reaches
# Sparkle unchanged.
appcast_item() {
  local channel="$1" title="$2" pub_date="$3" version="$4" short_version="$5" \
    min_system="$6" notes_link="$7" notes_file="$8" enclosure_url="$9" \
    signature="${10}" length="${11}"
  printf '    <item>\n'
  printf '      <title>%s</title>\n' "$(appcast_xml_escape <<<"$title")"
  printf '      <pubDate>%s</pubDate>\n' "$pub_date"
  [ -z "$channel" ] || printf '      <sparkle:channel>%s</sparkle:channel>\n' "$channel"
  printf '      <sparkle:version>%s</sparkle:version>\n' "$version"
  printf '      <sparkle:shortVersionString>%s</sparkle:shortVersionString>\n' "$short_version"
  printf '      <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>\n' "$min_system"
  printf '      <sparkle:fullReleaseNotesLink>%s</sparkle:fullReleaseNotesLink>\n' \
    "$(appcast_xml_escape <<<"$notes_link")"
  printf '      <description sparkle:format="markdown"><![CDATA[\n'
  appcast_cdata_escape <"$notes_file"
  printf '\n]]></description>\n'
  printf '      <enclosure url="%s" sparkle:edSignature="%s" length="%s" type="application/octet-stream" />\n' \
    "$(appcast_xml_escape <<<"$enclosure_url")" "$signature" "$length"
  printf '    </item>\n'
}

# appcast_compose <new-item> [<published>]: prints a whole appcast holding
# the item in <new-item> and the items of the <published> appcast, trimmed to
# the newest stable item and the newest beta item above it, newest first.
#
# Sparkle offers the highest sparkle:version among the channels an install
# allows, so an older item of either channel is never chosen, and a beta at or
# below the newest stable is chosen by no one. Of two items with the same
# sparkle:version, <new-item>'s wins.
appcast_compose() {
  local new_item="$1" published="${2:-/dev/null}"
  [ -e "$published" ] || published=/dev/null
  awk -v beta="$APPCAST_BETA_CHANNEL" "$_APPCAST_AWK_NOTES"'
    structural && /^[ \t]*<item>[ \t]*$/ { in_item = 1; buf = ""; version = ""; channel = "" }
    in_item { buf = buf $0 "\n" }
    in_item && structural && /^[ \t]*<sparkle:version>[0-9]+<\/sparkle:version>[ \t]*$/ {
      version = $0; gsub(/[^0-9]/, "", version)
    }
    in_item && structural && /^[ \t]*<sparkle:channel>[^<]*<\/sparkle:channel>[ \t]*$/ {
      channel = $0
      sub(/^[ \t]*<sparkle:channel>/, "", channel); sub(/<\/sparkle:channel>[ \t]*$/, "", channel)
    }
    in_item && structural && /^[ \t]*<\/item>[ \t]*$/ {
      in_item = 0
      if (version == "") next
      if (channel == "") {
        if (stable_buf == "" || version + 0 > stable + 0) { stable = version; stable_buf = buf }
      } else if (channel == beta) {
        if (beta_buf == "" || version + 0 > beta_version + 0) { beta_version = version; beta_buf = buf }
      }
    }
    END {
      if (beta_buf != "" && stable_buf != "" && beta_version + 0 <= stable + 0) beta_buf = ""
      print "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
      print "<rss version=\"2.0\" xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\">"
      print "  <channel>"
      print "    <title>Plume</title>"
      if (beta_buf != "") printf "%s", beta_buf
      if (stable_buf != "") printf "%s", stable_buf
      print "  </channel>"
      print "</rss>"
    }
  ' "$new_item" "$published"
}
