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

- **Drop the chat view on terminal-transport tabs.** Do this before the statusline rework, which would otherwise be built to read from two sources. It deletes more than it adds.
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

- [ ] Show subagents, their status and their transcripts. The list exists; the rest does not — see **Subagents** below.
- [ ] Render mermaid diagrams in chat messages and in viewed files.

The terminal stays the fallback. Polish what the native UI covers and skip the rest — that's what lets this ship in small pieces.

### From driving the headless transport

Found by answering a real plan and a real question in the chat, rather than by reading the code. Grouped by what they touch.

**Directory trust.** Launching in an untrusted directory stalls on Claude Code's folder-trust prompt, which the headless transport never surfaces — the turn just hangs with nothing to look at.

- [ ] Don't fail in an untrusted directory. Detect it before launching and offer to resolve it, rather than hanging.

Trust is readable, so this needn't be guesswork: `~/.claude.json` holds `projects.<absolute path>.hasTrustDialogAccepted`, 46 of 47 entries true on this machine. Plume can check the tab's directory against that map before spawning and, when it's missing or false, say so and offer the fix — a terminal tab in that directory (where the real prompt *can* be answered) is the honest version, since writing the flag on the user's behalf silently grants the trust the prompt exists to ask for.

**Permission mode. This one is a bug, not a preference.** `HeadlessCommand.swift:29` falls back to `.acceptEdits` when the task has no mode set, and `WorkTask.permissionModeRaw` starts nil — so a new agent tab *never* starts in plan mode, whatever the user's own CLI default is. The comment there explains the fallback exists because a `-p` session starts in Manual on every plan, which is a real constraint, but the chosen default silently overrides the user.

- [ ] Respect the user's own default permission mode instead of hardcoding `acceptEdits`.

Settling what "their default" means is the first task: Claude Code's own resolution order, a Plume setting, or a per-task choice made at creation.

**Questions.** `InteractiveToolRow` draws a question as header, text and labelled options.

- [ ] Show one question at a time, with prev/next buttons.
- [ ] Fix the type scale: question text and the main answer line are both body; the second answer line is caption.
- [ ] Stop double-tinting the options. The question area and its options are two stacked backgrounds, and a blue focus ring around the box makes it three. Either hold the question area's tint and drop the options to the regular background, or make one of the two outline-only — a blue outline on the options instead of a grey fill is the candidate.

**Plans.** The markdown renderer and the approval area under it.

