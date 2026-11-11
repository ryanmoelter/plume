#!/bin/bash
# Publishes the appcast package-release.sh wrote to the hosted feed at
# SUFeedURL (Configuration/Info.plist). Run it only after publishing the
# release's draft, since the appcast's enclosure URL 404s until then.
#
# The feed is site/appcast.xml on main, which .github/workflows/pages.yml
# deploys to GitHub Pages. This commits the new appcast there, pushes main,
# and waits until SUFeedURL serves the same bytes.
#
# Usage: scripts/publish-feed.sh [out/feed/appcast.xml]
#   CO_AUTHOR="Name <email>" adds a Co-Authored-By trailer to the commit.
set -uo pipefail

# shellcheck source=lib/appcast.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/appcast.sh"

fail() { echo "FAILED: $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_APPCAST="site/appcast.xml"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-600}"

APPCAST="$(cd "$(dirname "${1:-out/feed/appcast.xml}")" 2>/dev/null && pwd)/$(basename "${1:-out/feed/appcast.xml}")"
[ -s "$APPCAST" ] || fail "no appcast at ${1:-out/feed/appcast.xml} — run scripts/package-release.sh first"
xmllint --noout "$APPCAST" || fail "$APPCAST is not well-formed XML"

FEED_URL="$(appcast_feed_url)"
if [ -z "$FEED_URL" ] || appcast_feed_url_is_placeholder "$FEED_URL"; then
  fail "SUFeedURL in $APPCAST_INFO_PLIST is ${FEED_URL:-unset}, not a hosted feed"
fi

cd "$REPO_ROOT" || fail "cannot cd to $REPO_ROOT"

BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null)"
[ "$BRANCH" = "main" ] || fail "on ${BRANCH:-a detached HEAD}, not main — Pages deploys site/ from main"
[ -z "$(git status --porcelain --untracked-files=no)" ] \
  || fail "uncommitted changes to tracked files — commit or set them aside first"
git fetch -q origin main || fail "git fetch origin main failed"
git merge-base --is-ancestor origin/main HEAD \
  || fail "main is behind origin/main — pull first"

PUBLISHED_VERSION="$(appcast_newest_version "$SITE_APPCAST")"
NEW_VERSION="$(appcast_newest_version "$APPCAST")"
[ -n "$NEW_VERSION" ] || fail "$APPCAST has no sparkle:version"
if [ -n "$PUBLISHED_VERSION" ] && [ "$NEW_VERSION" -lt "$PUBLISHED_VERSION" ]; then
  fail "$APPCAST tops out at build $NEW_VERSION, below the published $PUBLISHED_VERSION"
fi

if cmp -s "$APPCAST" "$SITE_APPCAST"; then
  echo "$SITE_APPCAST already matches $APPCAST — nothing to commit"
else
  # Copied, never rewritten: appcast_compose reads the published file's
  # one-tag-per-line layout back on the next release.
  cp "$APPCAST" "$SITE_APPCAST" || fail "copy failed"
  SHORT_VERSION="$(sed -n 's:.*<sparkle\:shortVersionString>\(.*\)</sparkle\:shortVersionString>.*:\1:p' "$SITE_APPCAST" | head -1)"
  git add "$SITE_APPCAST"
  if [ -n "${CO_AUTHOR:-}" ]; then
    git commit -q -m "Publish the ${SHORT_VERSION:-new} appcast" -m "Co-Authored-By: $CO_AUTHOR" || fail "commit failed"
  else
    git commit -q -m "Publish the ${SHORT_VERSION:-new} appcast" || fail "commit failed"
  fi
fi

git push -q origin main || fail "push failed — the commit is on local main; push it to publish"
echo "pushed main @ $(git rev-parse --short HEAD); waiting for $FEED_URL"

SERVED="$(mktemp)"
trap 'rm -f "$SERVED"' EXIT
deadline=$(( $(date +%s) + DEPLOY_TIMEOUT ))
while :; do
  # The query string skips the CDN's cached copy.
  if curl -fsSL -o "$SERVED" "$FEED_URL?t=$(date +%s)" && cmp -s "$SERVED" "$SITE_APPCAST"; then
    echo "published: $FEED_URL serves build $NEW_VERSION"
    exit 0
  fi
  [ "$(date +%s)" -lt "$deadline" ] \
    || fail "$FEED_URL still differs from $SITE_APPCAST after ${DEPLOY_TIMEOUT}s — check the Pages workflow: gh run list --workflow=pages.yml"
  sleep 15
done
