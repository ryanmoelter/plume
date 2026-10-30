# Device leases

`plume devices` keeps concurrent agents off the same Android device with leases in one registry file. The tool works without the app; this page covers the registry itself and what the app does with the leases its tabs own. `docs/cli.md` covers the commands.

## The registry

`~/Library/Application Support/Plume/devices/registry.json`, with an `flock` on `lock` beside it (`DeviceRegistryStore`). Every build, debug and worktree builds included, and every `plume` outside Plume shares this one directory, so a lease means the same thing to all of them. A write goes to a temporary file and is renamed into place, so a reader that takes no lock still sees a whole file. A file with a newer `version` is never overwritten, and neither is an unreadable one: every command fails, asking for it to be moved aside, rather than read it as empty and save over every lease in it.

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
- **Pending.** `avd:<id>` is an emulator booting for a claimant, which keeps a second claimant from booting the same AVD, or claiming its serial, while the lock is free. A boot that finishes on a serial someone leased meanwhile fails rather than overwrite that lease. `claim:<uuid>` is a remote device being reserved. A pending entry may carry an `error`.
- **Remote serials.** A `localhost:<port>` serial is always a remote device, leased or not, so the local path never claims one: a device reserved from the picker has no lease to mark it.
- **Dates** are whole epoch seconds.

## Owners

- **A Plume tab**: `{"tab": <PLUME_TAB_ID>, "app": <PLUME_SOCKET>}`. The socket names the app that owns the tab, so the same tab ID in another build is another owner.
- **A label**: `{"label": "…"}`, from `--owner`, else the enclosing git worktree's path.

**The app only ever touches leases whose `owner.app` is its own socket** (`CLIServer.shared.socketPath`). A debug build and the installed app share the registry but never sweep, reap or release each other's leases. An app whose CLI server failed to start touches none.

## Expiry and reaping

Every lease expires, after an hour by default (`--ttl`, `renew`). Tab leases expire too, and also go when their tab does.

Every command reads `adb devices` before it takes the lock, so the lock is held only for file I/O, then reaps under the lock: expired local leases, local leases whose serial left `adb devices` (offline and unauthorized still count as present, and an empty list removes nothing, since `adb kill-server` empties it for every device), emulator leases whose serial now runs another AVD, and pending entries past their own expiry (15 minutes). A remote lease ignores adb and goes only five minutes past its expiry (`DeviceRegistry.remoteReapGrace`). That grace leaves the app that holds the reservation time to reap the lease itself and end the reservation with it. When adb is missing or fails, reaping goes by expiry alone, so `release`, `renew` and `installed` still work; `claim` and `list` fail with adb's error.

Reading a physical device's form takes `adb shell` round trips, so only `claim --form` reads live forms, before it takes the lock, and re-validates the device under it. An emulator's form comes from its AVD's `config.ini`. `claim` alone renews a device the claimant already holds before it leases another.

## The app

`DeviceLeaseCoordinator` (`Plume/Android/DeviceLeases.swift`) keeps this app's leases in step with its tabs. Its registry I/O runs on a background queue, never the main thread, since a `plume` may hold the lock while it waits on adb. It starts in `PlumeApp.init`, only when the CLI server bound a socket, so the test host never starts it.

- **Launch.** It drops this app's leases whose owner tab isn't in a task that is not archived, every remote lease of this app (a quit ended their reservations, and the ledger sweeps any left), and its pending `claim:` entries. A local lease whose device tab is gone keeps going without it.
- **Watching.** A `FileWatcher` on `registry.json` publishes this app's leases by owner tab into `DeviceLeaseStore`, which the sidebar reads. A task whose tabs hold a lease shows an `iphone` glyph on its project line, with help text naming each device ("Holds emulator-5554 (Pixel_8)").
- **Reaping.** Every minute it drops this app's expired leases and pending entries. An expired remote lease also ends its reservation, and closes its device tab if a claim created it.
- **A forgotten tab.** `TaskStore.forgetTab`, which closing, archiving and deleting all go through, tells the coordinator. The tab's own leases and pending entries go; a remote one also ends its reservation, and closes its device tab if a claim created it, while a tab that was already there returns to the picker. If the forgotten tab was a lease's device tab, a local lease just loses its `deviceTabID`, and a remote lease goes, since its reservation ended with the tab.
- **Quit.** `applicationWillTerminate` drops this app's remote leases under the lock, waiting at most two seconds; the next launch's sweep catches any it missed.

## Remote devices

A remote lease always belongs to a Plume tab, because the reservation behind it is billed and must end with the tab. `claim --kind=remote` runs in this order:

1. The tool checks the registry under the lock. A remote lease the tab already holds is renewed and printed, once its app has extended the reservation (see Renewing). A pending `claim:` entry the tab already has is waited on again. One with an `error` is dropped, and the claim starts afresh.
2. The tool sends `devices.reserve` to the tab's app. The app resolves the model and project, picks or opens a device tab, writes `pending["claim:<claimID>"]` (owner, model, device tab, 15-minute expiry), and only then answers with the claim ID and starts the reservation in the device tab's session.
3. The tool polls `registry.json` every second without the lock, and pings the app every 15 seconds.
4. When the device reaches adb, the session reports it (`DeviceSession.onReservationEvent`), and the coordinator replaces the pending entry with `devices["remote:<reservationID>"]`. The lease carries the claim ID, the device tab, and whether the claim created that tab. The tool sees the lease and prints its serial.

The claim lives in the coordinator's memory from step 2 until the device connects. A device tab holds one claim at a time, and a second `devices.reserve` from a tab whose claim is still reserving returns that claim's ID instead of starting another reservation, writing its pending entry again if a long reservation outlasted it. `devices.reserve` gives up without reserving if loading the catalog took 25 seconds, since the tool stops waiting for an answer at 30. If the device connects after the pending entry was reaped or the tool gave up, the lease is still written, and the next claim from that tab finds it.

The session reports three events, which keep the lease in step with the reservation:

- **Attached** writes the claim's lease, or, on a reconnect, moves an existing lease to the new `localhost:<port>`.
- **Failed** sets the pending entry's `error`, which the tool prints before it drops the entry. For a claim, the coordinator then ends the reservation, since a reservation whose device never reached adb still bills; the device tab stays, showing the failure. A failed reconnect for a lease already written leaves the reservation running, and the session retries while Device Streaming reports it active.
- **Ended** drops the lease, or marks a claim still pending. The session reports it when the reservation ends by expiry, End Reservation, Change Device, a replacement reservation, or the tab closing — never at quit, where the quit sweep drops this app's remote leases instead.

Releasing a remote lease (`devices.release`, expiry, or the owner tab going) ends the reservation through the device tab's session, which returns the tab to the picker, and closes the tab if the claim created it. If the owner tab goes while its claim is still reserving, the coordinator closes the device tab the claim created, or returns an existing one to the picker. A `plume` that can't reach the owning app drops the lease itself; the reservation then ends when that app quits or relaunches.

### Renewing

A remote lease lasts only as long as its reservation, so renewing one, or claiming a remote device the tab already holds, first asks the owning app to extend the reservation (`devices.extend`) to cover the new TTL. The app extends it through the device tab's session and answers once Device Streaming has. If the app can't be reached or the extension fails, the tool exits 1 and leaves the lease as it was. A new claim whose TTL runs past the reservation's own length is extended the same way once its device connects.

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
