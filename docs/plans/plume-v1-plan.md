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
- **2026-08-31 — Deployment target stays at the template's macOS 26.5** (Ryan's call), even though Xcode 26.2's SDK only compiles to 26.2 and every build therefore logs a deployment-target warning. Revisit if it ever becomes a hard error.
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
- **WP0.2 GhosttyKit into the build**: add libghostty-spm `.exact`, `ghostty_init()` at launch, write `docs/GHOSTTY_PIN.md`, record GhosttyTerminal-vs-raw-C verdict. *Accept:* linked and running; pin + wrapper decision documented.

**Phase 1 — Terminal embedding** (sequential; the risk phase, front-loaded)
- **WP1.1 Runtime + single surface**: GhosttyRuntime/Surface/NSView/TerminalSurfaceView; one hardcoded interactive terminal with user's ghostty config. *Accept:* typing, theme/font from config, resize, scrollback, `vim` usable.
- **WP1.2 Lifecycle + input polish**: SurfaceManager/TabSession, per-surface command/cwd/env, exit detection, focus/IME/clipboard/scroll. *Accept:* two concurrent surfaces; hide/show never kills a process; copy/paste works.

**Phase 2 — Tasks, tabs, workspaces** (WP2.1 ∥ WP2.2, then WP2.3)
- **WP2.1 Tab model + strip**: TabStrip/TabContent, add/close/reorder persisted; agent tab first-message view launching uninstrumented `claude "<msg>"`. *Accept:* mixed tabs per task; switching preserves processes; layout survives relaunch.
- **WP2.2 Workspace provisioning**: provisioner + GitRunner, both flows, `.plume/` gitignore bootstrap, error surfacing, worktree cleanup prompt. *Accept:* worktree task creates branch+worktree inside `.plume/worktrees/` and opens there; failures show readable errors; repo `git status` stays clean.
- **WP2.3 Frictionless creation + sidebar polish**: ⌘N instant-create, inline title edit, setup header, drag-folder, recent repos. *Accept:* ⌘N → first message sent to claude in ~5s after picking a folder; no modal blocks creation.

**Phase 3 — Instrumentation & status** (WP3.1 → WP3.2; WP3.3 ∥ WP3.2)
- **WP3.1 Hook pipeline**: AgentProvider + ClaudeCodeProvider, HookSettingsWriter, HookEventIngester + FileWatcher (offsets, rotation, startup replay). *Accept:* all hook types decoded live; session ID captured onto TaskTab.
- **WP3.2 StatusEngine + badges**: state machine, aggregation, StatusBadge, debounced persistence, dock badge = needsInput count. *Accept:* live correct badges across ≥3 parallel tasks; permission prompt → needsInput within ~1s.
- **WP3.3 JSONL resolver**: path resolution incl. worktree cwds, mtime fallback, documented chat-rendering seam. *Accept:* correct JSONL path for new and resumed sessions.

**Phase 4 — Restore & polish** (WP4.1 ∥ WP4.2)
- **WP4.1 Full restore**: resume overlay, event replay + status reset, missing-dir banners, quit confirmation while agents work. *Accept:* quit mid-session, relaunch, resume prior conversation.
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