- [ ] Stop padding inline code spans with space characters. `MarkdownCache.styledInline` inserts a real U+2009 thin space on each side of every span (`MarkdownCache.swift:76`), so the padding is part of the string: copying `foo` yields `\u{2009}foo\u{2009}`, and pasting it into a shell or an editor carries invisible characters that break the paste. Accurate copy matters more than the visual breathing room — if the chip has to hug the glyphs, let it. Only genuine layout padding (which `AttributedString`'s flat `backgroundColor` cannot express — see the note above on why these are square) is worth pursuing as a replacement, and not at the cost of the text.
- [ ] Support tables. Currently unsupported on purpose (`MarkdownBlock.swift:10`) — a table degrades to a paragraph. They're an important visualization tool and the degradation is poor.
- [ ] Syntax-highlight code blocks.
- [ ] Give code blocks more padding inside their border.
- [ ] Mermaid diagrams in the same renderer — already tracked above, and still the item that most needs its approach settled first.

Approval area:

- [ ] Hold it to content width, and give it more space above, away from the plan content.
- [ ] Offer better options than Approve/Reject:
  - **Approve** — also starts work right away, in auto mode when that's enabled.
  - **Approve + compact** — the same, but compacts first.
  - **Reject with an optional reason** — the feedback goes back for a retry.
  - The CLI's third option (reject with feedback, then auto-approve whatever plan comes back) is worth having, but its UX here is unsettled. One idea: alt+return while typing a rejection.

**Minor.**

- [ ] Give the first message a nicer intermediate state. The composer currently disappears before the message appears; disabling it in place would read better.
- [ ] Make the composer content-width rather than bleed-width.
- [ ] Distinguish a bash block's input from its result — they currently render alike.
- [ ] Put real newlines in a bash input block.

What exists:

- `TranscriptParser` turns a transcript into `ChatMessage`s; `TranscriptStore` watches the file per tab and republishes, following `AgentTitleMonitor`'s pattern with a shorter debounce because this drives visible content. `SessionJSONLReader` still resolves paths and now also enumerates the subagent transcripts.
- `MarkdownBlock` splits block structure by hand and inline-parses each paragraph with `AttributedString`, so there is no WebKit. Nested lists and tables are deliberately unsupported: a table degrades to a paragraph rather than being mangled.
- Chat items size themselves rather than inheriting a column from the list. `ChatMetrics` derives both widths from the font — content at `fontSize * 40` for prose, bleed at `fontSize * 50` for code blocks and the plan panel — and `listItemPadding(bleed:column:vertical:)` applies one of them. The nesting runs outside-in: a message row takes bleed as an *invisible* container (`.unpadded`, clamping without a gutter) and the prose inside steps back to content as a visible one, so only the innermost item pays an inset and nothing doubles up. Padding sits inside the clamp, so a content item's text measures a true `maxContentWidth` rather than that minus its own gutter.
- The user's bubble hugs its text instead of filling the column, capped at reading measure and hung off the bleed edge the code blocks use. The wash goes on the blocks themselves and the frames only position the result: bounded text wraps and reports the width it used, where a container in between would accept the full width on offer and make a two-word message as wide as a paragraph. `chatHugsContent` is what tells the blocks inside not to expand.
- Prose rhythm scales with the font too: block spacing at `fontSize * 1.15`, extra line leading at `0.22`, and a heading's space-above tapering by level (H1 widest, H5 and H6 nothing) so it mirrors the heading font ladder. A heading opening a message gets no space above it, having nothing to separate from.
- Inline code spans get the monospace face and the code block's tint, padded with thin spaces so the background reads as a chip rather than hugging the glyphs. Corners are square: `AttributedString` offers only a flat `backgroundColor`, and rounding would mean one view per span — losing paragraph-wide text selection and needing a custom wrapping layout. The styling is cached in `MarkdownCache.styledInline`, keyed by text, size *and* tint so a light/dark switch misses rather than serving the previous appearance's chips; uncached it measured ~57µs a paragraph, which the render loop turns into seconds.
- `TranscriptParser` also surfaces the latest `planFilePath` from a session's `plan_mode`/`plan_mode_exit` attachment lines. When that path exists on disk, `ChatTabView` shows a "Plan" button that opens `MarkdownFileView` in a sheet — a file-backed, live-updating `MarkdownFileStore` reads the same `MarkdownView` renderer chat messages use, so it isn't hardcoded to plans.
- The composer sends with ⌘↩ — plain ↩ inserts a newline, so a half-typed message is never lost. It reaches the agent through `TerminalSession.submit(text:)`, which pastes and then presses Enter as two operations. **A trailing `\r` in pasted text does not submit**: the wrapper's text path is a paste, and bracketed paste leaves the carriage return in the edit line.
- A draft survives leaving the tab. `DraftStore` holds the unsent composer text of every tab in memory, keyed by tab ID, because a chat tab's view unmounts whenever it stops being selected and view state goes with it. `TaskStore` forgets a tab's draft when the tab or its task is deleted. This is a draft, not a queue — see the queued-messages note below.
- The chat follows a reply as it grows, not just as new messages arrive. `ChatScrollAnchor` keeps the decisions pure and testable: within 40pt of the bottom still counts as at the bottom, and growth of the *same* message pulls the view down only if the distance measured **before** the growth was inside that tolerance. Scroll away and new content stops chasing you, and a glass jump-back button appears once you are past `detachedThreshold`.
- Permission mode is settable before launch and cyclable during a session. `WorkspacePickerView` has a chip writing `WorkTask.permissionMode`, which `ClaudeCodeProvider` turns into `--permission-mode`; mid-session the statusline strip shows the mode and clicking it calls `TerminalSession.cyclePermissionMode()`, which sends Shift+Tab. That is a *step*, not a setter — the CLI offers no way to set a mode outright once running, so the strip advances by one and reads back where the session landed. `PermissionMode` deliberately omits `manual` and `dontAsk`, so a session in one of those shows its reported string rather than a wrong selection, and `bypassPermissions` shows red.
- **Quota and cost come from the headless stream.** `rate_limit_event` and each turn's `total_cost_usd` land on `HeadlessSession`, and the strip reads them from there — no capture, and no writes to `~/.claude/settings.json`. A terminal-transport tab has no headless session, so its strip shows context use, model, effort and branch alone, all transcript-derived.

Left for later:

- Mermaid has no renderer yet. `MarkdownBlock` already isolates fenced code blocks, so a `mermaid` fence is easy to *detect* — drawing it is the work. Worth deciding early whether that means WebKit (mermaid.js is JavaScript, and a `WKWebView` per diagram is the quick path but reintroduces the browser this renderer deliberately avoids) or native drawing of a useful subset. Until one exists, a mermaid fence should keep degrading to readable source the way an unsupported table already degrades to a paragraph.

### More from driving plans

**Two bugs in the same place, both from `ToolCallRow` drawing a plan it can't answer.**

- [ ] A rejected plan briefly says "Approve or reject in the terminal."

`InteractiveToolRow` is answerable only when a caller hands it an `answer` closure. `PendingPermissionDock.swift:23` supplies one; `ToolCallRow.swift:18` does not, so the transcript's copy of the same plan always falls through to `answerHint("Approve or reject in the terminal.")` (`InteractiveToolRow.swift:72`). While a request is live the dock's answerable row covers for it. Answering removes the pending entry, the dock's row disappears, and the transcript row underneath — with its terminal hint — is what's left showing until the next transcript parse catches up. So the hint is not merely stale, it is wrong on the headless transport, where the terminal is not where you answer. Fix the hint to reflect the tab's transport, and give the resolved row a settled state ("Rejected", with the reason) rather than an instruction to act.

**The plan overlay does both jobs.** Today it never opens on its own: `planPresentation` starts `.closed` (`ChatTabView.swift:13`) and every assignment of `.expanded` sits behind a button (lines 146, 204), so it is a viewer the user opens rather than a presentation the agent triggers. It should be both — a proposed plan opens the overlay, and the overlay is where it gets approved.

- [ ] Present a proposed plan in the overlay, with the approval options in it.
- [ ] Inline, show only a row for the `ExitPlanMode` call — with a button to reopen the overlay while it is unanswered.

The overlay then has two roles, before and after the decision: approving the plan on the table, and reviewing the plan already approved. That also gives the approval controls somewhere with room, which the inline row does not have.

The two content sources turn out to be one, so this needs no reconciliation: an `ExitPlanMode` input carries **both** `plan` (the markdown) and `planFilePath` (`InteractiveToolPayload.swift:41`), and the latter is the same path `TranscriptParser` records from the `plan_mode` attachment line and the overlay already renders. **The overlay always reads the file** — that file is what is being proposed — so it keeps its existing `MarkdownFileStore` path unchanged and gains live updates for free if the plan is rewritten. The payload's markdown is not a second source to merge; it is what the inline row summarizes.

**Interrupting the reader is fine**, as long as the overlay can be minimized — which it already can (`PlanPresentation.minimized` docks it as a bar above the composer). So a proposal expands over the conversation and the user dismisses it if they were mid-thought; no special quiet-arrival case is needed.

**The overlay's footer has three states**, driven by where the plan stands rather than by how the overlay was opened:

| State | Footer |
|---|---|
| Proposed, awaiting a decision | The approval options |
| Approved | "Approved" |
| Any other time — before a proposal, or after a rejection | "Not approved yet" |

"Not approved yet" deliberately covers both of the third state's situations — never proposed, and proposed then rejected — because the plan may have been rewritten since the rejection, so saying anything about that rejection risks describing a document that no longer exists. It speaks only to the state that is still true.

One thing to get right when picking this up: a plan file exists *before* it is ever proposed. `TranscriptParser` records `planFilePath` from a `plan_mode` line as well as `plan_mode_exit` (`TranscriptEntry.swift:238`), so the agent writing a plan is enough to make it viewable. That is the same third state, and it means the footer cannot be derived from the file's existence — it needs the state of the most recent `ExitPlanMode` call and its answer.

### Queued messages

Driven and working: messages list while the agent is busy, each is removable, and they drain in order when the turn ends. What's left is polish on getting one back to edit it.

- [ ] An edit icon beside the queued message's ✕. It cancels the message and moves its text into the composer.
- [ ] ↑ from an empty composer does the same, taking the last queued message. The composer hint becomes "Press ↑ to edit a queued message" while a queue exists.

Both are one operation — remove from the queue, put the text in the composer — so build it once and give it two triggers. `HeadlessSession.removeQueuedMessage(at:)` already exists and returns nothing; the edit path needs the text it removed.

The keyboard half has room to land cleanly. `MarkdownComposerTextView.keyDown` already intercepts key code 126 (Up), but only while the slash-command list is showing (`MarkdownComposerTextView.swift:196-217`), and that interception returns early — so an Up with no autocomplete open falls straight through to `super`. The new case belongs after that block, gated on an empty composer so ↑ still moves the caret in a half-typed message. Repeated ↑ walking further back through the queue is the obvious extension, and worth deciding on up front: it is the shell-history behavior the key implies, and building the first one without it tends to hardcode "the last message" in a way that resists the second.

### Statusline

Driven on a headless tab. Quota, cost and context do arrive from stream events as intended, but the strip around them has bugs and needs a rethink. It is also horizontally squished, which is what made the rest hard to see.

**Bugs. The interactive segments share one root cause: they send a change but display transcript state.** Every value in the strip — `model`, `effort`, `permissionMode` — is read from `transcript` (`ChatTabView.swift:73-77`), while the controls write through the session. So a segment only updates once the change has round-tripped into the transcript *and* been parsed back out, and shows nothing at all if it never does.

- [ ] The permission mode control doesn't work. It is a click-to-cycle `Button`, not a dropdown (`StatuslineStripView.swift:168`) — so it reads as a menu that never opens. `cyclePermissionModeHandler` derives the next mode from `transcript?.permissionMode`, so when the transcript reports nothing (or a mode `recognizing` doesn't offer, like `manual`) `currentIndex` falls back to `-1` and every click resolves to the same first mode. Make it a real dropdown, and drive it from session state.
- [ ] Changing effort posts a message into the chat but never updates the control. `effortSelectionHandler` sends `/model`-style text through `submit(text:)` (`ChatTabView.swift:301`) — an ordinary user turn, which is why it appears as a chat message. The displayed value only catches up if the transcript reports the new effort.
- [ ] Changing model appears to do nothing. Unlike effort, this one sends a real control request (`HeadlessSession.setModel`, `StreamJSONEncoder.setModel`) — so it may well be taking effect with no feedback, since the label still comes from the transcript. Two things to establish: whether the control request is accepted mid-conversation, and whether switching model mid-conversation is something we want to offer at all. Answer that before styling the control.
- [ ] Model and effort each show two chevrons — one drawn by `segmentLabel` (`StatuslineStripView.swift:233`) and one by `.menuStyle(.borderlessButton)`. Drop the hand-drawn one.
- [ ] Text styles across the strip are inconsistent. Settle one scale for the whole row.

