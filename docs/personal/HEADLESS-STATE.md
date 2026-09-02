# Headless cutover — working state

Scratch coordination doc for the `ryanm/headless-agent` branch. Not a design
doc: `docs/headless-protocol.md` is the verified wire reference and
`docs/agent-transport.md` holds the checklist being worked through. Delete this
file before the branch merges.

## Ground rules for anyone picking this up

- **Worktree**: `/Users/ryanmoelter/Development/Plume/.worktrees/headless-agent`,
  branch `ryanm/headless-agent`, based on `ryanm/polish-plan-view` (NOT main).
  Never read, edit, or run commands outside that path.
- **Commit signing is broken** in this session (1Password locked). Commit with
  `--no-gpg-sign`. Every commit on this branch so far is unsigned.
- Build: `xcodebuild -scheme Plume -destination 'platform=macOS' build`
- Test: `xcodebuild -scheme Plume -destination 'platform=macOS' test -only-testing:PlumeTests`
- The user is asleep and unavailable. Make the simple choice and record it here
  rather than blocking. Bias to the simple option — "we can complicate things
  later" is a direct instruction.

## Decisions the user made

1. **Headless becomes the default** transport for agent tabs; the TUI stays
   reachable as an escape hatch. Includes uninstalling the statusline capture
   and feeding quota/cost from the stream.
2. **Everything in the `agent-transport.md` checklist** is in scope — blockers,
   serious gaps, rendering, retired-on-cutover, and the lost-outright items.
3. Branch off `polish-plan-view` in a new worktree (done).

## What the protocol research settled

All verified first-hand against Claude Code 2.1.258 — see
`docs/headless-protocol.md` for the full detail and exact JSON.

The single most important finding: **`--permission-prompt-tool stdio` plus an
`initialize` control request** is what makes permission requests reach the host.
Without both, a headless run auto-denies anything needing approval and the turn
ends having done nothing. Everything the doc called "impossible" — answering an
`AskUserQuestion`, approving `ExitPlanMode`, denying a tool with a reason — works
through the resulting `can_use_tool` control requests. All confirmed live.

Also settled: one process serves the whole conversation (multi-turn on one
stdin, one session_id, memory carried across turns); interrupt is a control
request, not a signal; `initialize`'s reply carries the slash-command list.

## Code landed so far

`Plume/Agent/Headless/` — the transport core, builds clean, not yet wired to
any view:

- `StreamJSONMessage.swift` — the wire vocabulary (events, control requests,
  `SlashCommand`, `PendingPermission`'s payload types).
- `StreamJSONDecoder.swift` — pure line→message decoding. Forgiving: unknown
  types become `.unknown` rather than failing the stream.
- `StreamJSONEncoder.swift` — outbound lines: user turns, `initialize`,
  `interrupt`, `set_permission_mode`, `set_model`, permission responses, and
  `answeredQuestionInput` for AskUserQuestion answers. Defines
  `PermissionDecision` (`.allow(updatedInput:)` / `.deny(message:)`).
- `HeadlessCommand.swift` — argv builder. Real argument array, no shell wrap.
- `HeadlessProcess.swift` — owns the subprocess and both pipes, buffers partial
  lines across reads. Knows nothing about chat.
- `HeadlessSession.swift` — `@MainActor @Observable`, one per tab. Holds
  `pendingPermissions`, `streamingText`, `queuedMessages`, `rateLimit`,
  `sessionCostUSD`, `slashCommands`, and drives `StatusEngine`.
- `HeadlessSessionManager.swift` — `shared`, keyed by tab ID, mirrors
  `SurfaceManager`'s shape.

Also: `JSONValue` (in `Transcript/TranscriptEntry.swift`) gained `Encodable`,
`Equatable`, and typed accessors (`doubleValue`, `boolValue`, `objectValue`,
`arrayValue`). It was documented as encoding losslessly but did not.

## Still to do

Roughly in dependency order. The transport exists; nothing below it is wired.

1. **Wire the session into a tab.** `AgentLauncher` currently always spawns a
   PTY. Needs a headless path, chosen by default, with the TUI as fallback.
   `TaskTab.renderMode` already distinguishes chat from terminal; the transport
   choice is a separate axis and probably wants its own field or a setting.
2. **Permission approval UI** in `Plume/UI/Chat/` — approve/deny with the tool
   name and input, plus deny-with-reason. `HeadlessSession.pendingPermissions`
   is the model; `resolve(_:with:)` is the call.
3. **AskUserQuestion answering** — `InteractiveToolRow` renders the options
   read-only today. Make them selectable and call `session.answer(_:answers:)`.
   Answers map question text → chosen option label.
4. **ExitPlanMode approve/reject** — same row, `.allow` / `.deny`.
5. **Stop/interrupt button** — `session.interrupt()`.
6. **Live streaming** — `streamingText` / `streamingThinking` accumulate
   deltas; no view reads them yet.
7. **Queued messages** — `queuedMessages` exists on the session and drains on
   turn end; the composer still sends immediately and shows no pending state.
8. **Rendering gaps** — system/error/compaction entries dropped by
   `TranscriptParser`, images unmodeled, no diff rendering for Edit/Write,
   injected content, subagent live status, scroll-to-bottom.
9. **Retire the statusline capture** — five files in `Plume/Agent/Statusline/`
   plus call sites in Settings, `ChatTabView`, `MainWindow`, `AgentLauncher`,
   `TaskStore`, `AppSettings`. **Call `StatuslineInstaller.restore()` before
   deleting** or the user's global `~/.claude/settings.json` keeps pointing at
   a script Plume no longer writes. Keep `StatuslineStripView` and
   `StatuslineAttention`; only the data source changes. Watch the units:
   stream `utilization` is 0–1, the old `used_percentage` was 0–100.
10. **Slash commands** — `session.slashCommands` is populated from the
    initialize reply but nothing consumes it.

## Verification

Unit-testable without a process: the decoder, the encoder, and the argv
builder. `PlumeTests` uses Swift Testing (`@Test`/`#expect`), and the
real-corpus tests in `RealTranscriptCorpusTests` are the model for asserting
against real data.

Captured real NDJSON from the protocol research lives in the session scratchpad
(`.../scratchpad/probe/*.ndjson`): `basic`, `control4` (a real `can_use_tool`),
`askq2` (an answered question), `exitplan`, `multiturn` (three turns plus an
interrupt). Useful as decoder fixtures — copy them into the repo as test
fixtures rather than re-deriving them.

Note the known-environmental test failures from the root `CLAUDE.md`:
`SessionJSONLReaderTests.encodingResolvesADirectoryClaudeCodeHasUsed` and
`SurfaceCommandTests` both fail in a worktree for reasons unrelated to any
change here. Check against `main` before believing a regression.
