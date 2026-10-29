# Remote Android devices

A device tab (`TabKind.device`, platform `androidRemote`) can show a physical device reserved from Google's lab through Device Streaming. The `android` command-line tool reserves the device and attaches it to local adb. From there it is an ordinary adb device, and the tab mirrors it over scrcpy exactly as `docs/android-physical-device.md` describes. This page covers what is different: the reservation, its cost, and the tool.

## Layout

- `Plume/Android/Remote/AndroidCLI.swift` finds the `android` tool and runs it. `ChildProcess` captures stdout and stderr and has a deadline.
- `RemoteDeviceParsers` parses the tool's plain-text output. No command prints JSON.
- `RemoteReservation` owns one reservation, from `create` to `remove`.
- `RemoteReservationLedger` records every reservation Plume created until it is removed.
- `RemoteDeviceCatalog` holds the tool's sign-in state, projects and models, for the picker and Settings ▸ Integrations.

## Finding the tool

The tool is `android` (version 1.1 measured), usually `/usr/local/bin/android`, which wraps `~/.android/bin/android-cli`. A GUI launch has no shell PATH, so `AndroidCLI.locate()` asks the login shell for `command -v android`, then tries `/usr/local/bin/android`, `/opt/homebrew/bin/android` and `~/.android/bin/android-cli`. It runs with the SDK's `launchEnvironment` and adb's directory first on PATH, so the tool's `connect` finds the same adb Plume uses.

## Commands (measured)

Every command takes `--project=<id>`, a Google Cloud project ready for streaming. Plume passes the one picked in Settings or the picker (`AppSettings.remoteDeviceProjectID`), or the only one there is.

| Command | Output | Plume reads |
|---|---|---|
| `auth status` | `Logged in as Name <email>` | the account; anything else is signed out |
| `device remote projects` | a carriage-return spinner, then `Projects ready for streaming:` and one indented id per line | the ids |
| `device remote models` | a `├─`/`└─` tree of manufacturers, each model row with one `codename/api` column per API level | one model per API level |
| `device remote create <codename>/<api>` | `New reservation created with id <id>. Reservation ends at 10:51 PM`, then `Waiting for reservation to activate...` and `Reservation is ACTIVE` | the id, as soon as it prints, and the end time |
| `device remote connect <id>` | `Device connected on port 59095` | the port; the adb serial is `localhost:<port>` |
| `device remote list <id>` | a table: `Reservation State Expires Manufacturer Model Codename API Level` | the row's state and expiry. `ACTIVE` is active; `FINISHED` (observed), `CANCELLED`, `EXPIRED` and `ENDED` are ended; any other state is unknown, which keeps the tab and logs the output |
| `device remote extend --duration=<minutes> <id>` | `Reservation extended. New expire time: 10:57 PM` | the new expiry; it adds to the current one |
| `device remote disconnect <id>` | `Disconnected.` | nothing |
| `device remote remove <id>` | `Reservation cancelled successfully.` | nothing |

- Times are clock times with no date, written with a narrow no-break space (U+202F) before AM/PM. `RemoteDeviceParsers.clockTime` takes the date that puts the time nearest now.
- Table columns are separated by two or more spaces. A model name can hold a single space (`Pixel Tablet`).
- Plume runs `create` without `--connect`, then `connect` itself, so it can read the port.
- `connect` starts a detached daemon (`android-cli device remote daemon-connect <id>`, parent pid 1) and exits. **The daemon is the tunnel**: killing it turns the adb device `offline`. `disconnect` kills it. `ChildProcess` waits for the tool to exit, never for its pipes to close, in case the daemon holds them.
- `/usr/local/bin/android` is a wrapper that runs `android-cli` as its child. `ChildProcess` starts each command as the leader of its own process group and, on a cancel or a timeout, signals the whole group, so `android-cli` dies with the wrapper. A command that finishes is never signalled, so the daemon a `connect` leaves behind survives even if it stayed in the group.
- `list <id>` with no row for the id counts as ended only when the output is the table or says `There are no active reservations.` Anything else is logged and read as unknown, which keeps the tab.
- `connect` refuses with exit 1 and `Reservation <id> is already connected on port N.` when a connection is still recorded. If adb lists `localhost:N` as `device`, Plume reuses that tunnel. Otherwise it runs `disconnect` and tries `connect` once more.
- `disconnect` with nothing connected exits 1 with `No active connection found for reservation <id> in project <p>`, and `remove` of an ended reservation exits 1 with `Reservation <id> has already ended.` Both count as success.
- Failures print text such as `Error: Failed to obtain auth token: HTTP connect timed out`. The tab shows it as is.

