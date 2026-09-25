# Reads CHANGELOG.md, one `## <version> (<build>)` section per release.
# Sourced by package-release.sh and scripts/debug/serve-test-appcast.sh.

# changelog_split <changelog> <dir>: writes each section's body to
# <dir>/<n>.md and prints "<n> <version> <build>" per section, newest first.
# A "## " line inside a fenced code block is body text, not a heading.
changelog_split() {
  local changelog="$1" dir="$2"
  awk -v dir="$dir" '
    /^```/ { fenced = !fenced }
    /^## / && !fenced {
      if (!match($0, /^## [^ ]+ \([0-9]+\)$/)) { print "bad heading: " $0 > "/dev/stderr"; exit 1 }
      n++
      version = $2
      build = $3; gsub(/[()]/, "", build)
      file = dir "/" n ".md"
      printf "" > file
      print n, version, build
      next
    }
    n { print > file }
  ' "$changelog"
}
