# Testing in a macOS VM

A macOS guest has its own window server, focus and launchd. So a debug build can be frontmost there, run menu commands, take screenshots and run UI tests without touching the host. PLUME-290 builds a pool of at most 2 guests, owned by the installed app. This document starts with the base image and the spike that proved the path; the pool itself is documented as it lands.

## The base image

`scripts/vm/make-base-image.sh` builds `plume-base-<os>`, a stopped Tart VM in `~/.tart/vms`, where `<os>` is the host's macOS major. It runs in about 4 minutes once the vanilla image is cached; the first run downloads about 30 GB. It runs these steps:

1. Clone the Cirrus vanilla image for the host's major, then set 4 CPUs, 8 GB, a 120 GB disk and a 1920×1200 display.
2. Boot it with `tart run --no-graphics`, then install `~/Library/Application Support/Plume/vms/id_ed25519` with the vanilla password.
3. Stream the host's selected `Xcode.app` in over ssh, then accept the license, run `-runFirstLaunch`, and fail unless the guest's `xcodebuild -version` equals the host's.
4. Enable DevTools, the `_developer` group and automation mode without authentication. Turn off sleep, the screensaver, the screen lock, Spotlight and automatic updates.
5. Shut down, rename the VM to `plume-base-<os>`, and write `vms/base-<os>.json`.

Pass `--xcode=<Xcode.app>` to copy another Xcode, `--image=<ref>` to start from another image, and `--force` to replace an existing base. The guest user is `admin`, password `admin`, the image's published default.

## Spike findings

Measured on 2026-11-22: host macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Tart 2.42.0, guest image `ghcr.io/cirruslabs/macos-golden-gate-vanilla:27.2` (`sha256:b35695ce…`, macOS 27.2, 26B123).

### Image

- The macOS 27 vanilla image is `ghcr.io/cirruslabs/macos-golden-gate-vanilla`, with tags `latest`, `27.0` and `27.2`. macOS 26 is `macos-tahoe-vanilla`.
- The vanilla image already has user `admin`/`admin` (uid 501), Remote Login on, auto-login as `admin`, passwordless sudo, Gatekeeper off, FileVault off, the screen lock off, and `admin` in `_developer`.
- Cirrus builds the 27 image from an IPSW with `tart run --provisioning-opts=…` (`VZMacGuestProvisioningOptions`, macOS 27 on host and guest), with no Setup Assistant clicks. So building our own image from an IPSW is possible without a human if Cirrus ever lags.
- `tart set --disk-size 120` is enough: the guest's APFS container already fills the larger disk at the next boot, and `diskutil apfs resizeContainer … 0` is a harmless no-op.
- `tart run --no-graphics` registers as `BackgroundOnly`: no Dock icon, and the host's frontmost app doesn't change.

### The VM directory

- `~/.tart/vms/<name>/` holds `config.json`, `disk.img` (ASIF, `diskFormat: "asif"`) and `nvram.bin`.
- `config.json` has exactly these keys: `version` (1), `os` (`"darwin"`), `arch` (`"arm64"`), `cpuCount`, `cpuCountMin`, `memorySize`, `memorySizeMin` (bytes), `macAddress` (`"76:7b:f5:77:06:5d"`), `display` (`{"width":1024,"height":768}`), `hardwareModel` and `ecid` (both base64 of the VZ `dataRepresentation`), and `diskFormat`.
- `tart clone` gives each clone a new MAC but **copies the ecid unchanged**. Two clones then run at once with the same machine identifier and the same serial number. Writing `VZMacMachineIdentifier().dataRepresentation` (base64) to a clone's `ecid` boots fine and gives it a new serial, so Plume should do that after each clone.
- `tart get`/`tart list` report a clone as `stopped` while our own process runs it. Tart cannot see VMs it didn't start.

### Booting with our own VZVirtualMachine

- A windowless accessory process (`NSApp.setActivationPolicy(.accessory)`, registered as `UIElement`) boots a Tart clone from `config.json`, `disk.img` and `nvram.bin`. It never becomes frontmost.
- `com.apple.security.virtualization` is required even under ad hoc signing. Without it, `validate()` fails with `VZErrorDomain Code=2 "The process doesn't have the "com.apple.security.virtualization" entitlement."`.
- Signing with Developer ID, the hardened runtime and that entitlement also boots (not notarized; run locally).
- `VZVirtualMachine(configuration:queue:)` on a private serial queue works. A `VZVirtualMachineView` attached to it on the main thread raised nothing, and the VM kept running before, during and after the view was attached, and with no view at all.
- A real keystroke sent to the view (`keyDown(with:)`) reached the guest. Its `HIDIdleTime` reset.
- A third VM fails in `start` with `VZErrorDomain Code=6 "The maximum supported number of active virtual machines has been reached."` (`VZError.virtualMachineLimitExceeded`). `canStart` is still `true`, so the error is the only signal.
- `kill -9` on the owning process takes the VM with it. `com.apple.Virtualization.VirtualMachine` and its `Identity.Virtio` plugin exit within 3 seconds, and the clone boots normally afterwards.
- `requestStop()` returns no error, but a logged-in guest didn't shut down within 60 seconds. `sudo shutdown -h now` over ssh stops it in about 9 seconds, so use that and keep `stop()` as the fallback.
- Each running guest's XPC process holds about 8–9 GB resident.

