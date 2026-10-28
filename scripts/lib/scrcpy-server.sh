# Guards against a Git LFS pointer standing in for scrcpy-server. Sourced by
# install-release.sh and package-release.sh, which each already run under
# `set -uo pipefail` and define fail().
#
# A checkout without Git LFS holds a small text pointer where the server's zip
# belongs, and every physical device tab then fails to connect.

SCRCPY_LFS_FIX="run \`git lfs pull\`, then rebuild Release"

SCRCPY_SOURCE="$(dirname "${BASH_SOURCE[0]}")/../../Plume/Resources/Scrcpy/scrcpy-server"

is_zip() { [ "$(head -c 2 "$1" 2>/dev/null)" = "PK" ]; }

check_scrcpy_server_source() {
  is_zip "$SCRCPY_SOURCE" \
    || fail "Plume/Resources/Scrcpy/scrcpy-server is not a zip (a Git LFS pointer?) — $SCRCPY_LFS_FIX"
}

check_scrcpy_server_bundled() {
  local app="$1"
  local server="$app/Contents/Resources/scrcpy-server"
  echo "--- bundled scrcpy-server (expect a zip, not a Git LFS pointer) ---"
  [ -f "$server" ] || fail "scrcpy-server missing from Contents/Resources — $SCRCPY_LFS_FIX"
  is_zip "$server" || fail "bundled scrcpy-server is not a zip (a Git LFS pointer?) — $SCRCPY_LFS_FIX"
  ls -l "$server"
}
