# Plume roadmap

Features we intend to build, in no particular order. This tracks what we want and what the code already provides — it doesn't say how to build any of it. Work out the approach when you pick an item up.

## Where to start

Recommendations, not commitments. Reorder freely.

**Start here.** State restoration comes before everything else: a notification that tells you to look at a task is worth less if switching to it disturbs what's running there.

1. **Keep terminals intact across task switches.** The processes already survive; the hosted views don't, so scroll position, selection and focus are lost every switch. See the section below for the two ways to fix it.
2. **Resume an existing conversation.** Today `--resume` only works for a session Plume started and captured. Listing what's in `~/.claude/projects/` and letting a tab attach to one closes the gap.

**Then these — small, self-contained, and each one is felt every day:**

3. **⌘N opens a task in the current group.** One call site (`MainWindow.swift`) hardcodes ungrouped; `TaskStore.createTask` already takes a `group:`. Smallest real win on the list.
4. **Terminal bell + a dot on tabs that rang one.** The wrapper already publishes `bellCount` / `lastBellAt`, and `TerminalSession` already mirrors published fields. Little more than wiring.
5. **System notification on bell.** Once the bell signal exists, this is one `UNUserNotificationCenter` call and a permission prompt. Together with the two above it delivers most of "tell me when to look" for a fraction of the whole notifications section.
6. **Terminal focus when a tab is shown.** A one-line irritation that shows up constantly. Related to item 1 — both are focus lost on a switch — so check whether fixing restoration already covers it.
7. **⌘N defaults to the current directory.** Turns the common case into zero decisions, and doesn't depend on the larger directory rework below.

**Then the highest-value item on the list:**

8. **Notify on Claude Code events, above all waiting-for-input.** This is the thing that makes parallel tasks actually parallel — right now a blocked agent waits silently. The signal already exists and already drives `needsInput`; only delivery is missing. Highest value per unit of work of anything here.

**Nearly done already:**

