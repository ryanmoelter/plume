# Plume roadmap

Features we intend to build. Each section records what we want and what the code already provides — it doesn't say how to build any of it. Work out the approach when you pick an item up.

Sizes are rough: **S** is a call site or two, **M** is a contained feature, **L** touches several files or needs a design decision, **XL** is wide or deep enough to plan on its own.

## Up Next

The queue, highest priority first. Each line points at the section holding the detail; nothing here repeats it.

1. **S** — Clamp the context meter's label, then work out why it reads a full window. See [The context window meter](#the-context-window-meter).
2. **S** — Fix the session cost figure: it double-counts, and the error compounds every turn. Confirmed by probing the wire. See [The statusline](#the-statusline).
3. **S** — Free-form answers to questions, as an option alongside the listed ones. See [Interactive rows: plans and questions](#interactive-rows-plans-and-questions).
4. **S** — `!` command execution mode in the composer, monospace styling first. See [The composer](#the-composer).
5. **S** — `/btw` support, as the first case of the local echo for intercepted commands. See [The composer](#the-composer).
6. **S** — Give a streaming response the same space above it a finished one has. See [Streaming vs. settled spacing](#streaming-vs-settled-spacing).
7. **S** — Move the stop button out of the statusline, to the left of the send button. See [The statusline](#the-statusline).
8. **S** — Cap the width of a tab chip with a long name. See [Tabs and window chrome](#tabs-and-window-chrome).
9. **S** — Copy icon on code blocks, bundled with giving them more padding inside the border. Same view, same edit. See [The markdown renderer](#the-markdown-renderer).
10. **S** — Remember effort and permission mode per session. See [The statusline](#the-statusline).
11. **S** — ⌘N opens a task in the current group. See [Groups](#groups).
12. **S** — Terminal bell, with a dot on tabs that rang one. See [Notifications](#notifications).
13. **M** — System notification on bell, then on Claude Code events — above all waiting-for-input. See [Notifications](#notifications).
14. **L** — Subagents as a real view rather than a disclosure row. The case Plume exists to make legible, and currently the weakest part of the chat. See [Subagents](#subagents).
15. **L** — Mermaid diagrams in the markdown renderer. Blocked on one decision — WebKit or a native subset. See [The markdown renderer](#the-markdown-renderer).

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
- [ ] Give code blocks more padding inside their border, and a copy icon while hovering them.
- [ ] Distinguish a bash block's input from its result — they currently render alike.
- [ ] Put real newlines in a bash input block.
- [ ] Mermaid diagrams in the same renderer. Still needs its approach settled — WebKit or a native subset.

Padding and the copy icon are one edit: both land in `MarkdownView`'s `case .codeBlock`, which is a `Text` at `.padding(8)` inside a horizontal `ScrollView` (`MarkdownView.swift:95-103`). The scroll view is the thing to get right — an icon placed inside it scrolls away with the code, so it wants to be an `overlay` on the background container instead, where it stays put. Nothing in the app uses `NSPasteboard` yet, so this introduces that; copy the block's raw `code` string, which is already to hand and unstyled. `.textSelection(.enabled)` is not a substitute here — selecting a horizontally scrolled block by hand is the friction the icon removes.

Tables shipped native and did **not** settle the mermaid question. The two are separate problems: a table's layout is given by its source, so `Grid` is the whole implementation, while a diagram needs a layout *algorithm* — node ranking and edge routing — which is the entire job and shares nothing with tables beyond the fence.

What tables leave behind for it: `MarkdownBlock.codeBlock` already carries the fence's `language`, so detecting a mermaid fence costs nothing. `MarkdownView` currently discards that language — that is the seam to branch on. Note that a native subset degrades badly the moment a diagram uses an unsupported shape, which is the main argument for WebKit here even though tables didn't need it.

## The composer

- [ ] Give the first message a nicer intermediate state. The composer currently disappears before the message appears; disabling it in place would read better.
- [ ] Make the composer content-width rather than bleed-width.
- [ ] Echo a CLI-intercepted slash command locally, and show that it is running.
- [ ] `/btw` support — confirm the note is actually filed, and show it in the chat. It takes no turn, so today nothing in the UI changes when you send one.
- [ ] Decide whether the rejection-feedback submit button belongs inside the text field.
- [ ] Command execution mode. A leading `!` means "run this rather than say it", the way the CLI's bash mode does. While the message starts with `!`, style the rest of it monospaced — plain monospace, no code-chip background, so it reads as a different mode rather than as an inline code span.

A slash command the CLI handles itself never reaches the transcript, so the chat shows nothing at all while it runs. `/compact` is the case that hurts: this project's transcript holds **11** `compact_boundary` markers and **zero** `/compact` user messages, and compaction takes upwards of a minute and a half with no message, no spinner and no sign the command was received. `submit(text:)` only sends; the chat renders from the transcript, so anything the CLI intercepts vanishes. The fix is a locally-rendered echo plus a working indicator, driven from Plume's own state rather than the transcript — and it generalizes past `/compact` to every intercepted command.

Command mode has a styling half and a behavior half, and the styling half stands alone. `MarkdownComposerStyler` already turns a recognized slash command's token accent-colored via `SlashCommandMatcher.recognizedCommandRange`, so a line-leading `!` is the same shape of check: recognize the prefix, then restyle the remainder. What it can't reuse is `MarkdownHighlighter`'s `.inlineCode` span — that one carries `codeBackgroundColor`, which is exactly the chip look this shouldn't have. So it wants either a new style case with font but no background, or a direct attribute pass beside the slash-command one. What the `!` then *does* on send is the open half: the CLI intercepts its own bash mode, and Plume's `send()` hands text to `HeadlessSession.submit(text:)`, so a `!` message either passes through and relies on the CLI, or Plume runs it and echoes the result itself — the same locally-rendered-echo problem `/compact` has.

`/btw` is the sharpest case of that same problem, and needs nothing new to *send*. Slash commands are discovered rather than hardcoded — `HeadlessSession` reads them from the `initialize` reply's `commands` array (`HeadlessSession.swift:283-293`), so `/btw` already autocompletes and already styles as recognized if the CLI reports it. What it lacks is any evidence of having worked: it files a note without taking a turn, so there is no assistant message, no tool call and no transcript line to render — the composer just empties and the chat looks identical. That makes it a better first case for the local echo than `/compact`, which at least has a `compact_boundary` marker to anchor on. Worth checking first whether the note is filed at all on this transport, since a silent no-op and a working command are indistinguishable from the UI today.

## The statusline

`HeadlessSession` now owns `permissionMode`/`model`/`effort` as observable state, set optimistically when the host asks for a change and corrected from the stream (`system`/`init` for model and permission mode — there is no `set_effort` control request, so effort is never corrected, only ever what this host last sent). The strip and composer read this instead of the transcript, fixing the old bug where a control wrote through the session but displayed transcript state.

Still open:

- [ ] Stop accumulating `total_cost_usd`. It is already a running conversation total, so `+=` re-adds every prior turn and the displayed figure compounds. Assign it instead, and correct `docs/headless-protocol.md`, which records the wrong semantics.
- [ ] Move the stop button out of the statusline and put it left of the send button — a circular icon button with a dim background, mirroring send's shape.
- [ ] Consider moving the whole strip inside the composer box, if a compact form fits a narrow viewport.
- [ ] Customization UI, once a segment shape settles. `ComposerControlsRow`'s segments are already self-contained — each reads and writes only its own piece of session state — so this is additive, not a rewrite.
- [ ] The composer's two-row split is a first cut (plain `HStack`s, no styling pass) — revisit layout and spacing.
- [ ] Remember effort and permission mode per session, the way the context window already is.

**The session cost double-counts, and the error compounds.** `total_cost_usd` is a **running total for the whole conversation**, re-sent on every `result` event — not a per-turn charge. Plume accumulates it anyway (`sessionCostUSD += cost`, `HeadlessSession.swift:307`), so each turn re-adds every turn before it.

Verified on the wire rather than from the schema. Feeding several trivial messages into one `claude -p --input-format stream-json` session, the reported total rises turn over turn while `cache_read_input_tokens` climbs — turn 1 reported `$0.028072`, turn 2 `$0.034789` for a turn that produced **8 output tokens**. Eight Haiku tokens cost a fraction of a cent, so a per-turn field would have reported ~`$0.003`, not `$0.035`. The value is cumulative.

The overcount grows with conversation length: it is 1.0x after one turn, ~1.8x after two, and a 20-turn session whose true cost reaches $5 displays about **$52**. That shape — a figure that lurches by more than the turn could possibly have cost, and lurches harder the longer the session runs — is exactly the reported symptom.

The fix is to assign rather than add, which also makes the number correct across a resume: `sessionCostUSD` is in-memory only and nothing persists it on `TaskTab`, but a cumulative field re-sent each turn means the first `result` after a `--resume` already carries the true total. **`docs/headless-protocol.md:145` states the opposite** and must be corrected in the same change — it is the source of the wrong assumption, and the code comment on `TurnResult.totalCostUSD` repeats it (`StreamJSONMessage.swift:74`). Note the per-model `costUSD` values in `modelUsage` sum to the same figure, so they are cumulative too and are not an independent cross-check.

The stop button is the one control in the strip that isn't a session-wide fact, so moving it finishes the split the rest of the strip already made. It lives in `ChatTabView` rather than `StatuslineStripView` — a `Label("Stop", systemImage: "stop.fill")` shown beside the strip while `headlessSession?.isWorking == true` (`ChatTabView.swift:128-130`, `456-468`) — so it moves into `ChatComposer`'s bottom `HStack`, beside `sendButton`. Send is a 22pt circular `.borderedProminent` (`ChatComposer.swift:151-164`); matching its diameter and `buttonBorderShape(.circle)` with a dim fill instead of the accent one is what makes the pair read as siblings. `isWorking` and `hasSendableText` are independent, so both buttons can show at once — worth deciding whether stop replaces send while a turn runs or sits beside it.

`TaskTab.contextWindowTokens` holds the last window a turn reported, written from `ChatTabView` when the session's value changes — once per turn rather than per stream event, so it stays a snapshot rather than a stream of writes. Effort and permission mode want the same treatment for a different reason: neither survives a relaunch today, and effort has no source at all beyond what this host last sent (there is no `set_effort` control request to report it back), so a resumed tab shows no effort and whatever mode the launch flag supplied. Persisting both means a reopened conversation resumes as it was left, and gives the effort control a value to show instead of its placeholder. A stored mode wins over `AppSettings.defaultPermissionMode`: the tab reopens in the mode it was last in, because that is the mode the user last saw it in. The default only applies to a tab that has never had one, so changing it never retroactively moves an existing conversation.

## The plan overlay

Today the overlay never opens on its own: `planPresentation` starts `.closed` (`ChatTabView.swift:13`) and every assignment of `.expanded` sits behind a button (lines 146, 204), so it is a viewer the user opens rather than a presentation the agent triggers. It should be both — presenting a proposal for approval, and reviewing the plan once approved.

- [ ] The CLI's third option — reject with feedback, then auto-approve whatever plan comes back — is still worth having, but its UX here is unsettled. One idea: alt+return while typing a rejection.
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

One thing to get right: a plan file exists *before* it is ever proposed. `TranscriptParser` records `planFilePath` from a `plan_mode` line as well as `plan_mode_exit` (`TranscriptEntry.swift:238`), so the agent writing a plan is enough to make it viewable. That is the same third state, and it means the footer cannot be derived from the file's existence — it needs the state of the most recent `ExitPlanMode` call and its answer.

## Interactive rows: plans and questions

- [ ] Let a question be answered free-form as well as by option. Claude Code's own prompt always offers an "Other" escape hatch; Plume's card offers only the listed options, so a question whose real answer isn't among them has nowhere to go but the composer.
- [ ] Settle how a compacted context reads. It arrived rendered as an ordinary message from the user, which it is not; it now collapses to a marker row labelled "Compacted context". Whether that is the right disclosure — a marker, an expandable row, or something else — is still open.

**A free-form answer needs no new wire format.** An `Answer.questions` payload is already question text -> an arbitrary string (`PermissionAnswerState.answers(for:)` just happens to build it by joining chosen labels), so the control plane carries typed text as-is. The work is in the card and in `PermissionAnswerState`: a selection becomes either options or free text, `isComplete` has to accept a non-empty string, and `QuestionPrimaryAction` has to stop treating an empty option set as unanswered. Settled rendering comes back for free — `answers(from:for:)` reads whatever the result text records, without caring where it came from.

The answers on a settled block come from the tool result's own text, parsed in `InteractiveToolPayload.answers(from:for:)`. The `updatedInput` that carries them to the model never lands back in the transcript, so that text is the only place they survive a reload. It is a fixed-format string rather than JSON, so the parse anchors on each known question's exact text and degrades to showing nothing rather than guessing.

**The stale hint is a real bug, and the plan overlay work retires half of it.** `InteractiveToolRow` is answerable only when a caller hands it an `answer` closure. `PendingPermissionDock.swift:23` supplies one; `ToolCallRow.swift:18` does not, so the transcript's copy of the same plan always falls through to `answerHint("Approve or reject in the terminal.")` (`InteractiveToolRow.swift:72`). While a request is live the dock's answerable row covers for it. Answering removes the pending entry, the dock's row disappears, and the transcript row underneath — with its terminal hint — is what's left showing until the next transcript parse catches up. So the hint is not merely stale, it is wrong on the headless transport, where the terminal is not where you answer. Fix the hint to reflect the tab's transport, and give the resolved row a settled state ("Rejected", with the reason) rather than an instruction to act.

## Streaming vs. settled spacing

- [ ] Give a streaming response the same space above it that a finished one has. A reply sits tighter to the message above while it streams, then shifts down once the transcript takes over — so the text moves as the turn settles.

`StreamingBlocks` mounts in two places, and only one of them is padded like a message. Inside `ChatMessageRow.assistantBody` it inherits that body's `.padding(.vertical, 4)` (`ChatMessageRow.swift:96`), which is what a settled assistant row pays on top of the list's own `dimensions.verticalPadding`. Mounted standalone in `ChatMessageList` — the case for a turn that has not produced an assistant message yet (`ChatMessageList.swift:93-95`) — it gets the list padding and nothing else, so it renders 4pt tighter top and bottom. Both mounts already agree horizontally: each takes `.listItemPadding(bleed: true, column: .unpadded)`, and the inset is paid inside by `MarkdownView`'s own per-block `.listItemPadding(vertical: false)`, so this is vertical only.

The fix belongs on `StreamingBlocks` rather than at either call site, so the two mounts cannot drift apart again — but note it would then double up inside `assistantBody`, which already supplies it. Either move that padding out of `assistantBody` onto the blocks it wraps, or have the standalone mount pay it. A row whose height changes as it settles is also what the scroll follow behavior measures against, so check the two together.

## The context window meter

- [ ] Work out why the meter reads a full window. Seen live as **1M/1M** on a session nowhere near full, so both halves of the fraction are suspect and the number is currently not trustworthy.

Not diagnosed — what follows is where to look, with the one thing that is settled first.

**The label is unclamped while the bar is clamped.** `StatuslineMeterMath.fraction` pins the meter to 0–1 (`StatuslineStripView.swift:222-225`), but `tokenLabel` formats `used` and `max` straight through `formatTokenCount` (`StatuslineStripView.swift:141-145`), and `percentage` divides without a ceiling (line 136-139). So an over-count shows as a pinned bar beside a literal "1M/1M" rather than as anything obviously broken — which is why this reads as a wrong number instead of a visible overflow. Worth clamping the label regardless of the cause, so the next miscount announces itself.

Two candidates for the number itself, and they are testable separately since the numerator and denominator come from different places:

- **The denominator.** `contextWindow` is the largest `contextWindow` across the turn's `modelUsage` (`StreamJSONDecoder.swift:117-123`), which deliberately takes the max so a subagent's smaller window does not win. A 1M-context model on the main thread makes 1M the correct denominator, so 1M is not itself evidence of a bug here — but it does mean the numerator has to reach 1M for the fraction to fill, which is the part that does not add up.
- **The numerator.** `ContextUsage.total` sums `input + cache_read + cache_creation + output` (`StreamJSONMessage.swift:102-106`). Sampling a real 83-turn transcript, this lands where it should — the last turns read `in 2 / cr 169413 / cc 430 / out 694`, totalling ~170K against the model's window, not a full one. So the shared arithmetic is sound on transcript data, and both paths take the *latest* usage rather than accumulating (`TranscriptParser.swift:100`), which rules out the obvious cross-turn double count.

**The cost double-count does not extend to the context numbers, and probing the wire narrowed this further.** Both are read from a `result` event, but from different keys, and only one of the two shapes is cumulative:

| Source | Shape | What Plume reads it for |
|---|---|---|
| `usage{}` at the root | **Per turn** | `contextUsedTokens` — correct |
| `modelUsage{}` token counts | **Cumulative** | nothing — dodged |
| `modelUsage{}.contextWindow` | A constant (`200000`) | `contextWindow` — correct |
| `total_cost_usd` | **Cumulative** | `sessionCostUSD`, wrongly accumulated — see [The statusline](#the-statusline) |

Measured over two turns of one session: root `usage.input_tokens` stayed 3 and `output_tokens` stayed 4, while `modelUsage`'s `inputTokens` went 3 → 6 and `outputTokens` 4 → 8, and its `cacheReadInputTokens` went 13979 → 42705 (which is 13979 + 28726, the prior turn's total). So `modelUsage` sums across turns and root `usage` does not. `StreamJSONDecoder.turnResult` takes all four token counts from `root["usage"]` (`StreamJSONDecoder.swift:100,107-111`) and only `contextWindow` from `modelUsage`, so the meter's numerator is genuinely per-turn.

That also confirms `ContextUsage.total`'s four-way sum is not a double count *within* a payload: turn 2's `cache_read` (28726) is approximately turn 1's full total (28733), which is what a growing conversation looks like when each turn's context becomes the next turn's cache read. The sum equals the context actually sent.

So the 1M/1M reading is not explained by either mechanism, and both obvious arithmetic suspects are now eliminated. What remains unexplained is a denominator of 1M with a numerator that reached it. Note the probe ran on Haiku, which reports `contextWindow: 200000` — reproducing this needs a 1M-context model, where `largestContextWindow` taking the max across `modelUsage` is worth re-examining, since that is the one place a value from a *different* model than the main thread could win.

That leaves the live stream path as the least-examined half: the numbers above came from `TranscriptUsage`, while the meter prefers `headlessSession?.contextUsedTokens` and only falls back to the transcript (`ChatTabView.swift:118-122`). A `result` payload whose `usage` differs in shape from a transcript entry's — or a `modelUsage` carrying a window that is not the main thread's — would show up here and nowhere in the transcript sampling. Capture a raw `result` event from a session showing a wrong meter before changing any of the arithmetic; the stored `tab.contextWindowTokens` fallback is a third possible source and a stale one persists across relaunches.

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
- [ ] Rebalance the chat chrome: put the titlebar's empty space to work. The statusline/composer split (see **The statusline**) already moved the next-message controls into the message box; what's left is the titlebar itself.
- [ ] Cap a tab chip's width, so a long title can't take the whole strip. Much shorter than today's, which grows to fit whatever the title is.
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

What exists: next/previous *tab* is already bound to ⌘⇧] / ⌘⇧[ (`PlumeCommands`), and ⌘T already opens a tab in the current task — it's labelled "New Agent Tab", with ⌘⇧T for a terminal tab. Collapsing to one tab kind (see **Tabs and window chrome**) makes ⌘T just "New Tab" and frees ⌘⇧T. There is no next/previous *task* command at all yet. Nothing is user-assignable: every shortcut is hardcoded in a SwiftUI `Commands` body, so making them configurable means a binding store, a settings UI, and a way to apply a stored binding to a menu command. Alt-based chords are also the case most likely to collide with the terminal swallowing keys, which ties this to the focus item under **Misc UX**.

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

What exists:

- Shortcuts are plain SwiftUI `Commands` gated on `@FocusedValue`, with no low-level key interception, which is likely why they don't survive terminal focus.
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
