# Testing in a macOS VM

A macOS guest has its own window server, focus and launchd. So a debug build can be frontmost there, run menu commands, take screenshots and run UI tests without touching the host. PLUME-290 builds a pool of at most 2 guests, owned by the installed app. This document covers the base image, the pool in the app, and the spike that proved the path.

## Setup

0. Turn on **Settings ▸ Labs ▸ macOS VMs for testing** in the Plume that will own the VMs. It is off by default. Off, the device picker shows no macOS VMs section unless a VM is left from before, and every `vms.*` socket command answers "macOS VMs are a Labs feature; turn them on in Settings ▸ Labs", which `plume devices … --kind=vm` prints before exiting 1. From a shell, `defaults write com.ryanmoelter.Plume labsVMsEnabled -bool true` (`com.ryanmoelter.Plume.debug` for every debug build) turns it on; the app reads it at launch, so relaunch after. Turning it off while VMs run stops nothing: new claims are refused, while the socket, the picker and the VM tab still offer a VM left from before (leased, running, or one that didn't stop) so it can be shown and released, and leases run out or are released as usual. `VMManager` starts its reaper on the first claim and touches no Tart until then, so a Plume that never opts in pays nothing.
1. Install Tart, which moved to `openai/tools`. Homebrew refuses its `tart` and `softnet` formulas until they are trusted.

   ```
   brew tap openai/tools
   brew trust --formula openai/tools/tart
   brew trust --formula openai/tools/softnet
   brew install tart
   ```

2. Run `scripts/vm/make-base-image.sh`. It needs no input. The base has no Xcode, which is all `plume-vm launch` needs. To run `plume-vm test` too, add `--with-xcode`, which copies in the host's Xcode and takes longer (about 4 minutes once the vanilla image is cached; the Xcode copy is most of that). Without Xcode the base builds faster and is about 8 GB smaller on the host.
3. Run a Plume that has the VM pool. `plume-vm` talks to the app at `PLUME_SOCKET`, so set it to the socket of the app that should own the VM. When you test a debug build of this feature, that is the debug build's socket, and `PLUME_CLI` is its `plume` tool.
4. Grant the debug app Full Disk Access once per base image: build the debug app, then run `scripts/vm/plume-vm grant-fda` and follow what it prints. Without the grant, the app's first launch in each clone opens its "Grant Full Disk Access?" sheet, which blocks an agent driving it. See [Full Disk Access](#full-disk-access).

The `plume-vm-setup` project skill walks through these steps and the rebuild.

## The base image

`scripts/vm/make-base-image.sh` builds `plume-base-<os>`, a stopped Tart VM in `~/.tart/vms`, where `<os>` is the host's macOS major. The first run downloads about 30 GB. Without Xcode it runs steps 1, 2, 4 and 5; `--with-xcode` adds step 3 and takes about 4 minutes once the vanilla image is cached. The steps:

1. Clone the Cirrus vanilla image for the host's major, then set 4 CPUs, 8 GB and a 1920×1200 display. With Xcode the disk grows to 120 GB; without it the vanilla image's 50 GB disk stays, since only Xcode and its build products need the room.
2. Boot it with `tart run --no-graphics`, then install `~/Library/Application Support/Plume/vms/id_ed25519` with the vanilla password.
3. With Xcode only: stream the host's selected `Xcode.app` in over ssh, then accept the license, run `-runFirstLaunch`, fail unless the guest's `xcodebuild -version` equals the host's, and enable DevTools, the `_developer` group and automation mode without authentication. Those three exist for `xcodebuild` and XCUITest.
4. Turn off sleep, the screensaver, the screen lock, Spotlight and automatic updates.
5. Shut down, rename the VM to `plume-base-<os>`, and write `vms/base-<os>.json`. The file records `"xcode": true` with `"xcodeVersion"`, or `"xcode": false`. A file without the field, or with a version string in `xcode` as older bases wrote, means the base has Xcode. It also records `"fullDiskAccess": false`. `plume-vm grant-fda` replaces it with the bundle ID it granted, a string, so the field is either `false` or a bundle ID. The script prints the mode at the end, then names `plume-vm grant-fda` as the next step, since a new base has no Full Disk Access grant.

Pass `--with-xcode` to copy in the selected Xcode, `--with-xcode=<Xcode.app>` for another one, `--xip=<Xcode.xip>` to expand and copy a `.xip` (both imply Xcode), `--image=<ref>` to start from another image, and `--force` to replace an existing base. A rebuild then deletes every `plume-<os>-<n>` clone whose lock is free, since they were cloned from the old base, and names any it skipped; run `plume devices reset vm:<n>` on those once they are free. The guest user is `admin`, password `admin`, the image's published default.

## The pool

`VMManager.shared` (`Plume/VM/`) owns the guests. VMs need Labs turned on (Setup step 0) and macOS 27: on an earlier host the device picker's macOS VMs section and the VM tab show only that, and `vms.claim` fails with it.

A device tab is the one way into a VM from the UI. Its picker lists the slots under macOS VMs, with Claim for a free slot and Show for a leased or running one. Either turns the tab into a VM tab (`TabKind.vm`, `vmSlot` set) in place, through `TaskStore.showVM`. Change Slot and Release turn it back into a device tab showing the picker (`TaskStore.showDevicePicker`), and so does a VM tab left with no slot. Slot `vm:<n>` always boots clone `plume-<os>-<n>` and keeps its share and control socket in `vms/vm<n>/`. Leases live in memory only, because the guests die with the app.

- **Claiming.** A claim answers at once and boots in the background: `reserved`, `cloning` (lock the clone, and clone the base if the clone is missing), `starting`, then `ready` once ssh answers and the guest user is logged in and unlocked. A clone is made under `<clone>-partial` and renamed once its `ecid` is rewritten, so a clone that exists is always complete. A release or a closed tab during `cloning` kills the `tart clone` and removes the partial copy. Readiness reads the DHCP lease for the clone's MAC on every poll, and accepts an address only when the guest there reports that MAC. The slot records the address as soon as that check passes, so a stop before `ready` still shuts the guest down over ssh. The claimant polls `vms.status`, and fails with `lease lost` if the slot's `owner` or `leaseToken` stops matching the lease it claimed. A boot has 4 minutes before it fails.
- **Owners.** An owner that already holds a slot gets it renewed for its own TTL unless the claim names one, and booted again if its boot failed. A claim for a particular slot (the picker's) fails while the owner holds a different one. A claim naming another worktree fails, since shares are fixed at boot. Worktrees are compared with symlinks resolved.
- **Clone locks.** An `flock` on `vms/<clone>.lock` is held for the VM's whole life, and the holder writes its pid and process start time into the file. A check for a free clone reads that record and never takes the lock, so it can't make another Plume's boot fail. The clone counts as held only while that pid is alive with the same start time, so a crashed holder's reused pid reads free, and this app's own lock never counts. The check runs off the main actor, on each claim, reset, `vms.status` and `vms.list`. Taking the lock retries for a second. A slot whose clone another Plume holds reads `heldElsewhere`, and claims skip it.
- **Pool full.** Every slot leased, or Virtualization refusing another macOS guest (`VZError` code 6), reads as pool full. The tool exits 3 and lists the slots.
- **Failure.** A failed boot keeps its lease and `error`, so the claimant sees why; the tool then releases the slot.
- **Stopping.** Release, expiry (checked every minute) and closing or archiving the tab that owns the lease (`TaskStore.forgetTab`) stop the guest and keep the clone, so the next boot is warm. A VM tab that claimed a slot owns its lease: the lease renews itself while the tab is a VM tab in a task that isn't archived, wherever its window is. Change Slot and Release end that lease and stop the guest, and closing the tab does too. A claim whose tab closes while it checks the host fails without booting. A VM tab that only shows a slot another owner holds never stops it on close, and its toolbar offers only Force Release…, which asks first and names the holder. A lease an agent tab claimed through `plume devices` expires unless renewed. A stop runs after the slot's boot step in flight, asks the guest over ssh to shut down if its MAC is this clone's, and forces `stop()` 20 seconds after the stop began, trying twice. A VM still starting can't be stopped, so the stop waits for it, for up to 60 seconds. The clone lock is released only once the VM has stopped. A VM still running after both forced stops leaves the slot `failed` and its clone locked, and still counts as running for the quit alert. A retry, a release (by anyone, once the slot has no lease) or a reset on that slot stops the VM again first, and goes on only once it stops. `reset` deletes a free slot's clone, so the next claim clones the base again; the slot reads `resetting` meanwhile, which the quit alert doesn't count.
- **Quitting.** Quitting with a guest running asks first, then stops every guest and answers `.terminateLater`. A `tart clone` or `tart delete` in flight is killed, so a boot that hasn't started its VM ends at once. Guests get 8 seconds to shut down before they are forced. The app quits once every VM has stopped or failed a forced stop, or after 30 seconds.
- **Display.** `VMManager.displays[n]` is what a `VZVirtualMachineView` shows. Call `attach(to:)` on the main actor, which hands the view a `VZVirtualMachineViewAdaptor`; the VM itself stays on its slot's serial queue.
- **Entitlement.** The app is signed with `com.apple.security.virtualization` (`Configuration/Plume.entitlements`, also passed by `scripts/lib/sign-bundle.sh`).

## Using a VM: `scripts/vm/plume-vm`

`plume-vm` runs the debug build of the current worktree, or its UI tests, in a VM. It resolves the `plume` tool from `$PLUME_CLI`, else this worktree's build, else `plume` on PATH, and takes the first whose `plume devices help` shows `--mine [--kind=vm]`. A Plume tab sets `PLUME_CLI` to its own app's tool, and a tool older than the VM pool reads `vm:<n>` as an Android serial: `release vm:1` then prints `vm:1 was not leased` and `list --kind=vm` is rejected. So the script skips such a tool and says so. Any other result fails and names the problem.

| Command | What it does |
| --- | --- |
| `claim [--worktree=P]` | Leases a VM and prints `vm:<n>`. Same as `plume devices claim --kind=vm`, with the worktree defaulting to the script's checkout. |
| `release [vm:<n>]` | Releases that VM, or without a key every VM you hold (`plume devices release --mine --kind=vm`), then drops each slot's tunnel and pid files. A refused release leaves them. |
| `list` | Lists the VM slots. |
| `reset vm:<n>` | Deletes a free slot's clone. |
| `ssh [-- cmd…]` | Opens a shell, or runs one command, in your VM. |
| `prepare` | Mirrors the host paths in the guest (see below). `launch` and `test` run it first. |
| `launch [--app PATH] [--seed N] [--env K=V]…` | Copies the debug app in, starts it frontmost, and forwards its control socket to the host. |
| `test [--only-testing X]… [--skip-build]` | Builds for testing on the host, then runs the tests in the guest. Needs a base with Xcode. |
| `grant-fda [--app PATH]` | Walks a person through granting the debug app Full Disk Access in a VM, checks it, then saves that VM as the base image. See [Full Disk Access](#full-disk-access). |

Every command that needs a VM first runs `plume devices claim --kind=vm --json --worktree=<the script's checkout>`, so the guest always shares the checkout the script builds from. That call is idempotent: it renews the lease you already hold. `claim` defaults `--worktree` to that checkout too.

### Path mirroring

`prepare` symlinks the host's worktree path and share path in the guest to the mounts under `/Volumes/My Shared Files` (`worktree` and `share`). So `#filePath`, `BuildInfo.sourceRoot`, captures and xcresult paths read the same on both sides. It removes the previous owner's symlinks and the `~/PlumeVM` leftovers first. `BuildInfo.branch` reads nil in the guest, because the worktree's `.git` file points outside the share.

### Driving a VM build

```
PLUME_CLI=<worktree build>/Plume.app/Contents/Helpers/plume PLUME_SOCKET=<that app's socket> \
  scripts/vm/plume-vm claim
scripts/vm/plume-vm launch --seed 1
```

`launch` keeps one app and one tunnel per slot, with their pids in `~/Library/Application Support/Plume/vms/vm<n>/`. It kills the previous tunnel and the guest's `Plume` first. It then copies the app into a fresh `app-<time>` folder in the share with `cp -Rc` (the guest's virtiofs can keep listing a recreated folder as empty), runs `rsync -a --delete` into `~/PlumeVM/Plume.app` in the guest, and starts it with `open --env PLUME_CONTROL_SOCKET=/tmp/plume-control.sock`. It forwards that socket to the slot's `controlSocket`, checks it answers, and records the branch with `plume devices installed`. It then prints the `plume-control.py --socket <controlSocket> …` line to drive the app, as in the `drive-plume` skill. After the launch, when the guest's TCC database has no Full Disk Access grant for the app, it prints one line naming `plume-vm grant-fda`. When it can't read the database, it says so instead. It never answers the sheet for you.

Right after launch, the menu chords read disabled. Invoke the selected tab chip once, as the script prints:

```
scripts/debug/plume-control.py --socket <controlSocket> invoke target='{"id":"tab-chip","index":0}'
```

Release the VM when you finish: `scripts/vm/plume-vm release`. A VM left claimed holds one of the 2 slots until its lease expires.

### Running the tests

`test` needs a base built with `--with-xcode`. It checks the claimed guest for `/Applications/Xcode.app` over ssh (the metadata file is informational only, since a skipped clone can differ from the rebuilt base) and, with none, refuses before building, naming `scripts/vm/make-base-image.sh --with-xcode --force`. A `--force` rebuild leaves existing slot clones on the old base, so run `plume devices reset vm:<n>` on any it skipped. `launch`, `prepare` and `ssh` work on either kind of base. `test` also refuses when the guest's `xcodebuild -version` differs from the host's. It stops any app and tunnel that `launch` started. Unless `--skip-build` is set, it runs `build-for-testing` into `build/vm-dd`. It copies `Build/Products` into the share, runs `rsync -a --delete` into `~/PlumeVM/Products` in the guest, then runs `test-without-building -xctestrun`. The default set is `PlumeUITests`, `PlumeTests/SurfaceCommandTests`, `PlumeTests/TerminalShortcutReclaimTests` and `PlumeTests/ControlHierarchyTests`; each `--only-testing` replaces it.

The script prints the host path of the `.xcresult` and its summary. It fails when any `--only-testing` identifier matches no test that ran, comparing each of its components (target, suite, test) in full, and otherwise exits with `xcodebuild`'s status.

## Full Disk Access

Plume shows its "Grant Full Disk Access?" sheet on the first launch that finds the permission missing (`MainWindow`, any build). `FullDiskAccess.isGranted` probes by opening TCC's database, and `hasPromptedForFullDiskAccess` in the app's defaults records that it asked, whatever the answer. A fresh clone has neither, so the sheet opens over the window an agent is about to drive.

**No script can grant it.** Full Disk Access is a TCC grant. SIP protects `TCC.db` even from root (`sudo touch` there fails with `Operation not permitted` in the guest), the guest is enrolled in no MDM, and only MDM can push a profile that grants Full Disk Access. So a person grants it once per base image, by hand, and every clone inherits it.

**The grant survives debug rebuilds.** TCC stores the grant against the bundle ID (`client_type` 0), not a path, with the app's designated requirement as its `csreq`. A Development-signed debug build's requirement names the bundle ID and the signing certificate's common name, with no cdhash: `identifier "com.ryanmoelter.Plume.debug" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: …" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */`. So a rebuild signed with the same certificate keeps the grant, and so does `launch` deleting and recopying `~/PlumeVM/Plume.app`. A build signed by another certificate, or ad hoc, doesn't match. Rebuilding the base image with `make-base-image.sh` loses the grant, so grant it again afterwards; the script says so at the end.

### Granting it: `plume-vm grant-fda`

Run it from a terminal with `PLUME_SOCKET` naming the Plume whose VM tab you'll use, after building the debug app. It:

1. Finishes a swap an earlier run left half done, under every slot's clone lock. With `plume-base-<os>` missing, it renames `plume-base-<os>-fda` into place and deletes `plume-base-<os>-old`, or, with no `-fda`, renames `-old` back. With the base present, it deletes a leftover `-old`.
2. Refuses to start while you hold a VM, since a claim would hand that VM back and the script would later release it. If an earlier run's save failed, it resumes that save at step 10 instead of asking for the grant again (see below). Otherwise it claims a VM. The clone becomes the base, so it must be a fresh clone of the current base: if the claimed clone existed before the claim, the script releases it, resets that slot with `plume devices reset`, and claims again. Other slots' clones stay.
3. Checks the guest's TCC database over ssh. The Cirrus image grants `sshd-keygen-wrapper` Full Disk Access, so ssh can read the database (`select max(auth_value) from access where service='kTCCServiceSystemPolicyAllFiles' and client='<bundle id>' and client_type=0`; 2 is granted).
4. Launches the app without `prepare`'s path links. When the fresh clone already has the grant, the base has it too, but the grant may name another signing certificate. So the script runs the sheet check from step 7. If the sheet stays away, it cleans up as in step 8, releases the VM and stops there.
5. Opens System Settings ▸ Privacy & Security ▸ Full Disk Access in the guest, then prints the steps. The app's probe already added it to that list, switched off. In Plume, open a device tab and click Show on the VM. In the guest, turn on Plume α, enter the password `admin`, and click Later if macOS offers to quit and reopen it.
6. Polls the database every 3 seconds, for up to 15 minutes, until the grant appears. If ssh fails 5 times in a row, the VM is gone, and the script fails at once.
7. Deletes `hasPromptedForFullDiskAccess` and relaunches the app. It waits for the main window, then fails if the sheet's `full-disk-access-dismiss-button` appears within 10 seconds.
8. Quits the app, found by its path under `~/PlumeVM`, and System Settings. It unregisters `~/PlumeVM/Plume.app` from LaunchServices. It removes the debug app's defaults and ByHost defaults, `Plume.debug*` data, caches, logs and saved state, and `~/PlumeVM`. It also removes `~/.claude`, `~/.claude/skills`, `~/.claude.json`, `~/.zsh_history`, `~/.zsh_sessions` and `~/Library/Application Support/Plume` when they didn't exist before the launch.
9. Shuts the guest down with `sudo shutdown -h now`. It waits up to 2 minutes for Plume to report that the guest stopped on its own: the slot reads `failed` with the error `vm:<n> stopped` and no reason. A forced stop or a crash can leave the disk inconsistent, so anything else fails the script and saves nothing.
10. Writes `vms/grant-fda-<os>.pending`, naming the granted clone, the bundle ID and the clone's `disk.img` modification time. It keeps the VM's lease, so no one boots the clone meanwhile. Then it takes every slot's clone lock, so no Plume clones a half-replaced base. While any VM runs, it names the busy slot and retries for up to 10 minutes. Under the locks, it checks that the clone's disk is unchanged since the grant. It clones the slot's clone to `plume-base-<os>-fda`, renames the old base to `plume-base-<os>-old` and the new one into place, then deletes the old one. A failed rename puts the old base back. It then deletes every `plume-<os>-<n>` clone, since they all hold the old base.
11. Deletes the pending file, records `"fullDiskAccess": "<bundle id>"` in `vms/base-<os>.json`, warning if it can't, and releases the VM.

**A failed save keeps the grant.** If a VM still runs after 10 minutes, or the swap fails, the script exits but keeps the granted clone and the pending file, and says so. Release every VM, leave that slot unclaimed, and run `grant-fda` again with the same app: it skips the grant and resumes at the save. A rerun forgets the pending file when the clone is gone or its disk changed, since a boot since then makes it no longer fresh, and then grants afresh. `make-base-image.sh` deletes the pending file, since a rebuilt base makes it stale.

If the script exits early, from an error, Ctrl-C or the 15-minute timeout, it releases its VM and drops the tunnel. A failed status poll while it waits for the shutdown is retried, not read as a lost lease. If you interrupt the claim, the script doesn't know the slot yet, so it releases every VM you hold. Step 2 made sure that is only this run's VM.

The scripts take clone locks with `with_locks` in `scripts/vm/lib.sh`. While it holds a lock, it writes the pid and start-time record `VMCloneLock` writes, and it clears the record on release. So a Plume checking for a free clone sees the script's locks. `with_slot_locks` locks slots 1 to `VM_SLOTS` plus any other `plume-<os>-*.lock` that exists.

The VM tab is the only window it needs; no `tart run` window opens on the host. A `tart run --no-graphics` boot of the base itself would need a VNC client to click in, because Plume's VM tab shows only the VMs Plume boots.

### Findings

Measured on 2026-11-23 in a clone of the macOS 27.2 base:

- The guest has no per-user `~/Library/Application Support/com.apple.TCC/TCC.db`, and neither does a macOS 27.2 host. `FullDiskAccess.isGranted` therefore probes `/Library/Application Support/com.apple.TCC/TCC.db` first, which always exists, and the user's file second.
- That system database refuses a process without Full Disk Access. A `launchctl submit` job in the guest gets `Operation not permitted` from it, and from `~/Library/Safari` and `~/Library/Mail`; ssh, which holds Full Disk Access, reads all three.
- An app started with `open` over ssh is its own responsible process (`launchctl procinfo` names the app), so it doesn't inherit ssh's Full Disk Access. The debug app reads "Not granted" in Settings ▸ General.
- The probe's denied read adds a `kTCCServiceSystemPolicyAllFiles` row for the bundle ID with `auth_value` 0, so the app is already listed in System Settings, switched off.
- `screencapture` over ssh fails with `could not create image from display`, so check the guest's System Settings through the VM tab, not a guest screenshot.

## Limits

- Guest Metal is paravirtualized. Use a VM for correctness, not performance.
- A guest never really sleeps, so it can't test sleep behavior.
- Nothing in a guest can move the real pointer for an agent, so a VM can't test cursor changes. A `CGEvent` posted over ssh is dropped, because the process lacks Accessibility. `CGWarpMouseCursorPosition` moves the pointer but delivers no events, so no tracking area fires. The VM view on the host passes only the host's own pointer.
- Each running VM uses about 8 GB of RAM.
- With `--with-xcode`, the guest's Xcode must match the host's, so rebuild the base image after an Xcode update. A base without Xcode has no such limit, and `plume-vm test` is unavailable on it.
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
- The spike's crash and failures have these causes:
  - All three `SurfaceCommandTests` once crashed the test host with `EXC_BAD_ACCESS` in `objc_release`. Their test windows lacked `isReleasedWhenClosed = false`, so `close()` over-released them. Fixed in `SurfaceCommandTests` and `TerminalShortcutReclaimTests`.
  - `focusedSurfaceConsumesOptionChordsWithoutTheMonitor` (⌥J) depends on the user's Ghostty config binding alt+j, which tests can't override. It skips when there is no binding, as in a guest.
  - `testNewTaskButtonIsAccessible` queried `buttons`, but the control is a `Menu` with a primary action, which XCUITest exposes as a pop-up button. It now queries any descendant.
  - `testComposerFieldIsAccessibleWithSeededTask` failed while the tab pane's container identifier overrode the identifiers inside it. It passes now.
- Current result in the guest: 18 passed, 1 skipped (the ⌥J test).
