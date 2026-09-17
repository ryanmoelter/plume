# Plume

Native macOS app for organizing and parallelizing coding-agent work: a sidebar of tasks in groups, agent/terminal tabs per task, and at-a-glance status.

## The roadmap

The roadmap lives in **Linear**, team `Plume` — seven projects by area, one issue per item. **Use the `roadmap` skill** rather than the MCP tools directly; it knows the queue's conventions. Read the issue before starting work, and move it to Done as it lands.

Todo means queued, Backlog means wanted but not queued. `estimate` is the size: 2 = S, 3 = M, 5 = L, 8 = XL. An issue states the item and any real blocker, not what the code already does — read the code for that.

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
  Support/    Log, AppPaths, AppSettings, FileWatcher, HexColor, CommandLineHelper, SmokeHarness (DEBUG)
  Resources/  Fonts, Themes, Mermaid, Skills, plume-notify (the CLI helper)
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

## Agent transports

An agent tab runs over one of two transports, chosen by `TaskTab.transport` and defaulted by a setting. This is a separate axis from `renderMode`, which only picks a view.

**Headless (`.headless`, the default).** `claude -p` speaking stream-json over pipes, owned by `HeadlessSession` and keyed by tab ID in `HeadlessSessionManager` — the same shape as `SurfaceManager`, and no PTY at all. **`docs/headless-protocol.md` is the wire reference.** Read it before touching `Plume/Agent/Headless/`.

- **`--permission-prompt-tool stdio` plus an `initialize` control request** is what makes permission requests reach the host. Without both, anything needing approval is auto-denied and the turn ends having done nothing.
- Answering a running prompt, approving a plan, denying a tool with a reason, setting mode and model, and interrupting all ride the control plane. Interrupt is a control request — **never a signal**, which abandons the turn.
- One process serves the whole conversation. `session_id` is stable and gets persisted to the tab so a restart can `--resume`.
- **A control response is correlated by `request_id`**, through `pendingControlRequests`. Sniffing replies for a field you recognize works only while one request matters; add a request by recording its kind when you send it.
- **`/rc` is served by Plume, not the CLI.** `remote-control` is an interactive TUI command with no non-interactive variant, so it never reaches the headless `commands` list. `PlumeSlashCommand` supplies it and `ChatComposer.send()` intercepts it — only on this transport, since a terminal tab's real TUI already has a working `/rc`.
- Status, quota and cost arrive as events, so headless tabs start no hook watch. `total_cost_usd` is per turn and accumulates; stream `utilization` is 0–1 where the retired statusline capture used 0–100.

**Terminal (`.terminal`).** The Claude Code TUI hosted in a real PTY, kept as an escape hatch. Input reaches it as a paste plus a synthetic Enter, so it cannot answer a running `AskUserQuestion` — that ceiling is why the headless transport exists. `docs/agent-transport.md` records it.

Both transports launch through `AgentLauncher` and report through `StatusEngine`, which is transport-agnostic.

### Hook instrumentation (terminal transport)

`claude` launches with `--settings <generated>` plus `PLUME_TASK_ID` / `PLUME_TAB_ID` / `PLUME_EVENTS_DIR`. Each hook appends its stdin to `~/Library/Application Support/Plume/events/<taskID>/<tabID>.jsonl`; `AgentEventMonitor` tails those files and feeds `StatusEngine`.

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

