# Testing in a macOS VM

A macOS guest has its own window server, focus and launchd. So a debug build can be frontmost there, run menu commands, take screenshots and run UI tests without touching the host. PLUME-290 builds a pool of at most 2 guests, owned by the installed app. This document covers the base image, the pool in the app, and the spike that proved the path.

## Setup

1. Install Tart, which moved to `openai/tools`. Trust the `tart` and `softnet` formulas when Homebrew asks.

   ```
   brew tap openai/tools
   brew install tart
   ```

2. Run `scripts/vm/make-base-image.sh`. It needs no input and takes about 4 minutes once the vanilla image is cached.
3. Run a Plume that has the VM pool. `plume-vm` talks to the app at `PLUME_SOCKET`, so set it to the socket of the app that should own the VM. When you test a debug build of this feature, that is the debug build's socket, and `PLUME_CLI` is its `plume` tool.

## The base image

`scripts/vm/make-base-image.sh` builds `plume-base-<os>`, a stopped Tart VM in `~/.tart/vms`, where `<os>` is the host's macOS major. It runs in about 4 minutes once the vanilla image is cached; the first run downloads about 30 GB. It runs these steps:

1. Clone the Cirrus vanilla image for the host's major, then set 4 CPUs, 8 GB, a 120 GB disk and a 1920×1200 display.
2. Boot it with `tart run --no-graphics`, then install `~/Library/Application Support/Plume/vms/id_ed25519` with the vanilla password.
3. Stream the host's selected `Xcode.app` in over ssh, then accept the license, run `-runFirstLaunch`, and fail unless the guest's `xcodebuild -version` equals the host's.
4. Enable DevTools, the `_developer` group and automation mode without authentication. Turn off sleep, the screensaver, the screen lock, Spotlight and automatic updates.
5. Shut down, rename the VM to `plume-base-<os>`, and write `vms/base-<os>.json`.

Pass `--xcode=<Xcode.app>` to copy another Xcode, `--image=<ref>` to start from another image, and `--force` to replace an existing base. The guest user is `admin`, password `admin`, the image's published default.

## The pool

`VMManager.shared` (`Plume/VM/`) owns the guests. VMs need macOS 27: on an earlier host the VM tab shows only that, `vms.claim` fails with it, and the New VM Tab menu items are hidden. Slot `vm:<n>` always boots clone `plume-<os>-<n>` and keeps its share and control socket in `vms/vm<n>/`. Leases live in memory only, because the guests die with the app.

- **Claiming.** A claim answers at once and boots in the background: `reserved`, `cloning` (lock the clone, and clone the base if the clone is missing), `starting`, then `ready` once ssh answers and the guest user is logged in and unlocked. A clone is made under `<clone>-partial` and renamed once its `ecid` is rewritten, so a clone that exists is always complete. Readiness reads the DHCP lease for the clone's MAC on every poll, and accepts an address only when the guest there reports that MAC. The slot records the address as soon as that check passes, so a stop before `ready` still shuts the guest down over ssh. The claimant polls `vms.status`. A boot has 4 minutes before it fails.
- **Owners.** An owner that already holds a slot gets it renewed, and booted again if its boot failed. A claim naming another worktree fails, since shares are fixed at boot.
- **Clone locks.** An `flock` on `vms/<clone>.lock` is held for the VM's whole life, and the holder writes its pid into the file. A check for a free clone reads that pid and never takes the lock, so it can't make another Plume's boot fail. Taking the lock retries for a second. A slot whose clone another Plume holds reads `heldElsewhere`, and claims skip it.
- **Pool full.** Every slot leased, or Virtualization refusing another macOS guest (`VZError` code 6), reads as pool full. The tool exits 3 and lists the slots.
- **Failure.** A failed boot keeps its lease and `error`, so the claimant sees why; the tool then releases the slot.
- **Stopping.** Release, expiry (checked every minute) and closing or archiving the tab that owns the lease (`TaskStore.forgetTab`) stop the guest and keep the clone, so the next boot is warm. A VM tab that claimed a slot owns its lease: the lease renews itself while the tab is in a task that isn't archived, and closing the tab stops the guest. A VM tab that only shows a slot another owner holds never stops it on close. A lease an agent tab claimed through `plume devices` expires unless renewed. A stop runs after the slot's boot step in flight, asks the guest over ssh to shut down if its MAC is this clone's, and forces `stop()` 20 seconds after the stop began, trying twice. A VM still starting can't be stopped, so the stop waits for it. The clone lock is released only once the VM has stopped; a VM still running after both forced stops leaves the slot `failed` and its clone locked. `reset` deletes a free slot's clone, so the next claim clones the base again.
- **Quitting.** Quitting with a guest running asks first, then stops every guest and answers `.terminateLater`. A `tart clone` or `tart delete` in flight is killed, so a boot that hasn't started its VM ends at once. Guests get 8 seconds to shut down before they are forced. The app quits once every VM has stopped or failed a forced stop, or after 30 seconds.
- **Display.** `VMManager.displays[n]` is what a `VZVirtualMachineView` shows. Call `attach(to:)` on the main actor, which hands the view a `VZVirtualMachineViewAdaptor`; the VM itself stays on its slot's serial queue.
- **Entitlement.** The app is signed with `com.apple.security.virtualization` (`Configuration/Plume.entitlements`, also passed by `scripts/lib/sign-bundle.sh`).

