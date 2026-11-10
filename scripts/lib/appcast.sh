# Reads and merges the appcasts package-release.sh writes: one <item> per
# release, each tag on its own line. Sourced by package-release.sh.

# appcast_newest_version <appcast>: prints the highest sparkle:version in
# <appcast>, or nothing when it has none or the file is missing.
appcast_newest_version() {
  [ -s "$1" ] || return 0
  sed -n 's#.*<sparkle:version>\([^<]*\)</sparkle:version>.*#\1#p' "$1" | sort -n | tail -1
}

# appcast_newest_item <appcast> [<above>]: prints the <item> block with the
# highest sparkle:version, or nothing unless that version is above <above>.
appcast_newest_item() {
  [ -s "$1" ] || return 0
  awk -v above="${2:-0}" '
    /<item>/ { in_item = 1; buf = ""; version = "" }
    in_item {
      buf = buf $0 "\n"
      if (match($0, /<sparkle:version>[^<]*<\/sparkle:version>/))
        version = substr($0, RSTART + 17, RLENGTH - 35)
    }
    /<\/item>/ && in_item {
      in_item = 0
      if (version + 0 > above + 0 && version + 0 > best + 0) { best = version; newest = buf }
    }
    END { printf "%s", newest }
  ' "$1"
}

# appcast_merge <appcast> <other> [<above>]: prints <appcast> with <other>'s
# newest item added after its own, when that item is above <above>.
appcast_merge() {
  local appcast="$1" other="$2" above="${3:-0}" extra
  extra="$(mktemp)"
  appcast_newest_item "$other" "$above" >"$extra"
  awk -v extra="$extra" '
    /<\/channel>/ { while ((getline line < extra) > 0) print line }
    { print }
  ' "$appcast"
  rm -f "$extra"
}