**The discovered file is only the entry point.** `expandConfig` follows `config-file` includes recursively, and that is load-bearing: a config that only redirects (`config-file = "~/.config/ghostty/ghostty-config"`) is a supported setup that otherwise loads nothing. An include applies *after* the file that named it, and a relative path is relative to that file. Resolve themes against `winningThemeSourcePath(in:)`, not the root config — the theme is often declared in an included file whose directory is where `themes/` lives.

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
- **The chat list places one lazy item per *block*, not per message.** `ChatPieceSplitter` builds them and `ChatPieceView` draws them; a message's wash is painted per piece on the edges that piece owns. `LazyVStack` estimates unrealized items from realized ones, and a realized set whose heights differ by a large factor never settles under momentum scrolling. Anything that puts a whole message back in one item reopens that. **`docs/chat-list-hang.md`** has the evidence, the measured ratios, and the `PLUME_CHAT_ITEM_STATS` probe they came from. That measurement was a one-off; do not re-run it routinely.
- **`EnterWorktree` moves a live transcript to another project directory.** The session id is unchanged, but Claude Code relocates the `.jsonl` into a directory keyed by the worktree's path — so a path derived from the task's original folder goes stale mid-session. `FileWatcher` recreates the file it watches, so the move also leaves a zero-byte stub at the old path that reads as an empty conversation. `TranscriptStore` re-points on an empty read via `SessionJSONLReader.locateTranscript(sessionID:)`; never trust a derived transcript path to stay valid.
- **`scrollTo` into the chat's `LazyVStack` is for a jump the user asked for, never for following content.** The list follows new content through `defaultScrollAnchor(.bottom, for: .sizeChanges)`; a `ScrollPosition` jump serves the jump-to-bottom button and the minimap, and animating one is fine. The controlled trials in `docs/chat-list-hang.md` put the hang in the lazy stack's own height estimation — they reproduced it with animation removed, and with every row a blank rectangle — so animation was falsified as a participant. What stays banned is feeding a *measured* layout height back into the piece model, which is the real feedback loop.
- **The chat list has two engines behind `AppSettings.chatListEngine`.** `docs/chat-list.md` is the reference for the custom one, Plume's own `NSScrollView`-based container. A fresh `NSHostingView` root has none of the SwiftUI environment a view mounted normally would inherit, so any environment key a chat row reads has to be forwarded by hand in `ChatListItemRoot` or the row silently renders with defaults instead of failing loudly. `ChatMessageList` still owns and builds the pieces for both engines.
- **`.symbolEffect` with a repeating option is not free in-process.** RenderBox re-rasterizes the symbol every frame on the main thread and blocks on the render-server commit, about a tenth of a core per instance, and the stall starves wheel-event handling. `WorkingEllipsis` fades masked copies of the glyph off a `TimelineView` for this reason; measure any repeating symbol effect in a bare window before shipping one. `docs/handoff-idle-cpu.md` has the numbers.
- **Never bind the composer's focus through `FocusState`.** SwiftUI answers a programmatic `false` on a `.focused` binding by resigning whatever is first responder *at that moment*, from inside a layout pass. During a click on selectable text that is the field editor whose mouse-tracking loop is still on the stack, and detaching it spins the main thread at 100% forever. `MarkdownComposerTextView` takes a plain `Binding<Bool>` and mirrors first responder itself; `docs/selectable-text-link-hang.md` has the trace and a repro that needs neither the pointer nor the frontmost window.
- **Never write to `@Observable` state during a SwiftUI `body`.** SwiftUI records the write as a dependency of the view being rendered, so the render invalidates itself and spins forever — one core at 100%, no crash, and the surfaces never spawn their PTYs. A `sample` blames whatever is most expensive inside the loop (`ProcessInfo.environment`, say), not the write. Create sessions and register them from `.onAppear`/`.task` and hold them in `@State`; `TerminalTabHost` in `TabContentView` is the pattern.
- **The wrapper's text path is a *paste*, not typing.** `TerminalViewState.paste(text:)` frames its argument as a bracketed paste, so a trailing `\r` lands in the program's edit line instead of submitting — `send(_:)` is deprecated for exactly this reason. Sending a line means `paste(text:)` then `sendKey(.enter)`; `TerminalSession.submit(text:)` does both.
- **`SurfaceCommandTests` needs a real GUI session.** It spawns real `NSWindow`s and PTYs, so it fails from a headless shell. That is environmental; check it against `main` before believing a regression.
- **`SessionJSONLReaderTests.encodingResolvesADirectoryClaudeCodeHasUsed` only asserts where Claude Code has run in this checkout.** It derives the repo path from `#filePath` and locates the transcript directory by the `cwd` Claude Code records, which a worktree or a freshly cloned machine has none of. There its `#require` fails with "Claude Code has not run in …" — an environmental failure, not a regression. More than one directory can legitimately record the same `cwd`, because an agent working in a worktree still stamps the parent repository's path, so the test asserts the encoded name is *among* the owning directories rather than the only one.
- Swift Testing runs suites in parallel in one process, so tests sharing libghostty state can contaminate each other's results.
- **A test that waits on a file watcher must await the store's own read signal, never a wall clock.** `RealTranscriptCorpusTests` parses every transcript on the machine — hundreds of files, tens of seconds — and Swift Testing runs it in parallel with everything else, so a deadline generous enough to look safe still expires under that load. `TranscriptStore.didRead` and `MarkdownFileStore.didRead` exist for this; the `waitUntil` helpers in their suites resume on the signal and finish instantly. Lengthening a timeout only moves the threshold.
- Swift Testing's `#expect` cannot wrap a throwing call. `allSatisfy(\.isHexDigit)` counts as throwing (the closure is `rethrows`), so write `allSatisfy { $0.isHexDigit }`. The failure names a generated macro file, but `…MX45…` in that name is the **line number** in the real source.
- **A shell script under `Plume/Resources/` ships executable.** The synchronized group flattens it into `Contents/Resources/`, and neither the copy nor the codesign clears its mode bits, so `plume-notify` needs no build phase of its own. `docs/releasing.md` covers how it reaches PATH.
- **`[ -w /dev/tty ]` is true even with no controlling terminal**, and the redirect then fails at the shell, where `2>/dev/null` on the command does not catch it. A script that must write to the real terminal has to *attempt* the open inside a subshell — `if ! (printf … >/dev/tty) 2>/dev/null`. `plume-notify` falls back to stdout that way.
- Adding a *source file* needs no project edit, but adding a *SwiftPM package* means hand-editing `project.pbxproj` (build file, package reference, product dependency, and the Frameworks phase).
- **A GUI-launched app does not inherit your shell PATH.** Launched from Xcode or a terminal it does, so a PATH bug hides completely until the app is opened from Finder or the Dock — `claude` at `~/.local/bin` then fails with `No such file or directory`. Both transports run through `LoginShellCommand.wrap` for this reason. Test PATH-sensitive changes by opening the installed bundle, not from a terminal.
- Deployment target is macOS 26.2, matching the Xcode 26.2 SDK ceiling. Raising it above the installed SDK makes every build warn.
