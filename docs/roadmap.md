# Plume roadmap

Features we intend to build. Each section records what we want and what the code already provides — it doesn't say how to build any of it. Work out the approach when you pick an item up.

Sizes are rough: **S** is a call site or two, **M** is a contained feature, **L** touches several files or needs a design decision, **XL** is wide or deep enough to plan on its own.

## Up Next

The queue, highest priority first. Each line points at the section holding the detail; nothing here repeats it.

Everything queued for 0.3.1 and 0.3.2 shipped. What is left, not yet ordered:

- **M** — Read a subagent's completion from the line shape the CLI actually writes; finished subagents read working today. See [Subagents](#subagents).
- **S** — A resumed headless conversation came up in plan mode after running in auto mode; re-check item 12 live. See [The statusline](#the-statusline).
- **M** — Track an agent tab's current worktree, including through `EnterWorktree`, and open new terminal tabs there. See [Worktrees](#worktrees).
- **S** — Make ⌘T a terminal tab and ⌘⌥T an agent tab. See [Shortcuts](#shortcuts).
- **M** — Restyle a tool row's one-liner as `Bash: command…`, with the code part in monospace. See [The markdown renderer](#the-markdown-renderer).
- **S** — Let the command line send a notification, like `cmux notify`. See [Notifications](#notifications).
- **M** — Fix giving feedback on a plan: Return approves instead of sending feedback, and the field is a plain `TextField` rather than the composer's editor. See [The plan overlay](#the-plan-overlay).
- **M** — Autocomplete slash commands in the composer before the first message. See [The composer](#the-composer).
- **M** — `/btw`: confirm the note is filed on the headless transport, then show it in the chat. See [The composer](#the-composer).
- **M** — Grow `PlumeUITests` against the new accessibility identifiers. See [Make the UI drivable](#make-the-ui-drivable).
- **M** — Keep the Mac awake while an agent, subagent or long-running command is in flight. See [Keep the Mac awake](#keep-the-mac-awake).
- **L** — Fix the titlebar: empty space, sidebar-resize overflow, and tabs at the top of the window. See [Tabs and window chrome](#tabs-and-window-chrome).
- **M** — Animate chat row height changes. See [Chat animation](#chat-animation).
- **M** — Reveal streamed text a character at a time instead of a paragraph at once. See [Chat animation](#chat-animation).
- **L** — Store and restore terminal tab history across a reopen. See [Terminal history restore](#terminal-history-restore).
- **S** — A short-lived screenshot lease so agents capture one at a time. See [Infrastructure](#infrastructure).
- **S** — Spellcheck the composer. See [The composer](#the-composer).
- **M** — Give a subagent row a second, dim line: model, time running, context used, and take the list to content width. See [Subagents](#subagents).
- **L** — Show each tab's agent separately in the sidebar, with its folder and status. See [The sidebar](#the-sidebar).
- **L** — Generate a tab title with Apple's on-device model, falling back to today's. See [Tab titles](#tab-titles).
- **L** — Talk to a subagent directly, from its transcript rather than through the main chat. See [Subagents](#subagents).
- **S** — Fix numbered lists rendering every item as `1.`. See [The markdown renderer](#the-markdown-renderer).

Deferred rather than dropped: **`!` command execution mode** waits for a real implementation — the styling half alone produces a mode that looks live but does nothing on send (see [The composer](#the-composer)).

Not queued, and deliberately so: **Renaming "task"** is cheap to do and expensive to redo, so settle the word before it touches more call sites (see [Naming](#naming)). **Directories on tabs instead of tasks** is the widest change on the list and forces a real question about what a task is (see [Task creation and directories](#task-creation-and-directories)). **Strict concurrency** is worth its own pass rather than folding into feature work (see [Concurrency correctness](#concurrency-correctness)).

## Notifications

Tell me when I need to pay attention to tasks.

- [x] Terminal bell support, with a dot next to chats that have rung one.
- [x] System notification on bell.
- [ ] Let the command line send a notification (title + description), like `cmux notify`.
- [x] Notify automatically on Claude Code events — above all, waiting for input.

What shipped:

- `BellStore` holds the tabs with an unseen bell, and `TabStripView` draws a dot on their chips. A bell rung in the tab on screen is already seen and leaves no dot; the mark clears when the tab comes on screen, and when a notification click lands on it.
- `TerminalSession` mirrors `bellCount` and the OSC 9 / OSC 777 notification into observable storage, alongside `title` and `workingDirectory`.
- `Notifier` (`Plume/Support/`) is the delivery layer over `UNUserNotificationCenter`. It asks for authorization the first time something wants to notify, queues that first post until the answer arrives, and no-ops afterwards if the answer was no. It also no-ops in a process with no bundle identity, which is what keeps the test host safe.
- **The suppression rule**: a notification is dropped only when Plume is frontmost *and* the event's tab is the one on screen. A background tab, a background task, or any tab while Plume is behind another app all notify. `NotificationSuppression` holds the rule on its own, and is unit-tested.
- `StatusNotifier` hooks `StatusEngine.onTabStatusChanged`, so both transports are covered at once. `needsInput`, `done` and `error` notify; `working`, `idle` and `unset` do not.
- Clicking a notification activates Plume and selects the task and tab it came from.

What exists:

- The Ghostty wrapper publishes `bellCount` / `lastBellAt` on `TerminalViewState`. `TerminalSession` mirrors `title` / `workingDirectory` from that same object, so a bell follows an established pattern.
- The wrapper also delivers OSC 9 / OSC 777 desktop notifications with a title and body (`terminalDidRequestDesktopNotification`). A shell can already notify Plume with `printf '\033]777;notify;Title;Body\a'` — the CLI helper is a convenience wrapper, not a new transport.
- `Notification` hook events are already decoded and already drive `needsInput` (`HookEvent`, `StatusEngine`). Notifying is a delivery layer over a signal that exists.

## Subagents

Parallel subagents are the case Plume exists to make legible, so this is a real view rather than the patched-up disclosure row it started as.

- [x] Show which subagents a conversation has spawned, identified by what they were asked to do rather than by ID.
- [x] Show each one's live status — working, waiting for input, done, failed.
- [x] Let a subagent's transcript be read properly, with the same rendering the main conversation gets.
- [x] Keep the live list short: a finished subagent lingers briefly, then collects into a "Completed subagents (N)" disclosure below the live rows.
- [x] Keep the sidebar honest: a task whose subagents are still working reads working, not done.
- [x] Give each subagent row a second line of dim caption text: the model it is running, how long it has been going, and how much of its context it has used.
- [ ] Make the subagent list content-width rather than bleed-width, like the composer. It sits at the bottom of the chat stream at `.listItemPadding(bleed: true, column: .unpadded)` (`ChatMessageList.swift:131`), so it runs wider than the conversation above it.
- [x] Read a subagent's completion from the `queue-operation` line the CLI writes today. Ten of eighteen subagents in one session read working long after they finished.
- [ ] Let a subagent be talked to directly. Its transcript is read-only today, so steering one means going back to the main chat and asking the parent to pass a message along.

What shipped: `SubagentTranscript` now carries a `descriptor` and a `status` beside its transcript. `SubagentListView` is a flat list of one compact row each — status badge, description, message count — and a row opens `SubagentTranscriptOverlay`, which renders the whole conversation through the same `ChatPieceView` the main chat uses. `ChatTabView` hosts that overlay beside the plan one and holds the open subagent by **id**, so the panel follows the subagent's live re-reads instead of freezing at the moment it was opened.

**The second line shipped as `SubagentCaption`.** It reads model, elapsed time and context spent off the `SubagentTranscript` the row already holds, and drops whichever part it cannot state — so a row that has only just appeared says less rather than something wrong. `SubagentRow` renders the caption `Text` even while it is empty, which keeps a live row's height fixed as the facts arrive.

Two figures needed a source. **Context percentage** divides `latestUsage.contextUsedTokens` by `AgentModel.nominalContextWindow` for the model the subagent itself records, falling back to the `model` its sidecar carries — the same denominator the tab's meter falls back to, and nil for a model this build has never heard of, which drops the percentage instead of inventing one. **Elapsed time** spans the transcript's own first and last line timestamps, now kept on `Transcript` as `startedAt` and `lastActivityAt`. That reads the conversation rather than the file, so a relaunch reports the same span and nothing here dates a row by an mtime — the rule `SubagentCompletionTracker` follows for its linger clock, for the opposite reason. A working agent's clock runs to now and a finished one stops at its last line. The figure is coarse (`45s`, `12m`, `1h 30m`) because the row redraws only when the transcript does.

**The completion signal moved, and Plume still reads the old one.** Diagnosed on 2026-09-06 against a session that spawned 18 subagents, of which 10 read `working` after finishing. Every one of the 18 has a real completion in the parent transcript: a top-level `{"type":"queue-operation","operation":"enqueue"}` line whose `content` is a string holding `<task-id>` and `<status>completed</status>`, with the task id equal to the subagent's own id. Nothing pairs wrongly — the line is simply never read. `TranscriptAttachment.init(from:)` decodes `plan_mode`, `plan_mode_exit` and `task_status` and drops everything else, `queue-operation` is not modelled at all, and `SubagentSpawnResults.init` looks only at `toolUseResult` and `attachment?.taskStatus`.

**`task_status` appears to be dead.** That file contains zero `task_status` attachments across 2.5 MB, so the attachment path the current code depends on is reading a shape this CLI build no longer writes. The `toolUseResult` for all 18 stays at `async_launched` and is never updated, which is what the section already records. So `parentSignal` never reaches `.completed` and `SubagentStatusDeriver` falls back to `lastStopReason == "end_turn"` — and each of those 10 closing reports carries `stop_reason: null`, which `TranscriptParser` skips, leaving the reason pinned to an earlier `tool_use`. The 7 that read `done` did so by luck, their previous non-null reason already being `end_turn`.

**The notification is read now, and the deriver's rules were left alone.** `TranscriptTaskNotification` lifts `task-id` and `status` out of a `queue-operation` line's `content`, and `SubagentSpawnResults` records the result beside the two signals it already read. Across the corpus the status is one of `completed`, `failed`, `killed` or `stopped`.

The payload is a plain string, so three things keep it from degrading into a wrong signal. Tags are read only from the **header**, before the `<result>` body, since an agent's own report quotes them. An unrecognized status — `killed`, `stopped`, anything new — yields **no signal at all**, leaving the verdict to the subagent's own transcript, where the interruption marker says whether the user asked for the ending. And only a `queue-operation` line is read: the same text arrives again as an ordinary user message, where reading it would let a user quoting the block fabricate a completion.

**A stopped agent stays interrupted.** It is notified `completed` like any other, so `SubagentMetadataReader` now decodes the sidecar's `stoppedByUser` (and its `model`), and `SubagentStatusDeriver.derive` takes it. The flag suppresses only the parent's word — an agent resumed after a stop still reads `done` from its own `end_turn` — so the state this section already ships is untouched.

**Nothing on the wire sends a subagent a message.** The control plane's subtypes are all session-wide — mode, model, cwd, interrupt (`docs/headless-protocol.md`) — and a turn sent with `submit(text:)` goes to the parent. The parent is the only thing holding a handle on its subagents, so the honest first step is establishing what the CLI offers at all: whether a host can address a subagent, or whether the message has to reach it as an instruction to the parent to relay. That answer decides the whole shape. A relayed message is a composer in `SubagentTranscriptOverlay` that writes into the main conversation, which is what the user does by hand today, only without leaving the transcript; a direct one is a second input path with its own pending state and its own answers coming back. Either way the overlay needs somewhere to put a reply, since it renders the subagent's file and a relayed exchange lands in the parent's.

Four things worth knowing for anything that builds on this:

- **A subagent transcript is entirely `isSidechain`, and the parser dropped those lines.** So the old view rendered nothing at all — a step past what the checkbox described. `TranscriptParser.parse` takes `includeSidechain:` and the subagent read passes it; the default keeps a main transcript's sidechains out as before.
- **The description comes from a `.meta.json` sidecar, not from the parent scan.** Claude Code writes `agent-<id>.meta.json` beside each transcript carrying `description`, `agentType` and `toolUseId`. `SubagentSpawnScanner` is the fallback for transcripts written before it existed, and it has to match a `Task` call to its agent through the *result* — the `tool_use` itself names no agent id.
- **Done is `end_turn` in the subagent's file, or a real completion for it in the parent.** Neither signal alone is enough. Trailing assistant prose is not one at all: an agent narrates between tool calls, so 49 of 210 sampled subagents ended on prose while still working, every one a false green check. But keying on the sidecar alone left agents stuck at working after the main chat already had their report — 21 of 513 in the corpus. The sidecar's tail is unreliable in exactly that case: the closing message is written while streaming and carries `stop_reason: null`, which `TranscriptParser` skips, so `lastStopReason` keeps the `tool_use` from the turn before and the row never settles. Seventeen took that shape; two more ended on `stop_sequence` after an API error cut the response off, and two reached the parent only as a `task_status` attachment. So `SubagentStatusDeriver` takes either signal. The parent's is read as a **status, never as English**: `SubagentSpawnResults` keys `SubagentParentSignal` by agent id from a `toolUseResult` carrying `agentId` (`async_launched` and `forked` mean launched, `failed` and `error` mean failed, anything else is a real report) and from a `task_status` attachment, which is how a background agent's completion reaches a parent that never blocked on the spawning call. A completion outranks the launch that preceded it. Absent a parent completion the sidecar rule stands, latest `stop_reason` wins, so a resumed agent reads as working again. An async agent whose parent recorded nothing still shows working rather than guessing done.
- **Working subagents hold their tab at `working`.** The main agent ends its turn while the subagents it spawned keep going, so a bare `Stop` would flash the sidebar done and invite the user back to a task still moving. `StatusEngine.setSubagentActivity` records the per-tab flag and `status(forTab:)` folds it in: `done`, `idle` and `unset` become `working`, while `needsInput` and `error` win regardless, since a subagent cannot clear either. `TranscriptStore` feeds it from the read that already publishes subagent statuses — the one place with a watcher per subagent file — and clears it when a tab stops being watched. Because the callbacks now carry effective status, `StatusNotifier` posts "Finished its turn." once, on the final settle, and the persisted `lastStatusRaw` snapshot records the effective status: it is what the user last saw, and subagent activity is not itself persisted, so a raw `done` would reappear as a status the app never showed.
- **A finished subagent lingers 30s before folding away, across task switches.** `SubagentCompletionTracker.shared` is keyed by tab then subagent id, in memory only, like `SurfaceManager` and `BellStore`. It has to be shared because selecting another task unmounts the chat: held in the view, both the record of when a row finished and the timer that moves it died with it, and coming back restarted every countdown. The timer belongs to the store for the same reason — a view's `.task` is cancelled on unmount, so a linger that elapsed off screen would never fire. The clock starts from the moment Plume *observes* the status, never from the transcript's mtime, since dating rows by their own timestamps would collapse every one the instant a relaunch re-read old files. `SubagentListView` observes it from `.onChange` rather than `body`, keyed on a status signature so transcript growth alone does not restart a linger, and `TaskStore` forgets a tab's rows when the tab or its task is deleted.

Freshness is a `FileWatcher` per subagent file, reconciled after each parent read (`TranscriptStore.syncSubagentWatchers`) — a new subagent's file always follows a parent write, so no timer is needed.

**Resume no longer shows everything as fresh.** `SubagentCompletionTracker` records which tabs it has read, and a subagent already finished on the *first* read of its tab is pre-completed: settled from the start, with no instant recorded and no timer. Only a finish observed on a later read earns a linger. The read is per tab and lives in the shared store, so remounting the chat — which selecting another task does — is not a first read and a row mid-linger keeps its linger. A pre-completed subagent that goes back to work loses that standing and earns a real linger when it finishes again. The clock is still never derived from the transcript's mtime.

**`TaskStatus.interrupted` shipped.** A subagent the user killed mid-turn kept the `tool_use` stop reason of the step it was on and read `working` forever — 4 of the 215 subagent transcripts on this machine, every one still spinning. `SubagentStatusDeriver` now reads an `[Request interrupted by user]` line in the transcript's **last message** as `interrupted`. Two things keep it conservative. It is checked last, so it can only ever replace `working`: a parent completion, an `end_turn`, a pending question and a failure all still win. And only the last message counts — the fifth of those five transcripts carried the marker mid-file, was told to carry on, and ended `end_turn`. The parent is no help here: its recorded statuses are only `async_launched`, `completed` and `forked`, and nothing like "cancelled" appears anywhere in the corpus, so an interruption is knowable from the subagent's own file alone.

An interrupted subagent is finished as far as the rest of the app is concerned: it stops holding its tab at `working` (`TranscriptStore` counts only `working` subagents as activity), it lingers and folds into the completed row like a success or a failure, and it notifies nobody — the user did the interrupting. `StatusEngine.effectiveStatus` groups it with `needsInput` and `error`, since a working subagent cannot undo an interruption. It aggregates between `done` and `error`.

## The markdown renderer

Shared by the chat, the plan overlay and the file viewer, so none of these are plan-specific.

- [ ] Restyle a tool call's collapsed one-liner. `Bash(python3 - <<'PY')` should read `Bash: python3 - <<'PY'…`, with the tool's name in prose and the detail it carries in monospace.
- [ ] Fix numbered lists: seen live rendering every item with a `1.` prefix. Check that a list survives a blank line between items and a wrapped item, then fix what doesn't.
- [ ] Syntax-highlight code blocks.
- [x] Give code blocks more padding inside their border, and a copy icon while hovering them.
- [ ] Distinguish a bash block's input from its result — they currently render alike.
- [ ] Put real newlines in a bash input block.
- [ ] Size inline code inside a heading to the heading, not to prose. `MarkdownView.heading` builds its text through `inline(_:)`, which is `MarkdownCache.styledInline(text, fontSize: typography.bodySize, …)` — so a code run gets `Font.system(size: bodySize * 0.92, design: .monospaced)` written straight onto it, and that font wins over the `headingFont(level:)` applied to the whole `Text`. A heading naming a type in backticks therefore drops to body size mid-line. The size has to come from the heading's own level, which means `styledInline` taking the size the caller is rendering at rather than always the body's — and the size already keys the cache, so a per-level size needs no new invalidation.
- [x] Mermaid diagrams in the same renderer.

**The one-liner is a flat `String`, which is what blocks the styling.** `ToolCallSummary.summary` formats `Name(detail)` and hands back one string, stored as `ToolCall.summary` and drawn by `ToolCallRow`'s `Label`. Styling only the detail means the summary stops being a `String` — either a small struct of name plus detail, or an `AttributedString` built where the fonts are known. Whichever it is, the elision at 60 characters has to keep applying to the detail alone.

Not every detail is code, so the table needs to say which are. A `Bash` command and a `Grep` pattern are; the `Agent` row's `subagent_type: description` is prose and would read badly in monospace; a `Read` or `Edit` filename and a `WebFetch` host sit in between. Decide per case in `ToolCallSummary.detail`, where the tools are already enumerated. Note the trailing `…` in the wanted form appears whether or not the text was elided, unlike today's marker, so say which is meant before implementing it.

**A blank line between items is the likely cause.** The marker is positional — `MarkdownView` renders `\(index + 1).` from the item's index within its block — so an all-`1.` list means each item became a block of its own rather than a mis-numbered one. `MarkdownBlock.parse` builds a `numberedList` from *consecutive* lines that `numberedItemText` accepts, and stops at the first line that isn't one. A blank line between items ends the list, and the next item starts a fresh one at index 0. A wrapped item is the second suspect: its continuation line stops the list too, and falls through to a paragraph. Both are ordinary output from an agent, so confirm which one produced the case seen live before changing the parser. Note also that the source's own numbers are discarded, so a list starting at 3 renumbers to 1 — worth deciding on while the marker is in hand.

Padding and the copy icon shipped together in `MarkdownView`'s `case .codeBlock`. The icon is an `overlay` on the background container rather than inside the horizontal `ScrollView`, so it stays pinned instead of scrolling away with the code, and it reveals on hovering the block rather than the button itself. It copies the block's raw `code` string, and introduced the app's first `NSPasteboard` use.

Tables shipped native and did **not** settle the mermaid question. The two are separate problems: a table's layout is given by its source, so `Grid` is the whole implementation, while a diagram needs a layout *algorithm* — node ranking and edge routing — which is the entire job and shares nothing with tables beyond the fence.

**Mermaid shipped on WebKit**, which was the open decision. A native subset degrades badly the moment a diagram uses an unsupported shape, and that argument decided it. `MarkdownView`'s `case .codeBlock` branches on the `language` the fence already carried, so the parser did not change; `MermaidBlock` renders the diagram and `MermaidDocument` builds its page. mermaid **11.4.1** is vendored under `Plume/Resources/Mermaid/` with its MIT license, so rendering works offline. Synchronized groups flatten resources into `Contents/Resources`, so the page loads through `loadHTMLString(_:baseURL:)` with that directory as its base and a relative `<script src>` resolves against it — no `WKWebViewConfiguration` tweak, no entitlement, and no file-access preference was needed.

Sizing is what keeps the chat safe. The page posts its rendered height back over a `WKScriptMessageHandler` once mermaid resolves, and the row takes an explicit frame from it, so a row settles at one height rather than resizing — a view that kept resizing would reopen the placement loop in `docs/chat-list-hang.md`. Until that height arrives, and permanently if mermaid rejects the source, the existing code-block rendering shows the raw fence instead, so the row is never blank. Copying still yields the source rather than the drawn diagram. Both outcomes log to `Log.app`, which is how rendering is verified without a screenshot.

Diagrams and tables then centered, and a tall diagram gained a way to be read. `MermaidDocument` grew a `Sizing` axis: `natural` keeps the diagram's own height and reports it, while `fit` scales the SVG down to its container in both axes. Both center it. A diagram taller than `MermaidLayout.maximumInlineHeight` (420pt) takes that height as its frame and re-renders `fit` inside it, so a 4000pt diagram no longer owns the whole viewport. The frame stays explicit either way, so the row still settles; the capped re-render's own report is ignored, since taking it would shrink the frame, which would rescale, which would report again. A hover-revealed expand button beside the copy icon opens the diagram in a sheet at `fit` sizing, which is where the detail now lives. The sheet is raised from `MermaidBlock` itself rather than from `ChatTabView`, so the plan overlay and the file viewer get it for free.

The fullscreen sheet then gained pinch-to-zoom and scroll-to-pan, on top of that `fit`-capped inline block staying exactly as it was. Its web view is a plain, magnifying `WKWebView` — `allowsMagnification = true`, driven by pinch gestures and by ⌘+/⌘-/⌘0 toolbar buttons that set `magnification` through a small `MermaidZoomController` — rather than the inline block's `NonScrollingWebView`, which still forwards every wheel event to the chat list and has no zoom of its own. A third `MermaidDocument.Sizing` case, `fitZoomable`, is what makes that safe: `WKWebView` magnification scales the whole page, so past 1x the page grows past its viewport, and `fitZoomable` lets it overflow (with the scrollbar hidden and `overscroll-behavior: none`) instead of clipping like `fit` does — that overflow is exactly what turns a two-finger scroll into panning. At magnification 1.0 it renders identically to `fit`.

## The composer

- [x] Give the first message a nicer intermediate state. The composer currently disappears before the message appears; disabling it in place would read better.
- [x] Make the composer content-width rather than bleed-width.
- [ ] Echo a CLI-intercepted slash command locally, and show that it is running.
- [ ] Autocomplete slash commands in the first message. A tab with no session yet offers none at all, so the one message most likely to be a `/` command is the one with no help typing it.
- [ ] `/btw` support. Confirming the note is actually filed on this transport is the first step of the work, not a precondition for starting it; then show it in the chat. It takes no turn, so today nothing in the UI changes when you send one.
- [x] Tell `<local-command-caveat>` apart from `<local-command-stdout>`. They share one case, so the caveat's boilerplate and the real output render alike.
- [x] Title a command-output row with the command that produced it.
- [x] Render a command-output body as markdown. It is monospaced plain text today, so a `/context` dump shows raw table source.
- [x] Decide whether the rejection-feedback submit button belongs inside the text field. It stays beside it.
- [ ] Command execution mode. A leading `!` means "run this rather than say it", the way the CLI's bash mode does. While the message starts with `!`, style the rest of it monospaced — plain monospace, no code-chip background, so it reads as a different mode rather than as an inline code span.
- [ ] Drag and drop an image into the chat to attach it to the next message. Dropping a file on the conversation or the composer should stage it, show it before it is sent, and let it be removed again.
- [ ] Spellcheck the composer, the way every other Mac text field does.

**Spellcheck is off because nothing turns it on.** `MarkdownComposerTextView.setUp` disables the substitutions a prose field should not have — smart quotes, dashes, text replacement — and enables automatic spelling *correction*, but never `isContinuousSpellCheckingEnabled` (`MarkdownComposerTextView.swift:317-321`), so misspellings go unmarked while autocorrect silently rewrites them. Turning the underline on is the change; the thing to check is how it interacts with `MarkdownComposerStyler`, which reapplies attributes as you type and could fight the checker's temporary marks.

**Images arrive today, but only from the agent's side.** The transcript already carries them: `ChatImage` holds base64 that `ChatImageCache` decodes and `ChatImageView` renders, so an image the agent produced or the CLI read shows inline. Nothing goes the other way — the composer has no drop destination, no paste handler for image data, and `submit(text:)` sends text alone. So the work is a staging area beside the composer plus whatever the headless transport accepts as image input; settle that wire question first, since it decides whether Plume sends the bytes or writes the file somewhere and sends a path.

**The composer paints no surface of its own.** Its text, its control strip, and the queued-messages strip that floats above them all sit directly on the floating panel's glass, at one `composerFieldInset` from that edge. The text view's own line-fragment padding covers part of that inset, so the first glyph lines up with the control strip's left edge rather than sitting further in; its built-in vertical inset does the rest of the top spacing's work. `composerFieldCornerRadius` — `ComposerPanelMetrics.concentricRadius` of the panel's own radius at that same inset — still shapes the queued-messages strip and the slash-command popup, the two things that keep a fill of their own now that the field itself doesn't. `ComposerControlsRow`'s segments take `composerControlHeight`, the 22pt the send and stop circles already used, so the strip is one band rather than labels of assorted heights.

**The composer stays put through the first message.** `emptyState` keeps it mounted and `disabled` once a session exists rather than dropping it, so it no longer vanishes between sending and the first line of transcript arriving.

**The rejection-feedback button stays beside the field.** Return does submit from inside the field, so an inline button would duplicate that gesture — but the button is not only a submit control. Its label flips Reject → "Give feedback" the moment the user types (`PlanRejectionLabel`), and that is the only thing on screen that says what Return will do. It also has to sit next to Approve for the two decisions to read as a pair; inside the field, one of two equal options would hide inside the input for the other.

A slash command the CLI handles itself never reaches the transcript, so the chat shows nothing at all while it runs. `/compact` is the case that hurts: this project's transcript holds **11** `compact_boundary` markers and **zero** `/compact` user messages, and compaction takes upwards of a minute and a half with no message, no spinner and no sign the command was received. `submit(text:)` only sends; the chat renders from the transcript, so anything the CLI intercepts vanishes. The fix is a locally-rendered echo plus a working indicator, driven from Plume's own state rather than the transcript — and it generalizes past `/compact` to every intercepted command.

Command mode has a styling half and a behavior half, and the styling half stands alone. `MarkdownComposerStyler` already turns a recognized slash command's token accent-colored via `SlashCommandMatcher.recognizedCommandRange`, so a line-leading `!` is the same shape of check: recognize the prefix, then restyle the remainder. What it can't reuse is `MarkdownHighlighter`'s `.inlineCode` span — that one carries `codeBackgroundColor`, which is exactly the chip look this shouldn't have. So it wants either a new style case with font but no background, or a direct attribute pass beside the slash-command one. What the `!` then *does* on send is the open half: the CLI intercepts its own bash mode, and Plume's `send()` hands text to `HeadlessSession.submit(text:)`, so a `!` message either passes through and relies on the CLI, or Plume runs it and echoes the result itself — the same locally-rendered-echo problem `/compact` has.

`/btw` is the sharpest case of that same problem, and needs nothing new to *send*. Slash commands are discovered rather than hardcoded — `HeadlessSession` reads them from the `initialize` reply's `commands` array (`HeadlessSession.swift:283-293`), so `/btw` already autocompletes and already styles as recognized if the CLI reports it. What it lacks is any evidence of having worked: it files a note without taking a turn, so there is no assistant message, no tool call and no transcript line to render — the composer just empties and the chat looks identical. That makes it a better first case for the local echo than `/compact`, which at least has a `compact_boundary` marker to anchor on. Checking whether the note is filed at all on this transport is where the work starts, since a silent no-op and a working command are indistinguishable from the UI today — and the answer decides whether the rest is a rendering job or a transport one.

**The first message has no slash-command autocomplete, because the list is a session's answer.** `ChatComposer.availableSlashCommands` returns `[]` outright when `headlessSession` is nil, and `ComposerAutocompleteController.update` shows nothing for an empty list — so a cold tab offers no completions, no descriptions and no argument hints. The names come from the `initialize` reply's `commands` array (`HeadlessSession.applyReportedCommands`), which cannot arrive before the process starts, and starting a process just to populate a menu is the wrong trade for a tab the user may never send from.

The list is a property of the CLI installation rather than of a conversation, so remembering the last one is the obvious shape: show the remembered list before `initialize`, then replace it with what the session actually reports. That is the same guess-then-correct pattern the model and permission-mode controls already use, and `HeadlessSession.hasReportedModeAndModel` is the precedent for saying on screen that a value is not yet confirmed. Two smaller things fall out of it. `PlumeSlashCommand.all` — `/rc` today — is Plume's own and needs no session to be *listed*, though whether it can be *run* before one exists is a separate question. And a remembered list goes stale when the user adds or removes a project command, which argues for correcting it on every `initialize` rather than caching it once.

A command's *output* is already classified and already rendered: `<local-command-stdout>` and `<local-command-caveat>` both become `InjectedContent.commandOutput` (`InjectedContent.swift:18`, classified at lines 86-88), and `ChatPieceView` sends every injected block to `InjectedContentRow` — the same collapsed marker row the "Compacted context" summary gets, full-width rather than in a user bubble. So these three extend a working path. Sharing one case is what costs the caveat and the output their distinct labels, and `command-args` is parsed nowhere, so a row cannot name the command it came from. The markdown item carries the only real decision: the expanded body is a monospaced `Text` (`InjectedContentRow.swift:36-44`), and swapping in `MarkdownView` would change every injected kind at once — shell output and skill bodies included, where monospace is right. It wants to be per-kind. Note also that this row hand-builds its disclosure from a `Button` and a chevron while `ToolCallRow` and `SubagentListView` use `DisclosureGroup`; settle on one before a third caller arrives.

**All three shipped, and the disclosure settled on `DisclosureGroup`.** `commandCaveat` is now its own case, labelled "Command caveat", so the boilerplate no longer reads as output. `classify` parses `<command-args>`, which the slash-command label appends to the name, and `TranscriptParser` carries the last slash command forward as `precedingCommand` so a `<local-command-stdout>` line — which names nothing itself — titles as "Output of /context". The carried command clears on the next injected line other than the caveat, which sits between a command and its output, so a stray stdout cannot borrow an old title. Body rendering is a per-kind `InjectedContent.BodyStyle`: markdown for `commandOutput`, `commandCaveat` and `compactSummary`, monospace for everything else, since a skill body, a `<system-reminder>` and shell output are all literal blocks where the wrapper tags matter. A markdown body first drops its wrapper element through `bodyText(_:)`, which unwraps all-or-nothing so anything that is not one whole `<tag>…</tag>` is left untouched.

## The statusline

`HeadlessSession` now owns `permissionMode`/`model`/`effort` as observable state, set optimistically when the host asks for a change and corrected from the stream (`system`/`init` for model and permission mode — there is no `set_effort` control request, so effort is never corrected, only ever what this host last sent). The strip and composer read this instead of the transcript, fixing the old bug where a control wrote through the session but displayed transcript state.

Still open:

- [x] Stop accumulating `total_cost_usd`. It is already a running conversation total, so `+=` re-adds every prior turn and the displayed figure compounds. Assign it instead, and correct `docs/headless-protocol.md`, which records the wrong semantics.
- [x] Move the stop button out of the statusline and put it left of the send button — a circular icon button with a dim background, mirroring send's shape.
- [x] Consider moving the whole strip inside the composer box, if a compact form fits a narrow viewport. It sits below the composer instead.
- [x] Make the composer and statusline one floating glass panel rather than a full-width bar: the statusline sits below the composer behind a divider, and the minimized plan panel docks above the composer behind a divider when it is present. Polish the plan overlay's show/hide with a transition that shows continuity between the docked bar and the expanded overlay — a zoom from the bar's frame, probably. `PlanPresentation.minimized` already docks the bar above the composer, and the overlay uses the `planGlass` material, so the panel extends that look rather than inventing one.
- [ ] Customization UI, once a segment shape settles. `ComposerControlsRow`'s segments are already self-contained — each reads and writes only its own piece of session state — so this is additive, not a rewrite.
- [x] Give each control an icon: `brain` for model, the `gauge.with.dots.needle.0percent` family for effort, and one per permission mode — `bolt.fill` for auto, `doc.text` for plan (matching the plan button's own icon), `pencil.line` for accept-edits, `exclamationmark.triangle.fill` for bypass.
- [ ] Collapse the controls to icons alone at narrow widths, dropping the text.
- [ ] Tooltip what a chip abbreviates — the working directory's full path above all.
- [x] The composer's two-row split is a first cut (plain `HStack`s, no styling pass) — revisit layout and spacing.
- [x] Remember effort and permission mode per session, the way the context window already is.
- [x] Offer model, effort and permission mode before the first message, when a tab has no session yet. All three controls now read and write the tab until a session exists.
- [x] Confirm a resumed tab ends up on the conversation's real model and permission mode, not the seeded snapshot. Verified by reading the code; the seeded pair now dims until `init` confirms it.
- [ ] Take effort from the resumed conversation too, once the CLI reports it back at all.
- [x] Label the smaller-window models 200K. The three `AgentModel.more` labels, the doc comments around them, `docs/headless-protocol.md` and the tests asserting the labels all say 200K now, matching what `nominalContextWindow` and the meter already reported.
- [x] Work out why the branch segment says "no upstream" for a branch that has one. `GitState.hasUpstream` read the tracking fact off the ahead/behind counts; it now parses `# branch.upstream` for itself.
- [x] Show the values a fresh tab will actually start with, rather than blank controls. All three now fall back to the resolution the launch performs.

**Icons, a narrow form, and tooltips are one pass over `ComposerControlsRow`.** They share a shape: each segment renders through `segmentLabel(_:foreground:height:)`, a bare `Text` with no image, so an icon is one change at one call site rather than four. Three things to settle while doing it.

The permission modes are four, not the three that obviously map. `PermissionMode` is `plan`, `acceptEdits`, `auto` and `bypassPermissions` — so `acceptEdits` needs an icon of its own, and which of them the `info.circle` "ask" icon belongs to is a naming question as much as an icon one. Effort's family gives the levels a natural ladder (`…needle.0percent` through the higher fills), which is worth using rather than one gauge for all of them.

An icon-only form needs the width to decide from and a label to survive on. Every segment takes `.fixedSize()` and the row spaces itself by `panelContentInset`, so nothing measures the available width today — `onGeometryChange` on the row is where that would come from, matching how `ChatTabView` already measures the panel. Dropping the text also drops the only thing naming the control, so the collapsed form is where the tooltips stop being a nicety: `ModelControl`, `PermissionModeControl` and `EffortControl` each already carry `.help(…)`, and those strings currently explain state rather than name the segment.

The workspace chips are the tooltip gap. `WorkspacePickerView.folderChip` shows only the last path component and already attaches `.help` with the tilde-abbreviated full path (`WorkspacePickerView.swift:77`) — worth confirming that help actually surfaces through the `Menu` it wraps before writing new ones. `worktreeChip` has none at all, so a branch name is all there is; its path is the more useful thing to show, since two worktrees of one repository differ only there.

**The bottom chrome is one floating panel, content width, over the conversation.** The statusline and composer surface no longer spans the pane edge to edge: it takes the content column — the same measure the prose above it wraps at — rounds all four corners to `panelCornerRadius`, and leaves `panelInset` below itself, so it reads as a panel resting over the chat rather than a bar bolted to it. It overlays the message list rather than stacking below it, so the conversation scrolls behind the glass instead of ending at its top edge: `ChatTabView` measures the panel with `onGeometryChange` and hands the height to `ChatMessageList`, which adds it to the list's bottom padding and lifts the jump-to-bottom button clear. Nothing in the panel is sized from that height, so the measurement cannot feed itself. There is exactly one drawn surface: the plan bar (when docked), a divider, the composer, another divider, and the statusline all sit on the same glass, with no box of the composer's own nested inside it. Every other measurement derives from `panelCornerRadius` through `ComposerPanelMetrics`, which is why the panel's inset and the floating popups' corner radius are one decision rather than two literals. The `GlassEffectContainer` that used to hold the panel and a separately-surfaced dock bar together is gone — one surface has no other surface's shadow to keep off itself.

**The strip moved below the composer, and stayed a strip.** The panel now runs composer, divider, then the session facts — where this runs, context, quota, cost and Remote Control (see [Below the composer](#below-the-composer) for the layout they settled into). Folding the strip into the composer box was weighed against that at a narrow width and lost: the controls row already fills the box with a workspace picker and three menus, so a compact form has nowhere to put four more segments but a second line inside the field — which is the two-row split again, one row deeper, and it puts what the session has spent inside the box for the message being written. As a footer the strip truncates gracefully instead, and the divider keeps the two readings apart.

**The plan bar docks as the panel's top row.** It sits inside the same glass as the composer and statusline, above a `Divider()` that appears and disappears with it, and takes the same `composerFieldInset` horizontal inset as every other row rather than stepping in behind the panel's own corners. Its top corners are the panel's own rounded corners, clipped by the panel's shape rather than rounded on their own. Expanding it is still a `matchedGeometryEffect` zoom from the bar's frame rather than a generic scale — the namespace lives on `ChatTabView`, since the bar and the overlay are separate view trees, and the bar's own transition dropped to opacity so it does not fight the frame the zoom interpolates.

**The session cost is fixed.** `total_cost_usd` is a running total for the whole conversation, re-sent on every `result` event — Plume accumulated it, so each turn re-added every turn before it. Confirmed on the wire: turn 1 reported $0.2548 and turn 2 $0.2996 for a turn that emitted a single digit. Assigning instead of adding also makes the figure correct across a `--resume`, since the first `result` after resuming already carries the true total. `docs/headless-protocol.md` recorded the opposite and was corrected in the same change.

The stop button now sits in the composer beside send — a 22pt circle matching send's shape with a dim fill rather than the accent one, so the pair reads as two related controls. Both show at once: `isWorking` and `hasSendableText` are independent, and stop replacing send would hide the ability to queue a follow-up.

`TaskTab` now snapshots permission mode and effort alongside `contextWindowTokens`, written from `ChatTabView` when the session's value changes — once per turn rather than per stream event. Launch resolves the mode tab → task → app default, so a tab reopens in the mode the user last saw it in and the default only fills in for a tab that never had one. Effort has no launch flag and no `set_effort` control request to report it back, so the snapshot is its only record across a relaunch; it seeds `HeadlessSession` directly at construction rather than through `setEffort(_:)`, which would submit a real turn.

**The controls now render before the first message.** `ComposerSettings` is the one seam: it holds the tab and the optional session, and every read and write picks between them. Before launch all three controls are the tab's own persisted values — which is exactly what `AgentLauncher` launches from, so setting one is what the first turn runs with rather than a preference the launch would ignore. Once a session exists its live values take over. Model was the one gap and is closed: `TaskTab.model` persists as `modelRaw`, and `HeadlessCommand` grows a `--model` flag that is **omitted entirely** when no model was chosen, so an untouched tab still gets the CLI's own default rather than a guess Plume invented.

The model list needed no new source, and there is none to be had: the `init` event reports only the model in use, and `capabilities` names protocol features rather than models. So `AgentModel` carries a hand-maintained list of presets — Fable, Opus, Sonnet and Haiku 4.5 on the top level, the 200K variants under a "More" submenu — plus an "Other…" field for an ID this build has never heard of. It is a struct over a CLI model ID rather than an enum, because the set is open.

**Resuming is confirmed correct, by reading the code.** The `TaskTab` write-back cannot clobber the `init` correction, because it only ever runs session → tab: `ChatTabView`'s `onChange(of: headlessSession?.model / .permissionMode)` reads the session and writes the tab, and nothing reads the tab back into a live session. The only tab → session direction is `AgentLauncher`'s seeding, which runs once at launch, strictly before any `init` can arrive. So the sequence is seed → `init` overwrites the session → `onChange` fires → the *corrected* value reaches the tab; the stale snapshot has no path back. `initializedCorrectsBothSeededValuesAtOnce` locks the correction itself down.

The seeded value is now visibly a guess. `HeadlessSession.hasReportedModeAndModel` is false until `init` arrives, and the model and permission-mode labels render at reduced opacity with a "not yet confirmed by Claude Code" tooltip while it is. Effort is deliberately excluded from that dimming: nothing ever reports it back, so it would dim forever and the signal would stop meaning anything.

**Resuming already corrects two of the three, and cannot correct the third.** Resume is not a separate path — `launchHeadless` takes a `resumeSessionID` and otherwise seeds from `tab.*` exactly as a cold launch does, so both a relaunched app and a chat resumed into a new tab start from the snapshot rather than from the conversation. That snapshot is only a starting guess, and the stream fixes it for `model` and `permissionMode`: the `init` event reports both, and `handle(_:)` overwrites the seeded values with whatever the CLI actually resumed with (`HeadlessSession.swift:227-232`). Effort is the exception, and structurally so — no `set_effort` control request exists and nothing reports effort back, so `initialEffort` is never corrected and the control shows what this host last sent, which a `/effort` typed straight into the CLI would silently contradict. Until the protocol reports effort, the snapshot is the best available answer rather than a bug to fix. Both of the things worth checking about the other two have now been checked — see the confirmation paragraph below.

**The controls name a default rather than going blank.** A tab that has chosen nothing still launches on *something*, so `ComposerSettings.Defaults` resolves what that is and every unset control displays it. Permission mode reuses `AgentLauncher.resolvedPermissionMode` (tab → task → app default), so the composer and the launch cannot disagree. Effort gained an app-level default — `AppSettings.defaultEffort`, Medium, in the Settings window beside the other defaults — because nothing reports effort back and the control would otherwise stay empty forever. Model reads the CLI's own configuration: `ClaudeCodeSettingsResolver.resolvedDefaultModel` takes `model` from `~/.claude/settings.json`, with `settings.local.json` overriding, and maps aliases and full IDs onto `AgentModel`. A defaulted model renders as "Default (Opus)", and the menu offers that same "Default (…)" as a selectable item that clears the tab's pick. It renders in the normal foreground: dimming is reserved for a *running* session whose `init` has yet to report, where the value really is a guess.

Displaying a default never writes one. The tab stays unset until the user picks, which is what keeps `--model` off the command line — the "omit when unchosen" rule is unchanged.

**`--model` is omitted on a resume unless the user picked the model since.** Established by experiment, not documentation: a bare `--resume` restores the model the conversation already used, and `--model` on a resume overrides it (the three `init` events are recorded under "Model on resume" in `docs/headless-protocol.md`). That makes replaying a snapshot actively wrong — `tab.model` is overwritten by whatever the session reports, so it records what the conversation ran on, not what the user wants. `TaskTab.isModelUserChosen` separates the two: `ComposerSettings.setModel` sets it, the session's write-back in `ChatTabView` clears it, and `HeadlessCommand.arguments` passes `--model` on a resume only when it is set. A cold launch is unaffected, having no conversation to restore from.

**Seen live on 2026-09-05:** switching a running tab from the terminal transport to headless resumed the conversation in plan mode although it had been running in auto mode. Either the tab snapshot seeded a stale mode that the `init` correction did not override, or the resume command passed a mode flag the CLI honored over the conversation's own. Reproduce with a tab whose mode was changed mid-conversation, then resume it, and compare the `init` event's `permissionMode` with what the control shows.

**"no upstream" was a parse that read tracking off the wrong header.** `# branch.upstream` names the tracked branch; `# branch.ab` carries only the counts, and git prints the first without the second whenever it cannot compare the two — a remote-tracking ref deleted, pruned, or never fetched. `GitState.hasUpstream` was `ahead != nil`, so every such repository read as untracked. Reproduced by deleting `refs/remotes/origin/main` from a clone: `git status --porcelain=v2 --branch` then prints `# branch.upstream origin/main` and no `# branch.ab` at all. `GitState` now parses `upstream` as its own field and `hasUpstream` asks that; `GitStateTests` covers both the header fixture and a real clone whose remote ref is gone.

Two related fixes went in beside it. The segment no longer names one branch while reporting another's upstream: the chip labels `GitState.branch`, so the name and the markers beside it come from one `git` run, with the task's own branch only as a fallback before git answers. And `GitStateStore` watches `rev-parse --absolute-git-dir` rather than `<root>/.git`, which in a linked worktree was a pointer file that never changes — a worktree's state was only ever as fresh as the 15s poll.

## The plan overlay

Today the overlay never opens on its own: `planPresentation` starts `.closed` (`ChatTabView.swift:13`) and every assignment of `.expanded` sits behind a button (lines 146, 204), so it is a viewer the user opens rather than a presentation the agent triggers. It should be both — presenting a proposal for approval, and reviewing the plan once approved.

- [ ] Make Return in the feedback field send the feedback. It approves the plan instead, which is the opposite of what the field invites.
- [ ] Give the feedback field the composer's text: the same font, and the same basic markdown styling as you type.
- [ ] Confirm multi-line feedback and the send-key setting actually work, once Return reaches the field at all.
- [ ] Keep an undecided plan reachable: while a proposal is awaiting a decision, minimize is the only way out of the overlay. Hide the close button and drop its ⎋ shortcut, and hide the dock bar's close button too, so the plan can never leave the screen entirely before it is approved or rejected.
- [x] ⌥↩ approves with feedback — the CLI's third option: take the note and auto-approve whatever plan comes back. Caption it beneath the field, since nothing else reveals the key. The note cannot ride the permission response: `ExitPlanMode` declares no input fields, so an extra `updatedInput` key is dropped silently, and there is no allow-with-message. It follows the approval as an ordinary user turn, which queues behind the approved turn and lands when that turn ends — exactly when it should steer the next plan. Payload recorded in `docs/headless-protocol.md`.
- [x] Label the reject button "Reject" until the user types, then "Give feedback". `PlanRejectionLabel` owns the rule, and `ReservedWidthButton` lays out both labels hidden so the button cannot resize under the pointer.
- [x] Confirm **Approve** starts work in auto mode where that is enabled. `HeadlessSession.approvePlan` sends `set_permission_mode` with `auto` right after allowing the call, so the session leaves plan mode on approval; confirmed from the code path, not from a live run.

**The overlay always reads the file.** An `ExitPlanMode` input carries both `plan` (the markdown) and `planFilePath` (`InteractiveToolPayload.swift:41`), and the latter is the same path `TranscriptParser` records from the `plan_mode` attachment line and the overlay already renders. So the two content sources are one: the overlay keeps its existing `MarkdownFileStore` path unchanged and gains live updates for free if the plan is rewritten. The payload's markdown is not a second source to merge; it is what the inline row summarizes.

**An undecided plan should not be closable.** Both the panel header and the dock bar carry a close button that sets `planPresentation = .closed` (`ChatTabView.swift:345-354`, `500-508`), and the panel's also answers ⎋ through `.keyboardShortcut(.cancelAction)`. A user who closes a live proposal loses the only place the approval options are shown, while the request stays open on the wire. Gate all three on whether a proposal is awaiting a decision — the same state the footer table keys off — leaving minimize as the only exit. Closing stays available once the plan is approved or rejected, where the overlay is just a viewer again.

**Interrupting the reader is fine**, as long as the overlay can be minimized — which it already can (`PlanPresentation.minimized` docks it as a bar above the composer). So a proposal expands over the conversation and the user dismisses it if they were mid-thought; no special quiet-arrival case is needed.

**The footer has three states**, driven by where the plan stands rather than by how the overlay was opened:

| State | Footer |
|---|---|
| Proposed, awaiting a decision | The approval options |
| Approved | "Approved" |
| Any other time — before a proposal, or after a rejection | "Not approved yet" |

"Not approved yet" deliberately covers both of the third state's situations — never proposed, and proposed then rejected — because the plan may have been rewritten since the rejection, so saying anything about that rejection risks describing a document that no longer exists. It speaks only to the state that is still true.

**⌥↩ is the one key worth captioning**, because nothing on screen reveals it and it is the only way to reach the third option. It resolves the request as an approval while passing the typed note along, so it needs a control request that carries both — unlike **Approve**, which sends no message, and **Give feedback**, which denies through `PlanResolution.denialMessage`. The caption reads "⌥↩ approves with this feedback".

**"Give feedback" mislabels an empty field.** With nothing typed the button is a plain rejection, and `denialMessage(reason:)` already says so on the wire — it trims the reason and falls back to a bare rejection prefix when it is blank (`PermissionAnswerState.swift:98-102`). So the label should read "Reject" until `planRejectionReason` is non-empty and "Give feedback" after, matching a distinction the wire format already makes. Watch the button width changing mid-type; the tab chip's reserved close-button slot is the precedent for keeping a control from resizing under the pointer.

**Return approves rather than sends feedback.** Seen live on 2026-09-05. The field already carries everything the behavior needs on paper — `axis: .vertical` with a 1–6 line limit, and an `.onKeyPress(.return)` handler that routes through `PlanFeedbackKey.forReturn`, which states `composerSendKey`'s rule over modifiers alone so this `TextField` obeys the same setting the composer does. What it is up against is the Approve button beside it, which takes `.keyboardShortcut(.defaultAction)` (`ChatTabView.swift:376-379`) — the first thing to check is whether that shortcut wins the Return keypress before the field's handler sees it. Multi-line entry and the send-key setting are unverifiable until that is settled, so treat them as unconfirmed rather than shipped.

**The field is a plain `TextField`, and should be the composer's editor.** `planApprovalOptions` uses `TextField(…, axis: .vertical)` with `.roundedBorder` and the caption font (`ChatTabView.swift:361-364`), while the composer is `MarkdownComposerTextView` with `MarkdownComposerStyler` giving it the prose face and live markdown styling. So the same note reads as two different kinds of text depending on where it is typed. Sharing the composer's editor is also what would settle the Return question by construction — `ComposerNSTextView.keyDown` reads a real `NSEvent` and never competes with a SwiftUI default action, which is exactly why `PlanFeedbackKey` had to restate the rule in the first place.

One thing to get right: a plan file exists *before* it is ever proposed. `TranscriptParser` records `planFilePath` from a `plan_mode` line as well as `plan_mode_exit` (`TranscriptEntry.swift:238`), so the agent writing a plan is enough to make it viewable. That is the same third state, and it means the footer cannot be derived from the file's existence — it needs the state of the most recent `ExitPlanMode` call and its answer.

## Interactive rows: plans and questions

- [ ] Clean up the permission prompt's layout, and bring it closer to the question card's. The two ask for a decision in the same place and should read as one family.
- [x] Let a question be answered free-form as well as by option. Claude Code's own prompt always offers an "Other" escape hatch; Plume's card offers only the listed options, so a question whose real answer isn't among them has nowhere to go but the composer.
- [ ] Settle how a compacted context reads. It arrived rendered as an ordinary message from the user, which it is not; it now collapses to a marker row labelled "Compacted context". Whether that is the right disclosure — a marker, an expandable row, or something else — is still open.

**The two rows already share a container and diverge inside it.** `PermissionRequestRow` and `InteractiveToolRow` both draw a 12pt-padded, 10pt-rounded, bordered card, so the outer shape needs nothing. What differs is everything within: the permission row's deny reason is a bare `TextField` with `.roundedBorder`, its Allow/Deny sit in a plain `HStack` of default buttons, and its input fields are key/value pairs in a 220pt-capped `ScrollView` — while the question card composes a header, structured options and a free-form field through `PermissionAnswerState`. Decide which of those differences are the tool call's nature and which are only drift; the fields' scroll box is the clearest case of the former, since a whole file body has to go somewhere. The plan feedback field wants the composer's editor for the same reason ([The plan overlay](#the-plan-overlay)), so settle the field treatment once across all three rather than per row.

**Free-form answers shipped.** The wire needed nothing new: an `Answer.questions` payload is already question text -> an arbitrary string, so typed text rides the control plane as-is. A question is now answered by chosen options *or* typed text, never both — setting either clears the other, so `isComplete`, `answers(for:)`, the primary button's enabled state and what actually gets sent all read one source of truth per question. The field renders only on an answerable row, leaving the transcript's read-only copy unchanged.

The answers on a settled block come from the tool result's own text, parsed in `InteractiveToolPayload.answers(from:for:)`. The `updatedInput` that carries them to the model never lands back in the transcript, so that text is the only place they survive a reload. It is a fixed-format string rather than JSON, so the parse anchors on each known question's exact text and degrades to showing nothing rather than guessing.

**A resolved row still wants a settled state.** `InteractiveToolRow` is answerable only when a caller hands it an `answer` closure: `PendingPermissionDock` supplies one, `ToolCallRow` does not. While a request is live the dock's answerable row covers for the transcript's read-only copy underneath. What is still missing is a settled presentation for a rejected plan — "Rejected", with the reason — rather than the row simply falling back to its non-answerable rendering. (An earlier note here described a stale `answerHint("Approve or reject in the terminal.")`; no such hint exists in the code.)

## Chat spacing

- [x] Collapse the space between consecutive tool calls. Keep the current space where a tool call meets prose or any other block — a run of calls should read as one list, not as several separated statements.
- [x] Give a streaming response the same space above it that a finished one has. A reply sits tighter to the message above while it streams, then shifts down once the transcript takes over — so the text moves as the turn settles.

`ChatBlockSpacing` now decides every vertical gap in the chat from the kind of item above it: consecutive tool calls take `Dimensions.toolCallSpacing` (4), anything else takes `messageBlockSpacing` (8) within a message or `messageSpacing` (40) between two messages. Both gaps that made a run of calls read as separate statements are covered. The list carries no vertical inset of its own: every gap is the following item's top inset, which is the only shape in which one number can own it. `ChatPieceSplitter` assigns those insets when it builds the list's items, counting the previous *rendered* block, so a call the pending dock draws instead does not leave a gap behind, and a message the reader sees as tool calls alone continues a run through it.

The streaming overlay takes the gap it will have once it settles: after prose the text stays in the same message, so it takes the block gap; after a tool call the tool's result ends the assistant's run in the transcript, so the text retires into a message of its own and already sits a message apart. That is what stops the reply shifting as the stream retires — and what fixes the streamed text reading tight against the tool call above it.

## Chat animation

Two separate animations, to be taken one at a time and iterated on.

- [x] Animate the height of a chat row as it changes, so a row that grows or collapses eases into its new size instead of jumping.
- [x] Reveal streamed characters one at a time, rather than a whole paragraph appearing at once. Nothing fancy — the point is that text arrives at a readable pace.

What shipped:

- `AnimatedHeight` (`Plume/UI/Chat/`) measures an item's ideal height with `onGeometryChange` inside `fixedSize`, then drives an explicit `frame(height:)` from it. Measuring inside `fixedSize` is what stops the animated frame feeding back into its own input. The first measurement is assigned without animating, at `.easeOut(duration: 0.2)` thereafter.
- **Lazy-stack recycling never animates.** The modifier's `height` is `@State`, so a row the stack realizes starts at nil and snaps. A DEBUG probe counting first-versus-animated measurements read **520 first measurements and 0 animated** through a jump-scroll of a thousand-row transcript, then stopped counting entirely once the rows were built. Recycling costs a measurement, not an animation.
- **The item carrying the live stream is left unanimated**, because its height already changes every frame as the reveal draws; easing it only retargets an animation that never settles. Animating both together was the one configuration that tripped `detect-chat-hang.sh`. An item whose wash continues into its neighbours is left alone for a different reason: an eased height opens a seam in the join.
- `CharacterReveal` is an `Animatable` view whose `animatableData` is a `Double` count, and `RevealPacing` / `RevealProgress` hold the pacing. A reveal runs at 220 characters a second, capped at 1s and floored at 0.1s; every delta landing before the previous reveal's deadline multiplies the duration by 0.7, down to a quarter. So a delta mid-reveal shortens what is left rather than queueing, and the uneven rhythm that produces is the point. A reveal from rest eases out; a retargeted one runs linearly, so the curve does not also change speed at every delta.
- Both animations are `AppSettings` toggles in the Settings window, defaulting on and independent of each other.

What the harness showed (optimized build with the DEBUG flag, three seeded tasks on 8 MB and 13 MB transcripts, `PLUME_FAKE_STREAM=0.08`, `PLUME_CYCLE_SELECTION=1`, `PLUME_SCROLL_WHEEL=40`):

- Both animations on, before the streaming-row fix: `HANG` at t=221s. The sampled frames were plain layout work with no `signalPrefetch → requestUpdate`, and the main thread fell back to 6% on its own, so it was load rather than the recorded loop. Each half alone cleared 300s in the same configuration.
- After leaving the streaming row unanimated, both on cleared two consecutive 400s windows. Mean main-thread CPU over 60s: 39.9% with both off, 59.8% with both on.
- Under the gentler configuration (`PLUME_FAKE_STREAM=0.25`, `PLUME_CYCLE_SELECTION=3`, no wheel), mean CPU was 32.4% off, 38.4% with row height alone, 44.4% with the reveal alone. The reveal's cost is `MarkdownBlock.parse` and text typesetting running once a frame over the growing string, which `MarkdownCache` cannot absorb because every frame is a new key.

The constraints both items ran into:

- **The chat list is a `LazyVStack` that must not be driven programmatically.** `docs/chat-list-hang.md` records a hang where an animation in flight inside the lazy stack's placement pass never reached a fixed point: each pass moved the target, the prefetch asked for another, and the content grew underneath. The list now follows content through `defaultScrollAnchor(.bottom, for: .sizeChanges)` alone (`ChatMessageList.swift:113-114`), with no `ScrollViewReader`, no per-row `.id()`, no `scrollTo`. Row-height animation is the item closest to that failure — an animated height *is* a size change the anchor reacts to, on rows the stack is still estimating — so it wants the harness in that doc pointed at it before it is called done.
- **A per-tick animation next to this list has already been measured as expensive.** `ChatWorkingIndicator` explains why the working dot derives opacity from a `TimelineView` clock instead of using `phaseAnimator` or a `repeatForever` opacity animation: those rebuilt the whole chat tree ~37,000 times over 15 seconds. A character reveal is the same shape of risk, and the same escape hatch (drive from a clock, keep the redraw inside one view) is the thing to reach for.
- **The text to reveal already accumulates in one place.** `HeadlessSession.streamingText` appends `textDelta`s (`HeadlessSession.swift:281`), and a delta can carry many characters at once — which is exactly why a paragraph can land whole today. `ChatStreamHandoff.Overlay.text` is what `StreamingBlocks` draws, so the reveal is a rendering concern over a growing buffer rather than a change to the transport.
- **It can be driven without a live model.** `HeadlessSession.debugStream(text:restart:)` (DEBUG only, `HeadlessSession.swift:96-99`) feeds the live-text path with no process, so `SmokeHarness` can exercise a reveal against a transcript on disk.

## Terminal history restore

- [ ] Store a terminal tab's output and restore it, so reopening a tab shows what the last session printed.

What exists, and why this is harder than the chat side:

- **Nothing survives today.** Surfaces live across tab and task switches, since `TabContentView` keeps every tab mounted and only toggles visibility, and `SurfaceManager` returns the cached session. But `SurfaceManager` is in-memory only and holds no persistence, so a relaunch gives every terminal tab a fresh PTY with empty scrollback. `TaskTab` persists only small scalars — no bulk text, and there is no tee, ring buffer or recorder capturing PTY output anywhere in the app.
- **The chat's restore model does not transfer.** A chat tab restores because *Claude Code* writes a structured JSONL transcript and Plume stores only its path, watches it, and re-parses it (`SessionJSONLReader`, `TranscriptStore`, `TranscriptParser`). A plain shell has no equivalent — its history is rendered terminal output, already interpreted into a grid, with nobody writing a semantic log of it.
- **The C API supports both halves; the Swift wrapper exposes neither on the surface Plume uses.** `ghostty.h` declares `ghostty_surface_read_text` (with a `GHOSTTY_POINT_SCREEN` tag that reaches scrollback, not just the viewport) and `ghostty_surface_write_buffer`, which paints bytes into the grid for display without them reaching the child process. In the wrapper, both are called only from `InMemoryTerminalSession`, a separate headless backend Plume does not use at all; the real `TerminalSurface` wraps only `ghostty_surface_read_selection`, which returns a user's current selection and nothing without one. So capture and replay each need wrapper work before either is reachable — and per the "All `ghostty_*` calls stay in `Plume/Ghostty/`" rule, that work belongs in one folder.
- **`paste(text:)` is not the replay path.** It frames its argument as a bracketed paste into the running program's edit line, so restored scrollback would land as input to the shell rather than as prior output on screen.

## The context window meter

- [x] Work out why the meter reads a full window. **Diagnosed and fixed:** the numerator was measuring throughput, not context size.
- [x] Assume the denominator from the selected model, so the meter reads before the first turn completes.

What shipped: `AgentModel.nominalContextWindow` derives the assumed window from the ID — 1M for everything in `selectable` except `more`'s bare 200K variants, which report 200,000 (matching the real `modelUsage` figure the fixture carries). Nil outside `selectable`, so an unrecognized model assumes nothing. `HeadlessSession.nominalContextWindow` exposes `model?.nominalContextWindow`, and `ChatTabView`'s `StatuslineStripView` call now falls back to it, then to `tab.model?.nominalContextWindow`, only after both measured sources (`headlessSession?.contextWindow`, `tab.contextWindowTokens`) come up nil — a reported window still wins. The label stays undistinguished between measured and assumed, per plan.

**Root `usage` on a `result` event accumulates across the round-trips within one turn.** Each round-trip re-reads the whole cached prompt, and the root object sums those re-reads. `ContextUsage.total`'s four-way sum was therefore reporting cumulative token throughput for the turn rather than the size of the context. The two coincide only when a turn makes exactly one round-trip, which is why trivial probes and transcript sampling both looked correct for so long.

Measured on Opus 5, forcing tool calls:

```
num_turns (round-trips): 3
root usage: input 6 / cache_read 88,334 / cache_creation 28,094 / output 650
the single element of usage.iterations: cache_read 40,863
four-way sum: 117,084
```

Root `cache_read` is neither the max nor the sum of the `iterations` present — it exceeds the only iteration by more than 2x. A turn with many tool calls re-reads the prompt dozens of times, which is how the meter reached a reported **1.3M/1M**.

The fix reads the **last element of `usage.iterations`**, falling back to root `usage` when `iterations` is absent — that last round-trip is the prompt that was actually sent. `TranscriptUsage` needed no change: transcripts write one entry per round-trip, so their latest entry is already the last one, and no transcript entry on this machine exceeds 1M. `ContextUsage.total` stays shared between the live and transcript paths so a resumed conversation and a live one agree.

Ruled out along the way, and worth not re-testing: Plume does not accumulate (`HeadlessSession` and `TranscriptParser` both assign last-wins); the denominator is correct, since Opus 5 genuinely reports `contextWindow: 1000000`; and no model in use has a window below 1M, so a stale-window or model-switch mismatch was never involved.

**Assuming the denominator.** Every source of the window today is a completed turn: `HeadlessSession.contextWindow` is set from a `result` event's `modelUsage` (`StreamJSONDecoder.largestContextWindow`), and `TaskTab.contextWindowTokens` is only a snapshot of that. So `ChatTabView`'s `headlessSession?.contextWindow ?? tab.contextWindowTokens` is nil on a fresh tab, and `StatuslineStripView` has no denominator to print until the first turn ends. The model, by contrast, is known before the session starts — `TaskTab.model` is the launch pick and `HeadlessSession.model` is seeded at construction — and the ID already encodes the window: `AgentModel`'s `[1m]` suffix is exactly the 1M/256K distinction, and its doc comment records that an unspecified window means 1M. A nominal window per `AgentModel` would give the meter a denominator immediately, with the reported one still winning once a turn reports it. Two things to decide: what an unrecognized ID assumes (`AgentModel(unrecognizedID:)` keeps IDs this build has never seen), and whether the label should distinguish an assumed denominator from a measured one.

**The label stays unclamped, deliberately.** An earlier plan was to clamp `tokenLabel` and `percentage` so an over-count could not print a literal "1M/1M". That is rejected: the unclamped label is exactly what made this bug visible, and clamping would have hidden it while leaving the arithmetic wrong. `StatuslineMeterMath.fraction` still pins the bar to 0–1; the label is the honest signal and should stay that way.

## Running inside Plume

Let scripts and Claude itself know they're in Plume, and give Claude the formatting Plume can render.

- [x] Export an environment variable marking a shell as running inside Plume.
- [ ] Skills that prompt Claude to use richer formatting — diagrams above all — when it's running in Plume.
- [ ] Put Plume's own configuration in a config file — a superset of ghostty's, or a structured format of its own (TOML or JSON).

What exists:

- **`PLUME=1` shipped.** `LoginShellCommand.plumeEnvironment` (`["PLUME": "1"]`) is merged into the env at every seam that starts a shell — `ClaudeCodeProvider`'s terminal-agent launch, `AgentLauncher.launchHeadless`, and the plain terminal tab's `TerminalSurfaceOptions` in `TabContentView` — so every tab carries it, not just agent launches. `PLUME_TASK_ID` / `PLUME_TAB_ID` / `PLUME_EVENTS_DIR` are unchanged and still agent-only.
- Hook instrumentation already keys off `$PLUME_EVENTS_DIR/$PLUME_TASK_ID/$PLUME_TAB_ID`, and those are exactly the per-tab identifiers a general marker would sit beside. A bare `PLUME=1` answers "am I in Plume?" for a shell prompt or a script; it doesn't replace the per-tab IDs, which are what make captured output attributable to a tab.
- Config today is split: terminal behavior comes from the user's ghostty config, while Plume's own settings (worktree base path, provider, default transport, chat font size, quit confirmations, composer send key) live in `UserDefaults` behind `AppSettings`, reachable only through the Settings window. A file would make them diffable, shareable and version-controllable, which `UserDefaults` never will be.
- A superset is plausible because Plume already reads and rewrites the config rather than passing a path: `GhosttyConfigLoader` finds the file in ghostty's own search order, then hands libghostty *generated contents* with every `theme` line stripped, parsing line by line. Plume-specific keys would be stripped the same way — and they must be, since libghostty emits diagnostics for keys it doesn't recognize and `GhosttyRuntime` already logs them.
- A different format is worth weighing against the superset, not assumed away. TOML or JSON both express nesting natively, and JSON needs no dependency at all — `Codable` reads it, and the headless stream already parses JSON. TOML reads better by hand but means taking a parser. The cost either way is that Plume's config and ghostty's stop being one file, so the user keeps two — which may be honest rather than unfortunate, since the two configure genuinely different things. A middle path: keep terminal behavior in the ghostty config where it already lives and works, and give Plume's own settings their own structured file, rather than stretching a flat format to hold everything.
- Two things to settle first if the superset wins. Ghostty takes the first matching config file outright and never merges, so a Plume file that *is* the ghostty file means the user maintains one file for both, while a separate file means deciding precedence. And ghostty's format is flat `key = value` with repeated keys for lists, which suits toggles and paths but has no obvious shape for anything nested — worth checking that every setting worth moving actually fits before committing to the format. `AppSettings` stays the reader either way; a file is a new source for it, not a replacement for the type.
- The skills item depends on the renderer, not the other way round: telling Claude to draw mermaid before Plume can render it just produces fenced source. Sequence it after the mermaid work, and scope what the skill promises to what the renderer actually supports. Tables are now safe for a skill to encourage; mermaid is not, until it renders.
- **Skill content written**, unblocked by mermaid shipping on WebKit. It lives at `Plume/Resources/Skills/plume-formatting/SKILL.md`: when to reach for a table vs a list vs a diagram, mermaid guidance sized for the chat's narrow vertical column (`flowchart LR` over `TD`, modest node counts, short labels, capped sequence diagrams), which diagram types render well, and what not to do (no HTML, no images by URL, no ASCII art). What remains is the install mechanism — nothing yet copies this file into `~/.claude/skills` or otherwise hands it to a launched session.

## The sidebar

Today a sidebar row is a task: one title, up to two detail lines, one status badge (`TaskRowView.swift`). A task with three agents running in three tabs collapses to a single aggregated status, so the sidebar says something is working without saying what or where.

- [ ] Show each tab's agent as its own row under its task, with that agent's folder, its title, and its own status icon. The point is glanceability — seeing which agents are running, and which one wants you, without opening a task.

Most of what a per-agent row needs already exists per tab. `TitleStore` holds a live title keyed by tab id, `StatusEngine.status(forTab:)` gives a per-tab status the aggregate is derived from, and `StatusBadge` renders one. The folder is the open question: a working directory lives on the task, not the tab, so until [Task creation and directories](#task-creation-and-directories) settles, every agent under a task shows the same folder — worth confirming that is still worth showing. `TitleStore.representativeTab(of:)` exists precisely because a task has to pick one tab to speak for it; a per-agent list is the alternative to that choice, not a replacement for it, since the collapsed task row still needs a summary.

## Tab titles

- [ ] Explore titling a tab with Apple's on-device Foundation Models — summarizing the first prompt, and possibly more of the conversation, such as the plan file when there is one. Fall back to today's title whenever Apple Intelligence is off, the model is unavailable, or it declines to summarize.

A title comes from the agent today: `TitleStore` holds Claude's own session title for an agent tab and the terminal's title for a terminal tab, keyed by tab id, with a debounced snapshot in `TaskTab.title` so a relaunch has something to show. So this is a second source rather than a first one, and the fallback is not a special case — it is the current behavior left in place.

Worth weighing against a cheaper option first: the CLI has a `generate_session_title` control request (`docs/headless-protocol.md`), untried by Plume, which would title a tab with no local inference at all.

The framework is available: deployment target is macOS 26.2, and `SystemLanguageModel` reports its own availability, which is what the "Apple Intelligence is off" and "unsupported device" paths key off rather than a version check. Three things to decide when picking it up. Where the input comes from — the first user message is the cheap version, and the plan file is the richer one, but a plan arrives long after the tab needs a name. When it runs, since a title generated on every transcript read is a lot of inference for a string that rarely changes. And how a refusal is told apart from a bad title, because the model can return something plausible and useless as easily as it can decline.

## PR/MR state in the sidebar

Help me keep track of tasks once they leave my machine.

- [ ] Show PR/MR state the way my `wt` / `stack` utilities do, build and review state included.
- [ ] Use the existing `glab` / `gh` CLI auth.

What exists: nothing uses `gh` or `glab` yet. `WorkTask.integrationsData` is reserved for exactly this and is still unused.

## Task creation and directories

Make creating a task cheap, and stop pretending a task has one directory.

- [x] ⌘N inherits the selected task's working directory instead of leaving the workspace unset.
- [ ] Let the worktree choice happen *after* picking a directory, not before.
- [ ] Move the working directory onto tabs. A task probably doesn't need one.
- [ ] Track where an agent actually is — including when Claude uses `EnterWorktree` — and use that as the tab's current directory, e.g. when opening a new tab from it.

What exists:

- **⌘N inheritance shipped.** `TaskStore.createTask(inheritingFrom:)` copies `workingDirectoryPath`, `repoPath` and `branchName` from the selected task and sets `workspaceKind = .directory`; `MainWindow`'s ⌘N handler passes the selected task. A worktree task is inherited as a plain directory — the new task points at the same folder rather than getting a worktree of its own.
- The directory lives on `WorkTask` today (`workingDirectoryPath`, plus `repoPath` / `branchName` / `workspaceKind`), and it's read in roughly ten places across the sidebar, setup header, launcher and resume path. Moving it to `TaskTab` is the widest change on this list, though most call sites are a mechanical hop from `task.` to `tab.`. The question to settle first is what a task's identity becomes once it no longer owns a directory, and what the sidebar shows when a task's tabs disagree.
- `TerminalSession` **already tracks the live working directory per tab**, mirrored from the terminal's own reports — so a per-tab cwd is closer to how things already behave than the persisted per-task path is.
- `EnterWorktree` needs no special handling. Its `tool_use` input records the absolute path, but every transcript line afterwards also carries the new `cwd`, verified on a real session that moved into `.worktrees/…` mid-run. So reading `cwd` from the newest transcript line picks up `EnterWorktree` and every other directory change through one mechanism. `SessionJSONLReader` already reads these files.
- Creation is already frictionless in the sense of "no modal" — ⌘N makes a task immediately with `workspaceKind = .unset`, and `WorkspacePickerView` — the folder/worktree chips inside the composer's controls row — offers Choose Folder / New Worktree afterwards. What's missing is a sensible default and a worktree flow that doesn't have to be decided up front.

## Groups

- [x] ⌘N opens a new task in the current group.
- [ ] Icons (SF Symbols, probably by name) and colors for groups.
- [ ] Maybe colors for individual tasks too — or show the group's color across the whole group.

What exists: `TaskStore.createTask` already takes a `group:`, and the sidebar's "New Task in Group" passes it. ⌘N is the one call site that hardcodes ungrouped (`MainWindow.swift`). `TaskGroup` has no color or icon field yet.

## Colors and fonts

- [ ] Default to Lum. The full palette is in the dotfiles at `colors/lum.css` — use that, not just the simplified terminal palette.
- [ ] Preload other palettes: solarized, monokai, catppuccin, and other popular open-source ones.
- [ ] Support custom palettes, with light and dark.
- [ ] Choose the rest of the fonts — chat code separately from the terminal — and maybe bundle a few more good defaults.

Fonts sit alongside this, and the two halves of the app treat them differently. The terminal takes its font from the user's ghostty config, which is right — it should keep matching their terminal. The chat hardcodes `.system` for prose and `.monospaced` for code in `MarkdownBlockView`, `CodeSegmentView` and `MarkdownComposerStyler`; only the *size* is configurable (`AppSettings.chatFontSize`, clamped 11–28). So the work is a family setting to sit beside the size, threaded the same way through the environment, with prose and code chosen separately — a proportional body font next to a monospaced code font is the point, not one setting for both. Defaulting to the terminal's configured font for code is a reasonable starting point that needs no bundling at all. Prose is the half that's already decided.

**Libre Baskerville is the prose face**, bundled in `Plume/Resources/Fonts/` under SIL Open Font License 1.1 with its license file alongside. Newsreader was tried first and swapped out. Two differences worth knowing: Libre Baskerville is variable on `wght` alone (400–700), with no `opsz` axis, so nothing tracks the point size — and its family name is plain `Libre Baskerville`, where Newsreader's compatibility family was `Newsreader 16pt` against a typographic family of `Newsreader`, two names that were not interchangeable. It runs visually larger than Newsreader at the same point size, so `chatFontSize` may want revisiting. Registration is by CoreText at launch (`BundledFonts`), not `ATSApplicationFontsPath` — see the note below. Italics come from the italic file rather than a synthesized slant, which `ComposerProseFontTests` locks in by asserting the derived face has a different PostScript name from the upright.

**`INFOPLIST_KEY_ATSApplicationFontsPath` does not work here.** Xcode's Info.plist generator has no mapping for it, so the key never reaches the built plist — `INFOPLIST_KEY_LSApplicationCategoryType` beside it generates fine, which is what proves the mechanism rather than the spelling is at fault. The project generates its plist and has no file to add the key to. `BundledFonts.registerIfNeeded()` calls `CTFontManagerRegisterFontsForURL` at launch instead, which also sidesteps bundle layout: file-system synchronized groups flatten `Plume/Resources/Fonts/` into `Contents/Resources` rather than preserving the directory.

What exists: `GhosttyThemeResolver` and `ThemeChrome` already tint the sidebar and tab strip from the user's resolved ghostty theme, and `Color(hex:)` exists, so this extends a theming layer rather than starting one. Lum in `lum.css` is a 14-hue × 8-tone system whose tone names already split light from dark (`-28`/`-35`/`-on-dark` vs `-93`/`-97`/`-on-light`/`-on-white`) — richer than the 16-color ghostty theme, and a good fit for group and task colors.

## Tabs and window chrome

- [ ] One tab kind. "New Tab" opens a shell; when `claude` is running in it, the tab takes on agent chrome — no agent-vs-terminal prompt at creation.
- [ ] Remove the unused title bar, or move something into it (task name? directory?).
- [ ] Fix the titlebar's layout: it is empty space today, and shrinking the sidebar pushes the sidebar's overflow into that area. Ideally the tab strip moves up into the titlebar so tabs sit at the top of the window.
- [ ] Rebalance the chat chrome: put the titlebar's empty space to work. The statusline/composer split (see **The statusline**) already moved the next-message controls into the message box; what's left is the titlebar itself.
- [x] Cap a tab chip's width, so a long title can't take the whole strip. Much shorter than today's, which grows to fit whatever the title is.
- [ ] Drag a tab into another task.
- [ ] Move a tab out into a new task of its own.

What exists:

- Instrumentation can only be injected at launch — `--settings` and the `PLUME_*` env vars can't be attached to a `claude` the user started by hand. For a shell-first tab to keep reporting status and titles, Plume needs to set `PLUME_*` on every tab's shell, not just on agent tabs. `AgentLaunch` already carries per-surface env and `LoginShellCommand.wrap` already wraps the command, so the seam is there.
- The wrapper exposes `COMMAND_FINISHED` and `PROGRESS_REPORT` actions, and `TerminalViewState` publishes the command metadata — useful for detection.
- `AppDelegate` already makes the titlebar transparent and tints it.
- The chip already truncates — `lineLimit(1)` plus `.truncationMode(.middle)` (`TabStripView.swift:69-70`) — but nothing bounds it, so it grows to fit the title and the truncation never engages. A `maxWidth` on the label is the whole change; middle truncation then does the rest, which suits titles that differ at the end. Note the chip reserves its close-button slot to avoid resizing on hover, so the cap has to leave room for that.
- The detail pane has no toolbar at all — only the sidebar declares one, so the titlebar is empty tinted space. `StatuslineStripView` now carries only the session-wide facts (context, 5h, 7d, cost, branch); permission mode, model and effort moved to `ComposerControlsRow` in `ChatComposer`. Whether any of that still belongs in a window-level toolbar is open — such a toolbar shows the selected task's state, so it needs a decision about what it reads from when tabs disagree.
- Moving a tab between tasks is mostly a data operation — reassign `TaskTab.task` and renumber `orderIndex`, both of which `TaskStore` already owns. The catch is the terminal: `SurfaceManager` is keyed by tab ID, not by task, so the surface itself should survive the move untouched. Don't tear it down and rebuild it, or the move kills a running agent. A tab whose working directory came from its old task also needs a decision — the process keeps its original cwd regardless of where the tab now lives.

## Shortcuts

- [ ] Assignable hotkeys for next/previous tab and next/previous task, so I can set them to alt+J/K and alt+shift+J/K (cmd instead of alt is fine too).
- [ ] ⌘T opens a new tab in the current task.
- [x] Swap the two: ⌘T opens a terminal tab, ⌘⌥T opens an agent tab.
- [x] ⌘W closes the current tab, not the window.

What exists: next/previous *tab* is already bound to ⌘⇧] / ⌘⇧[ (`PlumeCommands`), and ⌘T already opens a tab in the current task — it's labelled "New Agent Tab", with ⌘⇧T for a terminal tab. Collapsing to one tab kind (see **Tabs and window chrome**) makes ⌘T just "New Tab" and frees ⌘⇧T. Nothing is user-assignable: every shortcut is hardcoded in a SwiftUI `Commands` body, so making them configurable means a binding store, a settings UI, and a way to apply a stored binding to a menu command. Alt-based chords are also the case most likely to collide with the terminal swallowing keys, which ties this to the focus item under **Misc UX**.

**The swap shipped, and it is a relabelling, and a stopgap.** ⌘T was "New Agent Tab" and ⌘⇧T the terminal one; the change exchanges the two commands' keys and moves the second off ⇧ onto ⌥, so ⌘T now opens a terminal tab and ⌘⌥T an agent tab. It holds until the one-tab-kind collapse under **Tabs and window chrome** lands, at which point ⌘T becomes a plain "New Tab" and the second key is free again. Not a conflict — an ordering.

**Next/previous task shipped**, hardcoded to ⌘] / ⌘[ — the same keys as the tab commands, minus shift, and free of any existing binding. `PlumeCommands`' `Tab` menu gets two more items backed by a new `selectAdjacentTask` focused value; `MainWindow` supplies it from a `navigableTasks` list (groups in order, then ungrouped) walked with the same `SidebarKeyboardNavigation.destination` helper the sidebar's arrow keys already use, so ⌘] / ⌘[ land on the same task an arrow key would and don't wrap at either end. Unlike the per-task `TaskCommands`, this focused value stays available with nothing selected, so it can select the first task the way an arrow key does. Assignability is still unaddressed — out of scope for this pass.

**⌘W shipped.** The old "Close Tab" item sat in `CommandGroup(after: .saveItem)`, so AppKit's own "Close Window" (also ⌘W, since `.saveItem` is the placement that covers closing windows) still won the shortcut. Replacing that group instead of appending to it removes the standard item outright; the one remaining "Close Tab" button closes the selected tab, or the window when the task has none.

## Naming

- [ ] Consider renaming "task" to something that better fits a long-lived thing — "workspace" was the suggestion.

The observation is right: these outlive a single unit of work, and "task" undersells that. But "workspace" is already taken. `WorkspaceKind` (unset / directory / worktree) is a *property of* a `WorkTask` meaning where it runs, and `WorkspaceProvisioner` creates those directories and worktrees. Renaming the model to `Workspace` would give us `workspace.workspaceKind` and two unrelated `Workspace*` concepts. So this needs a third word, or a rename of the existing workspace concept too — worth settling before anyone starts, since it touches the model, the store, the UI, and every test.

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
- [x] Drag and drop to reorder tabs.
- [ ] Decide whether a restored agent tab auto-resumes on launch or waits to be selected.
- [x] Give archived tasks better names in the archive. An unnamed task shows nothing at all there.
- [x] Focus the composer when a new tab or task opens. The wiring is in place and does not take effect — ⌘N leaves focus elsewhere.
- [x] Clear every per-tab in-memory store when a tab closes, not only when its task is deleted. `TaskStore.forgetTab(_:)` is the one seam, and `closeTab` and `delete` both call it — so neither can drift into forgetting less than the other. It covers both session managers plus `TitleStore`, `DraftStore`, `BellStore`, `SubagentCompletionTracker`, `TranscriptStore` and `UntrustedDirectoryStore`, which is a superset of what either path cleared before.
- [x] Truncate a sidebar task title at the trailing edge, not the middle.
- [x] The sidebar's add button and its dropdown menu don't react to light/dark mode, or not reliably.

What exists:

- **Title truncation shipped.** `TaskRowView`'s title `Text` now sets `.truncationMode(.tail)` (`TaskRowView.swift:42`), so a long title reads "I'm going to start to move this to…" instead of eating both ends. The detail lines below it keep `.truncationMode(.middle)` — those carry a branch and a working directory, where the tail is the distinguishing part.
- **Add button tint shipped.** The `Menu` in `SidebarView`'s toolbar (label + `primaryAction`) rendered as an AppKit split-button bezel that didn't track appearance changes the way a plain `Button` does. `.menuStyle(.borderlessButton)` plus `.labelStyle(.iconOnly)` on the label strips that bezel so it matches the neighbouring Archive button's plain icon styling. Not verified visually in this pass — worth a quick look in both appearances.

- Shortcuts are plain SwiftUI `Commands` gated on `@FocusedValue`, with no low-level key interception, which is likely why they don't survive terminal focus.
- **Composer focus shipped.** Two separate bugs, found by logging `NSApp.keyWindow?.firstResponder` across a run rather than guessing: (1) `ChatComposer`'s `@FocusState` was never attached via `.focused()` — it was only read manually inside `MarkdownComposerTextView.updateNSView`, and a `@FocusState` write with no `.focused()` anywhere in the tree never reaches that read at all, so `inputFocused = true` was a no-op from the start. Task 1's composer only ever looked focused by coincidence, from AppKit's own default-responder assignment on first window activation. (2) Even after wiring `.focused($inputFocused)` correctly, a *second* tab's focus request still lost: the headless chat path unmounts a hidden tab's `ChatComposer` rather than hiding it, and switching *tasks* replaces the whole tab subtree the same way (tabs are keyed by id, and a new task's tabs share none with the old one's) — so the new view's focus claim arrives in the same transaction as the old view resigning real first responder, and SwiftUI drops it silently. Deferring the write one run loop turn (`DispatchQueue.main.async`) fixed it. Confirmed live via the same logging for `ChatComposer` (⌘N-equivalent, i.e. creating and selecting a task while another was focused) and `TerminalTabView` (adding a terminal tab to the current task). `AgentFirstMessageView` already had `.focused($inputFocused)` wired correctly, so only needed the deferred write for consistency with the others.
- **Tab drag-to-reorder shipped.** `.onMove` needs a `List`, which `TabStripView`'s `HStack` of chips isn't, so each `TabChip` carries `.draggable(tab.id.uuidString)` and `.dropDestination(for: String.self)` instead — dropping onto a chip moves the dragged tab to sit immediately before it, and the trailing `Spacer` past the last chip is its own drop target for moving a tab to the end. Both funnel into `TaskStore.moveTabs`, the same dense-`orderIndex` rewrite `TaskStore.move` already used for sidebar tasks, so ordering stays out of the view. `ForEach(task.orderedTabs)` keys tab content by `TaskTab.id`, so reordering only permutes the array — no tab's `TerminalTabView`/`AgentTabContent` is torn down or rebuilt, and every surface keyed by tab id in `SurfaceManager` is untouched.
- **Shipped:** `ArchiveView` now renders `TitleStore.shared.displayTitle(for:)` (`ArchiveView.swift:19`) instead of raw `task.title`, matching the live sidebar (`TaskRowView.swift:40`) — an unnamed task falls back to its representative tab's title and finally "Untitled" instead of a blank row. The archived row still shows the working directory beneath the title, which is often the more identifying of the two.
- Restoring the selection has shipped: `LastOpenTask` persists the selected task's UUID and `MainWindow` restores it, matching the per-task selected tab that `WorkTask.selectedTabID` already carried. A task archived or deleted since the last launch doesn't match and the pane opens empty. What's left is the auto-resume question, which is a behavior decision rather than plumbing: the existing rule deliberately avoids spawning `claude` for every agent tab at startup, and reopening a tab shouldn't quietly undo that.

## Keep the Mac awake

Plume should hold a sleep assertion while something is running that the user is waiting on, and release it when nothing is.

- [ ] Keep the Mac awake while an agent turn is running.
- [ ] Keep it awake while a subagent is running.
- [ ] Keep it awake while a monitor or other long-running tool call is in flight.
- [ ] Consider a running foreground command in a terminal tab, and a `git worktree` or build Plume itself started, as further reasons to stay awake.

What exists:

- Nothing in the app calls `IOPMAssertionCreateWithName` or spawns `caffeinate` yet. An `IOPMAssertion` of type `PreventUserIdleSystemSleep` is the whole mechanism; a single owner that counts reasons and holds one assertion while the count is non-zero is the shape.
- Every signal already flows through in-memory state: `StatusEngine` knows every tab's `working` status across both transports, `SubagentTranscript.status` (new in 0.3.0) knows each subagent's, and a monitor is a tool call whose `tool_result` has not arrived, which the transcript parser already tracks for the tool-call row's spinner. The Ghostty wrapper reports `COMMAND_FINISHED` / `PROGRESS_REPORT`, which is what a terminal-command reason would key on.
- **Remote control now exists as its own feature** (see [Remote Control](#remote-control)), so what is left here is the caffeine half: a session driven from a phone wants the Mac awake until told otherwise, regardless of what is running. That wants a three-way per-session toggle — not caffeinated / caffeinated / caffeinated for a remote session — and a CLI Claude can call to set it, alongside the notify helper under **Notifications**. The automatic reasons above and this manual override should share the one assertion owner.
- Worth deciding: whether "waiting for input" keeps the Mac awake. It probably should not — the user is the one who is away — but a notification on wake-up (see **Notifications**) makes that safe to get wrong.

## Remote Control

Drive a Plume conversation from a phone or claude.ai/code, the way the CLI's own `/rc` does.

- [x] Support `/rc` on the headless transport — connect, disconnect, and show the link.
- [ ] Reconnect a bridge automatically after a `--resume`, rather than starting disconnected.
- [ ] Show remote-control state in the sidebar, so a published session is legible without opening it.

What shipped:

- **`/rc` is a Plume command, not a CLI one, and it has to be.** The CLI's `remote-control` renders an interactive TUI component and ships no non-interactive variant, so it never appears in the `initialize` reply's commands and sending the text does nothing. `PlumeSlashCommand` serves it into the composer's list — deduped against the CLI's own names, so a later CLI that does report `/rc` wins — and `ChatComposer.send()` intercepts it. Two guards keep that honest: only on the headless transport, since a terminal tab's real TUI already has a working `/rc`, and only once a session exists, since a tab's first message has no bridge to attach to.
- The mechanism is a **host-originated `remote_control` control request**; `docs/headless-protocol.md` is the wire reference, verified first-hand rather than inferred.
- **`session_url` is the link, not `connect_url`.** `connect_url` names an environment, which a session hosted on this Mac does not have, so it arrives as a bare `https://claude.ai/code?environment=` and goes nowhere.
- State lives on `HeadlessSession` and nowhere else. A bridge belongs to the running process, so nothing about it is persisted and a relaunch starts disconnected — the same rule terminals follow.
- `/rc` writes no transcript line, so without some local report the chat looks identical whether the command worked or did nothing at all. `RemoteControlToast` floats that report briefly above the composer and copies the link on click. It is deliberately **not** a chat row: the chat renders conversation history, and a bridge is a live property of the session rather than something that happened at a point in the transcript — and a row would grow the message list's content for something that is not a message. The notice and its dismissal timer live on `HeadlessSession` for the usual reason: held in the view, both would die on a task switch and start over on the way back. A failure does not time out, since the toast is the only place its reason is shown.
- **Two things the wire made necessary.** `ControlResponse` could not express a failure at all, so a refused request would have hung the UI at "Connecting…" forever — nothing times out a control request on either side. And replies are now correlated by `request_id` rather than sniffed for a `commands` key, which only worked while `initialize` was the sole reply anyone read.

What exists:

- `bridge_epoch` increments per connect, and the state machine drops an event from an older bridge — a fast disconnect/reconnect would otherwise let the previous bridge's failure land on the live one. The first event of every connect carries no epoch, which says nothing about ordering and is not treated as stale.
- Nothing reconnects on resume. `agentSessionID` survives a relaunch and `--resume` restores the conversation, but the bridge does not come back with it.

## Below the composer

The strip under the composer has accumulated rather than been designed. Everything in it is worth showing; almost none of it is in the right place.

- [x] Restructure the row of session facts below the composer text. Both rows were redesigned together; see below.

What we knew going in:

- **`/rc` status belongs in the statusline**, not in `ComposerControlsRow`. The controls row describes the *next turn* — model, effort, permission mode — and Remote Control is a session-wide fact like quota and branch. It sits left of the model dropdown today only because that was somewhere to put it.
- **The controls row is already crowded.** Adding the antenna pushed it there: at a narrow pane the icon sits hard against the model dropdown. Accepted for now, and another reason `/rc` should move rather than be squeezed.
- **The antenna menu's items should name what they act on.** "Connect" and "Disconnect" read fine under a labelled segment, but the icon carries no label, so they should be "Connect Remote Control" and "Disconnect Remote Control".
- **The plan link probably belongs somewhere else too.** It is a document the conversation produced, not a setting or a session fact.
- **The worktree and the branch should sit next to each other.** They answer one question — where is this running — and currently do not.
- **The context and quota bars are too wide** for what they say. Worth finding a way to narrow them.
- One idea that addresses several of these at once: **give the statusline more vertical space**, so a segment can stack a label over its bar instead of laying them out side by side. That buys width back for everything else and lets the meters shrink without losing their labels.

**The two rows now split by tense: the composer row is the next turn, the statusline is the session.** The controls row holds only model, effort and permission mode, right-aligned beside send and stop. Everything session-wide moved down: the workspace chips, Remote Control, and the meters. The statusline reads left to right as where this runs, then what it has spent, then whether anyone else can drive it.

**Worktree and branch became one chip rather than two segments.** They were showing the same name in different rows from different sources — the picker from the task, the segment from the transcript. `WorkspacePickerView` now takes the `GitState` and labels the chip with the branch git reports, with ahead/behind, "no upstream" and the dirty dot beside it. The separate branch segment is gone, and `statusline-branch` identifies the group that replaced it.

**The meters stack their reading over their bar**, centered rather than leading — a short reading over a long bar, or the reverse, both read as placed rather than merely left-aligned. Bar lengths (longest first, matching how precisely each is worth reading): context 50, the seven-day quota 36, the five-hour quota 28. The row is top-aligned, so the cost — one line with no bar — still lines up with the readings beside it. That costs the statusline one line of height and gives the width back to everything else.

**The plan button moves with the plan's own state.** Minimized still docks a bar above the composer, behind its own divider. Closed, the button moves into the composer's controls row — leading edge, across the `Spacer` from model/effort/permission mode — rather than heading the panel above the composer text; expanded, the full overlay covers the panel entirely, so nothing needs to render there either way. `PermissionMode.plan`'s icon (`doc.text`) now matches the button's, so the mode and the document it produces read as one concept, and the button draws its own trailing chevron since a plain `Button` gets no menu-style chevron for free.

**The statusline dims to secondary, keeping only real attention live.** Text, meter bars and the workspace chips all read as supporting metadata now, so the eye lands on the conversation and on the composer's own model/effort/permission dropdowns instead — those stay full-strength, since they're next-turn controls the statusline isn't trying to de-emphasize. The one exception is a context or quota meter that's gone yellow or red: `StatuslineColors.statuslineText` keeps `foreground`'s warning/danger hue for those, since that color is the entire point once it fires. Remote Control follows the same rule — only its failed (red) state stays a live color; connected, connecting and disconnected are all just "fine," so all three now dim to the same secondary gray.

**The row lays out from each segment's intrinsic width instead of squeezing everything proportionally.** The workspace picker's folder chip, the ahead/behind/dirty markers, the meters and Remote Control all carry `.fixedSize()`, so none of them gives up space when the panel narrows. The one exception is deliberate: the worktree chip's branch name is the single flexible segment left, so it's the one that truncates first, which is the trade worth making since a shortened branch name is still legible and everything else isn't. A wider gap (`statuslineTrailingGap`) also now separates the meters from the antenna, which previously sat close enough to read as one more segment of the group it's actually reporting on.

**The controls carry icons and collapse to them when the row is narrow.** `brain` for model, the `gauge.with.dots.needle` ladder for the five effort levels, and one symbol per permission mode — `bolt.fill`, `doc.text`, `pencil.line`, `exclamationmark.triangle.fill` — so the collapsed form still tells the four modes apart. `ComposerControlsMetrics` decides the form: it estimates each segment's width from its label's character count and compares the total against the width the row was measured at. Estimating rather than measuring keeps it a pure function with its own tests, and the row can never resize itself from the decision — every segment hugs its content and the leading `Spacer` absorbs the rest, so the measured width is the panel's, not the labels'. A closed plan's button reserves its own estimated width off the top of that measurement before the three next-turn controls decide whether they fit.

**The label-less form made tooltips load-bearing**, so every segment names itself and its value: "Model: Opus", "Effort: High (changing it sends a message)", "Permission mode: Auto". The workspace chips gained the paths — the folder's, and the worktree's, since two worktrees of one repository differ only there — attached to the menu itself rather than to the wrapper around it. The antenna's items name what they act on ("Connect Remote Control"), since no label sits under the icon.

**The workspace chips follow the panel into the empty state.** The strip needs a session to have anything to say, but choosing where a tab runs matters most before its first message, so the pre-session panel carries the composer, a divider and the workspace row — the same shape, minus the facts that do not exist yet.

The context meter and the plan button gained accessibility identifiers, which were the two controls in either row without one, and every existing identifier stayed attached to its segment through the move.

## Infrastructure

Tooling for the agents that build Plume, rather than for Plume itself.

- [ ] A screenshot lease, so only one agent at a time can try to capture the screen. There is one screen, so the lease is short-lived: an agent asks for a single screenshot, gets the capture, and the lease releases on its own shortly after. A skill or a small CLI (`screenshot-lease take`, say) that blocks until the lease is free, captures, and releases is the shape; parallel `screencapture` calls from several agents fail today.

What exists:

- Nothing. Each agent calls `screencapture` directly, and the 0.3.0 sweep hit the collision — two agents captured at once and both failed. The per-project memory records the rule ("one agent may screenshot at a time") but nothing enforces it.
- The lease wants to live outside the repo, beside `papercut` and `distress-call` in the dotfiles, since every project's agents share the one screen. A lock file with a timeout under `~/.local/state` is enough; there is no cross-machine case.

## Make the UI drivable

Give the interface an accessibility surface, so both `PlumeUITests` and an
agent driving the app can find and operate controls by name.

- [x] Put accessibility identifiers on the controls worth driving: the sidebar's task rows, the tab strip, the composer field and send button, the statusline's dropdowns, and the plan overlay's approve/reject buttons. Identifiers live in `Plume/Support/AccessibilityID.swift`; applied across `TaskRowView`, `SidebarView`, `TabStripView`, `ChatComposer`, `ComposerControlsRow`, `StatuslineStripView`, `ChatTabView`'s plan overlay, `InteractiveToolRow`, and `SubagentListView`. `SubagentTranscriptOverlay`'s close button carries one too.
- [x] Grow `PlumeUITests` past launching the app, now that there is something to query. Two tests added (`testNewTaskButtonIsAccessible`, `testComposerFieldIsAccessibleWithSeededTask`); both currently fail in this environment because the accessibility tree is still unreachable here (see "What exists" below) — kept rather than deleted since the identifiers themselves are correct.

What exists:

- The app is effectively opaque to the accessibility tree today. `entire contents of window 1` returns **0** elements and every top-level element's `name` is `missing value`, so nothing can be found by name or role. Coordinate clicks and keyboard shortcuts work; everything else does not.
- That is the ceiling on automated verification. `PlumeUITests` launches the app and stops there, and an agent checking a change can screenshot the result but cannot operate the control it just changed — so a visual check needs a person to click first.
- SwiftUI supplies identifiers through `.accessibilityIdentifier(_:)` and labels through `.accessibilityLabel(_:)`. A few of the latter already exist (the composer's send button, for one), so this is extending a pattern rather than introducing one.
- Worth doing before the next round of UI work rather than after: the chat, statusline and composer are all being reshaped right now, and identifiers added while a view is already open cost far less than a separate pass over settled code.

## Worktrees

Create and delete moved onto `GitService` and have not been driven since. The feature ships with a WIP marker so its state is honest — that marker is in place; what it covers is still unverified.

- [x] Track the worktree an agent tab is actually in, including after an `EnterWorktree` tool call, somewhere the whole app can read.
- [x] Open a new terminal tab in that worktree rather than in the task's folder.
- [ ] Create and delete a worktree, now that both run on `GitService` rather than the main thread.
- [ ] Make `git worktree remove` fail, and confirm the task survives with the error shown.

What shipped:

- `TabDirectoryStore` (`Plume/Models/`) holds each tab's current directory in memory, keyed by tab id, shaped like `TitleStore`. Nothing is persisted; a relaunch starts from the task's folder until a tab reports again.
- Both tab kinds feed it. An agent tab writes `ChatTabView.gitDirectory` — the transcript's own `cwd`, which follows an `EnterWorktree` because every line after the call carries the new `cwd`. A terminal tab writes `TerminalSession.workingDirectory`, the wrapper's OSC 7 report.
- `startingDirectory(for:)` answers where a *new* tab belongs, preferring the last-focused agent tab, then the selected tab, then any tab, then the task's folder. `TerminalTabHost` passes it to `SurfaceManager`, so a terminal tab opened after the agent moved lands in the worktree.
- `TaskStore.forgetTab(_:)` clears the store with the rest of a closed tab's state.

Two things not to lose. `TerminalSurfaceOptions` are read once at surface creation — re-requesting an existing session ignores new options by design — so this changes where a *new* tab starts, never where a live one is. And the sidebar's detail line still reads the task-level path; it has not been moved onto the store.

The marker shows on the "New Worktree…" button (`WorkspacePickerView.swift:128`), the sheet's title (`NewWorktreeSheet.swift:20`), and the two destructive delete items (`SidebarView.swift:100,103`). The delete items are the ones that most need it — they are irreversible, and their failure path is the least exercised code in the feature. Settle one marker and use it everywhere, since this will not be the last unfinished feature to ship visible.

What exists:

- `WorkspaceProvisioner.removeWorktree` passes `--force`, so ordinary "dirty tree" refusals never reach the failure handler (`SidebarView.swift:141-145`) — reproducing it needs `git worktree lock` or an already-removed path.
- The riskiest part is the git conversions, because they changed *when* a value appears rather than what it is. `task.repoPath` is now written after `GitService` answers instead of during the call that sets the folder, so anything reading it in the same turn sees nil where it used to see a path. Nothing does today; that is the assumption to check.
- `SidebarView.deleteTask` was restructured around the same change: the git call moved into a `Task`, so the early `return` that aborted a delete on failure became a `finishDeleting` continuation. The success path is ordinary use, but the failure path — git refuses, the task stays, the error shows — has never run.
