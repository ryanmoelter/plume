---
name: plume-devices
description: Coordinate Android emulators and devices between concurrent agents with Plume's `plume devices` command — claim a free device (booting an emulator if needed), release, renew, list leases and record the installed branch. Use before any adb, maestro or other direct use of an Android device, when picking an emulator to test on, when a device seems busy, or on "claim a device", "which emulators are free", "release the emulator".
---

# Android devices with `plume devices`

`plume devices` leases Android devices so parallel agents never install onto or drive the same one. Run `plume devices help` first; its output wins over anything here.

If `plume` is not on PATH, run `"$PLUME_CLI"` instead.

## Rules

1. Claim before you touch. Any adb, maestro or other direct use of a device must target a serial you hold. `plume devices claim` leases a free device and prints its serial, reusing a booted one or else booting a stopped emulator. `plume devices claim <serial>` claims that device.
2. Target the device with `ANDROID_SERIAL`, as in `ANDROID_SERIAL=<serial> adb shell ...`. `claim` prints only the serial on stdout, so `ANDROID_SERIAL=$(plume devices claim)` is safe.
3. `claim` picks emulators only by default. `--kind=any` also allows physical devices, and `--kind=physical` requires one. `--form=phone|tablet|foldable` picks a form factor.
4. Parse `--json` (`plume devices ls --json`, `plume devices claim --json`) rather than the human output. Its keys are camelCase, such as `expiresAt`.
5. Exit code 2 means another owner holds the lease: tell the user who. Never `release --force` someone else's lease unless the user says so. Exit code 3 means nothing free matches: list the leases, then wait or ask.
6. Leases expire after an hour. Run `plume devices renew <serial>` in a long session, and `plume devices release <serial>` (or `--mine`) when you are done.
7. Inside a Plume tab, the tab owns the lease. Plume releases it when the tab closes, and `claim` shows the device in a device tab of your task. Elsewhere the git worktree owns it, or the `--owner` label.
8. Remote devices are billed. `claim --kind=remote [--model=<codename/api>]` reserves a Device Streaming device, and works only from a Plume tab. Use it only when the user asks for a remote device, and release it afterwards; releasing ends the reservation.

## Common commands

| Goal | Command |
| --- | --- |
| Get a free emulator, booting one if needed | `plume devices claim` |
| Get a free tablet, emulator or physical | `plume devices claim --kind=any --form=tablet` |
| Claim a specific device | `plume devices claim <serial>` |
| See every device and who holds it | `plume devices ls` |
| Extend a long session | `plume devices renew <serial>` |
| Done with a device | `plume devices release <serial>` |
| Release everything you hold | `plume devices release --mine` |
| Record which branch's build is installed | `plume devices installed <serial> [<branch>]` |
