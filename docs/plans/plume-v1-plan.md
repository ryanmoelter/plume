# Plume — Native macOS Agentic Coding Tool: Implementation Plan

## Context

Plume is a new macOS app (empty SwiftUI/SwiftData Xcode template at `/Users/ryanmoelter/Development/Plume`) for organizing and parallelizing coding-agent work: a left sidebar of tasks in groups, flexible agent/terminal tabs per task, and at-a-glance status. This plan is written for **multiple agents to execute later in phases** — each work package (WP) is sized for one agent session with acceptance criteria.

### Locked decisions (from Ryan)
- **Terminal: libghostty, no fallback.** Consume prebuilt `GhosttyKit.xcframework` via the `Lakr233/libghostty-spm` SwiftPM package, pinned `.exact` (Ghostty 1.3.x line). Self-vendoring Ghostty's per-commit xcframework is the documented fallback, not the default. Load the user's normal ghostty config via `ghostty_config_load_default_files`.
- **Agent integration v1: `claude` CLI inside the embedded terminal**, instrumented via Claude Code hooks + session JSONL — not the Agent SDK. Native chat rendering comes later on this same data seam.
- **Workspace per task: user's choice** — plain working directory or a new git worktree, both first-class, both settable after creation.
- **Worktree location: inside the repo** at `<repo>/.plume/worktrees/<branch-slug>`, with an auto-created `<repo>/.plume/.gitignore` containing `*` so nothing under `.plume/` is ever tracked. (Caveat to accept: recursive tools scanning the repo may descend into worktrees.)
- **Agent launch: on first message.** An agent tab does not spawn `claude` until the user sends their first message — the empty tab shows a native input field; submitting launches `claude "<message>"` (with instrumentation) in the terminal. No idle `claude` processes.
- **Relaunch: explicit resume.** Agent tabs with a prior session show a "Resume / Start fresh" overlay (`claude --resume <sessionID>`); never auto-resume. Terminal scrollback is not preserved.
- **Persistence: full restore** of groups/tasks/tabs/selection via SwiftData.

