# Plume

Native macOS app for organizing and parallelizing coding-agent work: a sidebar of tasks in groups, agent/terminal tabs per task, and at-a-glance status.

## The roadmap

`docs/roadmap.md` tracks the features we intend to build. Read it before starting work, and check items off as they land. It records what each item is and what the code already provides, not how to build it — work out the approach when you pick an item up.

## Build and test

```
xcodebuild -scheme Plume -destination 'platform=macOS' build
xcodebuild -scheme Plume -destination 'platform=macOS' test -only-testing:PlumeTests
```

Every change ends with a clean build and a manual run. `PlumeUITests` launches the app, so a full `test` run is slow — prefer `-only-testing:PlumeTests` while iterating.

## Releasing locally

Plume is installed by hand — no archive, no notarization, no DMG. **`docs/releasing.md` is the reference**: version bump, build, verify, tag. Read it before cutting a release.

Release links Ghostty **statically** into a single self-contained binary — there is no `Contents/Frameworks`, and `otool -L` shows no non-system dylibs. Nothing needs embedding or separate signing.

## Layout

The Xcode project uses **file-system synchronized groups**: files added under `Plume/` join the target automatically. Adding a source file needs no `project.pbxproj` edit; adding a *package or build setting* does.

```
Plume/
  App/        PlumeApp, MainWindow, PlumeCommands, AppDelegate
  Models/     SwiftData models, TaskStore (CRUD/ordering), TitleStore, enums
  Ghostty/    GhosttyRuntime, GhosttyConfigLoader, GhosttyThemeResolver, TerminalSession, TerminalTabView, ThemeChrome
  Sessions/   SurfaceManager, LoginShellCommand
  Agent/      AgentProvider, ClaudeCodeProvider, AgentLauncher, hook plumbing, SessionJSONLReader
  Status/     StatusEngine, StatusPersistence
  Workspace/  WorkspaceProvisioner, GitRunner
  Support/    Log, AppPaths, AppSettings, FileWatcher, HexColor, SmokeHarness (DEBUG)
  UI/         Sidebar/, Task/, Settings/
```

## Terminals

`SurfaceManager.shared` owns every live terminal, keyed by **tab ID**. Views never create or destroy surfaces — they ask for a session and host it. This is what keeps processes alive across tab and task switches, so:

- Keep every tab's `TerminalTabView` mounted and toggle visibility (opacity). Never unmount to hide.
- **`TerminalSession` holds its platform view strongly, and that is what keeps the process alive.** The view owns the ghostty surface, which owns the PTY child, and the wrapper's `attachedView` is weak — so without that reference, unmounting a view (switching tasks, say) frees the surface and kills the terminal. The view is handed back on remount through the wrapper's `makePlatformView` hook. Hold the session, not just the surface state.
- Hidden tabs set `isSurfaceVisible = false` (`TabVisibility`), which stops rendering only. It never gates surface creation, so an unselected tab still spawns its PTY.
- Call `SurfaceManager.closeSession(for:)` when a tab or task is deleted. A SwiftData cascade delete does *not* reap the terminal.
- `TerminalSurfaceOptions` set surface identity. Re-requesting an existing session ignores new options by design — changing them would rebuild the surface and kill the process.
- Surfaces spawn their PTY lazily, when first attached to a view with a usable size — not on selection. A hidden tab still spawns.

## Agent instrumentation

`claude` launches with `--settings <generated>` plus `PLUME_TASK_ID` / `PLUME_TAB_ID` / `PLUME_EVENTS_DIR`. Each hook appends its stdin to `~/Library/Application Support/Plume/events/<taskID>/<tabID>.jsonl`; `AgentEventMonitor` tails those files and feeds `StatusEngine`.

Input reaches the agent as a paste plus a synthetic Enter, which is why a native chat can't answer a running `AskUserQuestion` or set a permission mode directly. **`docs/agent-transport.md` is the reference** for that ceiling, what Craft Agents does instead, and the headless `claude -p` alternative. Read it before building anything that needs to answer a running prompt.

