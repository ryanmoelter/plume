#!/bin/bash
# Bumps Casks/plume.rb in ryanmoelter/homebrew-tap to a newly published release:
# version + sha256 of that release's DMG.
#
# This script lives in a public repo, so it never references a tap checkout
# on this machine — it clones the tap fresh into a temp dir, edits, commits,
# pushes, and deletes the temp dir. The only identifier committed is the
# public repo name.
#
# Usage: scripts/update-tap.sh <version>
#   e.g. scripts/update-tap.sh 0.12.0
set -euo pipefail

TAP_REPO="ryanmoelter/homebrew-tap"
PLUME_REPO="ryanmoelter/plume"

fail() { echo "FAILED: $*" >&2; exit 1; }

[ $# -eq 1 ] || fail "usage: $0 <version>  (e.g. $0 0.12.0)"
VERSION="$1"
TAG="v$VERSION"
DMG_URL="https://github.com/$PLUME_REPO/releases/download/$TAG/Plume-$VERSION.dmg"

command -v gh >/dev/null || fail "gh missing — brew install gh"
gh auth status >/dev/null 2>&1 || fail "gh not authenticated — gh auth login"

# The DMG URL 404s while the release is a draft, so gate on it being
# published before hashing bytes nobody can download yet.
IS_DRAFT="$(gh release view "$TAG" --repo "$PLUME_REPO" --json isDraft --jq .isDraft 2>&1)" \
  || fail "release $TAG not found on $PLUME_REPO: $IS_DRAFT"
[ "$IS_DRAFT" = "false" ] || fail "release $TAG is still a draft — publish it first"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "--- downloading $DMG_URL ---"
DMG="$WORK/Plume-$VERSION.dmg"
curl -fL -o "$DMG" "$DMG_URL" || fail "download failed"

SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "sha256: $SHA256"

echo "--- cloning $TAP_REPO ---"
TAP="$WORK/tap"
gh repo clone "$TAP_REPO" "$TAP" -- -q || fail "clone failed"

CASK="$TAP/Casks/plume.rb"
[ -f "$CASK" ] || fail "no cask at $CASK"

# version and sha256 are each declared once, near the top of the cask.
sed -i '' \
  -e "s/^  version \".*\"/  version \"$VERSION\"/" \
  -e "s/^  sha256 \".*\"/  sha256 \"$SHA256\"/" \
  "$CASK"

grep -q "version \"$VERSION\"" "$CASK" || fail "version substitution did not take"
grep -q "sha256 \"$SHA256\"" "$CASK" || fail "sha256 substitution did not take"

git -C "$TAP" diff --stat -- Casks/plume.rb
git -C "$TAP" add Casks/plume.rb
git -C "$TAP" commit -q -m "plume $VERSION" || fail "commit failed"
git -C "$TAP" push -q || fail "push failed"

echo "pushed $TAP_REPO @ $(git -C "$TAP" rev-parse HEAD)"
