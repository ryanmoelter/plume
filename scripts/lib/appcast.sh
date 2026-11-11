# Reads and merges the appcasts package-release.sh writes: one <item> per
# release, each tag alone on its own line. Sourced by package-release.sh.
#
# Release notes sit in a CDATA section that opens at the end of the
# <description> line and closes on a line that is exactly
# "]]></description>". cdata_escape rewrites every "]]>" in the notes, so no
# notes line can equal that closing line. Lines between the two are notes,
# never structure, however much they look like tags.
_APPCAST_AWK_NOTES='
  { structural = !in_notes }
  structural && /^[ \t]*<description[^>]*><!\[CDATA\[$/ { in_notes = 1 }
  in_notes && /^\]\]><\/description>$/ { in_notes = 0 }
'

# appcast_newest_version <appcast>: prints the highest sparkle:version in
# <appcast>, or nothing when it has none or the file is missing.
appcast_newest_version() {
  [ -s "$1" ] || return 0
  awk "$_APPCAST_AWK_NOTES"'
    structural && /^[ \t]*<sparkle:version>[0-9]+<\/sparkle:version>[ \t]*$/ {
      v = $0; gsub(/[^0-9]/, "", v); print v
    }
  ' "$1" | sort -n | tail -1
}

# appcast_newest_item <appcast> [<above>]: prints the <item> block with the
# highest sparkle:version, or nothing unless that version is above <above>.
appcast_newest_item() {
  [ -s "$1" ] || return 0
  awk -v above="${2:-0}" "$_APPCAST_AWK_NOTES"'
    structural && /^[ \t]*<item>[ \t]*$/ { in_item = 1; buf = ""; version = "" }
    in_item { buf = buf $0 "\n" }
    in_item && structural && /^[ \t]*<sparkle:version>[0-9]+<\/sparkle:version>[ \t]*$/ {
      version = $0; gsub(/[^0-9]/, "", version)
    }
    in_item && structural && /^[ \t]*<\/item>[ \t]*$/ {
      in_item = 0
      if (version + 0 > above + 0 && version + 0 > best + 0) { best = version; newest = buf }
    }
    END { printf "%s", newest }
  ' "$1"
}

# appcast_newest_short_version <appcast>: prints the sparkle:shortVersionString
# of the item with the highest sparkle:version, or nothing.
appcast_newest_short_version() {
  appcast_newest_item "$1" | awk "$_APPCAST_AWK_NOTES"'
    structural && /^[ \t]*<sparkle:shortVersionString>[^<]*<\/sparkle:shortVersionString>[ \t]*$/ {
      sub(/^[ \t]*<sparkle:shortVersionString>/, ""); sub(/<\/sparkle:shortVersionString>[ \t]*$/, "")
      print; exit
    }
  '
}

# marketing_version_greater <a> <b>: succeeds when <a>'s numeric part is
# higher than <b>'s. A prerelease suffix is ignored, so 0.20.0-beta.1 > 0.19.1
# and 0.20.0-beta.1 is not greater than 0.20.0.
marketing_version_greater() {
  awk -v a="${1%%-*}" -v b="${2%%-*}" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, ".")
    n = na > nb ? na : nb
    for (i = 1; i <= n; i++) {
      if (x[i] + 0 > y[i] + 0) exit 0
      if (x[i] + 0 < y[i] + 0) exit 1
    }
    exit 1
  }'
}

# appcast_merge <appcast> <other> [<above>]: prints <appcast> with <other>'s
# newest item added after its own, when that item is above <above>.
appcast_merge() {
  local appcast="$1" other="$2" above="${3:-0}" extra
  extra="$(mktemp)"
  appcast_newest_item "$other" "$above" >"$extra"
  awk -v extra="$extra" "$_APPCAST_AWK_NOTES"'
    structural && /^[ \t]*<\/channel>[ \t]*$/ { while ((getline line < extra) > 0) print line }
    { print }
  ' "$appcast"
  rm -f "$extra"
}
