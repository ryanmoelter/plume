#!/usr/bin/env bash
# Builds the macOS base image Plume's VM pool clones: a Cirrus vanilla image for the host's
# macOS major, set up to run the debug app unattended. It has no Xcode unless asked, which is
# enough for `plume-vm launch`; `plume-vm test` needs --with-xcode. Tart boots the VM during
# setup only; the result is a stopped `plume-base-<os>` VM in ~/.tart/vms. docs/vm-testing.md
# is the reference.
# Usage: make-base-image.sh [--with-xcode[=<Xcode.app>] | --xip=<Xcode.xip>] [--image=<oci ref>] [--force]
#   --with-xcode  copy in Xcode, to run UI tests (default: the selected Xcode, from xcode-select -p)
#   --xip         copy in the Xcode inside this .xip instead; implies --with-xcode
#   --image       the vanilla image to start from (default: the Cirrus vanilla image for the host's macOS major)
#   --force       replace an existing plume-base-<os>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT/scripts/vm/lib.sh"
# Cirrus's published default; the vanilla image ships with it.
GUEST_PASSWORD=admin

with_xcode=0
xcode=""
xip=""
image=""
force=0
for arg in "$@"; do
  case "$arg" in
    --with-xcode) with_xcode=1 ;;
    --with-xcode=*) with_xcode=1; xcode="${arg#--with-xcode=}" ;;
    --xip=*) with_xcode=1; xip="${arg#--xip=}" ;;
    --image=*) image="${arg#--image=}" ;;
    --force) force=1 ;;
    -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

command -v tart >/dev/null || { echo "tart is not installed: brew tap openai/tools && brew install tart" >&2; exit 1; }

os="$(sw_vers -productVersion | cut -d. -f1)"
if [[ -z "$image" ]]; then
  case "$os" in
    27) image="ghcr.io/cirruslabs/macos-golden-gate-vanilla:latest" ;;
    26) image="ghcr.io/cirruslabs/macos-tahoe-vanilla:latest" ;;
    *) echo "no known Cirrus vanilla image for macOS $os; pass --image=" >&2; exit 1 ;;
  esac
fi
if [[ -n "$xip" && -n "$xcode" ]]; then
  echo "pass --xip or --with-xcode=<Xcode.app>, not both" >&2
  exit 2
fi
[[ -z "$xip" || -f "$xip" ]] || { echo "no such file: $xip" >&2; exit 1; }
[[ -z "$xip" ]] || xip="$(cd "$(dirname "$xip")" && pwd)/$(basename "$xip")"

base="plume-base-$os"
build="$base-build"
if tart get "$base" >/dev/null 2>&1; then
  [[ $force -eq 1 ]] || { echo "$base already exists; pass --force to replace it" >&2; exit 1; }
fi
tart delete "$build" >/dev/null 2>&1 || true

