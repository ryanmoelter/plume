# Builds the appcast description: the notes of the last several releases,
# newest first, as HTML. Sourced by package-release.sh and
# scripts/debug/serve-test-appcast.sh.
#
# Each release is a <section data-sparkle-version="<CFBundleVersion>">.
# Sparkle adds the class sparkle-installed-version to the section matching
# the running build, and the stylesheet hides it and every older one, so a
# user who skipped releases sees exactly what they missed.
#
# Each section also carries its markdown source in a
# <script type="text/markdown"> block, which a web view never displays.
# Plume's Homebrew update window renders that instead of the HTML
# (CumulativeReleaseNotes in UpdateController.swift). Keep the two formats
# in sync.

CUMULATIVE_NOTES_LIMIT=10

cumulative_notes_header() {
  printf '%s\n' '<style>.sparkle-installed-version, .sparkle-installed-version ~ section { display: none; }</style>'
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
