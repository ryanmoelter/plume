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

`AndroidSDKLocator` prefers an SDK with `emulator/emulator`, and otherwise takes the first candidate with `platform-tools/adb`. It looks for adb separately: the chosen SDK's own if it has one, else the first candidate that does. An adb-only install (Homebrew's `android-platform-tools`, say) therefore finds physical devices, and the picker reports that the emulator isn't installed. An SDK without `platform-tools/adb` still finds devices through another candidate's adb; only when no candidate has adb does the Devices section say adb wasn't found.

`PhysicalDeviceDiscovery` runs `adb devices -l` off the main actor every 2 seconds while the picker is on screen, and never otherwise. `emulator-*` serials are dropped, since emulators reach the picker through their discovery files. `unauthorized` and `offline` devices are listed but disabled, with a hint. The name is the `model:` field with underscores turned into spaces, or the serial.

## Connecting

The tab persists `devicePlatformRaw = "androidPhysical"` and the adb serial in `deviceIdentifier`. A tab from before physical devices has `androidEmulator` and an AVD id, and still resolves to an emulator; so does a tab with an identifier but no platform.

Picking a device in the picker connects at once, since the picker's adb list is current. On start, the session refreshes the adb list. If the serial is missing or not `device`, it shows "isn't connected" with **Try Again**, which looks again. Otherwise `ScrcpyConnection.connect()`:

1. pushes the server to `/data/local/tmp/plume-scrcpy-server-<scid>.jar`, a path per launch so two tabs on one device never overwrite each other's jar (`cleanup=true` deletes it),
2. runs `adb forward tcp:0 localabstract:scrcpy_<scid>`, where the scid is random,
3. starts the server with `adb shell app_process` (H.264, no audio, control on, `tunnel_forward=true`, `clipboard_autosync=false` since Plume never reads the device clipboard),
4. retries the video socket until the server sends its dummy byte (a forward accepts before the server listens), then opens the control socket,
5. reads the device name, codec and the initial video size.

Every adb command has a deadline: 30 seconds for the push and 5 for each forward command. A command that misses it is killed, and the tab shows the failure with **Reconnect**. Cancelling the connect kills the command in flight too. A killed `forward` may still have created the forward on a port nobody read, so the launch then runs `adb forward --list` and removes every entry pointing at its `localabstract:scrcpy_<scid>`. That cleanup, like every forward removal, runs on a background queue rather than as a cancellable command, so a cancelled connect still completes it. The launch joins the quit-time wait from before `adb forward` runs until its forward is either recorded or removed, so a quit mid-forward waits for that cleanup too.

Closing the session (closing the tab, `TaskStore.forgetTab`, or the idle stop) stops the server and removes the forward. The session starts that stop synchronously, through the connection's `terminate()`, before the asynchronous `close()` tears down the sockets, so a quit straight after a close still waits for it. `ScrcpyServerLaunch.stop()` is safe at any point: a close during the push or the forward releases whatever exists by then, and the launch then creates nothing more. Nothing ever powers a physical device off: the shut-down item is hidden for it in both the device view and the tab-strip menu.

On quit, `DeviceSessionManager.terminateAll()` starts each stop without waiting, and `applicationWillTerminate` then blocks in `DeviceSessionManager.awaitTerminations()`, alongside `AgentProcess.awaitTerminations()`, until the `adb shell` children have exited and the forwards are gone. The wait is bounded at a few seconds.

## Frames

- The device encodes at its native size. **A resize never restarts the stream**; the layer's `resizeAspect` scales it. (Emulators restart at the largest requested size instead.)
- Frames arrive already rotated, so the session reports every physical frame as `.portrait`.
- `DeviceFrame` carries an IOSurface for physical frames and a `CGImage` for emulator frames. The surface view sets either as `layer.contents` and holds the frame until the next one, which keeps the pixel buffer that owns the surface alive.
- scrcpy sends a frame only when the screen changes. The session keeps the last frame and hands it to a sink that attaches mid-stream, so a tab shown again within the grace period doesn't stay black on a static screen.
- A config packet the decoder rejects, or a frame it fails to decode (including one VideoToolbox returns with no image and no error), costs frames, not the connection. The decoder drops frames until the next key frame, and the pump sends `RESET_VIDEO` for one, at most once a second until a frame decodes (`KeyFrameRecovery`).