### Later (design for, don't build in v1)
Native SwiftUI chat rendering (deliberately excluded from this plan — it's involved enough to warrant its own plan later; the JSONL seam in WP3.3 is built for it); customizable statusline bar; more providers (Codex, local models); sidebar integrations (PR/MR status, Linear tickets).

## Amendments

Decisions made during execution that supersede the text below. Append here rather than rewriting the original.

- **2026-08-31 — Adopt the `GhosttyTerminal` wrapper.** WP0.2's evaluation resolved in favor of adopting it rather than writing our own wrapper on the raw C API. `libghostty-spm` has matured well past the 1.3.x assumed below (now 1.5.0), and the wrapper meets all three adoption criteria: per-surface `workingDirectory` + `command` + `envVars` via `TerminalSurfaceOptions` (its docs describe host tagging of surfaces with a UUID — exactly the `PLUME_TAB_ID` case), surface keep-alive across reparenting, and the user's config via `TerminalController.ConfigSource.file(path)` pointed at `~/.config/ghostty/config`. Note it does *not* call `ghostty_config_load_default_files`; it renders a config file from a base string plus programmatic overrides, so config-file discovery is ours to do. This substantially shrinks Phase 1 — no hand-written Metal layer or `NSTextInputClient` IME. The raw-C path stays the documented fallback, and the one-folder containment rule is unchanged.
- **2026-08-31 — Pin `.exact("1.5.0")`.**
- **2026-08-31 — Deployment target is macOS 26.2.** The template's 26.5 was unbuildable-in-principle: Xcode 26.2's SDK only compiles to 26.2, so every build warned. Lowered to match the SDK ceiling.
- **2026-08-31 — `ENABLE_USER_SELECTED_FILES` removed** alongside disabling the sandbox; it is a sandbox entitlement and is meaningless unsandboxed.

## Architecture

Single app target, organized by folder:

```
Plume/
  App/            PlumeApp.swift, AppDelegate.swift, MainWindow.swift
  Models/         TaskGroup.swift, WorkTask.swift, TaskTab.swift, enums (TabKind, TaskStatus, WorkspaceKind)
  Ghostty/        GhosttyRuntime.swift, GhosttyConfigLoader.swift, GhosttySurface.swift,
                  GhosttySurfaceNSView.swift, TerminalSurfaceView.swift (NSViewRepresentable), GhosttyError.swift
  Sessions/       SurfaceManager.swift, TabSession.swift
  Agent/          AgentProvider.swift (protocol), ClaudeCodeProvider.swift,
                  HookSettingsWriter.swift, HookEventIngester.swift, SessionJSONLReader.swift
  Status/         StatusEngine.swift, StatusBadge model
  Workspace/      WorkspaceProvisioner.swift, GitRunner.swift
  UI/Sidebar/     SidebarView.swift, TaskRowView.swift, GroupSectionView.swift, StatusBadge.swift
  UI/Task/        TaskDetailView.swift, TabStripView.swift, TabContentView.swift,
                  TaskSetupHeaderView.swift, AgentFirstMessageView.swift
  Support/        AppPaths.swift, FileWatcher.swift, Log.swift
docs/GHOSTTY_PIN.md
```

Principles:
- **SwiftData models are the persisted skeleton; live process/terminal state lives in in-memory `@Observable` objects** (`SurfaceManager`, `StatusEngine`) keyed by model UUID. Nothing about a running PTY is persisted.
- **All `ghostty_*` C calls confined to `Plume/Ghostty/`** — the C API is explicitly unstable between versions; upgrading Ghostty means touching one folder.
- Template corrections in Phase 0: set `ENABLE_APP_SANDBOX = NO` (a terminal host spawning PTYs, reading `~/.claude/**` and running `git worktree` cannot be sandboxed; Ghostty.app itself is unsandboxed; distribution is Developer ID + notarization, not MAS). Delete `Item.swift`.

## SwiftData schema

Names avoid colliding with Swift `Task` / SwiftUI `Group`:

```swift
@Model final class TaskGroup {
  var id: UUID; var name: String; var orderIndex: Int; var isExpanded: Bool
  @Relationship(deleteRule: .cascade, inverse: \WorkTask.group) var tasks: [WorkTask]
}

@Model final class WorkTask {
  var id: UUID; var title: String; var orderIndex: Int; var createdAt: Date
  var group: TaskGroup?                // nil = ungrouped section
  var workspaceKindRaw: String         // "unset" | "directory" | "worktree"
  var workingDirectoryPath: String?
  var repoPath: String?; var branchName: String?   // worktree tasks
  var lastStatusRaw: String            // snapshot for sidebar pre-restore
  var isArchived: Bool
  var integrationsData: Data?          // future: PR/Linear JSON blob
  @Relationship(deleteRule: .cascade, inverse: \TaskTab.task) var tabs: [TaskTab]
  var selectedTabID: UUID?
}

@Model final class TaskTab {
  var id: UUID; var kindRaw: String    // "agent" | "terminal"
  var title: String?; var orderIndex: Int; var task: WorkTask?
  var providerID: String?              // "claude-code" in v1
  var agentSessionID: String?          // for --resume
  var sessionJSONLPath: String?        // cached ~/.claude/projects/ path
  var launchArgumentsData: Data?       // future: extra args, statusline prefs
}
```

`enum TaskStatus: String { case unset, idle, working, needsInput, done, error }`. Raw-string enum storage keeps migrations trivial; `providerID` + the `Data?` blobs give the "later" features room without schema churn.

## GhosttyKit integration

- Add `Lakr233/libghostty-spm` with `.exact(<latest tag>)`; record tag + underlying Ghostty commit + upgrade/self-vendor procedure in `docs/GHOSTTY_PIN.md`.
- The Phase 1 spike also evaluates the package's `GhosttyTerminal` Swift wrapper product: adopt it if it supports (a) `ghostty_config_load_default_files`, (b) per-surface command + cwd + env injection, (c) surface keep-alive across reparenting; otherwise use it (plus Ghostty.app's `macos/Sources/Ghostty/*`, cmux, Termini, Sessylph's BUILDING_GHOSTTYKIT.md) as reference and write our own thin wrapper on the raw C API.
- **Process model: one `ghostty_app_t` per process, many `ghostty_surface_t`** (matches Ghostty.app).
  - `GhosttyRuntime` (`@MainActor` singleton): `ghostty_init`; config via `ghostty_config_new` → `ghostty_config_load_default_files` → `ghostty_config_finalize` (user's theme/font/keybinds apply automatically); owns the app handle; wakeup callback schedules `ghostty_app_tick` on main queue; action callback dispatched by tag (set-title, bell, clipboard, close-surface, cell-size…).
  - `GhosttySurface`: wraps one surface, created from `ghostty_surface_config_s` with **working directory, command override, and env vars** — this is how agent tabs launch `claude` and how `PLUME_TASK_ID`/`PLUME_TAB_ID`/`PLUME_EVENTS_DIR` are injected. Handles resize, focus, key/mouse, process-exit notification.
  - `GhosttySurfaceNSView: NSView`: Metal-backed layer, first responder, IME via `NSTextInputClient`.
  - `TerminalSurfaceView: NSViewRepresentable` is thin — it asks `SurfaceManager` for the **long-lived** NSView for a tab ID and hosts it; it never creates/destroys views, so processes survive tab/task switches.
- `SurfaceManager` (`@MainActor @Observable`): `[UUID: TabSession]` (surface, view, exit state, provider handle). Terminal tabs create lazily on first display; agent tabs create when the first message is submitted. Teardown on tab/task delete and app quit.

## Agent instrumentation & status

**Launch** (`ClaudeCodeProvider: AgentProvider`, protocol `launchCommand(for:resume:) -> (command, env)`):

```
claude --settings "~/Library/Application Support/Plume/hooks/settings.json" \
  ["<first message>"] [--resume <sessionID>]
```

env: `PLUME_TASK_ID`, `PLUME_TAB_ID`, `PLUME_EVENTS_DIR`.

**Hook transport — append-to-file + DispatchSource watching** (chosen over a local socket/HTTP listener: no port lifecycle, events written while Plume is closed replay on startup for correct restore-time status, `tail -f` debuggable, hook stays a dependency-free one-liner). `HookSettingsWriter` generates one static settings.json with hooks for `SessionStart`, `UserPromptSubmit`, `PreToolUse` (matcher `*`), `Stop`, `SubagentStop`, `Notification`, `SessionEnd`, each:

```
mkdir -p "$PLUME_EVENTS_DIR/$PLUME_TASK_ID" && cat >> "$PLUME_EVENTS_DIR/$PLUME_TASK_ID/$PLUME_TAB_ID.jsonl"
```

The payload on stdin carries `hook_event_name` and `session_id` — capturing the session ID for `--resume` comes free. `HookEventIngester` tails per-tab files with byte offsets, rotates above ~1 MB. Note `--settings` merges with (doesn't replace) user settings, so the user's own hooks survive.

**Status mapping** (`StatusEngine`, `@MainActor @Observable`):

| Event | Tab status |
|---|---|
| SessionStart / UserPromptSubmit / PreToolUse | working |
| Notification (permission / waiting) | needsInput |
| Stop | done (turn finished) |
| SessionEnd or PTY child exit | idle |
| abnormal surface exit | error |

Task status = max priority across agent tabs (needsInput > working > error > done > idle). Sidebar observes the engine directly; SwiftData gets only a debounced snapshot into `lastStatusRaw` — never per-event writes.

**JSONL** (`SessionJSONLReader`): resolve `~/.claude/projects/<dash-encoded-cwd>/<session_id>.jsonl`, cache on `TaskTab`, use mtime as fallback activity signal if hooks misfire. This is the designed seam for the future native chat renderer; no v1 UI parses message content.

## Workspace flows

`WorkspaceProvisioner` + `GitRunner` (Process, stderr surfaced in UI):

- **Plain directory**: NSOpenPanel or drag-a-folder onto the task → sets `workingDirectoryPath`.
- **Worktree**: pick source repo (recent-repos list in UserDefaults + open panel) → suggested branch `plume/<slugified-title>-<4char>` (editable) → ensure `<repo>/.plume/.gitignore` exists containing `*` → `git -C <repo> worktree add -b <branch> <repo>/.plume/worktrees/<branch-slug>` → store `repoPath`/`branchName`, set cwd, kind `.worktree`. Base ref = current HEAD in v1.
- Deleting a worktree task offers "Also remove worktree" (`git worktree remove --force` + optional branch delete) — never silent.

**Zero-friction creation**: ⌘N / "+" instantly creates a task — no dialog, no required fields: title "New Task" (inline-editing), one agent tab, `workspaceKind = .unset`, selected. `TaskSetupHeaderView` shows "Choose Folder… / New Worktree… / drop target" while unset, collapsing to a path/branch chip once set. Agent tab shows `AgentFirstMessageView` (native text input) until the first message launches `claude`.

## UI composition

- `MainWindow`: `NavigationSplitView(sidebar:detail:)`.
- `SidebarView`: `List(selection:)`, `Section` per group + "Ungrouped"; `TaskRowView` = title + `StatusBadge` (needsInput orange bell, working animated dot, done green check, idle gray, error red); context menus (rename/move/archive/delete); drag reorder via `orderIndex`.
- `TabStripView`: custom SwiftUI chip strip (add menu: agent/terminal, close, reorder, per-tab status dot).
- `TabContentView`: `ZStack` keeping every tab's `TerminalSurfaceView` mounted, non-selected hidden (fallback: reparent-on-select, contained in `SurfaceManager`).
- Exited agent tab: overlay with Restart / Resume.

## Restore

SwiftData restores tree/tabs/selection; `lastStatusRaw` badges show immediately. Terminal tabs get a fresh shell in cwd. Agent tabs with `agentSessionID` show Resume / Start fresh. Startup: replay hook events written while closed, then reset processless tabs to idle; validate directories/worktrees exist and banner-flag missing ones.

## Phases & work packages (each WP = one agent session)

**First action on approval (before any WP):** copy this plan verbatim into the repo at `docs/plans/plume-v1-plan.md` and commit it — it's the working document the implementing agents pick WPs from. Agents should check off / annotate WPs in that file as they complete them.

**Phase 0 — Skeleton & data model** (WP0.1 ∥ WP0.2)
- **[x] WP0.1 Hygiene + schema + shell** *(done 2026-08-31)*: sandbox off, delete `Item.swift`, Models/, NavigationSplitView shell with full group/task CRUD (placeholder detail). *Accept:* CRUD + reorder works, survives relaunch, clean build.
  - Added `TaskStore` (not in the original file list) to hold CRUD + dense-`orderIndex` reordering, keeping it out of the views. `TaskStatus.aggregate` implements the priority ladder now so Phase 3 inherits a tested seam.
  - 10 unit tests cover ordering, tab selection on close, group-delete-keeps-tasks, status aggregation, and an on-disk close/reopen round-trip standing in for relaunch.
  - Detail pane is an intentional placeholder listing tabs; `TabStripView`/`TabContentView` arrive in WP2.1.
- **[x] WP0.2 GhosttyKit into the build** *(done 2026-08-31)*: add libghostty-spm `.exact`, `ghostty_init()` at launch, write `docs/GHOSTTY_PIN.md`, record GhosttyTerminal-vs-raw-C verdict. *Accept:* linked and running; pin + wrapper decision documented.
  - Verdict: adopt `GhosttyTerminal` (see Amendments). Pinned `.exact("1.5.0")`; `Package.resolved` committed.
  - `GhosttyRuntime` (MainActor `@Observable` singleton) starts in `PlumeApp.init()`. Verified at runtime via unified log: the app loads the user's real config from `~/Library/Application Support/com.mitchellh.ghostty/config` with no config issue reported.
  - `GhosttyConfigLoader` implements ghostty's config search order, which is **Application Support before XDG** — the opposite of what ghostty's docs page implies. Verified against `src/config/file_load.zig` and locked down by tests.
  - Note for later verification: the Debug app binary is a 57K launcher stub; the real code and all ~6300 libghostty symbols live in `Plume.app/Contents/MacOS/Plume.debug.dylib`. Inspect that, not the stub.

**Phase 1 — Terminal embedding** (sequential; the risk phase, front-loaded)
- **[x] WP1.1 Runtime + single surface** *(done 2026-08-31)*: GhosttyRuntime/Surface/NSView/TerminalSurfaceView; one hardcoded interactive terminal with user's ghostty config. *Accept:* typing, theme/font from config, resize, scrollback, `vim` usable.
  - Adopting the wrapper removed the planned `GhosttySurfaceNSView` and IME work entirely: `TerminalSession` wraps the wrapper's `TerminalViewState`, and `TerminalTabView` is a thin `TerminalSurfaceView` host.
  - Verified: a real PTY spawns (`login` → `-zsh`, stdin/stdout/stderr on `/dev/ttysNNN`, state `SN+`), cwd honored.
  - **Not yet verified visually** — see Open items.
- **[x] WP1.2 Lifecycle + input polish** *(done 2026-08-31)*: SurfaceManager/TabSession, per-surface command/cwd/env, exit detection, focus/IME/clipboard/scroll. *Accept:* two concurrent surfaces; hide/show never kills a process; copy/paste works.
  - `SurfaceManager` keyed by tab ID; `TaskDetailView` keeps every tab mounted and toggles opacity, so switching never unmounts a surface.
  - Verified: **3 concurrent surfaces on 3 distinct PTYs survived 18 tab/task switches over 30s** with the same shell PIDs throughout and exactly 3 surfaces ever created. Quit reaps every child cleanly.
  - Exit detection via the wrapper's `onClose(processAlive:)`; `command`/`workingDirectory`/`envVars` confirmed reaching the surface config (the mechanism agent launch needs in Phase 2).
  - Surfaces spawn lazily on first attach to a visible view, so an unselected task's terminal starts only once shown.
  - Input polish (IME, clipboard, scroll) is the wrapper's, not reimplemented; **unverified by hand** — see Open items.

### Open items needing Ryan

- **Visual/interactive verification of the terminal is outstanding.** Screen Recording permission is not granted to this session's terminal host, so screenshots fail with "could not create image from display", and Accessibility permission is missing too, so UI scripting (`System Events`) fails with `-1743`. Everything provable without pixels has been proven (PTY allocation, process survival, teardown), but these remain unconfirmed: text actually renders, the user's theme/font apply, typing works, resize/reflow, scrollback, `vim`, and copy/paste. Grant Screen Recording (and optionally Accessibility) to re-enable automated checking, or eyeball it once manually.

**Phase 2 — Tasks, tabs, workspaces** (WP2.1 ∥ WP2.2, then WP2.3)
- **[x] WP2.1 Tab model + strip** *(done 2026-08-31)*: TabStrip/TabContent, add/close/reorder persisted; agent tab first-message view launching uninstrumented `claude "<msg>"`. *Accept:* mixed tabs per task; switching preserves processes; layout survives relaunch.
  - Verified end to end: an agent tab launched real `claude` (2.1.252) as the surface's child in the task's cwd, and the message reached it — confirmed by finding the exact prompt text in the session JSONL that `claude` created.
  - `AgentLauncher` is the single launch path, shared by the send button and the smoke harness.
  - Shell quoting is test-covered against injection (quotes, `$(…)`, backticks, `&&`).
- **[x] WP2.2 Workspace provisioning** *(done 2026-08-31)*: provisioner + GitRunner, both flows, `.plume/` gitignore bootstrap, error surfacing, worktree cleanup prompt. *Accept:* worktree task creates branch+worktree inside `.plume/worktrees/` and opens there; failures show readable errors; repo `git status` stays clean.
  - Tests drive real `git` against scratch repos, including the "`git status` stays clean" criterion.
  - Delete offers Task only / + worktree / + worktree and branch; a git failure surfaces its stderr and keeps the task rather than losing track of the directory.
- **[x] WP2.3 Frictionless creation + sidebar polish** *(done 2026-08-31)*: ⌘N instant-create, inline title edit, setup header, drag-folder, recent repos. *Accept:* ⌘N → first message sent to claude in ~5s after picking a folder; no modal blocks creation.
  - ⌘N creates and immediately opens inline rename; an emptied name reverts to "New Task".
  - Menu commands and shortcuts from WP4.2 landed here since the seam existed: ⌘T / ⌘⇧T new tab, ⌘W close, ⌘⇧[ / ⌘⇧] cycle, ⌘1–9 select.
  - **Timing criterion unverified** — needs the visual/interactive check below.

**Phase 3 — Instrumentation & status** (WP3.1 → WP3.2; WP3.3 ∥ WP3.2)
- **[x] WP3.1 Hook pipeline** *(done 2026-08-31)*: AgentProvider + ClaudeCodeProvider, HookSettingsWriter, HookEventIngester + FileWatcher (offsets, rotation, startup replay). *Accept:* all hook types decoded live; session ID captured onto TaskTab.
  - Verified against a live `claude`: `SessionStart`, `UserPromptSubmit`, `PreToolUse` (with `tool_name`), `Notification`, `Stop`, and `SessionEnd` all fired and decoded. **Session ID persisted onto the tab**, ready for `--resume`.
  - Two schema corrections from the docs, confirmed at source: **`Stop` and `UserPromptSubmit` reject a `matcher`** (the generated file omits it everywhere; for other events omitting it already means "all"). And `--settings` *unions* hook lists rather than replacing, so the user's own hooks keep firing.
  - Instrumentation is best-effort: if the settings file cannot be written, `claude` still launches, just unreported.
- **[x] WP3.2 StatusEngine + badges** *(done 2026-08-31)*: state machine, aggregation, StatusBadge, debounced persistence, dock badge = needsInput count. *Accept:* live correct badges across ≥3 parallel tasks; permission prompt → needsInput within ~1s.
  - Verified live: the app ingested events and drove `working` → `working` → `done` through a real turn, each within ~1s of the hook firing. The debounced snapshot persisted as `done`.
  - **Partly unverified:** the ≥3-parallel-tasks case and the badge/dock *visuals* need the screenshot permission below. The state machine itself is covered by 13 unit tests including aggregation across tabs.
- **[x] WP3.3 JSONL resolver** *(done 2026-08-31)*: path resolution incl. worktree cwds, mtime fallback, documented chat-rendering seam. *Accept:* correct JSONL path for new and resumed sessions.
  - The hook payload's `transcript_path` is authoritative; deriving from the cwd is the fallback. Both paths are covered.
  - Encoding replaces `/` and `.` with `-`, so a hidden directory yields a double dash and a worktree gets its own transcript directory, distinct from its parent repo's. Verified against real `~/.claude/projects` names, and a test resolves this repo's own directory so a scheme change fails loudly.
  - `_` handling is **unverified** (no local evidence, and `--print` mode did not create a directory to test with). It is not encoded, since guessing would be worse than falling back. Only affects the derived path, never the authoritative one.
  - `sessionJSONLPath` is cached onto the tab. No v1 UI parses message content — this is purely the seam.

**Phase 4 — Restore & polish** (WP4.1 ∥ WP4.2)
- **[x] WP4.1 Full restore** *(done 2026-08-31)*: resume overlay, event replay + status reset, missing-dir banners, quit confirmation while agents work. *Accept:* quit mid-session, relaunch, resume prior conversation.
  - `AgentResumeOverlayView` (new) is shown by `TabContentView` for an agent tab with no live session but a stored `agentSessionID` — Resume calls the existing `AgentLauncher.launch(resumeSessionID:)` path (`claude --resume` support already existed, just unused); Start Fresh clears `agentSessionID` and falls through to the ordinary `AgentFirstMessageView`. Neither happens automatically.
  - Event replay + idle reset: `MainWindow.restoreStatusMonitoring()` was already correctly ordered — `AgentEventMonitor.watch()` drains the backlog synchronously before the loop force-sets `.idle`, so idle always wins on launch, which is right (nothing is actually running yet). No change needed there.
  - Missing-directory banners: `TaskSetupHeaderView` already had one for the workspace chip. Extended the same `FileManager.fileExists` guard to `AgentFirstMessageView` (blocks Send, shows a banner) and to the new `AgentResumeOverlayView` (blocks Resume).
  - Quit confirmation: added `Plume/App/AppDelegate.swift` (`NSApplicationDelegate.applicationShouldTerminate`), wired via `@NSApplicationDelegateAdaptor` in `PlumeApp`. Confirms via `NSAlert` when any tab's `StatusEngine` status is `.working` or `.needsInput`; the yes/no decision logic is a static, unit-tested function (`AppDelegate.shouldConfirmQuit`).
  - New tests: `AppDelegateTests` (5 cases covering the confirm/don't-confirm matrix) and 3 additional `ClaudeCodeProviderTests` cases for the 4-argument `launchCommand` overload (env var injection, resume quoting) that had no prior coverage.
  - Verified: clean build, full `PlumeTests` pass. Runtime verification (fresh launch not auto-resuming, session ID persistence across relaunch, quit not crashing) was delegated to a runtime-check agent using the process-tree/unified-log recipe — see its results in the WP4.1 commit message / session notes; the interactive "does the confirmation dialog actually block quit" behavior remains unverifiable in this environment (no Accessibility permission for UI scripting).
- **WP4.2 Polish**: menu commands, shortcuts (⌘1–9, ⌘⇧]/[), empty states, Settings stub (worktree base path override, provider field), archive view, app icon. *Accept:* keyboard-only workflow; first launch self-explanatory.

## Risks & mitigations

- **libghostty API instability** (explicitly unversioned between releases): exact pin, all `ghostty_*` in one folder, `docs/GHOSTTY_PIN.md` upgrade procedure, self-vendor fallback (local SwiftPM `binaryTarget` pointing at Ghostty's per-commit xcframework + checksum) ready.
- **Embedding difficulty** (Metal layer, IME, focus inside SwiftUI): copy Ghostty.app's own Swift patterns; evaluate GhosttyTerminal wrapper; Phase 1 is isolated — later phases depend only on SurfaceManager's interface.
- **Hook reliability**: hooks are exit-0 stdin appends merged with user settings; JSONL-mtime fallback keeps status coarse-but-correct; missing/old `claude` degrades to plain terminal rather than breaking.
- **In-repo worktrees**: recursive tools may scan into `.plume/worktrees/`; acceptable per decision — Settings later allows overriding the base path.
- **Binary size**: static xcframework is tens of MB — fine for Developer ID distribution.
- **SwiftData + high-frequency events**: status lives in the @Observable engine; only debounced snapshots hit SwiftData.

## Verification

- Per-WP acceptance criteria above; every WP ends with a clean `xcodebuild -scheme Plume build` and manual run.
- End-to-end (post Phase 3): create two tasks (one plain dir, one worktree), send a first message in each agent tab plus open a terminal tab; confirm both sidebar badges track working → needsInput (trigger a permission prompt) → done; quit and relaunch; confirm structure restores, badges show snapshots, and Resume continues the prior claude conversation.
- Unit-testable seams: StatusEngine state machine (feed synthetic hook events), HookEventIngester (offsets/rotation/replay), JSONL path resolution, branch-slug generation.
