# How Plume drives Claude Code, and the ceiling on that approach

Plume runs the real `claude` TUI in a Ghostty PTY and automates it like a human. That works, but it has a ceiling. This document records where the ceiling is, what the alternatives are, and what Craft Agents does instead — so the decision can be made deliberately rather than rediscovered.

Nothing here is a commitment. No transport change is proposed.

## What Plume does today

- `ClaudeCodeProvider.launchCommand` builds an argv: `claude [--settings X] [--permission-mode Y] [--resume Z] ["first message"]`, wrapped by `LoginShellCommand.wrap` and handed to `SurfaceManager` as a PTY command.
- `TerminalSession.submit(text:)` is `state.paste(text:)` then `state.sendKey(.enter)` — two operations, because bracketed paste swallows a trailing `\r`.
- `TerminalSession.cyclePermissionMode()` sends Shift+Tab, because no CLI setter exists mid-session. It *advances* by one and reads back where it landed.
- Output is read entirely out-of-band: transcript JSONL under `~/.claude/projects/` (`SessionJSONLReader`, `TranscriptParser`) plus hook events appended by the injected `--settings` file (`HookSettingsWriter`, `AgentEventMonitor`). Rendered terminal text is never scraped for content.

So output is already structured and decoupled. **Only the input path is TUI-coupled** — that is the whole of the problem.

## Where the ceiling is

Answering an `AskUserQuestion` natively is impossible: the composer pastes text, so it has no way to pick the third option of a running prompt. Setting a permission mode directly is impossible for the same reason — cycling is the only move available. Both limits are input-side; see the native-UI section of `roadmap.md`.

## What Craft Agents does