## Lifecycle and cost

A reservation is billed while it lasts, 15 minutes by default, and the service ends it early after a stretch of inactivity. **Nothing Plume reserves outlives the tab or the app.**

- **Reserve.** The picker's "Remote Devices" section lists the models; Reserve runs `create`, which waits until the device is active. The session shows `.reserving`, then persists `.remote(reservationID:)` plus `remoteProjectID`, `remoteDeviceModel` and `remoteExpiresAt` on the tab, runs `connect`, and streams.
- **Video.** A remote device streams at `ScrcpyVideoLimits.remoteDevice`: 1280 pixels on the long side, 4 Mbit/s, 30 fps. USB devices keep scrcpy's defaults.
- **Hidden tabs** keep the reservation and the tunnel. Only scrcpy stops, after the same 5-second grace a USB device gets.
- **Turn Off Streaming** (device menu) stops scrcpy at once and shows "Streaming turned off" until the user re-enables it. The reservation, its monitor and the time left carry on, so it still bills; see `docs/android-physical-device.md`.
- **Time left.** The toolbar shows minutes left, orange under 3, and **+15 min** runs `extend`. A monitor wakes at the expiry, or every 60 seconds if that's sooner, but never sooner than 15 seconds, and runs `list`. When the monitor sees the reservation is no longer active, or the stream drops and `list` says it ended, the tab shows "The reservation ended" with **Reserve Again**, which reserves the same model.
- **Release.** Closing, archiving or deleting the tab, Change Device and End Reservation release the reservation: `disconnect`, then `remove`. End Reservation (toolbar, device menu or tab chip, after a confirmation) clears the persisted target and returns to the picker, the same path as Change Device. The menu hides Change Device while a reservation is live or being created. An end the session detects itself (the monitor, or a relaunch) shows "The reservation ended" instead. `RemoteReservation.release()` is idempotent. End Reservation works while `create` is still running: a release then stops `create` first and removes the id if one was printed.
- **Quit ends every reservation.** `DeviceSessionManager.terminateAll()` releases each session's reservation and every other ledger entry, including those of tabs never shown this run. A quit runs `disconnect` and `remove` at the same time, so `remove`, the call that stops billing, always starts. `applicationWillTerminate` waits up to 10 seconds in `DeviceSessionManager.awaitTerminations()`; a `remove` still running after that finishes on its own as an orphan. After a relaunch a remote tab shows "The reservation ended" with **Reserve Again**, and never asks the service about its old id.
- **Rotate.** Nobody can turn a lab device, so a remote tab shows one Rotate button. scrcpy's `rotateDevice` only toggles between portrait and landscape. With auto-rotate on, `rotateDevice` turns it back on straight after the turn and the sensor undoes the turn, so the first Rotate turns auto-rotate off (`settings put system accelerometer_rotation 0`) and leaves it off. The ellipsis menu's **Auto-rotate** toggle reads the setting (`settings get system accelerometer_rotation`, `1` is on) after connecting and after each Rotate, and writes `1` or `0`. Turning it on re-arms the lock, so the next Rotate locks it again. The toggle is disabled while the value is unknown.

## The ledger

`remote-reservations.json` in the app's Application Support folder lists every reservation id Plume created, with its project. `create` adds the id the moment the tool prints it, before activation. The entry goes only once `remove` succeeds (or reports the reservation already ended).

At launch, `RemoteReservationLedger.sweepAtLaunch` releases every entry off the main thread, since a quit already ended every reservation and anything left was leaked by a crash, a force-quit or a failed release. So a leak lasts only until the next launch. One gap remains: a `create` killed before it printed its id may have reserved a device Plume never learned about, which then ends on its own.

## The picker and Settings

- The picker's Devices list leaves out the `localhost:` serials Plume's own reservations attached, since those show in their own tabs. A remote device connected some other way, by an agent running `android device remote connect` say, still shows there.
- With the tool missing or signed out, the section points to Settings ▸ Integrations ▸ Android Device Streaming. That section shows the tool, the account, Sign In… (which opens an ungrouped "Sign in to Device Streaming" task whose terminal runs `android auth login` from the home folder, since login may be interactive, and checks the account again when it exits or its tab closes. A sign-in that ends signed in deletes the task, and a failed one keeps it so its error stays readable. `AppSettings.remoteDeviceSignInTaskID` remembers the task, so the next Sign In… replaces it instead of adding another) and Sign Out (`auth logout`), and the project picker the device picker shares.

## Logging

Remote sessions log through `EmulatorLog`, under the `emulator` category.
