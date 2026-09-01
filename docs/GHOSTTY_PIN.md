# Ghostty pin

Plume embeds Ghostty's terminal via a prebuilt `GhosttyKit.xcframework`. libghostty's C API is **explicitly unstable between releases**, so the package is pinned exactly and every upgrade is a deliberate, tested step.

## Current pin

| | |
|---|---|
| Package | [`Lakr233/libghostty-spm`](https://github.com/Lakr233/libghostty-spm) |
| Requirement | `.exact("1.5.0")` |
| Package revision | `df208c1b228da8f879317993680c7d6e39f5a69a` |
| Product used | `GhosttyTerminal` (the Swift wrapper, not raw `GhosttyKit`) |
| Underlying Ghostty | **1.3.1**, ref `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` |
| Binary artifact | `GhosttyKit.xcframework.zip` from the package's `upstream.1.3.1-2` release |
| Transitive dep | `Lakr233/MSDisplayLink` 2.2.0 |

The package version and the Ghostty version are **different numbers** — package 1.5.0 wraps Ghostty 1.3.1. Always record both.

## Why the wrapper

WP0.2 evaluated adopting the package's `GhosttyTerminal` product against writing our own wrapper on the raw C API. Adopted, because it satisfies all three criteria:

1. **Per-surface command, cwd, and env** — `TerminalSurfaceOptions` exposes `workingDirectory`, `command`, and `envVars`, mapped onto `ghostty_surface_config_s`. This is how agent tabs launch `claude` and how `PLUME_TASK_ID` / `PLUME_TAB_ID` / `PLUME_EVENTS_DIR` get injected.
2. **Surface keep-alive across reparenting** — surfaces outlive view reparenting, so processes survive tab and task switches.
3. **The user's own config** — via `TerminalController.ConfigSource.file(path)`.

**Caveat on config:** the wrapper does *not* call `ghostty_config_load_default_files`. It renders a config file from a base string plus programmatic overrides, so **discovering the user's config path is Plume's job** — see `GhosttyConfigLoader`, which mirrors ghostty's own search order.

## Config search order

From `preferredDefaultFilePath()` in ghostty's [`src/config/file_load.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/config/file_load.zig). First match wins outright — ghostty never merges these, and a zero-byte file does not count as a match:

1. `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`
2. `~/Library/Application Support/com.mitchellh.ghostty/config`
3. `$XDG_CONFIG_HOME/ghostty/config.ghostty` (default `~/.config/ghostty`)
4. `$XDG_CONFIG_HOME/ghostty/config`

Application Support outranks XDG on macOS — the reverse of what ghostty's own docs page suggests, and a known source of confusion ([#3456](https://github.com/ghostty-org/ghostty/issues/3456)). `GhosttyConfigLoaderTests` locks this ordering down.

## Upgrade procedure

1. Check the package's tags and read its changelog for C-API-affecting changes.
2. Bump the `exactVersion` in `project.pbxproj` (or via Xcode's package UI), then `xcodebuild -resolvePackageDependencies`.
3. Update the table above — **both** the package version and the new underlying Ghostty version/ref, read from the package's `Ghostty.version` and `Ghostty.ref` files.
4. Build, then run the terminal smoke checks: typing and shell interaction, the user's theme/font applying, resize/reflow, scrollback, a full-screen TUI (`vim`), copy/paste, and IME.
5. Re-verify per-surface `command` / `workingDirectory` / `envVars` still reach the child process — agent launching depends on all three.

If resolution fails with `already exists in file system` for the binary target, a half-downloaded artifact is cached. Remove the matching entry under `~/Library/Caches/org.swift.swiftpm/artifacts/` and retry. Don't delete the whole directory; it is shared with other projects.

## Fallback: self-vendoring

If the package stalls, is withdrawn, or diverges from an upstream Ghostty we need, vendor the xcframework directly:

1. Get `GhosttyKit.xcframework` for the desired Ghostty commit (from Ghostty's per-commit artifacts, or build it — see the package's own `build.sh` and Sessylph's `BUILDING_GHOSTTYKIT.md`).
2. Add a local SwiftPM package with a `.binaryTarget` pointing at it, with a checksum from `swift package compute-checksum`.
3. Point the app target at that local package instead.

This drops the `GhosttyTerminal` wrapper, so Plume would then need its own surface/NSView layer on the raw C API — reference Ghostty.app's `macos/Sources/Ghostty/*`, plus cmux and Termini. Everything Ghostty-specific is confined to `Plume/Ghostty/`, which is what keeps this fallback tractable.