## Hidden tabs and the grace period

A physical tab stays connected for `DeviceSession.physicalIdleStopDelay` (5 seconds) after its last sink leaves, or after connecting with no sink at all. A sink returning within that time cancels the stop and keeps the same connection and stream. Once the delay expires the session closes the connection, which stops the server and removes the forward, so a hidden tab never keeps the phone encoding. The session's state is then `.suspended`, which is not an error and offers no button. The next sink to attach reconnects to the same device, which takes about a second. Emulators stop streaming at once and keep their connection.

Reconnecting costs about a second and a visible stall, which a quick tab switch shouldn't pay. The delay is injected (`idleSleep`), so tests fire it by hand rather than waiting on a clock.

## Input

- **Coordinates.** A touch is in current video pixels, sent with that video size (`ScrcpyPosition`). The server drops any event whose size differs from its current one, so a touch that races a rotation vanishes instead of landing in the wrong place. The session sets `deviceSize` from each frame's video size, and the surface sends the size it mapped the point against, so `DeviceCoordinateMapper` needs nothing physical-specific.
- **Touches** go as `injectTouch` with the generic finger pointer id: down, moves, up; pressure 1, then 0 on up.
- **Scroll** goes as `injectScroll` at the pointer, one unit per notch (`WheelAccumulator`'s 120 units divided by 120). A wheel off the screen is dropped, since the server scrolls at a position.
- **Keys.** Plume follows the scrcpy client's default "mixed" key injection (`convert_keycode` and `sc_key_processor_process_text` in scrcpy's `app/src/keyboard_sdk.c`). Letters and space go as keycodes with their meta state, so Shift-A is KEYCODE_A with Shift and Control-C is KEYCODE_C with Control. The letter comes from `charactersIgnoringModifiers`, which follows the keyboard layout the way SDL's keysyms do, so an AZERTY "a" sends KEYCODE_A. Every other printable character goes as `injectText`: digits, punctuation, accented and non-Latin letters. Return, keypad Enter, Tab, Delete, Forward Delete, Escape, the arrows, Home, End, Page Up and Page Down always go as keycodes (so Shift-Tab works). A key sends one or the other, never both: scrcpy drops a text event whose first character is a letter or space because its key event already went, and Plume sends a letter key whose characters are something else, such as Option-A's "å", as text alone. A dead key sends nothing; the character it composes arrives with the next key. Like scrcpy, function keys are not forwarded. Unlike scrcpy, modifier presses alone are not forwarded either, since a lone Meta press and release can open Android's app list, and ⌘ chords stay with Plume's menus, matching emulator tabs. A held key's auto-repeats go as further key-downs with a rising repeat count, which the release resets; a held text key sends its text again. Each surface tracks which keycode each Mac key sent down (`AndroidPressedKeys`) and routes the release by that, not by the modifiers held at release: a Control-C whose Control is let go first still releases KEYCODE_C. A release with no matching press sends nothing, such as the release of a key pressed while ⌘ was held.
- **Buttons.** Back is `backOrScreenOn`, which wakes a sleeping screen. Home, Overview, Power and the volume keys are keycodes, down then up.
- **Rotate** has no button. A phone turns with its own sensor and auto-rotate setting, and the stream follows. `PhysicalDeviceConnection.rotate` still sends `rotateDevice`, which only toggles between portrait and landscape.

## Logging

Physical sessions log through `EmulatorLog`, under the `emulator` category, like emulators.