- **Never put a `matcher` on `Stop` or `UserPromptSubmit`** — Claude Code rejects it. Omitting `matcher` already means "all", so the generated file omits it everywhere.
- `--settings` *merges*, and hook lists *union*, so the user's own hooks keep firing. Don't expect replacement semantics.
- Instrumentation is best-effort: a missing settings file degrades to a plain `claude`, never a failed launch.
- A hook only fires when Claude Code actually reaches that point. Testing in an **untrusted directory** (like `/tmp`) stalls on the folder-trust prompt and produces no events — use a directory already trusted.

## Verifying terminal behavior

Verify from outside the app rather than by screenshot — the surfaces are real processes, so the process tree is better evidence than a picture:

```
PLUME_SEED_TASKS=1 PLUME_SEED_TABS=3 PLUME_CYCLE_SELECTION=3 \
  <DerivedData>/Plume.app/Contents/MacOS/Plume &
```

Then watch real processes — one `login` → `-zsh` per surface, each on its own tty:

```
PID=$(pgrep -x Plume)
for l in $(pgrep -P $PID); do pgrep -P $l; done   # shell pids, stable across switches
/usr/bin/log show --predicate 'subsystem == "com.ryanmoelter.Plume"' --last 2m --info
```

Stable PIDs across many switches is the real proof that hide/show doesn't kill processes. `SmokeHarness` (DEBUG only) drives this from env vars.

Always walk down from Plume's own PID. A global `pgrep`/`grep` for `claude` matches the Claude desktop app's helper processes and will convince you an agent launched when none did.

## Ghostty

Terminals come from the `GhosttyTerminal` product of `Lakr233/libghostty-spm`, pinned `.exact("1.5.0")`. **`docs/ghostty-pin.md` is the reference** — pin details, why the wrapper was adopted, config search order, upgrade steps, and the self-vendoring fallback. Read it before touching anything Ghostty-related or upgrading the package.

The wrapper does not call `ghostty_config_load_default_files`, so `GhosttyConfigLoader` finds the user's config itself. Its ordering (Application Support before XDG) is deliberate and test-locked — don't "fix" it to match ghostty's docs page, which is wrong.

The config reaches libghostty as **generated contents with every `theme` directive stripped**, never as a file path. `GhosttyThemeResolver` applies the theme in Swift instead. Passing `theme` through breaks terminal launching outright — surfaces silently spawn a login shell instead of their command, with no diagnostic. `GhosttyConfigLoader.configContentsForGhostty` documents the mechanism.

## Conventions

- **SwiftData models are the persisted skeleton only.** Live process/terminal state belongs in in-memory `@Observable` objects keyed by model UUID. Never persist anything about a running PTY.
- **Every SwiftData stored property needs a default value**, so lightweight migration keeps working as the schema grows.
- Enums persist as `...Raw` strings with a computed accessor (`workspaceKindRaw` / `workspaceKind`). Keeps migrations trivial.
- Ordering is a dense `orderIndex` per section, rewritten on move. All of it lives in `TaskStore` — keep it out of views.
- Model names avoid colliding with Swift's `Task` and SwiftUI's `Group`: `WorkTask`, `TaskGroup`, `TaskTab`.
- **All `ghostty_*` calls stay in `Plume/Ghostty/`.** The C API is unstable between versions; upgrading should touch one folder.
- Status flows through `StatusEngine` in memory; SwiftData gets only a debounced snapshot in `lastStatusRaw`, never per-event writes.

## Gotchas

- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` means transitive imports don't count. Using `Array.move(fromOffsets:toOffset:)` needs an explicit `import SwiftUI`; `IndexSet` needs `import Foundation`. The error names the missing module.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: everything is MainActor-isolated unless marked otherwise. Test suites touching models need `@MainActor`.
- The app is **unsandboxed** (`ENABLE_APP_SANDBOX = NO`) — it spawns PTYs, reads `~/.claude/**`, and runs `git worktree`. Distribution is Developer ID + notarization, not the App Store. Don't re-enable the sandbox.
- The store lives at `~/Library/Application Support/Plume/Plume.store`, alongside the `hooks` and `events` directories. Delete it to test first-run behavior. **Debug writes to `Plume.debug/` instead** — its bundle ID carries a `.debug` suffix and `AppPaths.directoryName` keys off that — so a debug run and the installed app no longer share data and can run side by side. The test host has no bundle ID and falls back to `Plume/`. If the store fails to open, `PlumeApp` moves it aside as `Plume.store.<timestamp>.bak` and starts empty rather than refusing to launch.
- SourceKit in-editor diagnostics go stale on new files and report phantom "cannot find type in scope" errors (often resolving `TaskGroup` to Swift's generic one). Trust `xcodebuild`, not the editor squiggles.
- In Debug, `Plume.app/Contents/MacOS/Plume` is a ~57K launcher stub. The real code — and every linked libghostty symbol — is in `Plume.debug.dylib` beside it. Inspecting the stub with `nm` makes it look like nothing is linked.
- **Tests that run `git commit` must set `commit.gpgsign false` on the scratch repo.** A signing config that prompts an external agent is unreachable from a test host: the commit hangs ~60s, then fails with exit 128. `WorkspaceProvisionerTests.makeRepository` does this.
- **`-only-testing` with a name that matches no Swift Testing test prints `** TEST SUCCEEDED **` having run nothing**, and `-parallel-testing-enabled NO` silently skips Swift Testing suites entirely. Both read as a pass. Confirm the test name appears in the output before believing a green run.
- **`TerminalViewState` is a Combine `ObservableObject`, not `@Observable`.** Its `title`/`workingDirectory` are `@Published`, which `@Observable` tracking cannot see, and `TerminalSession` holds it `@ObservationIgnored`. Reading it straight from a view renders once and never updates — a stale value that looks like it works. `TerminalSession` mirrors those two fields into its own observable storage; add any further ones the same way rather than observing the state object from a view.
- **Never write to `@Observable` state during a SwiftUI `body`.** SwiftUI records the write as a dependency of the view being rendered, so the render invalidates itself and spins forever — one core at 100%, no crash, and the surfaces never spawn their PTYs. A `sample` blames whatever is most expensive inside the loop (`ProcessInfo.environment`, say), not the write. Create sessions and register them from `.onAppear`/`.task` and hold them in `@State`; `TerminalTabHost` in `TabContentView` is the pattern.
- **The wrapper's text path is a *paste*, not typing.** `TerminalViewState.paste(text:)` frames its argument as a bracketed paste, so a trailing `\r` lands in the program's edit line instead of submitting — `send(_:)` is deprecated for exactly this reason. Sending a line means `paste(text:)` then `sendKey(.enter)`; `TerminalSession.submit(text:)` does both.
- **Two test suites only pass in the primary checkout with a real GUI session.** `SessionJSONLReaderTests.encodingResolvesADirectoryClaudeCodeHasUsed` derives the repo path from `#filePath` and asserts a matching directory exists under `~/.claude/projects`, so it fails in any worktree — that path has no transcripts. `SurfaceCommandTests` spawns real `NSWindow`s and PTYs, so it fails from a headless shell. Both are environmental; check them against `main` before believing a regression.
- Swift Testing runs suites in parallel in one process, so tests sharing libghostty state can contaminate each other's results.
- Swift Testing's `#expect` cannot wrap a throwing call. `allSatisfy(\.isHexDigit)` counts as throwing (the closure is `rethrows`), so write `allSatisfy { $0.isHexDigit }`. The failure names a generated macro file, but `…MX45…` in that name is the **line number** in the real source.
- Adding a *source file* needs no project edit, but adding a *SwiftPM package* means hand-editing `project.pbxproj` (build file, package reference, product dependency, and the Frameworks phase).
- Deployment target is macOS 26.2, matching the Xcode 26.2 SDK ceiling. Raising it above the installed SDK makes every build warn.