**Layout.**

- [ ] Give the strip bleed width and center it, so everything fits.
- [ ] Find a more horizontally compact form for context and quota. A small bar under the label is the leading idea — `5d: 15%` over a `|----________|` track. Radial fills read as compact but make relative sizes hard to compare, which is most of what these numbers are for.

**Bigger questions, worth settling before polishing the above.**

- [ ] Consider merging the strip with the directory/worktree/permission row above the composer. They already overlap: permission mode appears in both.
- [ ] Consider moving the whole thing inside the composer box, if a compact form fits a narrow viewport.
- [ ] Assume it becomes user-customizable eventually. Not a near-term item, but a useful lens for the decisions above — a segment that can be reordered or hidden has to be self-contained, which argues against special-casing any one of them.

There is a real ordering here: the merge-and-relocate question decides how much room the strip has, and the compact form depends on that. Do the chevron and text-style fixes whenever; hold the layout work until the placement is settled.

### Drop the chat view on terminal-transport tabs

- [ ] Remove `TabRenderMode`. A terminal tab shows the TUI; a headless tab shows the chat. The transport is the choice.

Yes, a terminal tab has a pretty mode today, and it is the **default**: `TaskTab.renderMode` defaults to `.chat` (`TaskTab.swift:44`), and `TabContentView` keeps both views mounted in a `ZStack`, toggling opacity (`TabContentView.swift:60-75`). A headless tab is already chat-only — `AgentTabMenu.renderModeAction` returns nil for it (`AgentTabMenu.swift:20`) — so the axis only does anything on the terminal transport.

