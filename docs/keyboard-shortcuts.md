# Keyboard shortcuts

Plume binds two kinds of chord. The fixed ones (⌘N, ⌘T, ⌘W, ⌘1…⌘9) live as `static let`s on `PlumeShortcuts`. The four cycling commands — next/previous tab, next/previous task — are rebindable, stored per action in `ShortcutBindings` and persisted to `UserDefaults` as one JSON blob.

Three layers have to agree for a chord to work.

1. **`PlumeCommands`** builds the menu item and gives it a `.keyboardShortcut`.
2. **`ShortcutMenuApplier`** writes later rebinds onto that built item.
3. **`TerminalShortcutMonitor`** claims the chord back from a focused terminal, which would otherwise consume it before the menu is offered anything.

## A rebind does not reach the menu on its own

**SwiftUI never re-evaluates a `Commands` body for a changed binding.** A `View` body re-renders when an `@Observable` it read changes; a `Commands` body does not. The menu is built once, from whatever `AppSettings.shared.shortcutBindings` held at launch, and keeps that chord for the life of the process.

That shipped as a complete failure of the feature: every chord recorded in Settings did nothing, and the chord it replaced went on working. Holding `AppSettings` as `@State` on the `Commands` struct does not fix it — the body still is not re-evaluated.

So `ShortcutMenuApplier` sets `keyEquivalent` and `keyEquivalentModifierMask` on the `NSMenuItem` directly. `AppDelegate` drives it from `AppSettings.shortcutBindingsStream`, once at launch and again on every change. Items are found by title, because a `Commands` `Button` carries no tag or identifier into AppKit — renaming a menu item means renaming `ShortcutAction.label` with it, and `apply` returns the actions it found so a drifted title is visible rather than silent.

## An Option chord is a usable binding

⌥J composes to ∆ on a US layout, so it looks like a chord AppKit could never match. It matches anyway: a menu key equivalent is compared against the key's label, not against what the chord types. `MenuKeyEquivalentTests` pins this, including the ⌘ and ⌘⌥ cases.

What an Option chord does cost is the terminal. `MenuShortcut.isClaimable` lets the monitor take Command chords unconditionally — Command never reaches a program over a PTY — and Option chords only because the user asked for one by binding it. The shell loses that key inside a terminal tab. Bare keys and Control chords always stay with the terminal.

## Verifying a shortcut change

`docs/control-server.md` has `key` and `menu`. Together they answer the two questions that matter:

- `menu` says what chord the item actually carries, as against what `PlumeCommands` asked for. A rebind that has not reached the menu shows up here immediately.
- `key` posts a real `NSEvent` through the whole dispatch path and reports `handledBy` — the item that owns the chord.

**A scratch instance cannot prove the action ran.** Every command gated on a `focusedSceneValue` — the whole Tab menu, most of the File menu — reads disabled unless the app's scene is active, and a hidden instance's never is. `handledByEnabled` reports that, so a no-op there is not evidence of a bug. Confirming the action itself still needs a frontmost app.

## Tests must not read the live bindings

`PlumeShortcuts.all` reads `AppSettings.shared`, so a test asserting against the shipped chords fails on any machine whose owner has rebound one. Pass an explicit set instead: `PlumeShortcuts.all(with: ShortcutBindings())` for the defaults, and `TerminalShortcutMonitor.isClaimed(shortcuts:characters:flags:)` to match against it. Never assign to `AppSettings.shared.shortcutBindings` from a test — it writes the developer's real preferences.
