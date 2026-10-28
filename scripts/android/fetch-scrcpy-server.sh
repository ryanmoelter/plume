#!/usr/bin/env bash
# Downloads a scrcpy-server release, verifies it against the release's SHA256SUMS.txt,
# and vendors it into Plume/Resources/Scrcpy.
# Usage: fetch-scrcpy-server.sh <version>   (e.g. 5.0.1)
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <version>" >&2
  exit 2
fi
version="$1"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/Plume/Resources/Scrcpy"
BASE="https://github.com/Genymobile/scrcpy/releases/download/v$version"
ASSET="scrcpy-server-v$version"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL -o "$work/$ASSET" "$BASE/$ASSET"
curl -fsSL -o "$work/SHA256SUMS.txt" "$BASE/SHA256SUMS.txt"

expected="$(awk -v name="$ASSET" '$2 == name { print $1 }' "$work/SHA256SUMS.txt")"
if [[ -z "$expected" ]]; then
  echo "SHA256SUMS.txt has no entry for $ASSET" >&2
  exit 1
fi
actual="$(shasum -a 256 "$work/$ASSET" | awk '{ print $1 }')"
if [[ "$expected" != "$actual" ]]; then
  echo "sha256 mismatch for $ASSET: expected $expected, got $actual" >&2
  exit 1
fi

if [[ "$(head -c 2 "$work/$ASSET")" != "PK" ]]; then
  echo "$ASSET is not a zip archive" >&2
  exit 1
fi

mkdir -p "$OUT"
cp "$work/$ASSET" "$OUT/scrcpy-server"
printf 'scrcpy %s\n%s\nsha256 %s (verified against SHA256SUMS.txt)\nApache-2.0, see scrcpy-LICENSE.txt\n' \
  "$version" "$BASE/$ASSET" "$actual" > "$OUT/scrcpy-VERSION.txt"

echo "Vendored $ASSET ($actual) into $OUT"
echo "Set ScrcpyServerVersion.pinned to $version and check the wire format against the release; the server refuses any other client version."