work="$(mktemp -d)"
tart_pid=""
cleanup() {
  if [[ -n "$tart_pid" ]] && kill -0 "$tart_pid" 2>/dev/null; then
    tart stop "$build" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

host_xcode=""
if [[ $with_xcode -eq 1 ]]; then
  if [[ -n "$xip" ]]; then
    echo "==> Expanding $xip"
    mkdir "$work/xip"
    (cd "$work/xip" && xip --expand "$xip")
    xcode="$(find "$work/xip" -maxdepth 1 -name '*.app' | head -1)"
  elif [[ -z "$xcode" ]]; then
    xcode="$(cd "$(xcode-select -p)/../.." && pwd)"
  fi
  [[ -d "$xcode/Contents/Developer" ]] || { echo "not an Xcode bundle: $xcode" >&2; exit 1; }
  host_xcode="$(DEVELOPER_DIR="$xcode/Contents/Developer" xcodebuild -version | paste -sd' ' -)"
fi

printf '#!/bin/sh\necho %s\n' "$GUEST_PASSWORD" > "$work/askpass"
chmod +x "$work/askpass"
cat > "$work/ssh_config" <<EOF
Host *
  User $GUEST_USER
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
  ConnectTimeout 5
  ServerAliveInterval 30
  IdentityFile "$KEY"
  IdentitiesOnly yes
EOF
guest() { ssh -F "$work/ssh_config" -o BatchMode=yes "$ip" "$@"; }

echo "==> Cloning $image to $build (the first run downloads about 30 GB)"
tart clone "$image" "$build"
tart set "$build" --cpu 4 --memory 8192 --display 1920x1200
# Only Xcode and its build products need more than the vanilla image's disk.
[[ $with_xcode -eq 0 ]] || tart set "$build" --disk-size 120

mkdir -p "$VMS_DIR"
chmod 700 "$VMS_DIR"
[[ -f "$KEY" ]] || ssh-keygen -q -t ed25519 -N '' -C plume-vm -f "$KEY"

echo "==> Booting $build"
tart run --no-graphics "$build" > "$work/tart-run.log" 2>&1 &
tart_pid=$!
ip="$(tart ip "$build" --wait 180)"
for _ in $(seq 1 60); do nc -z -G 2 "$ip" 22 2>/dev/null && break; sleep 2; done

echo "==> Installing the ssh key"
SSH_ASKPASS="$work/askpass" SSH_ASKPASS_REQUIRE=force \
  ssh-copy-id -F "$work/ssh_config" -i "$KEY.pub" "$ip" >/dev/null 2>&1
guest true

if [[ $with_xcode -eq 1 ]]; then
  echo "==> Growing the disk"
  guest 'sudo diskutil apfs resizeContainer "$(diskutil info -plist / | plutil -extract ParentWholeDisk raw -o - -)" 0 >/dev/null 2>&1 || true; df -h / | tail -1'

  # Streamed over ssh, not copied through a share: reading a symlink's extended attributes
  # over virtiofs fails with ELOOP, so ditto and cp -a drop every framework symlink.
  echo "==> Copying $xcode into the guest"
  guest 'sudo rm -rf /Applications/Xcode.app'
  ditto -c "$xcode" - | ssh -F "$work/ssh_config" -o BatchMode=yes -o Compression=no "$ip" \
    'sudo ditto -x --hfsCompression - /Applications/Xcode.app'
  guest 'codesign --verify --deep --strict /Applications/Xcode.app'

  echo "==> Setting up Xcode"
  guest 'sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch >/dev/null'
  guest_xcode="$(guest 'xcodebuild -version' | paste -sd' ' -)"
  if [[ "$guest_xcode" != "$host_xcode" ]]; then
    echo "guest Xcode ($guest_xcode) differs from the host's ($host_xcode)" >&2
    exit 1
  fi

  # DevTools, the _developer group and automation mode exist for xcodebuild and XCUITest.
  echo "==> Enabling developer tools"
  guest bash -s <<'EOF'
set -euo pipefail
sudo DevToolsSecurity -enable >/dev/null
sudo dseditgroup -o edit -a admin -t user _developer
sudo automationmodetool enable-automationmode-without-authentication </dev/null >/dev/null 2>&1
EOF
fi

echo "==> Configuring the guest for unattended use"
guest bash -s <<'EOF'
set -euo pipefail
sudo pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 standby 0
defaults -currentHost write com.apple.screensaver idleTime -int 0
sudo defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime -int 0
sysadminctl -screenLock off -password admin >/dev/null 2>&1
sudo mdutil -a -i off >/dev/null 2>&1
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
defaults write com.apple.loginwindow TALLogoutSavesState -bool false
defaults write com.apple.loginwindow LoginwindowLaunchesRelaunchApps -bool false
EOF

echo "==> Checking the guest"
guest bash -s <<'EOF'
set -euo pipefail
sudo -n true
[[ "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser)" == admin ]]
sudo -n systemsetup -getremotelogin | grep -q 'On'
EOF
if [[ $with_xcode -eq 1 ]]; then
  guest bash -s <<'EOF'
set -euo pipefail
automationmodetool | grep -q 'DOES NOT REQUIRE'
DevToolsSecurity -status | grep -q enabled
EOF
fi

echo "==> Shutting down"
guest 'sudo shutdown -h now' >/dev/null 2>&1 || true
wait "$tart_pid" || true
tart_pid=""

tart delete "$base" >/dev/null 2>&1 || true
tart rename "$build" "$base"
if [[ $with_xcode -eq 1 ]]; then
  xcode_meta="\"xcode\": true,
  \"xcodeVersion\": \"$host_xcode\","
  mode="with Xcode: $host_xcode"
else
  xcode_meta='"xcode": false,'
  mode="without Xcode; plume-vm test needs --with-xcode"
fi
cat > "$VMS_DIR/base-$os.json" <<EOF
{
  "name": "$base",
  "image": "$image",
  $xcode_meta
  "hostMacOS": "$(sw_vers -productVersion) ($(sw_vers -buildVersion))",
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "tart": "$(tart --version)"
}
EOF
echo "==> Built $base ($mode)"

# Slot clones were made from the old base. Delete each one under its clone lock, so a Plume
# booting it meanwhile keeps it; the app's next claim clones the new base.
skipped=()
while IFS= read -r clone; do
  [[ "$clone" =~ ^plume-$os-[0-9]+$ ]] || continue
  if perl -e 'use Fcntl ":flock"; open(my $f, ">>", shift) or exit 2; flock($f, LOCK_EX | LOCK_NB) or exit 3; system(@ARGV); exit($? == 0 ? 0 : 1)' \
    "$VMS_DIR/$clone.lock" tart delete "$clone"; then
    echo "==> Deleted stale clone $clone"
  else
    skipped+=("$clone")
  fi
done < <(tart list --source local -q)
for clone in ${skipped[@]+"${skipped[@]}"}; do
  echo "warning: $clone is in use or could not be deleted, so it still has the old base; once it is free, run: plume devices reset vm:${clone##*-}" >&2
done