[Craft Agents](https://github.com/lukilabs/craft-agents-oss) (Apache 2.0, Electron + TypeScript) never runs the TUI. It calls the official `@anthropic-ai/claude-agent-sdk` — `query()` in `packages/shared/src/agent/claude-agent.ts` — which spawns `claude` as a non-interactive subprocess speaking `stream-json` in both directions. Their app talks to a TypeScript API, not to keystrokes.

That buys them, in SDK vocabulary: streaming structured messages; `resume` / `forkSession` / `resumeSessionAt` for continuation and branching; `AbortController`-backed interrupt; a `canUseTool`-style permission callback; `SubagentStart`/`SubagentStop` hooks; MCP via `createSdkMcpServer()`; and reduced-tool subagents.

**Their subscription support is OAuth they implement themselves.** They do not reuse the `claude` CLI's stored credentials. `packages/shared/src/auth/claude-oauth.ts` runs its own OAuth 2.0 + PKCE flow against `https://claude.ai/oauth/authorize` with their own client ID and the scopes `org:create_api_key user:profile user:inference`, stores tokens AES-256-GCM-encrypted at `~/.craft-agent/credentials.enc`, and before each subprocess spawn clears `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_BASE_URL` from the environment before injecting the right one back.

## The catch

Anthropic's Agent SDK overview carries this note verbatim:

> Unless previously approved, Anthropic does not allow third party developers to offer claude.ai login or rate limits for their products, including agents built on the Claude Agent SDK. Use the API key authentication methods described in the Quickstart instead.

So the SDK is not a sanctioned route to subscription auth for a shipped product. Separately, Anthropic's support article currently states that Agent SDK, `claude -p`, and third-party app usage still draw from the subscription's usage limits (a planned change to that was paused).

Plume is personal and single-user, which is a different position from Craft's. But the useful conclusion is that **copying Craft's auth is the wrong lesson to draw.** The valuable half of what they do — escaping the TUI — does not require it.

## The option that gets the benefit without touching auth

Spawning the real `claude` binary headlessly keeps subscription login working exactly as it does today, because it is the same binary reading the same credentials:

```
claude -p --output-format stream-json --input-format stream-json --include-partial-messages --verbose
```

This is the same machinery the SDK wraps, minus the TypeScript dependency a Swift app would find awkward. It yields newline-delimited JSON events (`system/init` with session metadata and capabilities, assistant/user messages, `parent_tool_use_id` for subagent attribution, `system/api_retry`), accepts structured input on stdin rather than pasted keystrokes, and supports `--resume` and `--permission-mode`.

Caveats worth knowing before costing this out:

- **Never pass `--bare`.** It explicitly does not read `CLAUDE_CODE_OAUTH_TOKEN` or the keychain, and would force an API key — the exact thing this option exists to avoid. It also skips skills, hooks, MCP, and CLAUDE.md.
- A `-p` session shows no workspace-trust dialog, and its built-in starting permission mode is Manual on every plan, so a mode must be passed explicitly.
- SIGTERM exits 143 and leaves the turn unfinished; SIGINT ends the turn cleanly.
- `AgentProvider` is command-line-shaped today (`AgentLaunch` is a command string plus environment). A headless backend needs a pipe-and-event seam, not just a different argv — the existing protocol is a starting point, not a fit.

The transcript-reading half of Plume is largely unaffected either way: `TranscriptParser` and `SessionJSONLReader` already produce the chat model, and `stream-json` events carry the same content in a live stream instead of a watched file.

## Comparison

| | Interactive TUI (today) | Headless `claude -p` stream-json | Claude Agent SDK (Craft's route) |
|---|---|---|---|
| Subscription auth | Works, unchanged | Works, unchanged (same binary, same credentials) | Sanctioned auth is an API key; subscription OAuth needs prior approval |
| Input path | Paste + synthetic Enter | Structured JSON on stdin | Typed API |
| Answer an `AskUserQuestion` | Impossible | Possible | Possible |
| Set permission mode mid-session | Shift+Tab cycling only | Possible | Possible |
| Interrupt | Ctrl+C keystroke | SIGINT | `AbortController` |
| Language fit for a Swift app | Native | Native (subprocess + pipes) | Poor — TS/Python library |
| Quota and session cost | Statusline capture only — a global `~/.claude/settings.json` rewrite | Native `rate_limit_event` and `result` events | Native |
| Terminal still available | It *is* the transport | Optional, alongside | Separate concern |

## Bottom line

The ceiling is real but narrow: input, not output. Craft escapes it with the Agent SDK, and their subscription support is a self-implemented OAuth flow that Anthropic's own docs steer third-party products away from. For Plume the same escape is available one layer down — the headless `claude` binary — with no change to how the user logs in.

Nothing here is urgent. The TUI path works, and the roadmap's read-only rendering items (injected content, plan and question presentation) are worth doing regardless of transport. This is a decision to make deliberately before building anything that depends on answering a running prompt.

## The statusline capture is TUI-only

Quota and session cost are the one thing Plume cannot read from a transcript, so today it captures them from the payload Claude Code pipes to a statusline command (`StatuslineCaptureWriter`, `StatuslineInstaller`, `StatuslinePayload`). **That mechanism does not survive a move to `claude -p`.** A statusline is TUI chrome, and a headless run draws none.

Verified against Claude Code 2.1.258: with a `statusLine` configured through `--settings`, a `-p` run never executes the script — checked with both the default output format and `--output-format stream-json`. The script is not called with empty input; it is not called at all.

Headless does not lose the data, though. It gets it natively, pushed as events:

- **`rate_limit_event`**, emitted *first*, before `system/init`. Carries `unifiedWindows.five_hour` and `unifiedWindows.seven_day`, each with `utilization` and `resetsAt`, plus `overageStatus` and `isUsingOverage`.
- **`result`**, emitted last. Carries `total_cost_usd`, a `usage` breakdown, and a per-model `modelUsage` map with `contextWindow` and `costUSD` for each model the turn touched — including subagent models, which the statusline payload does not report at all.

Mapping onto what `StatuslinePayload` decodes today:

| `StatuslinePayload` field | Headless source | Note |
|---|---|---|
| `rate_limits.five_hour.used_percentage` | `rate_limit_event` → `unifiedWindows.five_hour.utilization` | **0–1, not 0–100.** `StatuslineAttention`'s thresholds are percentages. |
| `rate_limits.*.resets_at` | same event, `resetsAt` | Epoch seconds in both. |
| `cost.total_cost_usd` | `result` → `total_cost_usd` | Per run, so a resumed session needs accumulating. |
| `context_window.*` | `result` → `usage` / `modelUsage[].contextWindow` | Already transcript-derived today; unaffected. |
| `model.display_name`, `effort.level` | `system/init` → `model` | Already transcript-derived today; unaffected. |
| `workspace.current_dir` / `cwd` | `system/init` → `cwd` | Already transcript-derived today; unaffected. |

So the capture is scaffolding for the current transport, not a foundation. It is safe to install now, but it is not worth building further on — and a cutover deletes it rather than porting it.

## What the chat view still needs

Switching transports is the smaller half. Headless, the chat view stops being an optional nicer face over a terminal and becomes the only surface, so everything the TUI quietly handles has to exist natively. This is that list, ordered by whether it blocks a cutover. Check items off as they land. The rendering items are worth doing on the current transport too, so they need not wait on a decision.

### Blockers — the agent stalls without these

- [ ] **Permission approval UI.** Unresolved tool calls fall through to a `canUseTool` callback; leave it unanswered and the agent waits forever. `AskUserQuestion` and tools marked `requiresUserInteraction` always reach it, even when an allow rule matches, so `--allowedTools` can't avoid this. Needs approve/deny with the tool name and input, plus deny-with-reason. Nothing in `Plume/UI/Chat/` does this today: a `.needsInput` status only tints the last message orange, with no control attached.
- [ ] **Answer an `AskUserQuestion`.** Clickable options wired to a structured response. The payload already carries `questions[]` with `header`, `question`, `multiSelect` and `options[]` of `label` + `description`.
- [ ] **Ask one question at a time**, with next/previous to move between them, rather than every question in one column. A call can carry up to four, each with its own options, and the read-only rendering stacks them all — fine for review, cramped for answering. Stepping through them also gives the answer UI somewhere to put per-question state.
- [ ] **Accept a free-form answer**, not only the offered options. The TUI always allows one, and the tool description says so: users can always pick "Other" and type. So the options are suggestions, and a rendering that only offers buttons removes an answer the TUI would have taken.
- [ ] **Draw the option previews the TUI draws.** An option can carry a `preview` — pre-formatted monospace text, not an image: ASCII mockups, code snippets, diagrams, before/after blocks. It's common, in 66 of 277 options across the local corpus, and the TUI lays the option list and the focused option's preview out side by side. `InteractiveToolPayload.AskedQuestion.Option` decodes only `label` and `description`, so the field is dropped before a view could show it. `MarkdownView` already renders monospace blocks, so drawing one is mostly plumbing; the layout is the real work, since a preview needs far more width than an option row. Previews are single-select only, and the corpus also shows undocumented siblings (`description_long`, `description_extra`, `description2`) — decode defensively rather than assuming a fixed set.
- [ ] **Approve or reject an `ExitPlanMode`.** The plan *viewer* exists (`ChatTabView.swift:89`, opens `MarkdownFileView` in a side panel); accept/reject does not.

### Serious gaps — usable but painful

- [ ] **Stop / interrupt.** `TerminalSession` exposes exactly two outbound operations, `submit(text:)` and `cyclePermissionMode()` — no `interrupt()`, no `sendKey(.escape)`. Today Ctrl+C in the terminal covers it. Headless, send SIGINT: SIGTERM exits 143 and leaves the turn unfinished.
- [ ] **Live streaming state.** Content is entirely file-driven — `TranscriptStore` re-parses the whole transcript on a 250ms debounce, so nothing appears until Claude Code flushes a line. `--include-partial-messages` gives token deltas, but no view consumes them. The only in-flight signal is the hook-driven `WorkingIndicator` dot, which is a coarse boolean rather than real output.
- [ ] **Queued messages while the agent is working.** `ChatComposer.send()` submits immediately with no check on status and no pending-message model. Streaming input mode supports queueing.

### Rendering — worth doing on the current transport too

- [ ] **System, error, and compaction entries are dropped.** `TranscriptParser` matches only `("assistant","assistant")` and `("user","user")`; everything else hits `default: continue`. There is no error concept in the model at all. Headless this matters more: `system/api_retry`, auth failures, and `result` error subtypes would vanish silently instead of being visible in the terminal.
- [ ] **Images are not modeled.** `TranscriptBlock` has no `.image` case, so image blocks decode to `.ignored`. `decodeResultContent` separately keeps only text blocks, so an image returned by a tool is dropped twice over.
- [ ] **No diff rendering for `Edit` / `Write`.** Only `Bash` gets special input rendering (a `sh` code block); every other tool's input is pretty-printed JSON — including the `old_string` / `new_string` / `content` fields that most want a diff.
- [ ] **Injected content still renders as the user's own messages.** Skill bodies, slash-command expansions, and `<local-command-stdout>` all arrive as user lines.
- [ ] **Subagents always show `status: .unset`** — no live indicator while one is running.
- [ ] **No scroll-to-bottom affordance** once the user has scrolled away. Auto-follow exists (`ChatScrollAnchor`, 40pt tolerance); a manual jump does not.

### Retired on cutover — remove, don't port

- [ ] **The whole statusline capture.** `StatuslineCaptureWriter`, `StatuslineInstaller`, the Settings section, `AppPaths.sharedApplicationSupport`, and `StatuslineStore`'s file watching all exist to work around a TUI-only channel. Headless supplies the same numbers as events. **Uninstall before deleting**: the script is referenced from the user's global `~/.claude/settings.json`, so shipping a build that drops the code without first restoring that key leaves a `statusLine` pointing at a file Plume no longer writes. `StatuslineInstaller.restore()` already handles it; the cutover needs to *call* it, which nothing does automatically today.
- [ ] **Feed quota and cost from the stream instead.** Keep `StatuslineStripView` and `StatuslineAttention` — only the source changes. Three things to get right: `utilization` is 0–1 where `used_percentage` is 0–100; `total_cost_usd` is per run, so a resumed session must accumulate rather than replace; and `rate_limit_event` arrives before `system/init`, so the reader must tolerate quota landing before the session it belongs to is known.

### Lost outright without a replacement

- [ ] **Slash commands beyond `/model` and `/effort`.** Only those two are composed natively (`ModelEffortCommand`). Everything else works today purely because the text reaches a real TUI. A `-p` session does expand skills and commands in the prompt string, so this is recoverable — but it needs discovery and expansion, not just a passthrough.
- [ ] **Terminal-only prompts** — `/login`, first-run trust. A `-p` session shows no workspace-trust dialog at all.

### What already maps cleanly

No work needed; noted so nobody re-derives it. `TranscriptParser` already patches `tool_result` back onto its originating call, `ThinkingRow` and `SubagentListView` already exist, tool results already render in a collapsed height-clipped box, and permission mode is already settable pre-launch through a chip in `WorkspacePickerView`. The parsing model maps onto `stream-json` events cleanly — it is the interaction surface that is thin.

## Sources

- Anthropic's third-party restriction: https://code.claude.com/docs/en/agent-sdk/overview (the Note block)
- Headless flags and the `--bare` auth caveat: https://code.claude.com/docs/en/headless
- Auth precedence and `claude setup-token`: https://code.claude.com/docs/en/authentication
- Subscription usage limits for SDK and `-p`: https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan
- Craft's implementation: https://github.com/lukilabs/craft-agents-oss/blob/main/packages/shared/src/agent/claude-agent.ts and `packages/shared/src/auth/claude-oauth.ts`

The statusline finding is first-hand: `claude -p` was run against a configured `statusLine` on Claude Code 2.1.258 (September 2026), with both output formats, and the script never fired. Re-check it if the CLI ever grows a headless status channel.

Craft's OAuth endpoints, scopes, and env-var clearing were read from raw source files as of September 2026. The SDK, hook, and MCP mechanics came via DeepWiki's AI-generated summaries of the same repo — high-confidence but not verified line-by-line. If any of it becomes load-bearing, clone the repo and read it directly.