Removing it is the right call for the reason given: the chat would otherwise have to read from two sources forever. It already does, and the seams show. `ChatTabView` falls back from `headlessSession?.contextUsedTokens` to `transcript.latestUsage?.inputTokens`; the statusline bugs above come from displaying transcript state while writing session state; and the interactive rows still carry an "answer in the terminal" path that exists only for this case. Every one of those either disappears or gets simpler.

What it touches: `TabRenderMode` and `TaskTab.renderModeRaw`, `AgentTabMenu.renderModeAction` and its tests, the `ZStack` in `TabContentView`, the "Show Terminal / Show Chat" menu item (`TabStripView.swift:92`), the ⌘/ command (`PlumeCommands.swift:101`, `MainWindow.swift:70`), and `SmokeHarness`'s `PLUME_TOGGLE_RENDER_MODE`. The persisted property stays as a tombstone or gets a migration; everything else deletes. Worth doing before the statusline rework, which would otherwise be built to satisfy both sources.

### Slash command autocomplete

Driven and mostly working — the list appears, filters, and accepting rewrites the leading token. Four fixes:

- [ ] Scroll the list to follow the selection. Arrow keys currently move it outside the visible rows (`SlashCommandAutocompleteView`), so the selection disappears rather than the list following it.
- [ ] Put the caret at the end of the inserted command. Accepting fills the text but leaves the caret where it was.
- [ ] Show in the composer that a command is recognized — turn the token blue, or similar. Nothing currently distinguishes a real command from a typo until you send it. `MarkdownComposerStyler` already styles the composer's text and has an `inlineCode` case to follow (`MarkdownComposerStyler.swift:42`), and the recognized set is `headlessSession?.slashCommands`, which the matcher already reads.
- [ ] Let ⌘↩ send while the list is showing. `MarkdownComposerTextView.keyDown` intercepts Return whenever `autocompleteHandler.isShowing`, before any modifier is examined (`MarkdownComposerTextView.swift:196-217`), so ⌘↩ accepts the selection instead of sending. The fix is to check for the command modifier ahead of that block — the send path below it already distinguishes ⌘↩ from plain ↩.