### Network, shares and SSH

- The guest's address is in `/var/db/dhcpd_leases`, but the file drops leading zeros from each octet: the MAC `76:7b:f5:77:06:5d` appears as `hw_address=1,76:7b:f5:77:6:5d`. Normalize before matching.
- SSH answers about 12 seconds after `start()`. No Local Network prompt blocked SSH from an agent's process.
- A `VZVirtioFileSystemDeviceConfiguration` with `macOSGuestAutomountTag` and a `VZMultipleDirectoryShare` appears at `/Volumes/My Shared Files/<name>`. A read-only directory refuses writes with `Operation not permitted`.
- **Never copy a bundle out of a share with `ditto` or `cp -a`.** Reading a symlink's extended attributes over virtiofs fails with `Too many levels of symbolic links`, so both drop every framework symlink and the bundle fails `codesign --verify` (`bundle format unrecognized, invalid, or unsuitable`). `ditto --noextattr` fails too. `rsync -a` copies a valid bundle.
- Copies through a share also lose HFS compression: Xcode grew from 3.4 GB to 9.2 GB. `ditto -c "$xcode" - | ssh … 'sudo ditto -x --hfsCompression - /Applications/Xcode.app'` takes about 2m45s, lands at 3.7 GB, and passes `codesign --verify --deep --strict` and `spctl -a`.

### Xcode in the guest

- The host's Xcode 27.2 runs in the 27.2 guest: `xcodebuild -version` prints `Xcode 27.2` / `Build version 27B52`, and `-runFirstLaunch` takes about 45 seconds.
- `sudo automationmodetool enable-automationmode-without-authentication` prints `Enter the password for user 'root':` but succeeds without input.
- `softwareupdate --schedule off` still reports "Automatic checking for updates is turned on". The script sets the `com.apple.SoftwareUpdate` defaults instead.

### Running the debug app in the guest

- The guest user's uid is 501.
- **Readiness signal:** in `ioreg -n Root -d1 -a`, the `IOConsoleUsers` entry for `admin` has `kCGSSessionOnConsoleKey` and `kCGSessionLoginDoneKey` true, and has no `CGSSessionScreenIsLocked`. A locked session carries `CGSSessionScreenIsLocked = true` (seen on a locked host). The guest is ready about 13 seconds after boot, and `lsappinfo front` then names Finder, not loginwindow. `launchctl print gui/501` alone succeeds earlier.
- `open --env PLUME_CONTROL_SOCKET=/tmp/plume-control.sock --env PLUME_SEED_TASKS=1 <app>` over ssh launches the app frontmost: guest `lsappinfo front` names it, and `NSRunningApplication.isActive` is true. `launchctl asuser` is not needed, and fails with `Could not switch to audit session … Operation not permitted`.
- **macOS relaunches an app that was open at shutdown,** without the environment. `open --env` then fails with `Application … was already running and so the additional environment variables could not be set.`, even with `TALLogoutSavesState` and `LoginwindowLaunchesRelaunchApps` off. So kill any running instance (`pkill -x Plume`) before every launch.
- A terminal tab spawns `login` → `-zsh` on `ttys000` under the app's PID, so libghostty renders in the guest.
- `ssh -f -N -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes -L "<app support>/Plume/vms/vm1/control.sock:/tmp/plume-control.sock"` forwards the control socket, and `plume-control.py --socket <that path>` drives the guest app. The host path is 73 bytes, under the 104-byte limit.
- `screenshot path="/Volumes/My Shared Files/share/shot.png"` writes a real 1180×760 PNG that appears on the host at once.
- **Right after launch, every `focusedSceneValue` is nil**, so the Tab menu and most of the File menu read disabled even though the app is active and its window is key. Selecting a task row doesn't change that. Opening a tab or invoking a `tab-chip` does, and from then on `key key=t modifiers='["command"]'` reports `handledBy: "File > New Terminal Tab"`, `handledByEnabled: true` and adds a tab chip. Menu items without a focused value (`⌘,` opens Settings) work from the start. Invoke the selected tab chip once after launch.

### Tests in the guest

- `build-for-testing -derivedDataPath <worktree>/build/vm-dd` writes an `.xctestrun` whose paths are all `__TESTROOT__`-relative, so the products tree can move. Copy `Build/Products` into the share with `cp -Rc`, then `rsync -a` it to guest-local disk.
- `xcodebuild test-without-building -xctestrun Products/Plume_Plume_macosx27.2-arm64.xctestrun -destination 'platform=macOS' -only-testing:PlumeTests/SurfaceCommandTests -only-testing:PlumeUITests -resultBundlePath r.xcresult` runs unattended over ssh with no authentication prompt. On the script-built base: 6 passed, 2 failed, about 1m20s. The host reads the `.xcresult` after it is copied back through the share.
- `PlumeUITests.testNewTaskButtonIsAccessible` and `testComposerFieldIsAccessibleWithSeededTask` failed on both guest runs, timing out on the identifier lookup. They have no host baseline yet, since running them on the host takes focus.
- On one run all three `SurfaceCommandTests` crashed the test host with `EXC_BAD_ACCESS` in `objc_release` during an autorelease pool pop under `XCTWaiter`. On the next run, on a fresh clone, all three passed.
