# Plume roadmap

Features we intend to build, in no particular order. This tracks what we want and what the code already provides — it doesn't say how to build any of it. Work out the approach when you pick an item up.

## Where to start

Recommendations, not commitments. Reorder freely.

**Start here.** State restoration comes before everything else: a notification that tells you to look at a task is worth less if switching to it disturbs what's running there.

1. ~~**Keep terminals intact across task switches.**~~ Done — and it was worse than described: switching tasks killed the terminals outright. See the section below.
2. **Resume an existing conversation.** Today `--resume` only works for a session Plume started and captured. Listing what's in `~/.claude/projects/` and letting a tab attach to one closes the gap.

**Then these — small, self-contained, and each one is felt every day:**

3. **⌘N opens a task in the current group.** One call site (`MainWindow.swift`) hardcodes ungrouped; `TaskStore.createTask` already takes a `group:`. Smallest real win on the list.
4. **Terminal bell + a dot on tabs that rang one.** The wrapper already publishes `bellCount` / `lastBellAt`, and `TerminalSession` already mirrors published fields. Little more than wiring.
5. **System notification on bell.** Once the bell signal exists, this is one `UNUserNotificationCenter` call and a permission prompt. Together with the two above it delivers most of "tell me when to look" for a fraction of the whole notifications section.
6. ~~**Terminal focus when a tab is shown.**~~ Done alongside item 1, as that item predicted: `requestFocus()` on becoming visible.
7. **⌘N defaults to the current directory.** Turns the common case into zero decisions, and doesn't depend on the larger directory rework below.

**Then the highest-value item on the list:**

8. **Notify on Claude Code events, above all waiting-for-input.** This is the thing that makes parallel tasks actually parallel — right now a blocked agent waits silently. The signal already exists and already drives `needsInput`; only delivery is missing. Highest value per unit of work of anything here.

**Nearly done already:**