### Chat scrolling

Driven for the first time. Auto-follow is broken, and both symptoms come from one placement mistake.

- [ ] Follow a reply as it streams. It currently advances one tick and stops.
- [ ] Make the jump-to-bottom arrow reach the actual bottom, not the bottom of the last message.

**The bottom anchor is above the list's bottom padding.** `ChatMessageList` puts a 1pt `Color.clear` anchor as the last element *inside* the `VStack`, then applies `.padding(.bottom, bottomPadding)` to the VStack itself (`ChatMessageList.swift:102-107`) — so `dimensions.listBottomPadding`, which is `bodySize * 4.5` (`Dimensions.swift:43`), sits *below* the anchor and outside it. Every `proxy.scrollTo(bottomAnchorID, anchor: .bottom)` therefore lands short by that much, which is exactly what both reports describe: the arrow stops at the end of the text, and streaming settles one message-bottom short of the true bottom.

Why it then stops following: the geometry action guards on `ChatScrollAnchor.reflectsUserScroll` and records `distanceFromBottom` off the *previous* content height. Coming to rest a fixed padding's distance from the bottom reads as a deliberate scroll-away, so the anchor latches detached and stops chasing. The threshold is 40pt and the padding is larger than that at any sane font size, which is why it happens every time rather than intermittently.

Fix the anchor's placement first — move it below the padding, or move the padding inside the anchor's container — and re-check the follow behavior before touching the thresholds. `ChatScrollAnchorTests` covers the arithmetic and passes; it never placed the anchor, which is why the suite stayed green through two rewrites of this code.

### Mark worktrees as work in progress

Worktree create and delete moved onto `GitService` and have not been driven since. Rather than block on verifying a feature that matters less than the rest, label it so its state is honest.

- [ ] Put a beta/WIP marker on the worktree entry points.

Where it needs to show: the "New Worktree…" button (`WorkspacePickerView.swift:128`), the sheet's own title (`NewWorktreeSheet.swift:20`), and the two destructive delete items that remove a worktree or its branch (`SidebarView.swift:100,103`). The delete items are the ones that most need it — they are irreversible, and their failure path is the least exercised code in the feature.

Settle one marker and use it everywhere, since this will not be the last unfinished feature to ship visible. A "Beta" chip beside a label is the cheap version; a tooltip saying what specifically is unverified is the useful one.

**Still unverified, and worth stating plainly in the marker or alongside it:** creating a worktree, removing one, and the failure path where git refuses and the task must survive with an error shown (`SidebarView.swift:141-145`). Note that `WorkspaceProvisioner.removeWorktree` passes `--force`, so ordinary "dirty tree" refusals never reach that handler — reproducing it needs `git worktree lock` or an already-removed path.

### Subagents

