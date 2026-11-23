---
name: plume-vm-setup
description: Set up Plume's macOS test VMs from scratch, or rebuild them — install Tart, turn on the Labs toggle, build the base image with make-base-image.sh, grant the debug app Full Disk Access in the VM with plume-vm grant-fda, verify, and reset the clones after a macOS or Xcode update. Use on "set up VMs", "set up the VM pool", "rebuild the base image", "the VM base is out of date", "Full Disk Access in the VM", or when plume-vm says the base is missing, has no Xcode, or lacks Full Disk Access.
---

# Set up Plume's test VMs

`docs/vm-testing.md` is the reference. This is the order to run things in; read the doc for what each step does and why.

Ask the user before steps that need them: installing Homebrew packages, turning on Labs in an app they are running, and the Full Disk Access clicks.

## First-time setup

1. **Install Tart.** It lives in the `openai/tools` tap, and Homebrew refuses its `tart` and `softnet` formulas until they are trusted.

   ```
   brew tap openai/tools
   brew trust --formula openai/tools/tart
   brew trust --formula openai/tools/softnet
   brew install tart
   ```

2. **Turn on Labs.** The Plume that will own the VMs needs Settings ▸ Labs ▸ "macOS VMs for testing". From a shell: `defaults write com.ryanmoelter.Plume labsVMsEnabled -bool true`, or `com.ryanmoelter.Plume.debug` for debug builds. Relaunch the app afterwards; it reads the setting at launch.

3. **Build the base image.** Run `scripts/vm/make-base-image.sh` in the foreground. The first run downloads about 30 GB.
   - Without flags, the base has no Xcode. That is enough for `plume-vm launch`.
   - Add `--with-xcode` when the user needs `plume-vm test`. It copies the selected Xcode in, which must match the host's.

4. **Grant Full Disk Access.** This step is manual, once per base image. Build the debug app, then run `scripts/vm/plume-vm grant-fda` with `PLUME_SOCKET` set to the socket of the Plume the user is looking at. It prints the clicks: Show the VM in a device tab, turn on Plume α in the guest's System Settings, enter `admin`. Relay them to the user, and wait for the script to finish. It checks the grant, then saves the VM as the new base. Every VM must be released first: the script deletes the free clones so it grants in a fresh one, and it refuses to save the base while any VM runs. If the base already has the grant, it says so and saves nothing. If it stops partway, it releases its VM; if it names a clone that was in use, run `plume devices reset vm:<n>` once that VM is free, then run it again.

5. **Verify.**
   - `scripts/vm/plume-vm claim`, then `scripts/vm/plume-vm launch --seed 1`. The launch prints no Full Disk Access warning.
   - `scripts/debug/plume-control.py --socket <controlSocket> list plumeID=full-disk-access-dismiss-button` returns an empty `result`.
   - With `--with-xcode`, also run `scripts/vm/plume-vm test`.
   - Finish with `scripts/vm/plume-vm release`. Never leave a VM claimed.

## Rebuilding after a macOS or Xcode update

The base must match the host's macOS major, and with Xcode, the host's Xcode version. `plume-vm test` refuses a mismatched Xcode and names this fix.

1. Release every VM: `scripts/vm/plume-vm list` shows none leased.
2. Run `scripts/vm/make-base-image.sh --force`, with `--with-xcode` if the old base had Xcode. `vms/base-<os>.json` records whether it did.
3. The rebuild deletes every free `plume-<os>-<n>` clone. For each clone it names as skipped, run `plume devices reset vm:<n>` once that VM is free.
4. The new base has no Full Disk Access grant. Repeat step 4 and step 5 above.

A debug rebuild doesn't need a new grant, because TCC matches the signing certificate, not the binary. A build signed by another certificate does.