- **⌘T in the current task** already works — it's just labelled "New Agent Tab". Collapsing to one tab kind renames it and finishes the item.
- **Next/previous tab** is bound to ⌘⇧] / ⌘⇧[. What's missing is next/previous *task*, and making any of it user-assignable.

**Also cheap, once you want them:**

- **CLI notify** is nearly free — the wrapper already accepts OSC 9 / 777, so a shell can notify Plume today with no app change. The helper is a convenience script.
- **Shortcuts while the terminal is focused** is small if SwiftUI's focus system cooperates and a rabbit hole if it doesn't. Timebox it. Do it before **assignable hotkeys** — alt-based chords are exactly what a focused terminal is most likely to swallow, so binding them on top of a broken focus story would just move the bug.
- **Drag to reorder tabs** is contained; the sidebar already does the equivalent. Do it together with **dragging a tab into another task** — same drag machinery, and reordering alone is the fiddly half. Moving a tab out into a new task needs no drag at all and could be a menu item first.

**Bigger, and best taken deliberately:**

- **Native chat UI** is the largest item here and the one that most changes what Plume is. It's also the most incremental: font and message attribution first, then the statusline strip, then agents. Ship it in slices.
- **Assignable hotkeys** is the sleeper. Adding a next/previous *task* command is easy; making bindings user-settable means a binding store, a settings UI, and applying stored bindings to menu commands. Consider shipping fixed alt+J/K first and configurability later.
- **Directories on tabs instead of tasks** is the widest change here — ten-odd call sites, mostly mechanical, but it forces a real question about what a task *is* once it doesn't own a directory. Worth deciding alongside the naming question, since they're the same question wearing different hats. Tracking the agent's live directory is the easy half and could land first: the terminal already reports it per tab, and `EnterWorktree` needs no special case.
- **Palettes** and **PR/MR state** are both moderate. Palettes extend a theming layer that already exists; PR/MR state is new surface but a well-understood shape.
- **One tab kind** is small in UI and subtle underneath — see the note in its section about instrumentation. Worth doing, worth reading first.
- **Renaming "task"** is cheap to do and expensive to redo, and it collides with the existing workspace concept. Settle the word before writing code, and do it early if at all — the longer it waits, the more call sites it touches.

## State restoration

Terminals and conversations should survive everything short of being closed. Worth doing before the notification work — being told to look at a task matters less if looking at it disturbs what's there.

- [ ] Don't discard terminals when switching tasks. Don't discard one until it's actually closed, and never interrupt or clear its state.
- [ ] Let an agent tab resume an existing conversation with `claude --resume`, including one Plume didn't start.
- [ ] Restore a conversation after `/clear` — the new conversation only, never the cleared one.

What exists:

- The *process* already survives a task switch. `SurfaceManager` holds sessions in a dictionary keyed by tab ID and only `closeSession` removes one, which is why the earlier "same PIDs across 18 switches" check passed. This item is not about processes dying.
- What doesn't survive is the **view**. `TabContentView` keeps every tab of the *selected* task mounted, but `MainWindow` builds `TaskDetailView` only for the selected task, so switching tasks unmounts the previous task's whole tab tree. The surface lives on; its hosted `TerminalView` is rebuilt on return, taking scroll position, selection, and focus with it. The wrapper is built for this — `dismantleNSView` only clears a focus callback, and `TerminalViewState` documents that "the state outlives detached views" — so the fix is about keeping or restoring the view, not about keeping the process.
- Two directions worth weighing: keep every task's detail view mounted the way tabs already are (simple, but grows with task count), or reuse one persistent `TerminalView` per tab across remounts via the wrapper's `makePlatformView` hook, which Plume doesn't currently supply.
- `/clear` starts a fresh session with a new ID and its own transcript file, and the new file records no link back to the one it replaced. So Plume can't infer the succession from the transcripts alone; it has to notice the switch as it happens. The `SessionStart` hook already fires and Plume already captures session IDs from hook events (`MainWindow`), so the tab's stored `agentSessionID` should simply be overwritten with the newest one — the risk to avoid is resuming the stale pre-`/clear` ID, which would restore exactly the conversation the user threw away. Worth checking whether `SessionStart` distinguishes a `/clear` from a plain start; if it does, that's the signal, and if not, "the ID changed mid-tab" is enough.
- Resume works *only* for a conversation Plume started itself. `AutoResumingAgentTabView` fires `claude --resume` when `tab.agentSessionID` is set, but that field is only ever written from a captured hook event (`MainWindow`). Nothing enumerates past sessions and there is no picker, so a conversation started outside Plume — or one whose ID was lost — can't be reattached. The transcripts needed to list them are already on disk under `~/.claude/projects/`, and `SessionJSONLReader` already resolves and reads that directory.

## Notifications

Tell me when I need to pay attention to tasks.

- [ ] Terminal bell support, with a dot next to chats that have rung one.
- [ ] System notification on bell.
- [ ] Let the command line send a notification (title + description), like `cmux notify`.
- [ ] Notify automatically on Claude Code events — above all, waiting for input.

What exists:

- The Ghostty wrapper publishes `bellCount` / `lastBellAt` on `TerminalViewState`. `TerminalSession` mirrors `title` / `workingDirectory` from that same object, so a bell follows an established pattern.
- The wrapper also delivers OSC 9 / OSC 777 desktop notifications with a title and body (`terminalDidRequestDesktopNotification`). A shell can already notify Plume with `printf '\033]777;notify;Title;Body\a'` — the CLI helper is a convenience wrapper, not a new transport.
- `Notification` hook events are already decoded and already drive `needsInput` (`HookEvent`, `StatusEngine`). Notifying is a delivery layer over a signal that exists.
- Nothing in the app uses `UNUserNotificationCenter` yet.

## Native UI for Claude chats

Make the chat experience nicer than the terminal.

- [ ] Don't use a monospace font.
- [ ] Clearly distinguish my messages from Claude's.
- [ ] Separate treatment for work-in-progress and for a response that needs me.
- [ ] Show context-window use, 5h/7d quota, estimated session cost, branch, and model + effort level. Follow `~/.scripts/.claude/statusline.sh` for what belongs in each and when it turns yellow or red.
- [ ] Show agents and their status.
- [ ] A markdown viewer for plans and other files — ideally not a full browser.

The terminal stays the fallback. Polish what the native UI covers and skip the rest — that's what lets this ship in small pieces.

What exists:

- `SessionJSONLReader` resolves the transcript path today but deliberately parses no message content. That is the seam this builds on.
- The transcript is a clean message stream: `assistant` lines carry `text` and `tool_use` blocks, `user` lines carry a string or `tool_result`. User-vs-Claude and in-progress-vs-final are both derivable, as are `gitBranch`, `cwd`, `isSidechain` and `agent-name` for the agents list.
- Per-message `usage` and `model` are in the transcript, so context-window use and the model are derivable from it.
- The markdown viewer belongs to this workstream: rendering Claude's messages and rendering a plan file are the same problem, so build one renderer and point it at either. "Not a full browser" is achievable — SwiftUI's `Text` initializer takes an `AttributedString` parsed from markdown, which covers inline formatting with no WebKit at all. Its limits are the things a plan file actually uses: no headings, tables, or fenced code blocks. Expect to hand-render block structure and inline-parse each paragraph, or take a small markdown library.
- **Quota and cost are not.** They exist only in the payload Claude Code hands a statusline command — not in the transcript, and nowhere on disk. Decision: Plume installs its own statusline command that captures the payload and then chains to `~/.scripts/.claude/statusline.sh`, passing its output through unchanged, so the terminal statusline still looks the same. The capture can reuse the existing events-dir + `FileWatcher` transport. Note `statusLine` is a single object, so it replaces rather than unions the way hook lists do.

## PR/MR state in the sidebar

Help me keep track of tasks once they leave my machine.

- [ ] Show PR/MR state the way my `wt` / `stack` utilities do, build and review state included.
- [ ] Use the existing `glab` / `gh` CLI auth.

What exists: nothing uses `gh` or `glab` yet. `WorkTask.integrationsData` is reserved for exactly this and is still unused.

## Task creation and directories

Make creating a task cheap, and stop pretending a task has one directory.

- [ ] ⌘N defaults to the current directory instead of leaving the workspace unset.
- [ ] Let the worktree choice happen *after* picking a directory, not before.
- [ ] Move the working directory onto tabs. A task probably doesn't need one.
- [ ] Track where an agent actually is — including when Claude uses `EnterWorktree` — and use that as the tab's current directory, e.g. when opening a new tab from it.

What exists:

- The directory lives on `WorkTask` today (`workingDirectoryPath`, plus `repoPath` / `branchName` / `workspaceKind`), and it's read in roughly ten places across the sidebar, setup header, launcher and resume path. Moving it to `TaskTab` is the widest change on this list, though most call sites are a mechanical hop from `task.` to `tab.`. The question to settle first is what a task's identity becomes once it no longer owns a directory, and what the sidebar shows when a task's tabs disagree.
- `TerminalSession` **already tracks the live working directory per tab**, mirrored from the terminal's own reports — so a per-tab cwd is closer to how things already behave than the persisted per-task path is.
- `EnterWorktree` needs no special handling. Its `tool_use` input records the absolute path, but every transcript line afterwards also carries the new `cwd`, verified on a real session that moved into `.worktrees/…` mid-run. So reading `cwd` from the newest transcript line picks up `EnterWorktree` and every other directory change through one mechanism. `SessionJSONLReader` already reads these files.
- Creation is already frictionless in the sense of "no modal" — ⌘N makes a task immediately with `workspaceKind = .unset`, and `TaskSetupHeaderView` offers Choose Folder / New Worktree afterwards. What's missing is a sensible default and a worktree flow that doesn't have to be decided up front.

## Groups

- [ ] ⌘N opens a new task in the current group.
- [ ] Icons (SF Symbols, probably by name) and colors for groups.
- [ ] Maybe colors for individual tasks too — or show the group's color across the whole group.

What exists: `TaskStore.createTask` already takes a `group:`, and the sidebar's "New Task in Group" passes it. ⌘N is the one call site that hardcodes ungrouped (`MainWindow.swift`). `TaskGroup` has no color or icon field yet.

## Color palette

- [ ] Default to Lum. The full palette is in the dotfiles at `colors/lum.css` — use that, not just the simplified terminal palette.
- [ ] Preload other palettes: solarized, monokai, catppuccin, and other popular open-source ones.
- [ ] Support custom palettes, with light and dark.

What exists: `GhosttyThemeResolver` and `ThemeChrome` already tint the sidebar and tab strip from the user's resolved ghostty theme, and `Color(hex:)` exists, so this extends a theming layer rather than starting one. Lum in `lum.css` is a 14-hue × 8-tone system whose tone names already split light from dark (`-28`/`-35`/`-on-dark` vs `-93`/`-97`/`-on-light`/`-on-white`) — richer than the 16-color ghostty theme, and a good fit for group and task colors.

## Tabs and window chrome

- [ ] One tab kind. "New Tab" opens a shell; when `claude` is running in it, the tab takes on agent chrome — no agent-vs-terminal prompt at creation.
- [ ] Remove the unused title bar, or move something into it (task name? directory?).
- [ ] Drag a tab into another task.
- [ ] Move a tab out into a new task of its own.

What exists:

- Instrumentation can only be injected at launch — `--settings` and the `PLUME_*` env vars can't be attached to a `claude` the user started by hand. For a shell-first tab to keep reporting status and titles, Plume needs to set `PLUME_*` on every tab's shell, not just on agent tabs. `AgentLaunch` already carries per-surface env and `LoginShellCommand.wrap` already wraps the command, so the seam is there.
- The wrapper exposes `COMMAND_FINISHED` and `PROGRESS_REPORT` actions, and `TerminalViewState` publishes the command metadata — useful for detection.
- `AppDelegate` already makes the titlebar transparent and tints it.
- Moving a tab between tasks is mostly a data operation — reassign `TaskTab.task` and renumber `orderIndex`, both of which `TaskStore` already owns. The catch is the terminal: `SurfaceManager` is keyed by tab ID, not by task, so the surface itself should survive the move untouched. Don't tear it down and rebuild it, or the move kills a running agent. A tab whose working directory came from its old task also needs a decision — the process keeps its original cwd regardless of where the tab now lives.

## Shortcuts

- [ ] Assignable hotkeys for next/previous tab and next/previous task, so I can set them to alt+J/K and alt+shift+J/K (cmd instead of alt is fine too).
- [ ] ⌘T opens a new tab in the current task.

What exists: next/previous *tab* is already bound to ⌘⇧] / ⌘⇧[ (`PlumeCommands`), and ⌘T already opens a tab in the current task — it's labelled "New Agent Tab", with ⌘⇧T for a terminal tab. Collapsing to one tab kind (see **Tabs and window chrome**) makes ⌘T just "New Tab" and frees ⌘⇧T. There is no next/previous *task* command at all yet. Nothing is user-assignable: every shortcut is hardcoded in a SwiftUI `Commands` body, so making them configurable means a binding store, a settings UI, and a way to apply a stored binding to a menu command. Alt-based chords are also the case most likely to collide with the terminal swallowing keys, which ties this to the focus item under **Misc UX**.

## Naming

- [ ] Consider renaming "task" to something that better fits a long-lived thing — "workspace" was the suggestion.

The observation is right: these outlive a single unit of work, and "task" undersells that. But "workspace" is already taken. `WorkspaceKind` (unset / directory / worktree) is a *property of* a `WorkTask` meaning where it runs, and `WorkspaceProvisioner` creates those directories and worktrees. Renaming the model to `Workspace` would give us `workspace.workspaceKind` and two unrelated `Workspace*` concepts. So this needs a third word, or a rename of the existing workspace concept too — worth settling before anyone starts, since it touches the model, the store, the UI, and every test.

## Misc UX

- [ ] Shortcuts work while the terminal is focused.
- [ ] A terminal view takes focus when its tab is shown.
- [ ] Drag and drop to reorder tabs.

What exists: shortcuts are plain SwiftUI `Commands` gated on `@FocusedValue`, with no low-level key interception, which is likely why they don't survive terminal focus. `TabContentView` toggles opacity and never moves first responder. `.onMove` reorders sidebar tasks but `TabStripView` has no drag support.
