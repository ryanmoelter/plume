# Device leases

`plume devices` keeps concurrent agents off the same Android device with leases in one registry file. The tool works without the app; this page covers the registry itself and what the app does with the leases its tabs own. `docs/cli.md` covers the commands.

## The registry

`~/Library/Application Support/Plume/devices/registry.json`, with an `flock` on `lock` beside it (`DeviceRegistryStore`). Every build, debug and worktree builds included, and every `plume` outside Plume shares this one directory, so a lease means the same thing to all of them. A write goes to a temporary file and is renamed into place, so a reader that takes no lock still sees a whole file. A file with a newer `version` is never overwritten; an unreadable one reads as empty, with a warning, and the next write replaces it.

```json
{
  "version": 1,
  "devices": {
    "emulator-5554": {
      "kind": "emulator", "serial": "emulator-5554", "avd": "Pixel_8", "form": "phone",
      "owner": {"tab": "<uuid>", "app": "/Users/me/Library/Application Support/Plume/run/cli.sock"},
      "worktree": "/repo/.plume/worktrees/x", "branch": "feature",
      "claimedAt": 1760000000, "expiresAt": 1760003600,
      "deviceTabID": "<uuid>", "deviceTabCreatedByClaim": true,
      "installed": {"branch": "feature", "worktree": "/repo/.plume/worktrees/x", "at": 1760000100}
    }
  },
  "pending": {
    "avd:Tablet": {"owner": {"label": "/repo"}, "kind": "emulator", "avd": "Tablet", "startedAt": 1760000000, "expiresAt": 1760000900}
  }
}
```

- **Keys.** A local lease is keyed by its adb serial. A remote lease is keyed `remote:<reservationID>`, since its adb port changes on every reconnect; its `serial` holds the current `localhost:<port>`. The commands accept either.
- **Pending.** `avd:<id>` is an emulator booting for a claimant, which keeps a second claimant from booting the same AVD while the lock is free. `claim:<uuid>` is a remote device being reserved. A pending entry may carry an `error`.
- **Dates** are whole epoch seconds.

## Owners

- **A Plume tab**: `{"tab": <PLUME_TAB_ID>, "app": <PLUME_SOCKET>}`. The socket names the app that owns the tab, so the same tab ID in another build is another owner.
- **A label**: `{"label": "…"}`, from `--owner`, else the enclosing git worktree's path.

**The app only ever touches leases whose `owner.app` is its own socket** (`CLIServer.shared.socketPath`). A debug build and the installed app share the registry but never sweep, reap or release each other's leases. An app whose CLI server failed to start touches none.

## Expiry and reaping

Every lease expires, after an hour by default (`--ttl`, `renew`). Tab leases expire too, and also go when their tab does.

Every command reaps under the lock first: expired local leases, local leases whose serial left `adb devices` (offline and unauthorized still count as present), emulator leases whose serial now runs another AVD, and pending entries past their own expiry (15 minutes). A remote lease ignores adb and goes only five minutes past its expiry (`DeviceRegistry.remoteReapGrace`). That grace leaves the app that holds the reservation time to reap the lease itself and end the reservation with it.

## The app

`DeviceLeaseCoordinator` (`Plume/Android/DeviceLeases.swift`) keeps this app's leases in step with its tabs. Its registry I/O runs on a background queue, never the main thread, since a `plume` may hold the lock while it waits on adb. It starts in `PlumeApp.init`, only when the CLI server bound a socket, so the test host never starts it.

- **Launch.** It drops this app's leases whose owner tab isn't in a task that is not archived, every remote lease of this app (a quit ended their reservations, and the ledger sweeps any left), and its pending `claim:` entries. A local lease whose device tab is gone keeps going without it.
- **Watching.** A `FileWatcher` on `registry.json` publishes this app's leases by owner tab into `DeviceLeaseStore`, which the sidebar reads. A task whose tabs hold a lease shows an `iphone` glyph on its project line, with help text naming each device ("Holds emulator-5554 (Pixel_8)").
- **Reaping.** Every minute it drops this app's expired leases and pending entries. An expired remote lease also ends its reservation, and closes its device tab if a claim created it.
- **A forgotten tab.** `TaskStore.forgetTab`, which closing, archiving and deleting all go through, tells the coordinator. The tab's own leases and pending entries go; a remote one also ends its reservation, and closes its device tab if a claim created it, while a tab that was already there returns to the picker. If the forgotten tab was a lease's device tab, a local lease just loses its `deviceTabID`, and a remote lease goes, since its reservation ended with the tab.
- **Quit.** `applicationWillTerminate` drops this app's remote leases under the lock, waiting at most two seconds; the next launch's sweep catches any it missed.

## Device tabs

A claim from a tab asks that tab's app to show the device (`devices.show`), and records the tab in the lease as `deviceTabID`. `deviceTabCreatedByClaim` is true when the request opened the tab, and stays true when a later claim reuses it. The app picks a device tab in the caller's current task already on the device, else one with no device yet, else opens a new one behind the selection. It never repoints a tab showing another device.

## From device-pool

`plume devices` replaces Ryan's Python `device-pool` helper and keeps its commands and exit codes. There is no bridge: the two registries are separate files, and leases do not carry over.

| device-pool | plume devices |
|---|---|
| Its own registry under `~/.device-pool` | `~/Library/Application Support/Plume/devices/registry.json` |
| snake_case keys (`expires_at`) | camelCase keys (`expiresAt`) |
| Owner is the worktree or a label | Also a Plume tab, named with its app's socket |
| No app | A tab owner gets a device tab, and the app releases the lease with the tab |
