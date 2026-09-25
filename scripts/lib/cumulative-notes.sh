# Builds the appcast description: the notes of the last several releases,
# newest first, as HTML. Sourced by package-release.sh and
# scripts/debug/serve-test-appcast.sh.
#
# The notes come from CHANGELOG.md, one `## <version> (<build>)` section per
# release. Each becomes a <section data-sparkle-version="<build>">. Sparkle
# adds the class sparkle-installed-version to the section matching the
# running build, and the stylesheet hides it and every older one, so a user
# who skipped releases sees exactly what they missed. Sparkle's markdown
# format can't do this: it parses with NSAttributedString, which drops HTML.
#
# Each section also carries its markdown source in a
# <script type="text/markdown"> block, which a web view never displays.
# Plume's Homebrew update window renders that instead of the HTML
# (CumulativeReleaseNotes in UpdateController.swift). Keep the two formats
# in sync.

CUMULATIVE_NOTES_LIMIT=10

# changelog_split <changelog> <dir>: writes each section's body to
# <dir>/<n>.md and prints "<n> <version> <build>" per section, newest first.
changelog_split() {
  local changelog="$1" dir="$2"
  awk -v dir="$dir" '
    /^## / {
      if (!match($0, /^## [^ ]+ \([0-9]+\)$/)) { print "bad heading: " $0 > "/dev/stderr"; exit 1 }
      n++
      version = $2
      build = $3; gsub(/[()]/, "", build)
      file = dir "/" n ".md"
      print n, version, build
      next
    }
    n { print > file }
  ' "$changelog"
}

# markdown_to_html <file>: GitHub's own renderer, so the notes read the same
# as the release page. Falls back to preformatted text offline.
markdown_to_html() {
  local file="$1"
  if ! gh api -X POST markdown -f mode=gfm -F text=@"$file" 2>/dev/null; then
    echo "warning: could not render $file through GitHub — using plain text" >&2
    printf '<pre>'
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$file"
    printf '</pre>\n'
  fi
}

# cumulative_notes_section <build> <short version> <heading> <markdown file>
cumulative_notes_section() {
  local build="$1" version="$2" heading="$3" file="$4"
  printf '<section data-sparkle-version="%s">\n' "$build"
  printf '<h2>%s</h2>\n' "$heading"
  markdown_to_html "$file"
  printf '<script type="text/markdown" data-plume-version="%s">\n' "$version"
  # "</" would end the script block early.
  sed 's#</#<\\/#g' "$file"
  printf '\n</script>\n</section>\n'
}

# cumulative_notes <changelog> <work dir>: the whole description, from the
# newest CUMULATIVE_NOTES_LIMIT sections.
cumulative_notes() {
  local changelog="$1" dir="$2" index
  local -a versions builds
  changelog_split "$changelog" "$dir" >"$dir/index" || return 1
  while read -r index version build; do
    versions+=("$version"); builds+=("$build")
  done <"$dir/index"
  [ "${#versions[@]}" -gt 0 ] || { echo "no sections in $changelog" >&2; return 1; }

  printf '%s\n' '<style>.sparkle-installed-version, .sparkle-installed-version ~ section { display: none; }</style>'
  for index in "${!versions[@]}"; do
    [ "$index" -lt "$CUMULATIVE_NOTES_LIMIT" ] || break
    local heading="${versions[$index]}"
    [ "$index" -gt 0 ] || heading="Plume $heading"
    cumulative_notes_section "${builds[$index]}" "${versions[$index]}" "$heading" "$dir/$((index + 1)).md"
  done
}
