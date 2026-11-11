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

CHANGELOG_CUMULATIVE_SECTIONS=10

# changelog_markdown_to_html: converts the markdown CHANGELOG.md uses —
# headings, nested "-"/"*" lists, paragraphs, fenced code, and inline code,
# bold and links — to an HTML fragment. Anything else passes through as
# escaped text.
changelog_markdown_to_html() {
  awk '
    function esc(s) {
      gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
      return s
    }
    function inline(s,    out, c, rest, end, url, len) {
      out = ""
      while (match(s, /[`*[&<>]/)) {
        out = out substr(s, 1, RSTART - 1)
        c = substr(s, RSTART, 1)
        rest = substr(s, RSTART)
        s = substr(s, RSTART + 1)
        if (c == "`" && (end = index(s, "`")) > 0) {
          out = out "<code>" esc(substr(s, 1, end - 1)) "</code>"
          s = substr(s, end + 1)
        } else if (c == "[" && match(rest, /^\[[^]]*\]\([^ )]*\)/)) {
          len = RLENGTH
          end = index(rest, "](")
          url = esc(substr(rest, end + 2, len - end - 2))
          gsub(/"/, "\\&quot;", url)
          out = out "<a href=\"" url "\">" inline(substr(rest, 2, end - 2)) "</a>"
          s = substr(rest, len + 1)
        } else if (c == "*" && substr(s, 1, 1) == "*" && (end = index(substr(s, 2), "**")) > 1) {
          out = out "<strong>" inline(substr(s, 2, end - 1)) "</strong>"
          s = substr(s, end + 3)
        } else {
          out = out esc(c)
        }
      }
      return out s
    }
    function close_paragraph() { if (in_p) { printf "</p>\n"; in_p = 0 } }
    function close_lists_to(d) {
      while (depth > d) { printf "</li>\n</ul>\n"; depth-- }
    }
    function close_blocks() { close_paragraph(); close_lists_to(0) }

    fenced {
      if ($0 ~ /^[ \t]*```[ \t]*$/) { printf "</code></pre>\n"; fenced = 0 } else print esc($0)
      next
    }
    /^[ \t]*```/ {
      if (!(depth && /^[ \t]/)) close_blocks()
      close_paragraph()
      printf "<pre><code>"
      fenced = 1; blank = 0
      next
    }
    /^[ \t]*$/ { close_paragraph(); blank = 1; next }
    /^#{1,4} / {
      close_blocks()
      level = index($0, " ") - 1
      printf "<h%d>%s</h%d>\n", level, inline(substr($0, level + 2)), level
      blank = 0
      next
    }
    /^ *[-*] / {
      close_paragraph()
      match($0, /^ */)
      d = int(RLENGTH / 2) + 1
      if (d > depth + 1) d = depth + 1
      if (d > depth) { printf "<ul>\n"; depth = d }
      else { close_lists_to(d); printf "</li>\n" }
      text = $0; sub(/^ *[-*] /, "", text)
      printf "<li>%s", inline(text)
      blank = 0
      next
    }
    depth && (!blank || /^[ \t]/) {
      text = $0; sub(/^[ \t]+/, "", text)
      printf " %s", inline(text)
      blank = 0
      next
    }
    {
      close_lists_to(0)
      if (in_p) printf "\n"; else { printf "<p>"; in_p = 1 }
      printf "%s", inline($0)
      blank = 0
    }
    END {
      if (fenced) printf "</code></pre>\n"
      close_blocks()
    }
  '
}

# changelog_notes_html <changelog> <channel>: prints the newest
# $CHANGELOG_CUMULATIVE_SECTIONS sections as one HTML fragment, each in a
# <div data-sparkle-version="<build>">. Sparkle marks the installed build's
# div with sparkle-installed-version, and the style hides it and every older
# one, so an install sees only what is new to it. A stable item (empty
# <channel>) hides beta sections but keeps them in the page, so a beta
# install's div still anchors that rule.
changelog_notes_html() {
  local changelog="$1" channel="$2" dir n version build class
  dir="$(mktemp -d)" || return 1
  changelog_split "$changelog" "$dir" >"$dir/sections" || { rm -rf "$dir"; return 1; }
  # NSAttributedString's HTML import reads a page with no charset as Latin-1.
  printf '<meta charset="utf-8">\n<style>\n'
  printf ':root { color-scheme: light dark; }\n'
  printf 'body { font: 13px -apple-system, system-ui, sans-serif; }\n'
  printf 'code, pre { font: 12px ui-monospace, Menlo, monospace; }\n'
  # Plume 0.13–0.18 render these notes through NSAttributedString, which
  # keeps a link's color as a fixed RGB in both appearances.
  printf 'a { color: #2a7de1; }\n'
  printf '.sparkle-installed-version, .sparkle-installed-version ~ div { display: none; }\n'
  [ -n "$channel" ] || printf '.beta { display: none; }\n'
  printf '</style>\n'
  head -n "$CHANGELOG_CUMULATIVE_SECTIONS" "$dir/sections" |
    while read -r n version build; do
      class=""
      case "$version" in *-beta.*) class=' class="beta"' ;; esac
      printf '<div data-sparkle-version="%s"%s>\n<h2>%s</h2>\n' "$build" "$class" "$version"
      changelog_markdown_to_html <"$dir/$n.md"
      printf '</div>\n'
    done
  rm -rf "$dir"
}
