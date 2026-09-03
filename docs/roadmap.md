# Plume roadmap

Features we intend to build, in no particular order. This tracks what we want and what the code already provides — it doesn't say how to build any of it. Work out the approach when you pick an item up.

## Where to start

Recommendations, not commitments. Reorder freely.

Read this list in three passes, in this order. They don't conflict today — the bugs sit in the chat, the quick wins don't touch it — but when they do, the earlier pass wins.

1. **The bugs from driving, first.** Headless is the default transport for every new agent tab, and driving it turned up faults that matter more than any unstarted feature here. They're recorded in the chat sections below, each with the file and line. The two that stand out: chat scrolling doesn't follow a reply at all, and a new tab never starts in the user's own permission mode.
2. **Then the quick wins**, numbered below. Each is felt every day and none is entangled with the chat.
3. **Then the highest-value feature**, which is notifying on Claude Code events.

**Small, self-contained, and each one is felt every day:**

1. **⌘N opens a task in the current group.** One call site (`MainWindow.swift`) hardcodes ungrouped; `TaskStore.createTask` already takes a `group:`. Smallest real win on the list.
2. **Terminal bell + a dot on tabs that rang one.** The wrapper already publishes `bellCount` / `lastBellAt`, and `TerminalSession` already mirrors published fields. Little more than wiring.
3. **System notification on bell.** Once the bell signal exists, this is one `UNUserNotificationCenter` call and a permission prompt. Together with the two above it delivers most of "tell me when to look" for a fraction of the whole notifications section.

**Then the highest-value item on the list:**

4. **Notify on Claude Code events, above all waiting-for-input.** This is the thing that makes parallel tasks actually parallel — right now a blocked agent waits silently. The signal already exists and already drives `needsInput`; only delivery is missing. Highest value per unit of work of anything here.

**Nearly done already:**

