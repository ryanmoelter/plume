# Codex integration design

Design established on 2026-09-13 from the main checkout before inspecting the
`codex-provider` implementation. Protocol reference: the installed Codex CLI's
generated experimental schema and
[OpenAI's app-server documentation](https://learn.chatgpt.com/docs/app-server).

## Boundaries

Keep Claude and Codex as sibling session implementations behind `AgentSession`.
Share tab ownership, the composer, normalized chat messages, queued follow-ups,
interrupt and approval presentation. Keep wire decoding, history loading, model
catalogs and settings semantics in each provider. One app-server per Codex tab
is a reasonable first implementation: failures and lifecycle stay isolated.
Multiplexing threads in one process can be added later without changing the UI.

Persist the provider and conversation ID on the tab. Never interpret a Codex
thread as a Claude session or derive a Claude transcript path for it. Preserve
main's block-based chat list and its layout/scrolling contracts.

## Harness differences

| Concept | Claude Code | Codex | UI choice |
| --- | --- | --- | --- |
| Planning | Plan permission mode, blocking ExitPlanMode request | Plan collaboration mode, separate from sandbox and approvals | Codex Plan / Code control beside permissions; no fabricated ExitPlanMode request |
| Permissions | Claude modes and can_use_tool | Named profiles and typed approval requests | Native labels and decisions, common request presentation |
| Plan output | Plan file plus approval | Plan proposal item; progress plan updates are separate | Present a proposal for review; Implement starts a Code turn, Request changes stays in Plan |
| Denial feedback | Free-text reason | Decision enums, without a reason field | Show a reason field only where supported |
| Follow-up | Client queue | Queue or turn/steer | Separate Queue and Steer actions while a turn is running |
| Models/effort | Local catalog and Claude commands | model/list with per-model effort choices | Provider-specific options; do not reuse Claude defaults |
| History | Watched JSONL | Server item/history APIs | Normalize to ChatMessage without manufacturing JSONL |
| Streaming | Text overlay reconciled against file content | Stable item lifecycle and deltas | Update Codex items in place; authoritative completion replaces partial content |
| Quota | Named 5h/7d utilization fractions | Account buckets, arbitrary durations, usage percentages | Actual bucket/window labels; null means unavailable |
| Cost | Reported session dollars | No equivalent session dollar total | Omit unavailable cost |
| Remote Control | Claude control-plane feature | Experimental remote-control daemon and app-server APIs | Not yet integrated; local Plume chats are not automatically remotely accessible |

## Recovery and verification

Treat connection readiness, thread identity, and active turn identity separately.
Queue input until initialization, thread creation/resume, and history loading
finish. Preserve received event order when crossing to MainActor. Resolve every
RPC continuation on disconnect, and reject unsupported server requests explicitly.

Reconnect the stored thread without resending an input whose acceptance is
uncertain. Preserve only unsent queued inputs for an explicit reconnect. Keep
history visible on failure and show an actionable error. History responses must
not overwrite items updated while the history request was outstanding.

Verify request correlation, status transitions, late turn responses, planning
payloads, quota nulls/buckets, and history/live interleaving with injected protocol
transports. Build and run the Debug bundle on macOS, preserving the installed
release and its separate store.

## Remote access correction

The installed CLI exposes `codex remote-control start` and
`codex remote-control pair`, plus `remoteControl/enable`, pairing, and status
methods in its generated app-server schema. Remote access is therefore not
exclusive to the desktop app. Plume currently launches a private stdio
app-server per tab and does not enable or pair remote control. Starting a
separate daemon is not sufficient evidence that it can control a turn owned
by Plume's private process; integrating remote access needs explicit session
ownership and lifecycle handling.

The public [app-server documentation](https://learn.chatgpt.com/docs/app-server)
also describes connecting a remote CLI through authenticated WebSockets.
Availability of the experimental pairing flow in a particular mobile or web
client has not been verified.
