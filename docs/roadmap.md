# Plume roadmap

Features we intend to build. Each section records what we want and what the code already provides — it doesn't say how to build any of it. Work out the approach when you pick an item up.

Sizes are rough: **S** is a call site or two, **M** is a contained feature, **L** touches several files or needs a design decision, **XL** is wide or deep enough to plan on its own.

## Up Next

The queue, highest priority first. Each line points at the section holding the detail; nothing here repeats it.

1. **S** — Terminal bell, with a dot on tabs that rang one. See [Notifications](#notifications).
2. **M** — System notification on bell, then on Claude Code events — above all waiting-for-input. See [Notifications](#notifications).
3. **L** — Subagents as a real view rather than a disclosure row. The case Plume exists to make legible, and currently the weakest part of the chat. See [Subagents](#subagents).
4. **L** — Mermaid diagrams in the markdown renderer. Blocked on one decision — WebKit or a native subset. See [The markdown renderer](#the-markdown-renderer).
5. **S** — ⌘W closes the current tab, not the window. See [Shortcuts](#shortcuts).
6. **S** — Focus the composer on opening a new tab or task. See [Misc UX](#misc-ux).
7. **S** — ⌘N inherits the selected task's working directory. See [Task creation and directories](#task-creation-and-directories).
8. **S** — A multi-line plan feedback field, following the composer's send-key setting. See [The plan overlay](#the-plan-overlay).
9. **S** — Label the reject button "Reject" until the user types. See [The plan overlay](#the-plan-overlay).
10. **M** — ⌥↩ approves with feedback, captioned beneath the field. See [The plan overlay](#the-plan-overlay).
11. **M** — Set model, effort and permission mode before the first message in an agent tab. See [The statusline](#the-statusline).
12. **S** — Confirm a resumed tab shows the conversation's real mode and model, not the stale snapshot. See [The statusline](#the-statusline).

Deferred rather than dropped: **`!` command execution mode** waits for a real implementation — the styling half alone produces a mode that looks live but does nothing on send (see [The composer](#the-composer)). **`/btw` support** waits on confirming the note is filed at all on the headless transport, since a silent no-op and a working command look identical from the UI (see [The composer](#the-composer)).

Not queued, and deliberately so: **Renaming "task"** is cheap to do and expensive to redo, so settle the word before it touches more call sites (see [Naming](#naming)). **Directories on tabs instead of tasks** is the widest change on the list and forces a real question about what a task is (see [Task creation and directories](#task-creation-and-directories)). **Strict concurrency** is worth its own pass rather than folding into feature work (see [Concurrency correctness](#concurrency-correctness)).

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

## Subagents

Was marked done and is not: the old checkbox covered the *list*, while the status half never worked. Driven now, and it is well short of useful. Parallel subagents are the case Plume exists to make legible, so this deserves to be a real view rather than a patched-up disclosure row.

- [ ] Show which subagents a conversation has spawned, identified by what they were asked to do rather than by ID.
- [ ] Show each one's live status — working, waiting for input, done, failed.
- [ ] Let a subagent's transcript be read properly, with the same rendering the main conversation gets.

Today the label is `subagent.id` — a raw identifier (`SubagentListView.swift:59`) — over a one-line tail of the last message. `SubagentTranscript` carries only `id`, `transcript` and `modifiedAt` (`TranscriptStore.swift:6-10`), so neither a task description nor a status has anywhere to live yet; both want adding there. The description is recoverable: a subagent is spawned by a `Task`/`Agent` tool call in the parent transcript, whose input carries the prompt and a short description, and the transcript parser already reads those calls.

- **Status is hardcoded, not merely wrong.** `ChatMessageRow(message:, isLast: false, status: .unset)` (`SubagentListView.swift:53`) passes both constants, and `ChatMessageRow` gates its working spinner and needs-input indicator on `isLast && status == …` — so neither can ever fire, whatever the subagent is doing.
- **Freshness would still lag once status is wired.** A subagent's own writes don't trigger the main transcript's watcher, so the list refreshes only when the *main* transcript changes. `SessionJSONLReader` already enumerates the subagent transcripts, so what's missing is a watcher per file, not discovery.
- **Presentation.** A nested `DisclosureGroup` inside the chat list is a cramped place to read a whole conversation. Worth weighing against the alternatives — a sheet like the plan overlay, or a pane — especially once several subagents run at once, which is the situation that motivates the feature.

## The markdown renderer

Shared by the chat, the plan overlay and the file viewer, so none of these are plan-specific.

- [ ] Syntax-highlight code blocks.
- [x] Give code blocks more padding inside their border, and a copy icon while hovering them.
- [ ] Distinguish a bash block's input from its result — they currently render alike.
- [ ] Put real newlines in a bash input block.
- [x] Mermaid diagrams in the same renderer.

Padding and the copy icon shipped together in `MarkdownView`'s `case .codeBlock`. The icon is an `overlay` on the background container rather than inside the horizontal `ScrollView`, so it stays pinned instead of scrolling away with the code, and it reveals on hovering the block rather than the button itself. It copies the block's raw `code` string, and introduced the app's first `NSPasteboard` use.

Tables shipped native and did **not** settle the mermaid question. The two are separate problems: a table's layout is given by its source, so `Grid` is the whole implementation, while a diagram needs a layout *algorithm* — node ranking and edge routing — which is the entire job and shares nothing with tables beyond the fence.

**Mermaid shipped on WebKit**, which was the open decision. A native subset degrades badly the moment a diagram uses an unsupported shape, and that argument decided it. `MarkdownView`'s `case .codeBlock` branches on the `language` the fence already carried, so the parser did not change; `MermaidBlock` renders the diagram and `MermaidDocument` builds its page. mermaid **11.4.1** is vendored under `Plume/Resources/Mermaid/` with its MIT license, so rendering works offline. Synchronized groups flatten resources into `Contents/Resources`, so the page loads through `loadHTMLString(_:baseURL:)` with that directory as its base and a relative `<script src>` resolves against it — no `WKWebViewConfiguration` tweak, no entitlement, and no file-access preference was needed.

Sizing is what keeps the chat safe. The page posts its rendered height back over a `WKScriptMessageHandler` once mermaid resolves, and the row takes an explicit frame from it, so a row settles at one height rather than resizing — a view that kept resizing would reopen the placement loop in `docs/chat-list-hang.md`. Until that height arrives, and permanently if mermaid rejects the source, the existing code-block rendering shows the raw fence instead, so the row is never blank. Copying still yields the source rather than the drawn diagram. Both outcomes log to `Log.app`, which is how rendering is verified without a screenshot.

## The composer

- [ ] Give the first message a nicer intermediate state. The composer currently disappears before the message appears; disabling it in place would read better.
- [ ] Make the composer content-width rather than bleed-width.
- [ ] Echo a CLI-intercepted slash command locally, and show that it is running.
- [ ] `/btw` support — confirm the note is actually filed, and show it in the chat. It takes no turn, so today nothing in the UI changes when you send one.
- [ ] Tell `<local-command-caveat>` apart from `<local-command-stdout>`. They share one case, so the caveat's boilerplate and the real output render alike.
- [ ] Title a command-output row with the command that produced it.
- [ ] Render a command-output body as markdown. It is monospaced plain text today, so a `/context` dump shows raw table source.
- [ ] Decide whether the rejection-feedback submit button belongs inside the text field.
- [ ] Command execution mode. A leading `!` means "run this rather than say it", the way the CLI's bash mode does. While the message starts with `!`, style the rest of it monospaced — plain monospace, no code-chip background, so it reads as a different mode rather than as an inline code span.

A slash command the CLI handles itself never reaches the transcript, so the chat shows nothing at all while it runs. `/compact` is the case that hurts: this project's transcript holds **11** `compact_boundary` markers and **zero** `/compact` user messages, and compaction takes upwards of a minute and a half with no message, no spinner and no sign the command was received. `submit(text:)` only sends; the chat renders from the transcript, so anything the CLI intercepts vanishes. The fix is a locally-rendered echo plus a working indicator, driven from Plume's own state rather than the transcript — and it generalizes past `/compact` to every intercepted command.

Command mode has a styling half and a behavior half, and the styling half stands alone. `MarkdownComposerStyler` already turns a recognized slash command's token accent-colored via `SlashCommandMatcher.recognizedCommandRange`, so a line-leading `!` is the same shape of check: recognize the prefix, then restyle the remainder. What it can't reuse is `MarkdownHighlighter`'s `.inlineCode` span — that one carries `codeBackgroundColor`, which is exactly the chip look this shouldn't have. So it wants either a new style case with font but no background, or a direct attribute pass beside the slash-command one. What the `!` then *does* on send is the open half: the CLI intercepts its own bash mode, and Plume's `send()` hands text to `HeadlessSession.submit(text:)`, so a `!` message either passes through and relies on the CLI, or Plume runs it and echoes the result itself — the same locally-rendered-echo problem `/compact` has.

`/btw` is the sharpest case of that same problem, and needs nothing new to *send*. Slash commands are discovered rather than hardcoded — `HeadlessSession` reads them from the `initialize` reply's `commands` array (`HeadlessSession.swift:283-293`), so `/btw` already autocompletes and already styles as recognized if the CLI reports it. What it lacks is any evidence of having worked: it files a note without taking a turn, so there is no assistant message, no tool call and no transcript line to render — the composer just empties and the chat looks identical. That makes it a better first case for the local echo than `/compact`, which at least has a `compact_boundary` marker to anchor on. Worth checking first whether the note is filed at all on this transport, since a silent no-op and a working command are indistinguishable from the UI today.

A command's *output* is already classified and already rendered: `<local-command-stdout>` and `<local-command-caveat>` both become `InjectedContent.commandOutput` (`InjectedContent.swift:18`, classified at lines 86-88), and `ChatMessageRow` sends every injected block to `InjectedContentRow` — the same collapsed marker row the "Compacted context" summary gets, full-width rather than in a user bubble. So these three extend a working path. Sharing one case is what costs the caveat and the output their distinct labels, and `command-args` is parsed nowhere, so a row cannot name the command it came from. The markdown item carries the only real decision: the expanded body is a monospaced `Text` (`InjectedContentRow.swift:36-44`), and swapping in `MarkdownView` would change every injected kind at once — shell output and skill bodies included, where monospace is right. It wants to be per-kind. Note also that this row hand-builds its disclosure from a `Button` and a chevron while `ToolCallRow` and `SubagentListView` use `DisclosureGroup`; settle on one before a third caller arrives.

## The statusline

`HeadlessSession` now owns `permissionMode`/`model`/`effort` as observable state, set optimistically when the host asks for a change and corrected from the stream (`system`/`init` for model and permission mode — there is no `set_effort` control request, so effort is never corrected, only ever what this host last sent). The strip and composer read this instead of the transcript, fixing the old bug where a control wrote through the session but displayed transcript state.

Still open:

- [x] Stop accumulating `total_cost_usd`. It is already a running conversation total, so `+=` re-adds every prior turn and the displayed figure compounds. Assign it instead, and correct `docs/headless-protocol.md`, which records the wrong semantics.
- [x] Move the stop button out of the statusline and put it left of the send button — a circular icon button with a dim background, mirroring send's shape.
- [ ] Consider moving the whole strip inside the composer box, if a compact form fits a narrow viewport.
- [ ] Customization UI, once a segment shape settles. `ComposerControlsRow`'s segments are already self-contained — each reads and writes only its own piece of session state — so this is additive, not a rewrite.
- [ ] The composer's two-row split is a first cut (plain `HStack`s, no styling pass) — revisit layout and spacing.
- [x] Remember effort and permission mode per session, the way the context window already is.
- [ ] Offer model, effort and permission mode before the first message, when a tab has no session yet.
- [ ] Confirm a resumed tab ends up on the conversation's real model and permission mode, not the seeded snapshot.
- [ ] Take effort from the resumed conversation too, once the CLI reports it back at all.

**The session cost is fixed.** `total_cost_usd` is a running total for the whole conversation, re-sent on every `result` event — Plume accumulated it, so each turn re-added every turn before it. Confirmed on the wire: turn 1 reported $0.2548 and turn 2 $0.2996 for a turn that emitted a single digit. Assigning instead of adding also makes the figure correct across a `--resume`, since the first `result` after resuming already carries the true total. `docs/headless-protocol.md` recorded the opposite and was corrected in the same change.

The stop button now sits in the composer beside send — a 22pt circle matching send's shape with a dim fill rather than the accent one, so the pair reads as two related controls. Both show at once: `isWorking` and `hasSendableText` are independent, and stop replacing send would hide the ability to queue a follow-up.

`TaskTab` now snapshots permission mode and effort alongside `contextWindowTokens`, written from `ChatTabView` when the session's value changes — once per turn rather than per stream event. Launch resolves the mode tab → task → app default, so a tab reopens in the mode the user last saw it in and the default only fills in for a tab that never had one. Effort has no launch flag and no `set_effort` control request to report it back, so the snapshot is its only record across a relaunch; it seeds `HeadlessSession` directly at construction rather than through `setEffort(_:)`, which would submit a real turn.

**The controls are missing until the first message.** `ComposerControlsRow` renders model, effort and permission mode behind `if let headlessSession` (`ComposerControlsRow.swift:26-30`), and a tab has no session until one is launched — `existingSession(for:)` never creates one. So a fresh agent tab shows the workspace chips and nothing else, and the first message is the one turn whose model and mode cannot be chosen, which is backwards: it is the turn most worth setting, and the only one where the choice is free. Everything the fix writes to already exists — `tab.permissionMode` and `tab.effort` are persisted, and `AgentLauncher` already resolves the mode tab → task → app default (`AgentLauncher.swift:91-93`) and passes `initialEffort: tab.effort`. So the controls need to read and write the tab's own values before a session exists, then hand over to the session's once launched, with the pre-launch state seeding the launch it already feeds. Model is the one gap in that chain: unlike mode and effort it has no `TaskTab` field, so offering it pre-launch means persisting it and giving `AgentLauncher` a flag for it.

**Resuming already corrects two of the three, and cannot correct the third.** Resume is not a separate path — `launchHeadless` takes a `resumeSessionID` and otherwise seeds from `tab.*` exactly as a cold launch does, so both a relaunched app and a chat resumed into a new tab start from the snapshot rather than from the conversation. That snapshot is only a starting guess, and the stream fixes it for `model` and `permissionMode`: the `init` event reports both, and `handle(_:)` overwrites the seeded values with whatever the CLI actually resumed with (`HeadlessSession.swift:227-232`). Effort is the exception, and structurally so — no `set_effort` control request exists and nothing reports effort back, so `initialEffort` is never corrected and the control shows what this host last sent, which a `/effort` typed straight into the CLI would silently contradict. Until the protocol reports effort, the snapshot is the best available answer rather than a bug to fix; what is worth checking is that the seeded value is visibly a guess and that the `init` correction is not itself overwritten by a stale write-back of the snapshot.

## The plan overlay

Today the overlay never opens on its own: `planPresentation` starts `.closed` (`ChatTabView.swift:13`) and every assignment of `.expanded` sits behind a button (lines 146, 204), so it is a viewer the user opens rather than a presentation the agent triggers. It should be both — presenting a proposal for approval, and reviewing the plan once approved.

- [ ] Let the feedback field grow to several lines, following the composer's send-key setting.
- [ ] ⌥↩ approves with feedback — the CLI's third option: take the note and auto-approve whatever plan comes back. Caption it beneath the field, since nothing else reveals the key.
- [ ] Label the reject button "Reject" until the user types, then "Give feedback".
- [ ] Confirm **Approve** starts work in auto mode where that is enabled. It resolves the request and minimizes the overlay; whether auto mode then picks it up was not verified.

**The overlay always reads the file.** An `ExitPlanMode` input carries both `plan` (the markdown) and `planFilePath` (`InteractiveToolPayload.swift:41`), and the latter is the same path `TranscriptParser` records from the `plan_mode` attachment line and the overlay already renders. So the two content sources are one: the overlay keeps its existing `MarkdownFileStore` path unchanged and gains live updates for free if the plan is rewritten. The payload's markdown is not a second source to merge; it is what the inline row summarizes.

**Interrupting the reader is fine**, as long as the overlay can be minimized — which it already can (`PlanPresentation.minimized` docks it as a bar above the composer). So a proposal expands over the conversation and the user dismisses it if they were mid-thought; no special quiet-arrival case is needed.

**The footer has three states**, driven by where the plan stands rather than by how the overlay was opened:

| State | Footer |
|---|---|
| Proposed, awaiting a decision | The approval options |
| Approved | "Approved" |
| Any other time — before a proposal, or after a rejection | "Not approved yet" |

"Not approved yet" deliberately covers both of the third state's situations — never proposed, and proposed then rejected — because the plan may have been rewritten since the rejection, so saying anything about that rejection risks describing a document that no longer exists. It speaks only to the state that is still true.

**The feedback field is single-line today.** `TextField("Feedback (optional)", …)` in `planApprovalOptions` (`ChatTabView.swift:298`) takes no `axis`, so a long rejection scrolls sideways in one line — where `ChatComposer` and the AskUserQuestion field (`InteractiveToolRow.swift:270`) both pass `axis: .vertical` and grow. The keys follow `AppSettings.composerSendKey` like the composer does, so one setting governs both fields and the pair stays consistent however it is set. That replaces today's binding, where Return is wired to `.onSubmit { answerPlan(.reject) }` and sends the rejection outright. No caption is needed for a newline the composer already teaches.

**⌥↩ is the one key worth captioning**, because nothing on screen reveals it and it is the only way to reach the third option. It resolves the request as an approval while passing the typed note along, so it needs a control request that carries both — unlike **Approve**, which sends no message, and **Give feedback**, which denies through `PlanResolution.denialMessage`. Settle what the caption says once the binding exists.

**"Give feedback" mislabels an empty field.** With nothing typed the button is a plain rejection, and `denialMessage(reason:)` already says so on the wire — it trims the reason and falls back to a bare rejection prefix when it is blank (`PermissionAnswerState.swift:98-102`). So the label should read "Reject" until `planRejectionReason` is non-empty and "Give feedback" after, matching a distinction the wire format already makes. Watch the button width changing mid-type; the tab chip's reserved close-button slot is the precedent for keeping a control from resizing under the pointer.

One thing to get right: a plan file exists *before* it is ever proposed. `TranscriptParser` records `planFilePath` from a `plan_mode` line as well as `plan_mode_exit` (`TranscriptEntry.swift:238`), so the agent writing a plan is enough to make it viewable. That is the same third state, and it means the footer cannot be derived from the file's existence — it needs the state of the most recent `ExitPlanMode` call and its answer.

## Interactive rows: plans and questions

- [x] Let a question be answered free-form as well as by option. Claude Code's own prompt always offers an "Other" escape hatch; Plume's card offers only the listed options, so a question whose real answer isn't among them has nowhere to go but the composer.
- [ ] Settle how a compacted context reads. It arrived rendered as an ordinary message from the user, which it is not; it now collapses to a marker row labelled "Compacted context". Whether that is the right disclosure — a marker, an expandable row, or something else — is still open.

**Free-form answers shipped.** The wire needed nothing new: an `Answer.questions` payload is already question text -> an arbitrary string, so typed text rides the control plane as-is. A question is now answered by chosen options *or* typed text, never both — setting either clears the other, so `isComplete`, `answers(for:)`, the primary button's enabled state and what actually gets sent all read one source of truth per question. The field renders only on an answerable row, leaving the transcript's read-only copy unchanged.

The answers on a settled block come from the tool result's own text, parsed in `InteractiveToolPayload.answers(from:for:)`. The `updatedInput` that carries them to the model never lands back in the transcript, so that text is the only place they survive a reload. It is a fixed-format string rather than JSON, so the parse anchors on each known question's exact text and degrades to showing nothing rather than guessing.

**A resolved row still wants a settled state.** `InteractiveToolRow` is answerable only when a caller hands it an `answer` closure: `PendingPermissionDock` supplies one, `ToolCallRow` does not. While a request is live the dock's answerable row covers for the transcript's read-only copy underneath. What is still missing is a settled presentation for a rejected plan — "Rejected", with the reason — rather than the row simply falling back to its non-answerable rendering. (An earlier note here described a stale `answerHint("Approve or reject in the terminal.")`; no such hint exists in the code.)

## Streaming vs. settled spacing

- [x] Give a streaming response the same space above it that a finished one has. A reply sits tighter to the message above while it streams, then shifts down once the transcript takes over — so the text moves as the turn settles.

`StreamingBlocks` mounts in two places and only one was padded like a message. Inside `ChatMessageRow.assistantBody` it inherits that body's `.padding(.vertical, 4)`; mounted standalone in `ChatMessageList` — the case for a turn that has not produced an assistant message yet — it got the list padding and nothing else, rendering 4pt tighter. The standalone mount now pays that inset itself. Putting it on `StreamingBlocks` instead was tried and reverted: the view is a mid-stack element inside `assistantBody`, so unconditional padding there would have doubled up and widened the mid-turn gap between settled and streaming text.

## The context window meter

- [x] Work out why the meter reads a full window. **Diagnosed and fixed:** the numerator was measuring throughput, not context size.

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

**The label stays unclamped, deliberately.** An earlier plan was to clamp `tokenLabel` and `percentage` so an over-count could not print a literal "1M/1M". That is rejected: the unclamped label is exactly what made this bug visible, and clamping would have hidden it while leaving the arithmetic wrong. `StatuslineMeterMath.fraction` still pins the bar to 0–1; the label is the honest signal and should stay that way.

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
- The skills item depends on the renderer, not the other way round: telling Claude to draw mermaid before Plume can render it just produces fenced source. Sequence it after the mermaid work, and scope what the skill promises to what the renderer actually supports. Tables are now safe for a skill to encourage; mermaid is not, until it renders.

## PR/MR state in the sidebar

Help me keep track of tasks once they leave my machine.

- [ ] Show PR/MR state the way my `wt` / `stack` utilities do, build and review state included.
- [ ] Use the existing `glab` / `gh` CLI auth.

What exists: nothing uses `gh` or `glab` yet. `WorkTask.integrationsData` is reserved for exactly this and is still unused.

## Task creation and directories

Make creating a task cheap, and stop pretending a task has one directory.

- [ ] ⌘N inherits the selected task's working directory instead of leaving the workspace unset.
- [ ] Let the worktree choice happen *after* picking a directory, not before.
- [ ] Move the working directory onto tabs. A task probably doesn't need one.
- [ ] Track where an agent actually is — including when Claude uses `EnterWorktree` — and use that as the tab's current directory, e.g. when opening a new tab from it.

What exists:

- The directory lives on `WorkTask` today (`workingDirectoryPath`, plus `repoPath` / `branchName` / `workspaceKind`), and it's read in roughly ten places across the sidebar, setup header, launcher and resume path. Moving it to `TaskTab` is the widest change on this list, though most call sites are a mechanical hop from `task.` to `tab.`. The question to settle first is what a task's identity becomes once it no longer owns a directory, and what the sidebar shows when a task's tabs disagree.
- `TerminalSession` **already tracks the live working directory per tab**, mirrored from the terminal's own reports — so a per-tab cwd is closer to how things already behave than the persisted per-task path is.
- `EnterWorktree` needs no special handling. Its `tool_use` input records the absolute path, but every transcript line afterwards also carries the new `cwd`, verified on a real session that moved into `.worktrees/…` mid-run. So reading `cwd` from the newest transcript line picks up `EnterWorktree` and every other directory change through one mechanism. `SessionJSONLReader` already reads these files.
- Creation is already frictionless in the sense of "no modal" — ⌘N makes a task immediately with `workspaceKind = .unset`, and `TaskSetupHeaderView` offers Choose Folder / New Worktree afterwards. What's missing is a sensible default and a worktree flow that doesn't have to be decided up front.

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

Fonts sit alongside this, and the two halves of the app treat them differently. The terminal takes its font from the user's ghostty config, which is right — it should keep matching their terminal. The chat hardcodes `.system` for prose and `.monospaced` for code in `MarkdownView`, `ChatMessageRow` and `MarkdownComposerStyler`; only the *size* is configurable (`AppSettings.chatFontSize`, clamped 11–28). So the work is a family setting to sit beside the size, threaded the same way through the environment, with prose and code chosen separately — a proportional body font next to a monospaced code font is the point, not one setting for both. Defaulting to the terminal's configured font for code is a reasonable starting point that needs no bundling at all. Prose is the half that's already decided.

**Libre Baskerville is the prose face**, bundled in `Plume/Resources/Fonts/` under SIL Open Font License 1.1 with its license file alongside. Newsreader was tried first and swapped out. Two differences worth knowing: Libre Baskerville is variable on `wght` alone (400–700), with no `opsz` axis, so nothing tracks the point size — and its family name is plain `Libre Baskerville`, where Newsreader's compatibility family was `Newsreader 16pt` against a typographic family of `Newsreader`, two names that were not interchangeable. It runs visually larger than Newsreader at the same point size, so `chatFontSize` may want revisiting. Registration is by CoreText at launch (`BundledFonts`), not `ATSApplicationFontsPath` — see the note below. Italics come from the italic file rather than a synthesized slant, which `ComposerProseFontTests` locks in by asserting the derived face has a different PostScript name from the upright.

**`INFOPLIST_KEY_ATSApplicationFontsPath` does not work here.** Xcode's Info.plist generator has no mapping for it, so the key never reaches the built plist — `INFOPLIST_KEY_LSApplicationCategoryType` beside it generates fine, which is what proves the mechanism rather than the spelling is at fault. The project generates its plist and has no file to add the key to. `BundledFonts.registerIfNeeded()` calls `CTFontManagerRegisterFontsForURL` at launch instead, which also sidesteps bundle layout: file-system synchronized groups flatten `Plume/Resources/Fonts/` into `Contents/Resources` rather than preserving the directory.

What exists: `GhosttyThemeResolver` and `ThemeChrome` already tint the sidebar and tab strip from the user's resolved ghostty theme, and `Color(hex:)` exists, so this extends a theming layer rather than starting one. Lum in `lum.css` is a 14-hue × 8-tone system whose tone names already split light from dark (`-28`/`-35`/`-on-dark` vs `-93`/`-97`/`-on-light`/`-on-white`) — richer than the 16-color ghostty theme, and a good fit for group and task colors.

## Tabs and window chrome

- [ ] One tab kind. "New Tab" opens a shell; when `claude` is running in it, the tab takes on agent chrome — no agent-vs-terminal prompt at creation.
- [ ] Remove the unused title bar, or move something into it (task name? directory?).
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
- [ ] ⌘W closes the current tab, not the window.

What exists: next/previous *tab* is already bound to ⌘⇧] / ⌘⇧[ (`PlumeCommands`), and ⌘T already opens a tab in the current task — it's labelled "New Agent Tab", with ⌘⇧T for a terminal tab. Collapsing to one tab kind (see **Tabs and window chrome**) makes ⌘T just "New Tab" and frees ⌘⇧T. There is no next/previous *task* command at all yet. Nothing is user-assignable: every shortcut is hardcoded in a SwiftUI `Commands` body, so making them configurable means a binding store, a settings UI, and a way to apply a stored binding to a menu command. Alt-based chords are also the case most likely to collide with the terminal swallowing keys, which ties this to the focus item under **Misc UX**. ⌘W is AppKit's window-close default and no command overrides it, so taking it means declaring a `CommandGroup` that claims the binding and falls back to closing the window when the task has no tabs left.

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
- [ ] Drag and drop to reorder tabs.
- [ ] Decide whether a restored agent tab auto-resumes on launch or waits to be selected.
- [ ] Give archived tasks better names in the archive. An unnamed task shows nothing at all there.
- [ ] Focus the composer when a new tab or task opens.

What exists:

- Shortcuts are plain SwiftUI `Commands` gated on `@FocusedValue`, with no low-level key interception, which is likely why they don't survive terminal focus.
- Focus is never placed programmatically today, so a new tab renders with nothing focused and the first keystroke goes nowhere. The two transports need different answers: a headless tab has a real `TextField` to focus, while a terminal tab's focus is the ghostty surface.
- `.onMove` reorders sidebar tasks, but `TabStripView` has no drag support.
- The archive is the one task list that doesn't go through `TitleStore`. `ArchiveView` renders raw `task.title` (`ArchiveView.swift:19`), while the live sidebar uses `TitleStore.shared.displayTitle(for:)` (`TaskRowView.swift:40`), which falls back to the representative tab's title and finally to "Untitled". So a task the user never named renders as an empty string in the archive — not even a placeholder. Switching to `displayTitle(for:)` fixes the blank rows; whether a better name is available is a second question, since the tab title it falls back to is itself gone once the tabs are. The archived row already shows the working directory beneath the title, which is often the more identifying of the two.
- Restoring the selection has shipped: `LastOpenTask` persists the selected task's UUID and `MainWindow` restores it, matching the per-task selected tab that `WorkTask.selectedTabID` already carried. A task archived or deleted since the last launch doesn't match and the pane opens empty. What's left is the auto-resume question, which is a behavior decision rather than plumbing: the existing rule deliberately avoids spawning `claude` for every agent tab at startup, and reopening a tab shouldn't quietly undo that.

## Make the UI drivable

Give the interface an accessibility surface, so both `PlumeUITests` and an
agent driving the app can find and operate controls by name.

- [ ] Put accessibility identifiers on the controls worth driving: the sidebar's task rows, the tab strip, the composer field and send button, the statusline's dropdowns, and the plan overlay's approve/reject buttons.
- [ ] Grow `PlumeUITests` past launching the app, now that there is something to query.

What exists:

- The app is effectively opaque to the accessibility tree today. `entire contents of window 1` returns **0** elements and every top-level element's `name` is `missing value`, so nothing can be found by name or role. Coordinate clicks and keyboard shortcuts work; everything else does not.
- That is the ceiling on automated verification. `PlumeUITests` launches the app and stops there, and an agent checking a change can screenshot the result but cannot operate the control it just changed — so a visual check needs a person to click first.
- SwiftUI supplies identifiers through `.accessibilityIdentifier(_:)` and labels through `.accessibilityLabel(_:)`. A few of the latter already exist (the composer's send button, for one), so this is extending a pattern rather than introducing one.
- Worth doing before the next round of UI work rather than after: the chat, statusline and composer are all being reshaped right now, and identifiers added while a view is already open cost far less than a separate pass over settled code.

## Worktrees

Create and delete moved onto `GitService` and have not been driven since. The feature ships with a WIP marker so its state is honest — that marker is in place; what it covers is still unverified.

- [ ] Create and delete a worktree, now that both run on `GitService` rather than the main thread.
- [ ] Make `git worktree remove` fail, and confirm the task survives with the error shown.

The marker shows on the "New Worktree…" button (`WorkspacePickerView.swift:128`), the sheet's title (`NewWorktreeSheet.swift:20`), and the two destructive delete items (`SidebarView.swift:100,103`). The delete items are the ones that most need it — they are irreversible, and their failure path is the least exercised code in the feature. Settle one marker and use it everywhere, since this will not be the last unfinished feature to ship visible.

What exists:

- `WorkspaceProvisioner.removeWorktree` passes `--force`, so ordinary "dirty tree" refusals never reach the failure handler (`SidebarView.swift:141-145`) — reproducing it needs `git worktree lock` or an already-removed path.
- The riskiest part is the git conversions, because they changed *when* a value appears rather than what it is. `task.repoPath` is now written after `GitService` answers instead of during the call that sets the folder, so anything reading it in the same turn sees nil where it used to see a path. Nothing does today; that is the assumption to check.
- `SidebarView.deleteTask` was restructured around the same change: the git call moved into a `Task`, so the early `return` that aborted a delete on failure became a `finishDeleting` continuation. The success path is ordinary use, but the failure path — git refuses, the task stays, the error shows — has never run.
