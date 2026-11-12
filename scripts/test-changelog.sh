#!/bin/bash
# Tests scripts/lib/changelog.sh, the CHANGELOG.md to Sparkle release notes
# converter package-release.sh runs.
#
# Usage: scripts/test-changelog.sh [--show]
#   --show prints each converter output.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib/changelog.sh"
# shellcheck source=lib/changelog.sh
source "$LIB"

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

# A hung awk must fail a case, not spin. Without --foreground, the timeout
# signals the whole process group, so awk dies with the shell around it.
if command -v gtimeout >/dev/null; then TIMEOUT=gtimeout
elif command -v timeout >/dev/null; then TIMEOUT=timeout
else echo "FAIL neither gtimeout nor timeout is installed"; exit 1
fi

# html <markdown>: prints the converter's output.
html() {
  local out
  out="$(printf '%s\n' "$1" | "$TIMEOUT" -k 1 5 bash -c 'source "$0"; changelog_markdown_to_html' "$LIB")" || {
    echo "     converter failed or timed out on: $1" >&2
    return 1
  }
  if [ "$SHOW" = true ]; then
    echo "----- $1 -----" >&2
    echo "$out" >&2
  fi
  printf '%s\n' "$out"
}

# notes <changelog> <channel>: prints the cumulative notes page.
notes() {
  "$TIMEOUT" -k 1 5 bash -c 'source "$0"; changelog_notes_html "$1" "$2"' "$LIB" "$1" "$2"
}

# expect_html <markdown> <want>: the output is exactly <want>.
expect_html() {
  local got
  got="$(html "$1")" || return 1
  [ "$got" = "$2" ] || { echo "     got:  $got"; echo "     want: $2"; false; }
}

# expect_html_has <markdown> <substring>: the output contains <substring>.
expect_html_has() {
  local got
  got="$(html "$1")" || return 1
  grep -qF -- "$2" <<<"$got" || { echo "     got:  $got"; echo "     want to contain: $2"; false; }
}

count_of() { grep -oF -- "$2" <<<"$1" | wc -l | tr -d ' '; }

balanced_lists() {
  local got
  got="$(html "$1")" || return 1
  [ "$(count_of "$got" '<ul>')" = 3 ] && [ "$(count_of "$got" '</ul>')" = 3 ] &&
    [ "$(count_of "$got" '<li>')" = 3 ] && [ "$(count_of "$got" '</li>')" = 3 ] || {
    echo "     got: $got"; false
  }
}

# Fails on any parser error; xmllint exits 0 for those, so read its output.
html_parses() {
  local problems
  problems="$(xmllint --html --noout "$1" 2>&1)"
  [ -z "$problems" ] || { echo "$problems" | sed 's/^/     /'; false; }
}

check "a link becomes an anchor" expect_html '[t](u)' '<p><a href="u">t</a></p>'
check "a link inside bold keeps both" \
  expect_html '**bold [l](u)**' '<p><strong>bold <a href="u">l</a></strong></p>'
check "a link whose text is code" expect_html '[`x`](u)' '<p><a href="u"><code>x</code></a></p>'
check "two links on one line" \
  expect_html 'a [one](u1) and [two](u2)' '<p>a <a href="u1">one</a> and <a href="u2">two</a></p>'
check "a quote in a URL becomes &quot;" expect_html '[t](a"b)' '<p><a href="a&quot;b">t</a></p>'

check "inline code is escaped" expect_html 'x `c<d` y' '<p>x <code>c&lt;d</code> y</p>'
check "bold becomes strong" expect_html 'a **b** c' '<p>a <strong>b</strong> c</p>'
check "text escapes & < >" expect_html 'a&b <i>' '<p>a&amp;b &lt;i&gt;</p>'
check "]]> is kept as text" expect_html_has 'a ]]> b' ']]&gt;'

LISTS='- one
  - two
    - three deep'
check "a list nested 3 deep is balanced" balanced_lists "$LISTS"
check "the deepest item text is present" expect_html_has "$LISTS" '<li>three deep</li>'

check "### becomes h3" expect_html '### Head' '<h3>Head</h3>'

FENCE='```
<a> & b
```'
check "fenced code is escaped inside pre and code" \
  expect_html "$FENCE" '<pre><code>&lt;a&gt; &amp; b
</code></pre>'

# changelog <name> <count> <beta-position>: a synthetic changelog with <count>
# sections, builds <count>..1 newest first; the section at <beta-position> is a beta.
make_changelog() {
  local out="$TMP/$1.md" count="$2" beta="$3" i position=0
  : >"$out"
  for ((i = count; i >= 1; i--)); do
    position=$((position + 1))
    if [ "$position" = "$beta" ]; then
      printf '## 0.%d.0-beta.1 (%d)\n\n- Note %d\n\n' "$i" "$i" "$i" >>"$out"
    else
      printf '## 0.%d.0 (%d)\n\n- Note %d\n\n' "$i" "$i" "$i" >>"$out"
    fi
  done
}

make_changelog twelve 12 2
STABLE="$TMP/stable.html"
BETA="$TMP/beta.html"
notes "$TMP/twelve.md" "" >"$STABLE"
notes "$TMP/twelve.md" "beta" >"$BETA"
if [ "$SHOW" = true ]; then
  echo "----- stable page -----"
  cat "$STABLE"
fi

versions_of() { grep -o 'data-sparkle-version="[0-9]*"' "$1" | sed 's/[^0-9]//g' | tr '\n' ' ' | sed 's/ $//'; }
expect_versions() { [ "$(versions_of "$1")" = "$2" ] || { echo "     got: $(versions_of "$1")  want: $2"; false; }; }

check "only the newest sections are included, in file order" \
  expect_versions "$STABLE" "12 11 10 9 8 7 6 5 4 3"
check "the section count is CHANGELOG_CUMULATIVE_SECTIONS" \
  test "$(count_of "$(cat "$STABLE")" '<div data-sparkle-version')" = "$CHANGELOG_CUMULATIVE_SECTIONS"
check "the beta section carries class beta" \
  grep -qF '<div data-sparkle-version="11" class="beta">' "$STABLE"
check "only the beta section carries class beta" \
  test "$(count_of "$(cat "$STABLE")" 'class="beta"')" = 1
check "the stable page hides beta sections" grep -qF '.beta { display: none; }' "$STABLE"
check "the beta page shows beta sections" eval '! grep -qF ".beta { display: none; }" "$BETA"'
check "the beta page still marks the beta section" \
  grep -qF '<div data-sparkle-version="11" class="beta">' "$BETA"
check "the stable page parses as HTML" html_parses "$STABLE"
check "the beta page parses as HTML" html_parses "$BETA"

REAL="$SCRIPT_DIR/../CHANGELOG.md"
REAL_OUT="$TMP/real.html"
check "the real CHANGELOG.md converts" eval 'notes "$REAL" "" >"$REAL_OUT"'
check "the real notes are non-empty" test -s "$REAL_OUT"
check "the real notes parse as HTML" html_parses "$REAL_OUT"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all changelog tests passed"
else
  echo "$FAILURES changelog test(s) failed"
  exit 1
fi