- **⌘T in the current task** already works — it's just labelled "New Agent Tab". Collapsing to one tab kind renames it and finishes the item.
- **Next/previous tab** is bound to ⌘⇧] / ⌘⇧[. What's missing is next/previous *task*, and making any of it user-assignable.

**Next up:**

- **Don't render injected content as my messages.** The cheapest real improvement to the chat: it's a filter in one parser function, and today a skill's body shows up as a wall of text apparently written by me. Honoring `isMeta` handles half of it in a line; recognizing the `<command-name>` and `<local-command-stdout>` wrappers handles the rest.
- **Render plans and questions properly.** `ExitPlanMode` hands over finished markdown and `MarkdownView` can already draw it, so a plan is nearly free. A question is more work but reads worst as JSON. Keep both read-only at first — answering in place needs a send path the composer doesn't have.
- **Bundle Newsreader for chat prose.** Self-contained, and the most visible change per unit of work on the list. Adding a bundled family is the whole job; the font setting it eventually belongs to can come later.
- **Dim the sidebar's selected task.** Small and self-contained, and `TabStripView` already has the pattern to copy — a wash of the theme's own foreground instead of the system accent. The one thing to watch is that hand-drawing the row background gives up `List`'s automatic label inversion.

**Also cheap, once you want them:**

- **CLI notify** is nearly free — the wrapper already accepts OSC 9 / 777, so a shell can notify Plume today with no app change. The helper is a convenience script.
- **Shortcuts while the terminal is focused** is small if SwiftUI's focus system cooperates and a rabbit hole if it doesn't. Timebox it. Do it before **assignable hotkeys** — alt-based chords are exactly what a focused terminal is most likely to swallow, so binding them on top of a broken focus story would just move the bug.
- **Drag to reorder tabs** is contained; the sidebar already does the equivalent. Do it together with **dragging a tab into another task** — same drag machinery, and reordering alone is the fiddly half. Moving a tab out into a new task needs no drag at all and could be a menu item first.

**Bigger, and best taken deliberately:**

- ~~**Native chat UI**~~ Done, shipped in slices as predicted. See the section below for what landed and what it left.
- **Assignable hotkeys** is the sleeper. Adding a next/previous *task* command is easy; making bindings user-settable means a binding store, a settings UI, and applying stored bindings to menu commands. Consider shipping fixed alt+J/K first and configurability later.
- **Directories on tabs instead of tasks** is the widest change here — ten-odd call sites, mostly mechanical, but it forces a real question about what a task *is* once it doesn't own a directory. Worth deciding alongside the naming question, since they're the same question wearing different hats. Tracking the agent's live directory is the easy half and could land first: the terminal already reports it per tab, and `EnterWorktree` needs no special case.
- **Palettes** and **PR/MR state** are both moderate. Palettes extend a theming layer that already exists; PR/MR state is new surface but a well-understood shape.
- **One tab kind** is small in UI and subtle underneath — see the note in its section about instrumentation. Worth doing, worth reading first.
- **Renaming "task"** is cheap to do and expensive to redo, and it collides with the existing workspace concept. Settle the word before writing code, and do it early if at all — the longer it waits, the more call sites it touches.

## State restoration

Terminals and conversations should survive everything short of being closed. Worth doing before the notification work — being told to look at a task matters less if looking at it disturbs what's there.

- [x] Don't discard terminals when switching tasks. Don't discard one until it's actually closed, and never interrupt or clear its state.
- [ ] Let an agent tab resume an existing conversation with `claude --resume`, including one Plume didn't start.
- [x] Restore a conversation after `/clear` — the new conversation only, never the cleared one.

What exists:

- **Done.** The process did *not* survive a task switch, contrary to what this section used to claim. The ghostty surface lives in `core`, a `let` on `AppTerminalView`, and its `deinit` frees the surface — which reaps the PTY child on the `.exec` backend. Nothing held that view strongly, so unmounting a task's tab tree killed its terminals. The earlier "same PIDs" check missed it because `SmokeHarness` seeded tabs only on the first task, and because it compared PID counts, which a teardown-and-respawn preserves.
- The fix is `TerminalSession` holding the platform view strongly and handing it back through the wrapper's `makePlatformView` hook, so the same view — and the surface, scrollback and selection inside it — survives every remount. Verified by identical PID *sets* and ttys across repeated switches, with one "Created hosted view" per tab for a whole run.
- `isSurfaceVisible` is now driven from tab selection (`TabVisibility`). Hidden tabs previously kept drawing frames nobody saw. It gates rendering only, never surface creation, so a tab that has never been selected still spawns its PTY.
- **Done.** A `/clear` writes `SessionEnd` (`reason: "clear"`, carrying the *old* ID) immediately followed by `SessionStart` (`source: "clear"`, the new one). Both fields are now decoded. Because the `SessionEnd` carries the discarded ID, it is reported as a clear and its ID is dropped rather than written back; the `SessionStart` a moment later supplies the replacement. That closes the window where a crash between the two would have left the stale ID on disk to be resumed. The same event no longer reports the tab idle, which used to misreport a still-running agent.
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

- [x] Don't use a monospace font.
- [x] Clearly distinguish my messages from Claude's.
- [x] Separate treatment for work-in-progress and for a response that needs me.
- [x] Show context-window use, 5h/7d quota, estimated session cost, branch, and model + effort level. Follow `~/.scripts/.claude/statusline.sh` for what belongs in each and when it turns yellow or red.
- [x] Show agents and their status.
- [x] A markdown viewer for plans and other files — ideally not a full browser.
- [ ] Render mermaid diagrams in chat messages and in viewed files.
- [ ] Slash commands in the composer — completion for what's available, and a sensible rendering of the ones that answer in the chat.
- [ ] Render the tools that talk to me — a proposed plan and a question with its options — as their own thing, not as raw tool JSON.
- [ ] Stop showing injected content as if I wrote it. A skill's body, a slash command's expansion and its output all arrive as user lines and read as messages from me.

The terminal stays the fallback. Polish what the native UI covers and skip the rest — that's what lets this ship in small pieces.

What exists:

- **Done, in slices.** An agent tab now renders a native chat by default and keeps its terminal one ⌘/ away. Both stay mounted, so toggling never touches the PTY — the same rule tabs already follow.
- `TranscriptParser` turns a transcript into `ChatMessage`s; `TranscriptStore` watches the file per tab and republishes, following `AgentTitleMonitor`'s pattern with a shorter debounce because this drives visible content. `SessionJSONLReader` still resolves paths and now also enumerates the subagent transcripts.
- `MarkdownBlock` splits block structure by hand and inline-parses each paragraph with `AttributedString`, so there is no WebKit. Nested lists and tables are deliberately unsupported: a table degrades to a paragraph rather than being mangled.
- `TranscriptParser` also surfaces the latest `planFilePath` from a session's `plan_mode`/`plan_mode_exit` attachment lines. When that path exists on disk, `ChatTabView` shows a "Plan" button that opens `MarkdownFileView` in a sheet — a file-backed, live-updating `MarkdownFileStore` reads the same `MarkdownView` renderer chat messages use, so it isn't hardcoded to plans.
- The composer sends with ⌘↩ — plain ↩ inserts a newline, so a half-typed message is never lost. It reaches the agent through `TerminalSession.submit(text:)`, which pastes and then presses Enter as two operations. **A trailing `\r` in pasted text does not submit**: the wrapper's text path is a paste, and bracketed paste leaves the carriage return in the edit line.
- **Quota and cost still need the statusline capture.** They exist only in the payload Claude Code hands a statusline command. `StatuslineCaptureWriter` generates a chaining script and `StatuslineInstaller` can install it, but installation is **off by default and never automatic** — Settings shows the exact JSON it would write to `~/.claude/settings.json` behind an explicit button. With capture off the strip still shows context use, model, effort and branch, all of which come from the transcript. Note `statusLine` is a single object, so it replaces rather than unions the way hook lists do.

Left for later:

- Slash commands work only by accident today. The composer sends whatever is typed straight through, so `/review` reaches `claude` and runs, but nothing completes it, lists it, or knows it is a command. The one exception is `/model` and `/effort`, which `ModelEffortCommand` already composes and sends through `TerminalSession.submit` from the statusline strip's menu — so the send path is proven and the gap is discovery and presentation. Available commands are enumerable from disk (`~/.claude/skills/`, project `.claude/commands/`, plugins), though built-ins are not, so a completion list assembled from disk will be incomplete unless it also carries a static set. Worth deciding what a command's *output* should look like too: some answer in prose that renders fine as a chat message, while others are really UI in disguise, and those will read badly until the renderer knows about them.
- Mermaid has no renderer yet. `MarkdownBlock` already isolates fenced code blocks, so a `mermaid` fence is easy to *detect* — drawing it is the work. Worth deciding early whether that means WebKit (mermaid.js is JavaScript, and a `WKWebView` per diagram is the quick path but reintroduces the browser this renderer deliberately avoids) or native drawing of a useful subset. Until one exists, a mermaid fence should keep degrading to readable source the way an unsupported table already degrades to a paragraph.
- `AskUserQuestion` and `ExitPlanMode` render as pretty-printed JSON today, like any other tool call — `ToolCallInputRendering` special-cases only `Bash`. Both payloads already carry everything a real rendering needs: `AskUserQuestion` gives `questions[]` with `header`, `question`, `multiSelect` and `options[]` of `label` + `description`, and `ExitPlanMode` gives `plan` (markdown, renderable by `MarkdownView` as-is) alongside the `planFilePath` the parser already tracks. Worth deciding how far to go: showing them well is a rendering change, but making the options *clickable* means sending the answer back, and the composer's send path is a paste into the terminal — it has no way to pick the third option of a running prompt. Read-only presentation is the honest first slice.
- **Injected content renders as my messages.** `TranscriptParser` keys on `(entry.type, role)` alone and ignores `isMeta`, so every synthetic user line becomes a `.user` chat message: a skill's whole body (`Base directory for this skill: …`), `<command-name>`/`<command-message>` blocks, `<local-command-stdout>`, `<local-command-caveat>`, `<task-notification>` and `[Request interrupted by user]`. `isMeta: true` catches some of them — a skill body and the caveat block — but not all: a slash command's expansion and its stdout are both `isMeta: false`, so they need recognizing by their wrapper tags. These are worth *showing*, just not as prose in my voice; a skill invocation and a slash command are both things that happened, and a compact marker row reads better than either a raw dump or silence.
- Subagent status is best-effort: a subagent's own writes don't trigger the main transcript's watcher, so its freshness is bounded by main-transcript activity rather than watched per file.

## Running inside Plume

Let scripts and Claude itself know they're in Plume, and give Claude the formatting Plume can render.

- [ ] Export an environment variable marking a shell as running inside Plume.
- [ ] Skills that prompt Claude to use richer formatting — diagrams above all — when it's running in Plume.
- [ ] Put Plume's own configuration in a config file — a superset of ghostty's, or a structured format of its own (TOML or JSON).

What exists:

- Plume already injects `PLUME_TASK_ID`, `PLUME_TAB_ID` and `PLUME_EVENTS_DIR`, but only on an *agent* launch (`ClaudeCodeProvider`), so a plain terminal tab carries no marker at all. A general `PLUME=1`-style variable set on every tab's shell is the missing piece. `AgentLaunch` already carries per-surface env and `LoginShellCommand.wrap` already wraps the command, so the seam exists — this is the same change the one-tab-kind item needs, and doing it once serves both.
- The statusline integration does **not** need a new variable: `StatuslineCaptureWriter` already keys off `$PLUME_EVENTS_DIR/$PLUME_TASK_ID/$PLUME_TAB_ID`, and those are exactly the per-tab identifiers a general marker would sit beside. A bare `PLUME=1` answers "am I in Plume?" for a shell prompt or a script; it doesn't replace the per-tab IDs, which are what make captured output attributable to a tab.
- Config today is split: terminal behavior comes from the user's ghostty config, while Plume's own eight settings (worktree base path, provider, statusline capture, chat font size, quit confirmations, composer send key) live in `UserDefaults` behind `AppSettings`, reachable only through the Settings window. A file would make them diffable, shareable and version-controllable, which `UserDefaults` never will be.
- A superset is plausible because Plume already reads and rewrites the config rather than passing a path: `GhosttyConfigLoader` finds the file in ghostty's own search order, then hands libghostty *generated contents* with every `theme` line stripped, parsing line by line. Plume-specific keys would be stripped the same way — and they must be, since libghostty emits diagnostics for keys it doesn't recognize and `GhosttyRuntime` already logs them.
- A different format is worth weighing against the superset, not assumed away. TOML or JSON both express nesting natively, and JSON needs no dependency at all — `Codable` reads it, and the statusline capture already parses JSON. TOML reads better by hand but means taking a parser. The cost either way is that Plume's config and ghostty's stop being one file, so the user keeps two — which may be honest rather than unfortunate, since the two configure genuinely different things. A middle path: keep terminal behavior in the ghostty config where it already lives and works, and give Plume's own settings their own structured file, rather than stretching a flat format to hold everything.
- Two things to settle first if the superset wins. Ghostty takes the first matching config file outright and never merges, so a Plume file that *is* the ghostty file means the user maintains one file for both, while a separate file means deciding precedence. And ghostty's format is flat `key = value` with repeated keys for lists, which suits toggles and paths but has no obvious shape for anything nested — worth checking that every setting worth moving actually fits before committing to the format. `AppSettings` stays the reader either way; a file is a new source for it, not a replacement for the type.
- The skills item depends on the renderer, not the other way round: telling Claude to draw mermaid before Plume can render it just produces fenced source. Sequence it after the mermaid work, and scope what the skill promises to what the renderer actually supports — the same discipline that keeps tables degrading gracefully rather than being mangled.

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

## Colors and fonts

- [ ] Default to Lum. The full palette is in the dotfiles at `colors/lum.css` — use that, not just the simplified terminal palette.
- [ ] Preload other palettes: solarized, monokai, catppuccin, and other popular open-source ones.
- [ ] Support custom palettes, with light and dark.
- [ ] Dim the sidebar's selected task instead of painting it bright blue.
- [ ] Bundle Newsreader and make it the chat's prose font.
- [ ] Choose the rest of the fonts — chat code separately from the terminal — and maybe bundle a few more good defaults.

Fonts sit alongside this, and the two halves of the app treat them differently. The terminal takes its font from the user's ghostty config, which is right — it should keep matching their terminal. The chat hardcodes `.system` for prose and `.monospaced` for code in `MarkdownView`, `ChatMessageRow` and `MarkdownComposerStyler`; only the *size* is configurable (`AppSettings.chatFontSize`, clamped 11–28). So the work is a family setting to sit beside the size, threaded the same way through the environment, with prose and code chosen separately — a proportional body font next to a monospaced code font is the point, not one setting for both. Defaulting to the terminal's configured font for code is a reasonable starting point that needs no bundling at all. Prose is the half that's already decided.

The sidebar's selection is the system's, not ours: `SidebarView` is a plain `List(selection:)`, so macOS paints the selected row with the accent color. That reads as bright blue over a `themeTint`ed sidebar, which is the clash. `TabStripView` already solved the same problem for tab chips — its `chipBackground` falls back to `.selection` when no theme is configured, and otherwise washes the theme's own foreground at 0.22 opacity (0.1 on hover). Doing the same here means taking the row background over with `.listRowBackground` and drawing selection by hand, which also costs the free things `List` gives you: keyboard navigation still works, but the row no longer inverts its label color, so check contrast on a selected row in both light and dark themes.

**Newsreader is the chosen prose face**, in `~/Downloads/Newsreader`. It ships as two variable fonts — upright and italic — each with a `wght` axis (200–800, default 400) and an `opsz` optical-size axis (6–72, default 18), plus a `static/` directory of fixed instances at 9/14/24/36/60pt if the variable path proves awkward. It's SIL Open Font License 1.1, so bundling it is fine; the license file has to ship with it. Two things to check when it lands: whether SwiftUI reaches the `wght` and `opsz` axes usefully (`opsz` is the interesting one — it's what makes a variable face look right across the 11–28pt range `chatFontSize` already allows, and wiring it to the current size is close to free), and that italics come from the italic file rather than being synthesized by slanting the upright.

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
- [x] A terminal view takes focus when its tab is shown.
- [ ] Drag and drop to reorder tabs.
- [ ] Reopen the last session on launch — restore the selected task and tab instead of starting cold.

What exists:

- Shortcuts are plain SwiftUI `Commands` gated on `@FocusedValue`, with no low-level key interception, which is likely why they don't survive terminal focus.
- `.onMove` reorders sidebar tasks, but `TabStripView` has no drag support.
- On launch, the per-task selected tab already persists (`WorkTask.selectedTabID`), so only the selected *task* is missing. `MainWindow` holds it in plain `@State`, which starts nil every launch, so the app always opens on "No Task Selected" even though the rest of the tree restores. Persisting that one UUID — `AppSettings` or `@SceneStorage` — is most of the item. Decide what happens when the stored task is gone (archived or deleted), and whether a restored agent tab should auto-resume on launch or wait to be selected, since the existing rule deliberately avoids spawning `claude` for every agent tab at startup.