- **⌘T in the current task** already works — it's just labelled "New Agent Tab". Collapsing to one tab kind renames it and finishes the item.
- **Next/previous tab** is bound to ⌘⇧] / ⌘⇧[. What's missing is next/previous *task*, and making any of it user-assignable.

**Next up:**

- **Mermaid diagrams**, the last unstarted item in the chat section, and the one that most needs its approach settled first — WebKit or a native subset. Tables are now wanted too, and they are the same renderer question.

**Also cheap, once you want them:**

- **CLI notify** is nearly free — the wrapper already accepts OSC 9 / 777, so a shell can notify Plume today with no app change. The helper is a convenience script.
- **Shortcuts while the terminal is focused** is small if SwiftUI's focus system cooperates and a rabbit hole if it doesn't. Timebox it. Do it before **assignable hotkeys** — alt-based chords are exactly what a focused terminal is most likely to swallow, so binding them on top of a broken focus story would just move the bug.
- **Drag to reorder tabs** is contained; the sidebar already does the equivalent. Do it together with **dragging a tab into another task** — same drag machinery, and reordering alone is the fiddly half. Moving a tab out into a new task needs no drag at all and could be a menu item first.

**Bigger, and best taken deliberately:**

- **The plan overlay doing both jobs** — presenting a proposal for approval and reviewing an approved plan. Designed in the chat section below and ready to build; it also retires the inline row that caused the "answer in the terminal" bug.
- **Subagents** as a real view rather than a disclosure row. This is the case Plume exists to make legible, and it is currently the weakest part of the chat.
- **Assignable hotkeys** is the sleeper. Adding a next/previous *task* command is easy; making bindings user-settable means a binding store, a settings UI, and applying stored bindings to menu commands. Consider shipping fixed alt+J/K first and configurability later.
- **Directories on tabs instead of tasks** is the widest change here — ten-odd call sites, mostly mechanical, but it forces a real question about what a task *is* once it doesn't own a directory. Worth deciding alongside the naming question, since they're the same question wearing different hats. Tracking the agent's live directory is the easy half and could land first: the terminal already reports it per tab, and `EnterWorktree` needs no special case.
- **Palettes** and **PR/MR state** are both moderate. Palettes extend a theming layer that already exists; PR/MR state is new surface but a well-understood shape.
- **One tab kind** is small in UI and subtle underneath — see the note in its section about instrumentation. Worth doing, worth reading first.
- **Renaming "task"** is cheap to do and expensive to redo, and it collides with the existing workspace concept. Settle the word before writing code, and do it early if at all — the longer it waits, the more call sites it touches.

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

The terminal stays the fallback. Polish what the native UI covers and skip the rest — that's what lets this ship in small pieces.

Every open item for the chat now lives under **Testing results** below, grouped by area — subagents and mermaid rendering included.

## Testing results

Everything below came from driving the app rather than reading it — the headless
transport is the default for every new agent tab, and it shipped unexercised. The
build was clean and 556 tests passed throughout, so none of this was visible
without running it.

Grouped by area, so a section is a coherent piece of work to pick up. A few
sections share a file or a decision; where the order matters it is said so in
the section itself.

### Chat scrolling

Auto-follow is broken outright. One placement mistake causes both symptoms.

- [x] Follow a reply as it streams. It currently advances one tick and stops.
- [x] Make the jump-to-bottom arrow reach the actual bottom, not the bottom of the last message.

**The bottom anchor is above the list's bottom padding.** `ChatMessageList` puts a 1pt `Color.clear` anchor as the last element *inside* the `VStack`, then applies `.padding(.bottom, bottomPadding)` to the VStack itself (`ChatMessageList.swift:102-107`) — so `dimensions.listBottomPadding`, which is `bodySize * 4.5` (`Dimensions.swift:43`), sits *below* the anchor and outside it. Every `proxy.scrollTo(bottomAnchorID, anchor: .bottom)` therefore lands short by that much: the arrow stops at the end of the text, and streaming settles one message-bottom short of the true bottom.

Why it then stops following: the geometry action guards on `ChatScrollAnchor.reflectsUserScroll` and records `distanceFromBottom` off the *previous* content height. Coming to rest a fixed padding's distance from the bottom reads as a deliberate scroll-away, so the anchor latches detached and stops chasing. The threshold is 40pt and the padding is larger than that at any sane font size, which is why it happens every time rather than intermittently.

Fix the anchor's placement first — move it below the padding, or move the padding inside the anchor's container — and re-check the follow behavior before touching the thresholds. Widening the tolerance would hide the symptom and leave the arrow still landing short. `ChatScrollAnchorTests` covers the arithmetic and passes; it never placed the anchor, which is why the suite stayed green through two rewrites of this code.

### Launching an agent

- [x] Respect the user's own default permission mode instead of hardcoding `acceptEdits`.
- [x] Don't fail in an untrusted directory. Detect it before launching and offer to resolve it, rather than hanging.

**The permission mode is fixed.** A new `PermissionModeDefault` setting (`.followClaudeCode` by default) resolves through `AppSettings.resolvedDefaultPermissionMode`, reading `permissions.defaultMode` from `~/.claude/settings.json` when following Claude Code. `AgentLauncher` resolves `task.permissionMode ?? AppSettings.shared.resolvedDefaultPermissionMode` for both transports; `HeadlessCommand.arguments` still always passes `--permission-mode` (a `-p` session starts in Manual on every plan), with `.acceptEdits` remaining only as the last-resort floor when resolution comes back empty.

**Directory trust is checked before spawning.** `ClaudeTrustStore.isTrusted` reads `~/.claude.json`'s `projects.<absolute path>.hasTrustDialogAccepted` (side-effect free and path-injectable for tests). `AgentLauncher.launchHeadless` checks it first: on an untrusted directory it does not spawn, and records the tab in `UntrustedDirectoryStore` instead. `ChatTabView` reads that store and shows a message in place of the composer, with an "Open Terminal Tab" button (`TaskStore.addTab(kind: .terminal)`) — the terminal transport is where the real folder-trust prompt can be answered. The flag itself is never written by Plume.

### The plan overlay

Today the overlay never opens on its own: `planPresentation` starts `.closed` (`ChatTabView.swift:13`) and every assignment of `.expanded` sits behind a button (lines 146, 204), so it is a viewer the user opens rather than a presentation the agent triggers. It should be both — presenting a proposal for approval, and reviewing the plan once approved.

- [ ] Present a proposed plan in the overlay, with the approval options in it.
- [ ] Inline, show only a row for the `ExitPlanMode` call — with a button to reopen the overlay while it is unanswered.
- [ ] Hold the approval area to content width, and give it more space above, away from the plan content.
- [ ] Offer better options than Approve/Reject:
  - **Approve** — also starts work right away, in auto mode when that's enabled.
  - **Approve + compact** — the same, but compacts first.
  - **Reject with an optional reason** — the feedback goes back for a retry.
  - The CLI's third option (reject with feedback, then auto-approve whatever plan comes back) is worth having, but its UX here is unsettled. One idea: alt+return while typing a rejection.

**The overlay always reads the file.** An `ExitPlanMode` input carries both `plan` (the markdown) and `planFilePath` (`InteractiveToolPayload.swift:41`), and the latter is the same path `TranscriptParser` records from the `plan_mode` attachment line and the overlay already renders. So the two content sources are one: the overlay keeps its existing `MarkdownFileStore` path unchanged and gains live updates for free if the plan is rewritten. The payload's markdown is not a second source to merge; it is what the inline row summarizes.

**Interrupting the reader is fine**, as long as the overlay can be minimized — which it already can (`PlanPresentation.minimized` docks it as a bar above the composer). So a proposal expands over the conversation and the user dismisses it if they were mid-thought; no special quiet-arrival case is needed.

**The footer has three states**, driven by where the plan stands rather than by how the overlay was opened:

| State | Footer |
|---|---|
| Proposed, awaiting a decision | The approval options |
| Approved | "Approved" |
| Any other time — before a proposal, or after a rejection | "Not approved yet" |

"Not approved yet" deliberately covers both of the third state's situations — never proposed, and proposed then rejected — because the plan may have been rewritten since the rejection, so saying anything about that rejection risks describing a document that no longer exists. It speaks only to the state that is still true.

One thing to get right: a plan file exists *before* it is ever proposed. `TranscriptParser` records `planFilePath` from a `plan_mode` line as well as `plan_mode_exit` (`TranscriptEntry.swift:238`), so the agent writing a plan is enough to make it viewable. That is the same third state, and it means the footer cannot be derived from the file's existence — it needs the state of the most recent `ExitPlanMode` call and its answer.

### Interactive rows: plans and questions

- [ ] A rejected plan briefly says "Approve or reject in the terminal."
- [ ] Show one question at a time, with prev/next buttons.
- [ ] Fix the type scale: question text and the main answer line are both body; the second answer line is caption.
- [ ] Stop double-tinting the question options. The question area and its options are two stacked backgrounds, and a blue focus ring around the box makes it three. Either hold the question area's tint and drop the options to the regular background, or make one of the two outline-only — a blue outline on the options instead of a grey fill is the candidate.

**The stale hint is a real bug, and the overlay work above retires half of it.** `InteractiveToolRow` is answerable only when a caller hands it an `answer` closure. `PendingPermissionDock.swift:23` supplies one; `ToolCallRow.swift:18` does not, so the transcript's copy of the same plan always falls through to `answerHint("Approve or reject in the terminal.")` (`InteractiveToolRow.swift:72`). While a request is live the dock's answerable row covers for it. Answering removes the pending entry, the dock's row disappears, and the transcript row underneath — with its terminal hint — is what's left showing until the next transcript parse catches up. So the hint is not merely stale, it is wrong on the headless transport, where the terminal is not where you answer. Fix the hint to reflect the tab's transport, and give the resolved row a settled state ("Rejected", with the reason) rather than an instruction to act.

### The markdown renderer

Shared by the chat, the plan overlay and the file viewer, so none of these are plan-specific.

- [x] Stop padding inline code spans with space characters. `MarkdownCache.styledInline` inserts a real U+2009 thin space on each side of every span (`MarkdownCache.swift:76`), so the padding is part of the string: copying `foo` yields `\u{2009}foo\u{2009}`, and pasting it into a shell or an editor carries invisible characters that break the paste. Accurate copy matters more than the visual breathing room — if the chip has to hug the glyphs, let it. Only genuine layout padding (which `AttributedString`'s flat `backgroundColor` cannot express) is worth pursuing as a replacement, and not at the cost of the text.
- [ ] Support tables. Currently unsupported on purpose (`MarkdownBlock.swift:10`) — a table degrades to a paragraph. They're an important visualization tool and the degradation is poor.
- [ ] Syntax-highlight code blocks.
- [ ] Give code blocks more padding inside their border.
- [ ] Distinguish a bash block's input from its result — they currently render alike.
- [ ] Put real newlines in a bash input block.
- [ ] Mermaid diagrams in the same renderer — the item that most needs its approach settled first, WebKit or a native subset. Tables raise the same question, so decide them together.

### The composer

- [x] An edit icon beside a queued message's ✕. It cancels the message and moves its text into the composer.
- [x] ↑ from an empty composer does the same, taking the last queued message. The hint becomes "Press ↑ to edit a queued message" while a queue exists.
- [x] Scroll the slash-command list to follow the selection. Arrow keys currently move it outside the visible rows, so the selection disappears rather than the list following it.
- [x] Put the caret at the end of an accepted slash command. It fills the text but leaves the caret where it was.
- [x] Show in the composer that a slash command is recognized — turn the token blue, or similar. Nothing distinguishes a real command from a typo until you send it.
- [x] Let ⌘↩ send while the slash-command list is showing.
- [ ] Give the first message a nicer intermediate state. The composer currently disappears before the message appears; disabling it in place would read better.
- [ ] Make the composer content-width rather than bleed-width.

### The statusline

- [x] Fix the permission mode, model and effort controls, and the double chevron and mixed text scale around them.
- [x] Give the strip bleed width and center it, with a compact meter for context and quota.
- [x] Split session-wide facts (quota, cost, branch) in `StatuslineStripView` from what-the-next-message-does controls (permission mode, model, effort), which moved to a two-row `ChatComposer`: text on top, controls and send below.

`HeadlessSession` now owns `permissionMode`/`model`/`effort` as observable state, set optimistically when the host asks for a change and corrected from the stream (`system`/`init` for model and permission mode — there is no `set_effort` control request, so effort is never corrected, only ever what this host last sent). The strip and composer read this instead of the transcript, fixing the old bug where a control wrote through the session but displayed transcript state.

Still open:

- [ ] Consider moving the whole strip inside the composer box, if a compact form fits a narrow viewport.
- [ ] Customization UI, once a segment shape settles. `ComposerControlsRow`'s segments are already self-contained — each reads and writes only its own piece of session state — so this is additive, not a rewrite.
- [ ] The composer's two-row split is a first cut (plain `HStack`s, no styling pass) — revisit layout and spacing.

### Subagents

Was marked done and is not: the old checkbox covered the *list*, while the status half never worked. Driven now, and it is well short of useful. Parallel subagents are the case Plume exists to make legible, so this deserves to be a real view rather than a patched-up disclosure row.

- [ ] Show which subagents a conversation has spawned, identified by what they were asked to do rather than by ID.
- [ ] Show each one's live status — working, waiting for input, done, failed.
- [ ] Let a subagent's transcript be read properly, with the same rendering the main conversation gets.

Today the label is `subagent.id` — a raw identifier (`SubagentListView.swift:59`) — over a one-line tail of the last message. `SubagentTranscript` carries only `id`, `transcript` and `modifiedAt` (`TranscriptStore.swift:6-10`), so neither a task description nor a status has anywhere to live yet; both want adding there. The description is recoverable: a subagent is spawned by a `Task`/`Agent` tool call in the parent transcript, whose input carries the prompt and a short description, and the transcript parser already reads those calls.

- **Status is hardcoded, not merely wrong.** `ChatMessageRow(message:, isLast: false, status: .unset)` (`SubagentListView.swift:53`) passes both constants, and `ChatMessageRow` gates its working spinner and needs-input indicator on `isLast && status == …` — so neither can ever fire, whatever the subagent is doing.
- **Freshness would still lag once status is wired.** A subagent's own writes don't trigger the main transcript's watcher, so the list refreshes only when the *main* transcript changes. `SessionJSONLReader` already enumerates the subagent transcripts, so what's missing is a watcher per file, not discovery.
- **Presentation.** A nested `DisclosureGroup` inside the chat list is a cramped place to read a whole conversation. Worth weighing against the alternatives — a sheet like the plan overlay, or a pane — especially once several subagents run at once, which is the situation that motivates the feature.

### Mark worktrees as work in progress

Worktree create and delete moved onto `GitService` and have not been driven since. Rather than block on verifying a feature that matters less than the rest, label it so its state is honest.

- [x] Put a beta/WIP marker on the worktree entry points.

Where it needs to show: the "New Worktree…" button (`WorkspacePickerView.swift:128`), the sheet's own title (`NewWorktreeSheet.swift:20`), and the two destructive delete items that remove a worktree or its branch (`SidebarView.swift:100,103`). The delete items are the ones that most need it — they are irreversible, and their failure path is the least exercised code in the feature.

Settle one marker and use it everywhere, since this will not be the last unfinished feature to ship visible. A "Beta" chip beside a label is the cheap version; a tooltip saying what specifically is unverified is the useful one.

Still unverified: creating a worktree, removing one, and the failure path where git refuses and the task must survive with an error shown (`SidebarView.swift:141-145`). Note that `WorkspaceProvisioner.removeWorktree` passes `--force`, so ordinary "dirty tree" refusals never reach that handler — reproducing it needs `git worktree lock` or an already-removed path.

## Running inside Plume

Let scripts and Claude itself know they're in Plume, and give Claude the formatting Plume can render.

- [ ] Export an environment variable marking a shell as running inside Plume.
- [ ] Skills that prompt Claude to use richer formatting — diagrams above all — when it's running in Plume.
- [ ] Put Plume's own configuration in a config file — a superset of ghostty's, or a structured format of its own (TOML or JSON).

What exists:

- Plume already injects `PLUME_TASK_ID`, `PLUME_TAB_ID` and `PLUME_EVENTS_DIR`, but only on an *agent* launch (`ClaudeCodeProvider`), so a plain terminal tab carries no marker at all. A general `PLUME=1`-style variable set on every tab's shell is the missing piece. `AgentLaunch` already carries per-surface env and `LoginShellCommand.wrap` already wraps the command, so the seam exists — this is the same change the one-tab-kind item needs, and doing it once serves both.
- Hook instrumentation already keys off `$PLUME_EVENTS_DIR/$PLUME_TASK_ID/$PLUME_TAB_ID`, and those are exactly the per-tab identifiers a general marker would sit beside. A bare `PLUME=1` answers "am I in Plume?" for a shell prompt or a script; it doesn't replace the per-tab IDs, which are what make captured output attributable to a tab.
- Config today is split: terminal behavior comes from the user's ghostty config, while Plume's own settings (worktree base path, provider, default transport, chat font size, quit confirmations, composer send key) live in `UserDefaults` behind `AppSettings`, reachable only through the Settings window. A file would make them diffable, shareable and version-controllable, which `UserDefaults` never will be.
- A superset is plausible because Plume already reads and rewrites the config rather than passing a path: `GhosttyConfigLoader` finds the file in ghostty's own search order, then hands libghostty *generated contents* with every `theme` line stripped, parsing line by line. Plume-specific keys would be stripped the same way — and they must be, since libghostty emits diagnostics for keys it doesn't recognize and `GhosttyRuntime` already logs them.
- A different format is worth weighing against the superset, not assumed away. TOML or JSON both express nesting natively, and JSON needs no dependency at all — `Codable` reads it, and the headless stream already parses JSON. TOML reads better by hand but means taking a parser. The cost either way is that Plume's config and ghostty's stop being one file, so the user keeps two — which may be honest rather than unfortunate, since the two configure genuinely different things. A middle path: keep terminal behavior in the ghostty config where it already lives and works, and give Plume's own settings their own structured file, rather than stretching a flat format to hold everything.
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
- [ ] Choose the rest of the fonts — chat code separately from the terminal — and maybe bundle a few more good defaults.

Fonts sit alongside this, and the two halves of the app treat them differently. The terminal takes its font from the user's ghostty config, which is right — it should keep matching their terminal. The chat hardcodes `.system` for prose and `.monospaced` for code in `MarkdownView`, `ChatMessageRow` and `MarkdownComposerStyler`; only the *size* is configurable (`AppSettings.chatFontSize`, clamped 11–28). So the work is a family setting to sit beside the size, threaded the same way through the environment, with prose and code chosen separately — a proportional body font next to a monospaced code font is the point, not one setting for both. Defaulting to the terminal's configured font for code is a reasonable starting point that needs no bundling at all. Prose is the half that's already decided.

**Libre Baskerville is the prose face**, bundled in `Plume/Resources/Fonts/` under SIL Open Font License 1.1 with its license file alongside. Newsreader was tried first and swapped out. Two differences worth knowing: Libre Baskerville is variable on `wght` alone (400–700), with no `opsz` axis, so nothing tracks the point size — and its family name is plain `Libre Baskerville`, where Newsreader's compatibility family was `Newsreader 16pt` against a typographic family of `Newsreader`, two names that were not interchangeable. It runs visually larger than Newsreader at the same point size, so `chatFontSize` may want revisiting. Registration is by CoreText at launch (`BundledFonts`), not `ATSApplicationFontsPath` — see the note below. Italics come from the italic file rather than a synthesized slant, which `ComposerProseFontTests` locks in by asserting the derived face has a different PostScript name from the upright.

**`INFOPLIST_KEY_ATSApplicationFontsPath` does not work here.** Xcode's Info.plist generator has no mapping for it, so the key never reaches the built plist — `INFOPLIST_KEY_LSApplicationCategoryType` beside it generates fine, which is what proves the mechanism rather than the spelling is at fault. The project generates its plist and has no file to add the key to. `BundledFonts.registerIfNeeded()` calls `CTFontManagerRegisterFontsForURL` at launch instead, which also sidesteps bundle layout: file-system synchronized groups flatten `Plume/Resources/Fonts/` into `Contents/Resources` rather than preserving the directory.

What exists: `GhosttyThemeResolver` and `ThemeChrome` already tint the sidebar and tab strip from the user's resolved ghostty theme, and `Color(hex:)` exists, so this extends a theming layer rather than starting one. Lum in `lum.css` is a 14-hue × 8-tone system whose tone names already split light from dark (`-28`/`-35`/`-on-dark` vs `-93`/`-97`/`-on-light`/`-on-white`) — richer than the 16-color ghostty theme, and a good fit for group and task colors.

## Tabs and window chrome

- [ ] One tab kind. "New Tab" opens a shell; when `claude` is running in it, the tab takes on agent chrome — no agent-vs-terminal prompt at creation.
- [ ] Remove the unused title bar, or move something into it (task name? directory?).
- [ ] Rebalance the chat chrome: put the titlebar's empty space to work. The statusline/composer split (see "The statusline" below) already moved the next-message controls into the message box; what's left is the titlebar itself.
- [ ] Drag a tab into another task.
- [ ] Move a tab out into a new task of its own.

What exists:

- Instrumentation can only be injected at launch — `--settings` and the `PLUME_*` env vars can't be attached to a `claude` the user started by hand. For a shell-first tab to keep reporting status and titles, Plume needs to set `PLUME_*` on every tab's shell, not just on agent tabs. `AgentLaunch` already carries per-surface env and `LoginShellCommand.wrap` already wraps the command, so the seam is there.
- The wrapper exposes `COMMAND_FINISHED` and `PROGRESS_REPORT` actions, and `TerminalViewState` publishes the command metadata — useful for detection.
- `AppDelegate` already makes the titlebar transparent and tints it.
- The detail pane has no toolbar at all — only the sidebar declares one, so the titlebar is empty tinted space. `StatuslineStripView` now carries only the session-wide facts (context, 5h, 7d, cost, branch); permission mode, model and effort moved to `ComposerControlsRow` in `ChatComposer`. Whether any of that still belongs in a window-level toolbar is open — such a toolbar shows the selected task's state, so it needs a decision about what it reads from when tabs disagree.
- Moving a tab between tasks is mostly a data operation — reassign `TaskTab.task` and renumber `orderIndex`, both of which `TaskStore` already owns. The catch is the terminal: `SurfaceManager` is keyed by tab ID, not by task, so the surface itself should survive the move untouched. Don't tear it down and rebuild it, or the move kills a running agent. A tab whose working directory came from its old task also needs a decision — the process keeps its original cwd regardless of where the tab now lives.

## Shortcuts

- [ ] Assignable hotkeys for next/previous tab and next/previous task, so I can set them to alt+J/K and alt+shift+J/K (cmd instead of alt is fine too).
- [ ] ⌘T opens a new tab in the current task.

What exists: next/previous *tab* is already bound to ⌘⇧] / ⌘⇧[ (`PlumeCommands`), and ⌘T already opens a tab in the current task — it's labelled "New Agent Tab", with ⌘⇧T for a terminal tab. Collapsing to one tab kind (see **Tabs and window chrome**) makes ⌘T just "New Tab" and frees ⌘⇧T. There is no next/previous *task* command at all yet. Nothing is user-assignable: every shortcut is hardcoded in a SwiftUI `Commands` body, so making them configurable means a binding store, a settings UI, and a way to apply a stored binding to a menu command. Alt-based chords are also the case most likely to collide with the terminal swallowing keys, which ties this to the focus item under **Misc UX**.

## Naming

- [ ] Consider renaming "task" to something that better fits a long-lived thing — "workspace" was the suggestion.

The observation is right: these outlive a single unit of work, and "task" undersells that. But "workspace" is already taken. `WorkspaceKind` (unset / directory / worktree) is a *property of* a `WorkTask` meaning where it runs, and `WorkspaceProvisioner` creates those directories and worktrees. Renaming the model to `Workspace` would give us `workspace.workspaceKind` and two unrelated `Workspace*` concepts. So this needs a third word, or a rename of the existing workspace concept too — worth settling before anyone starts, since it touches the model, the store, the UI, and every test.

## Verify what shipped unexercised

The headless cutover landed with a passing suite and a clean build, but several
features were only read, never run. Most have now been driven — what they turned
up lives in the chat sections above. These are what's left.

- [ ] Create and delete a worktree, now that both run on `GitService` rather than the main thread.
- [ ] Make `git worktree remove` fail, and confirm the task survives with the error shown.

Both are worktree items, deliberately deferred — see **Mark worktrees as work in
progress** above, which covers labelling the feature until they are done.

What exists:

- The riskiest part is the git conversions, because they changed *when* a value appears rather than what it is. `task.repoPath` is now written after `GitService` answers instead of during the call that sets the folder, so anything reading it in the same turn sees nil where it used to see a path. Nothing does today; that is the assumption to check.
- `SidebarView.deleteTask` was restructured around the same change: the git call moved into a `Task`, so the early `return` that aborted a delete on failure became a `finishDeleting` continuation. The success path is ordinary use, but the failure path — git refuses, the task stays, the error shows — has never run. Note `--force` means a dirty tree will not trigger it.

## Concurrency correctness

Stop the main thread from doing work that belongs elsewhere.

- [ ] Turn on strict concurrency — `SWIFT_STRICT_CONCURRENCY = complete`, then Swift 6 language mode — and fix what it reports.

What exists:

- The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES`, but `SWIFT_VERSION = 5.0` with no `SWIFT_STRICT_CONCURRENCY`. Isolation is therefore inferred and largely unchecked: code that hops back onto the main actor compiles silently.
- That combination has already produced the same bug twice, both found by sampling rather than by the compiler. `TranscriptStore.read` parsed multi-megabyte JSONL on the main thread; `GitStateStore.refresh` ran `git status` there on a 15s timer, taking ~37% of main-thread samples while scrolling. Both *looked* correct — each wrapped its work in `Task.detached` — but `Task.detached` escapes the enclosing actor, not the callee's isolation, and every callee defaulted to `MainActor`.
- The fixes were `nonisolated` on the parsing and git layers, plus `GitService`, an actor that owns every `git` subprocess. The actor is the part that generalizes: `nonisolated` makes a blocking call *legal everywhere*, while an actor makes it *unreachable from a synchronous context*, so the mistake becomes a compile error instead of a dropped frame.
- Strict concurrency would have caught both at build time. Expect it to surface a backlog well beyond these two — the SwiftData models, the observable stores and the Ghostty layer all cross isolation boundaries — so it is worth doing as its own pass rather than folded into feature work.

## Misc UX

- [ ] Shortcuts work while the terminal is focused.
- [ ] Drag and drop to reorder tabs.
- [ ] Reopen the last session on launch — restore the selected task and tab instead of starting cold.

What exists:

- Shortcuts are plain SwiftUI `Commands` gated on `@FocusedValue`, with no low-level key interception, which is likely why they don't survive terminal focus.
- `.onMove` reorders sidebar tasks, but `TabStripView` has no drag support.
- On launch, the per-task selected tab already persists (`WorkTask.selectedTabID`), so only the selected *task* is missing. `MainWindow` holds it in plain `@State`, which starts nil every launch, so the app always opens on "No Task Selected" even though the rest of the tree restores. Persisting that one UUID — `AppSettings` or `@SceneStorage` — is most of the item. Decide what happens when the stored task is gone (archived or deleted), and whether a restored agent tab should auto-resume on launch or wait to be selected, since the existing rule deliberately avoids spawning `claude` for every agent tab at startup.
