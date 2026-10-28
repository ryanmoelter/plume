# Physical Android devices

A device tab (`TabKind.device`, platform `androidPhysical`) can mirror a physical Android device connected over adb, and forward mouse, scroll and keyboard input to it. It runs [scrcpy](https://github.com/Genymobile/scrcpy)'s server on the device and speaks its protocol directly; Plume never runs the scrcpy client. Emulators use their gRPC service instead (`docs/android-emulator.md`). Both kinds share `DeviceSession`, the picker and the device view.

## Layout

- `Packages/ScrcpyControl/` holds the wire layer: `ScrcpyServerLaunch` (push, forward, run), `ScrcpyDemuxer`, `H264Decoder` (VideoToolbox, IOSurface-backed BGRA) and `ScrcpyControlMessage`. `ScrcpyConnection` is its facade. Run `swift test` in the package for its tests; `ScrcpyProbe` mirrors a real device for a few seconds without the app.
- `Plume/Android/PhysicalDeviceConnection.swift` adapts `ScrcpyConnection` to `DeviceConnecting`, the protocol the session talks to. `EmulatorDeviceConnection` is the emulator's adapter.
- `Plume/Android/PhysicalDeviceDiscovery.swift` lists devices from `adb devices -l`.
- `Plume/Android/AndroidKeycodeMapper.swift` turns Mac key events into Android keycodes and text.

## The server binary

`Plume/Resources/Scrcpy/scrcpy-server` is scrcpy's prebuilt server, pinned to `ScrcpyServerVersion.pinned` and stored in Git LFS. `scripts/android/fetch-scrcpy-server.sh` updates it; `scrcpy-VERSION.txt` records the version and checksum, and `scrcpy-LICENSE.txt` ships its Apache 2.0 license. The server checks that the client's version string matches its own exactly, so the binary and `pinned` move together.

- The file has **no `.jar` extension** on purpose: Xcode leaves a `.jar` in the synchronized group out of the bundle's `Resources`. The app finds it with `Bundle.main.url(forResource: "scrcpy-server", withExtension: nil)`.
- A checkout without `git lfs` has a pointer file there. `ScrcpyServerLaunch.verifyJar` catches that and the tab shows "is a Git LFS pointer … Run `git lfs pull`".

## Discovery

`AndroidSDKLocator` prefers an SDK with `emulator/emulator`, and otherwise takes the first candidate with `platform-tools/adb`. An adb-only install (Homebrew's `android-platform-tools`, say) therefore finds physical devices, and the picker reports that the emulator isn't installed.

`PhysicalDeviceDiscovery` runs `adb devices -l` off the main actor every 2 seconds while the picker is on screen, and never otherwise. `emulator-*` serials are dropped, since emulators reach the picker through their discovery files. `unauthorized` and `offline` devices are listed but disabled, with a hint. The name is the `model:` field with underscores turned into spaces, or the serial.

## Connecting

The tab persists `devicePlatformRaw = "androidPhysical"` and the adb serial in `deviceIdentifier`. A tab from before physical devices has `androidEmulator` and an AVD id, and still resolves to an emulator; so does a tab with an identifier but no platform.

On start, the session refreshes the adb list. If the serial is missing or not `device`, it shows "isn't connected" with **Try Again**, which looks again. Otherwise `ScrcpyConnection.connect()`:

1. pushes the server to `/data/local/tmp/plume-scrcpy-server.jar`,
2. runs `adb forward tcp:0 localabstract:scrcpy_<scid>` with a random scid,
3. starts the server with `adb shell app_process` (H.264, no audio, control on, `tunnel_forward=true`),
4. retries the video socket until the server sends its dummy byte (a forward accepts before the server listens), then opens the control socket,
5. reads the device name, codec and the initial video size.

Closing the session (closing the tab, `TaskStore.forgetTab`, or quitting) stops the server and removes the forward. Nothing ever powers a physical device off: the shut-down item is hidden for it in both the device view and the tab-strip menu. On quit the stop is best-effort, because termination doesn't wait for it; the server exits once its sockets close anyway (`cleanup=true`).

## Frames

- The device encodes at its native size. **A resize never restarts the stream**; the layer's `resizeAspect` scales it. (Emulators restart at the largest requested size instead.)
- Frames arrive already rotated, so the session reports every physical frame as `.portrait`.
- `DeviceFrame` carries an IOSurface for physical frames and a `CGImage` for emulator frames. The surface view sets either as `layer.contents` and holds the frame until the next one, which keeps the pixel buffer that owns the surface alive.
- scrcpy sends a frame only when the screen changes. The session keeps the last frame and hands it to a sink that attaches mid-stream, so a tab shown again doesn't stay black on a static screen.

## Hidden tabs and the grace period

A physical tab keeps streaming for `DeviceSession.physicalIdleStopDelay` (5 seconds) after its last sink leaves. A sink returning within that time cancels the stop. Once it expires the session cancels the frame stream but keeps the connection open while the tab exists. The pump keeps draining the socket without decoding, and when a stream starts again `ScrcpyConnection` sends `RESET_VIDEO` and waits for a key frame. Emulators still stop at once.

Restarting the encoder costs a key frame and a visible stall, which a quick tab switch shouldn't pay. The delay is injected (`idleSleep`), so tests fire it by hand rather than waiting on a clock.

## Input

- **Coordinates.** A touch is in current video pixels, sent with that video size (`ScrcpyPosition`). The server drops any event whose size differs from its current one, so a touch that races a rotation vanishes instead of landing in the wrong place. The session sets `deviceSize` from each frame's video size, and the surface sends the size it mapped the point against, so `DeviceCoordinateMapper` needs nothing physical-specific.
- **Touches** go as `injectTouch` with the generic finger pointer id: down, moves, up; pressure 1, then 0 on up.
- **Scroll** goes as `injectScroll` at the pointer, one unit per notch (`WheelAccumulator`'s 120 units divided by 120). A wheel off the screen is dropped, since the server scrolls at a position.
- **Keys.** Unmodified printable keys go as `injectText`, so the Mac's keyboard layout decides the character. Return, Tab, Delete, Forward Delete, Escape, the arrows, Home, End, Page Up and Page Down go as keycodes with their meta state (so Shift-Tab works). Control chords go as keycodes by ANSI position. ⌘ chords stay with Plume's menus, matching emulator tabs. Modifier presses alone are not forwarded.
- **Buttons.** Back is `backOrScreenOn`, which wakes a sleeping screen. Home, Overview, Power and the volume keys are keycodes, down then up.
- **Rotate** is `rotateDevice`, which only toggles between portrait and landscape, so a physical tab shows one rotate button.

## Logging

Physical sessions log through `EmulatorLog`, under the `emulator` category, like emulators.
