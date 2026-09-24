# Agent transports

An agent tab runs over one of two transports, chosen by `TaskTab.transport`: headless `claude -p`, or the interactive TUI in a real terminal. Headless is the default for new tabs (`AppSettings.defaultAgentTransport`), and the terminal transport stays available as a picker option and an escape hatch.

## Why headless is the default

The terminal transport runs the real `claude` binary in a Ghostty PTY and drives it like a human: `TerminalSession.submit(text:)` pastes text and sends a synthetic Enter, and `cyclePermissionMode()` sends Shift+Tab because no CLI setter exists mid-session. That input path is TUI-coupled in a way its output never was — transcript JSONL and hook events already gave Plume structured output before this cutover.

The coupling made several things structurally impossible over the terminal transport, because the composer can only paste text into an edit line:

- Answering a running `AskUserQuestion`. There is no way to pick an option; the request isn't visible as a request at all.
- Setting permission mode or model directly. Cycling with Shift+Tab is the only move.
- Approving or rejecting `ExitPlanMode` from the chat.
- Interrupting a turn without killing the process. Ctrl+C is the only stop, and it's a keystroke, not a targeted control.

Headless `claude -p`, speaking `stream-json` over stdin/stdout, replaces all of it with structured requests and responses on a control plane. It's the same binary reading the same credentials as the TUI, so subscription login is unaffected. `docs/headless-protocol.md` is the verified wire reference — invocation, the handshake, every request and event shape. This document stays at the level of what the two transports buy and cost, not the wire format.

## What headless bought

- **Permission approval with a reason.** `PermissionRequestRow` and `PendingPermissionDock` show every pending tool call — name, input, and the CLI's own `decision_reason` when it has one — with Allow and Deny buttons. A denial takes an optional reason, sent back as the tool result the model reads.
- **Answering `AskUserQuestion` for real.** `InteractiveToolRow` renders the question, its options, and a `multiSelect` question as a checklist rather than a single choice. `PermissionAnswerState` tracks the selection and sends it back keyed by question text.
- **Approving or rejecting a plan.** The same row renders `ExitPlanMode`'s proposed plan with Approve and Reject controls, reject taking an optional reason.
- **Interrupting without losing the session.** `HeadlessSession.interrupt()` sends a control request, not a signal. The in-flight turn stops and the process stays alive for the next one — unlike SIGTERM, which exits 143 and abandons the turn.
- **Live streaming.** `ChatStreamHandoff` merges the reply being written into the transcript's message with the same API message id, so one message renders whichever source it came from, without a visible gap or duplicate. `ChatRevealModel` fades it in a word at a time.
- **Queued messages while the agent is working.** `ChatComposer` holds messages sent mid-turn in `HeadlessSession.queuedMessages`, shown in the composer and removable before they go out — the terminal transport has no way to see or hold a message typed into a busy PTY at all.
- **Quota and cost pushed as events.** `rate_limit_event` and each turn's `total_cost_usd` reach `HeadlessSession` directly. This retired the statusline capture, a script Plume used to install into `~/.claude/settings.json` to scrape the same numbers out of band.
- **Slash-command discovery.** The `initialize` control request's reply carries every slash command with its name, description and argument hint. `SlashCommandMatcher` ranks them for the composer's autocomplete. This was expected to need reconstructing from disk; the handshake already supplies it.
- **Rendering that isn't specific to headless, but shipped alongside it.** System, error and compaction entries (`ChatNotice`), inline images (`ChatImage`), and Edit/Write diffs (`FileDiff`) all render as their own thing instead of raw tool JSON or dropped content. Injected content — skill bodies, slash-command expansions, `<local-command-stdout>` — renders through `InjectedContentRow`, not as a message from the user.

## How the process launches

Both transports run `claude` inside a login shell, via `LoginShellCommand.wrap`. `claude` typically lives at `~/.local/bin`, which reaches PATH only through the user's shell profile — and a GUI-launched app inherits launchd's minimal PATH, not the profile's. Exec'ing `claude` directly works when the app is launched from a terminal (Xcode included) and fails with `No such file or directory` once it is launched from Finder or the Dock, so the terminal is a misleading place to test it.

`HeadlessCommand.loginShellCommand(arguments:)` shell-quotes each argument and joins them into the wrapped command, keeping a spaced `--settings` path and the stream-json tokens intact as separate words.

One consequence of `-lic`: the user's `.zshrc` runs, and anything it prints lands on stderr. `HeadlessProcess` therefore reports stderr as a failure explanation only for a run that produced no stream-json message at all — a launch that never started. Profile chatter from a session that ran normally explains nothing.

## What's still missing or degraded

- **Subagents show no live status.** `SubagentListView` always passes `status: .unset` — there's no indicator while a subagent is actually running.
- **No workspace-trust dialog.** A `-p` session shows no first-run folder-trust prompt for an unfamiliar directory, and Plume has no equivalent in the headless flow. `claude --help` documents the skip as unconditional in non-interactive mode, and a probe of 2.1.278 bears it out: `claude -p` answers normally in a directory with no trusted ancestor, and records no `projects` entry for it. `AgentLauncher` still refuses to spawn into a directory `ClaudeTrustStore` cannot vouch for — Plume's own stance, not a limit the CLI imposes.
- **`/login` and other terminal-only prompts don't exist headless.** Anything that depends on an interactive TUI prompt beyond `AskUserQuestion` and `ExitPlanMode` has no headless equivalent; the terminal transport remains the only way to run them.

The terminal transport stays exactly for this last gap: a tab can be switched to it for `/login`, for first-run trust, or for anything else that needs a real TUI. Both transports launch through `AgentLauncher` and report through `StatusEngine`, which is transport-agnostic.