Was marked done and is not: the checkbox above covered the *list*, while the status half never worked. Three notes elsewhere in this document already admit pieces of it, which is how it stayed checked off. Driven now, and it is well short of useful.

Parallel subagents are the case Plume exists to make legible, so this deserves to be a real view rather than a patched-up disclosure row.

- [ ] Show which subagents a conversation has spawned, identified by what they were asked to do rather than by ID.
- [ ] Show each one's live status — working, waiting for input, done, failed.
- [ ] Let a subagent's transcript be read properly, with the same rendering the main conversation gets.

Today the label is `subagent.id` — a raw identifier (`SubagentListView.swift:59`) — over a one-line tail of the last message. `SubagentTranscript` carries only `id`, `transcript` and `modifiedAt` (`TranscriptStore.swift:6-10`), so neither a task description nor a status has anywhere to live yet; both want adding there. The description is recoverable: a subagent is spawned by a `Task`/`Agent` tool call in the parent transcript, whose input carries the prompt and a short description, and the transcript parser already reads those calls.

Three specifics behind the items above:

- **Status is hardcoded, not merely wrong.** `ChatMessageRow(message:, isLast: false, status: .unset)` (`SubagentListView.swift:53`) passes both constants, and `ChatMessageRow` gates its working spinner and needs-input indicator on `isLast && status == …` — so neither can ever fire, whatever the subagent is doing.
- **Freshness would still lag once status is wired.** A subagent's own writes don't trigger the main transcript's watcher, so the list refreshes only when the *main* transcript changes. `SessionJSONLReader` already enumerates the subagent transcripts, so what's missing is a watcher per file, not discovery.
- **Presentation.** A nested `DisclosureGroup` inside the chat list is a cramped place to read a whole conversation. Worth weighing against the alternatives — a sheet like the plan overlay, or a pane — especially once several subagents run at once, which is the situation that motivates the feature.

`SubagentListView` hardcodes both status arguments: `ChatMessageRow(message: message, isLast: false, status: .unset)` (`SubagentListView.swift:53`). Since `ChatMessageRow` gates its working spinner on `isLast && status == .working` and its needs-input indicator on the same pair, a running subagent can never show either — the two arguments that would drive them are constants. Fixing it means `SubagentTranscript` carrying a status, or `SubagentListView` deriving one, plus a real `isLast` for the newest row.

Freshness is the second half, and it is why a status would still lag once wired: a subagent's own writes don't trigger the main transcript's watcher, so the list only updates when the *main* transcript happens to change. `SessionJSONLReader` already enumerates the subagent transcripts, so the watcher is the missing piece rather than the discovery.

Worth deciding how much of the chat's own rendering a subagent row should get, rather than fixing the status flag alone — the row is the same `ChatMessageRow`, so most of the gap is arguments and freshness rather than a separate renderer.

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
- [ ] Rebalance the chat chrome: put the titlebar's empty space to work, consolidate the statusline, and move some of it into the message box.
- [ ] Drag a tab into another task.
- [ ] Move a tab out into a new task of its own.

What exists:

- Instrumentation can only be injected at launch — `--settings` and the `PLUME_*` env vars can't be attached to a `claude` the user started by hand. For a shell-first tab to keep reporting status and titles, Plume needs to set `PLUME_*` on every tab's shell, not just on agent tabs. `AgentLaunch` already carries per-surface env and `LoginShellCommand.wrap` already wraps the command, so the seam is there.
- The wrapper exposes `COMMAND_FINISHED` and `PROGRESS_REPORT` actions, and `TerminalViewState` publishes the command metadata — useful for detection.
- `AppDelegate` already makes the titlebar transparent and tints it.
- The chrome is unbalanced in both directions: the detail pane has no toolbar at all — only the sidebar declares one, so the titlebar is empty tinted space — while `StatuslineStripView` packs up to seven segments into one flat `HStack` (context, 5h, 7d, cost, branch, permission mode, model/effort). Some of those belong nearer the composer, since they describe what the *next* message will do rather than the session as a whole: permission mode, model and effort are all already interactive, and reading them at the point of sending is more useful than reading them above the transcript. The session-wide facts — quota, cost, branch — are the natural candidates for the titlebar. Two things to settle: a window-level toolbar shows the selected task's state, so it needs a decision about what it reads from when tabs disagree, and the strip's items are sized for `.caption` in a themed row, so moving them is a restyle rather than a reparent.
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
