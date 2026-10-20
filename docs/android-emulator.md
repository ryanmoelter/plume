# Android emulator tabs

A device tab (`TabKind.device`, platform `androidEmulator`) shows a live Android emulator and forwards mouse, scroll and keyboard input. It talks to the emulator's gRPC control service (`EmulatorController` in `emulator_controller.proto`), the same service Android Studio's Running Devices panel uses. Every fact below marked *measured* was checked against emulator 37.1.11 on Apple silicon.

## Layout

- `Packages/EmulatorControl/` holds all gRPC and protobuf code. It is a local package rather than part of the app target because the app's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` breaks generated protobuf code. Its public facade (`EmulatorConnection` and value types) is the only API the app sees.
- `Packages/EmulatorControl/Sources/EmulatorControl/Generated/` is generated. Never edit it by hand; run `scripts/android/generate-emulator-grpc.sh`. `--update-proto` first copies the proto from the SDK into `Packages/EmulatorControl/Protos/`; `--check` diffs a fresh generation against the checked-in files.
- `Plume/Android/` holds SDK discovery, the AVD catalog, the running-emulator discovery, the launcher, the input mappers and the per-tab session.
- `Plume/UI/Device/` holds the tab host, the picker and the device view.

## Finding the SDK

`AndroidSDKLocator` takes the first candidate whose `emulator/emulator` is executable: `ANDROID_HOME`, `ANDROID_SDK_ROOT`, the same two read from an interactive login shell, `~/Library/Android/sdk`, `~/.android/sdk`, then the root above the login shell's `adb`. The login-shell step exists because an app opened from Finder inherits none of the shell's environment, and `ANDROID_HOME` usually lives in `.zshrc`.

An AVD's id is its `<id>.ini` basename in `~/.android/avd`, not the name of the `.avd` directory that ini points at. `-avd` and the discovery file both use the id.

## Finding a running emulator

Each running emulator writes `pid_<pid>.ini` to `~/Library/Caches/TemporaryItems/avd/running/`. It holds `avd.id`, `grpc.port`, `grpc.token` and the console and adb ports.

- The pid is qemu's, not the `emulator` launcher's, so a boot is matched to its file by `avd.id` and modification time.
- Files outlive their emulator after a crash. A file counts only while its pid is alive and that process's path contains `qemu-system` (pid reuse).
- `EmulatorDiscovery` watches the directory only while the picker is on screen. A boot does not hold the watcher; it polls `refresh()` instead.

## Authentication (measured)

Every emulator writes `grpc.token`, whether or not it was started with `-grpc-use-token` — including one started with `android emulator start` (what `device-pool` uses) or by Android Studio. A call without `authorization: Bearer <grpc.token>` fails with `UNAUTHENTICATED`; with it, every call Plume makes succeeds. Plume never needs the JWT path.

## Booting

`EmulatorLauncher` runs `emulator -avd <id> -no-window -grpc-use-token -no-boot-anim` in its own session (`POSIX_SPAWN_SETSID`), with stdin from `/dev/null` and output to `~/Library/Application Support/Plume/Emulators/<id>.log`. The emulator must outlive the tab and Plume: closing a tab only stops streaming, and quitting Plume leaves every emulator running. Shut one down from the tab's menu, which calls `setVmState(SHUTDOWN)`.

With `-no-window` the emulator runs `qemu-system-aarch64-headless` and renders with SwiftShader, a software GPU (*measured*).

## Frames (measured)

- `streamScreenshot` with `RGBA8888` and a bounding box. The emulator aspect-fits the device into the box and never upscales; `Image.format` reports the size it actually used.
- Shared memory: pass `ImageTransport{channel: MMAP, handle: "file:///<path>"}`. The client creates the file and sizes it to width × height × 4; the emulator writes each frame into it and `Image.image` comes back empty.
- Rows are top-down, despite the proto comment.
- The image arrives already rotated. `Image.format.rotation` names the rotation; a landscape frame is the portrait frame rotated counter-clockwise.
- The emulator sends a frame only when the screen changes, so a static screen costs nothing.

## Input (measured)

- Touches are in natural-orientation device pixels (`hw.lcd.width` × `hw.lcd.height`, from `getStatus().hardwareConfig`) whatever the rotation. `DeviceCoordinateMapper` undoes the aspect fit and the rotation. Pressure 1 is down; 0 lifts.
- Rotation is `setPhysicalModel(ROTATION, [0, 0, z])` with z = 0, 90, 180 or −90 for portrait, landscape, reverse portrait and reverse landscape.
- Keys go as `codeType: Mac` keydown/keyup, so holds and repeats work. Mac keycode 0 (`A`) is dropped — proto3 never serializes a zero — so it goes as evdev 30 instead. ⌘ chords are never forwarded; they stay with Plume's menus.
- Named keys `GoHome`, `GoBack`, `AppSwitch` and `Power` work. `AudioVolumeUp`/`AudioVolumeDown` are accepted and ignored, so volume goes as evdev 115 and 114.
- All input rides one `streamInputEvent` client stream, so a touch's down, moves and up cannot reorder.

## Hidden tabs

A hidden tab unmounts its device view, and the view stops streaming when it leaves the window or its window is occluded. A stream exists only while a view is on screen. Nothing ticks while hidden: no frame stream, no status polling, no discovery watch.

## Logging

Debug builds log the session's state changes, connects, lost connections, stream starts and stops, boots and discovery changes under the `emulator` category. Release builds log nothing yet (`EmulatorLog`).

```
/usr/bin/log show --predicate 'subsystem == "com.ryanmoelter.Plume" && category == "emulator"' --last 10m --info
```