## Using a VM: `scripts/vm/plume-vm`

`plume-vm` runs the debug build of the current worktree, or its UI tests, in a VM. It resolves the `plume` tool from `$PLUME_CLI`, else this worktree's build, else `plume` on PATH when `plume devices help` mentions `--kind=vm`. Any other result fails and names the problem.

| Command | What it does |
| --- | --- |
| `claim [--worktree=P]` | Leases a VM and prints `vm:<n>`. Same as `plume devices claim --kind=vm`, with the worktree defaulting to the script's checkout. |
| `release vm:<n>` | Releases the VM, then drops the slot's tunnel and pid files. A refused release leaves them. |
| `list` | Lists the VM slots. |
| `reset vm:<n>` | Deletes a free slot's clone. |
| `ssh [-- cmd…]` | Opens a shell, or runs one command, in your VM. |
| `prepare` | Mirrors the host paths in the guest (see below). `launch` and `test` run it first. |
| `launch [--app PATH] [--seed N] [--env K=V]…` | Copies the debug app in, starts it frontmost, and forwards its control socket to the host. |
| `test [--only-testing X]… [--skip-build]` | Builds for testing on the host, then runs the tests in the guest. |

Every command that needs a VM first runs `plume devices claim --kind=vm --json --worktree=<the script's checkout>`, so the guest always shares the checkout the script builds from. That call is idempotent: it renews the lease you already hold. `claim` defaults `--worktree` to that checkout too.

### Path mirroring

`prepare` symlinks the host's worktree path and share path in the guest to the mounts under `/Volumes/My Shared Files` (`worktree` and `share`). So `#filePath`, `BuildInfo.sourceRoot`, captures and xcresult paths read the same on both sides. It removes the previous owner's symlinks and the `~/PlumeVM` leftovers first. `BuildInfo.branch` reads nil in the guest, because the worktree's `.git` file points outside the share.

### Driving a VM build

```
PLUME_CLI=<worktree build>/Plume.app/Contents/Helpers/plume PLUME_SOCKET=<that app's socket> \
  scripts/vm/plume-vm claim
scripts/vm/plume-vm launch --seed 1
```

`launch` keeps one app and one tunnel per slot, with their pids in `~/Library/Application Support/Plume/vms/vm<n>/`. It kills the previous tunnel and the guest's `Plume` first. It then copies the app into the share with `cp -Rc`, runs `rsync -a --delete` into `~/PlumeVM/Plume.app` in the guest, and starts it with `open --env PLUME_CONTROL_SOCKET=/tmp/plume-control.sock`. It forwards that socket to the slot's `controlSocket`, checks it answers, and records the branch with `plume devices installed`. It then prints the `plume-control.py --socket <controlSocket> …` line to drive the app, as in the `drive-plume` skill.

Right after launch, the menu chords read disabled. Invoke the selected tab chip once, as the script prints:

```
scripts/debug/plume-control.py --socket <controlSocket> invoke target='{"id":"tab-chip","index":0}'
```

Release the VM when you finish: `scripts/vm/plume-vm release vm:<n>`. A VM left claimed holds one of the 2 slots until its lease expires.

### Running the tests

`test` refuses to run when the guest's `xcodebuild -version` differs from the host's. It stops any app and tunnel that `launch` started. Unless `--skip-build` is set, it runs `build-for-testing` into `build/vm-dd`. It copies `Build/Products` into the share, runs `rsync -a --delete` into `~/PlumeVM/Products` in the guest, then runs `test-without-building -xctestrun`. The default set is `PlumeUITests`, `PlumeTests/SurfaceCommandTests`, `PlumeTests/TerminalShortcutReclaimTests` and `PlumeTests/ControlHierarchyTests`; each `--only-testing` replaces it.

The script prints the host path of the `.xcresult` and its summary. It fails when a requested suite ran zero tests, and otherwise exits with `xcodebuild`'s status.

## Limits

- Guest Metal is paravirtualized. Use a VM for correctness, not performance.
- A guest never really sleeps, so it can't test sleep behavior.
- Each running VM uses about 8 GB of RAM.
- The guest's Xcode must match the host's. Rebuild the base image after an Xcode update.
- VMs die with their owning app. Quitting, relaunching or crashing it stops them.
- Virtualization allows 2 macOS guests per host, shared with every other app that runs one.

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
