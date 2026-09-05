# The headless `claude` wire protocol

Verified first-hand against Claude Code **2.1.258** (September 2026) by driving the real binary and by reading the protocol schemas embedded in it. Everything here was observed, not inferred. Re-verify against a new CLI version before trusting it — none of this is a published API.

`docs/agent-transport.md` argues *why* Plume moves off the TUI. This document is *how*.

## Invocation

```
claude -p --output-format stream-json --input-format stream-json \
       --include-partial-messages --verbose \
       --permission-mode <mode> --permission-prompt-tool stdio \
       [--resume <session-id>] [--model <model>] [--settings <path>] [--add-dir <dir>]
```

`--verbose` is required for `stream-json` output. Never pass `--bare`: it refuses the keychain and forces an API key.

**`--permission-prompt-tool stdio` is the load-bearing flag.** Without it a headless run never asks — a tool needing approval is auto-denied with "no prompt available in headless mode", and the turn ends having done nothing. The flag's own help text says permission prompts reach the host over stdio. Its value is not validated at startup, so a wrong one fails only later, at the first tool call.

## The two message planes

Both directions are newline-delimited JSON on stdin/stdout. Two independent planes share the pipe:

- **Conversation**: `user` in; `system`, `assistant`, `user`, `stream_event`, `rate_limit_event`, `result` out.
- **Control**: `control_request` / `control_response` / `control_cancel_request`, in both directions, correlated by `request_id`.

A control request from either side is answered by a `control_response` from the other carrying the same `request_id`. The CLI's own ids are UUIDs; ids the host sends may be any string.

## Startup handshake

Send this before the first user message. It is what registers the host as a capable client:

```json
{"type":"control_request","request_id":"init-1","request":{"subtype":"initialize","hooks":{}}}
```

The reply carries the session's capabilities — `commands` (every slash command with `name`, `description`, `argumentHint`), plus skills, agents and output styles. **This is the slash-command discovery source**; nothing else needs parsing to build a command menu.

Other fields `initialize` accepts, all optional: `sdkMcpServers`, `sdkMcpServerConfigs`, `skills`, `agents`, `title`, `systemPrompt`, `appendSystemPrompt`, `planModeInstructions`, `toolAliases`, `forwardSubagentText`, `promptSuggestions`, `agentProgressSummaries`.

## Sending a turn

```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"…"}]}}
```

**One process serves the whole conversation.** Verified: three turns down one stdin kept a single `session_id`, and turn 2 recalled a number given in turn 1. There is no need to re-spawn or `--resume` between turns — `--resume` is for picking a conversation back up in a *new* process.

Each turn ends with exactly one `result` event. Treat `result` as the turn boundary, not the process boundary.

## Permission requests — `can_use_tool`

Whenever a tool needs approval the CLI sends:

```json
{"type":"control_request","request_id":"<uuid>","request":{
  "subtype":"can_use_tool",
  "tool_name":"Write",
  "display_name":"Write",
  "input":{"file_path":"/tmp/x.txt","content":"hello\n"},
  "description":"/tmp/x.txt",
  "permission_suggestions":[
    {"type":"setMode","mode":"acceptEdits","destination":"session"},
    {"type":"addDirectories","directories":["/tmp"],"destination":"session"}],
  "decision_reason":"Path is outside allowed working directories",
  "decision_reason_type":"workingDir",
  "tool_use_id":"toolu_…",
  "requires_user_interaction":true
}}
```

Optional fields seen in the schema: `agent_id` (set when the call came from a subagent), `matched_ask_rule`, `classifier_approvable`, `blocked_path`, `suppress_always_allow_rule`, `default_to_no`.

Answer it:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"<same id>",
 "response":{"behavior":"allow","updatedInput":{…}}}}
```

- `behavior: "allow"` must echo an `updatedInput` — normally the request's `input` unchanged. It is also the hook for editing a tool call before it runs.
- `behavior: "deny"` takes a `message`, which the model receives as the tool result. This is deny-with-reason.
- Leaving a request unanswered stalls that tool call indefinitely. The turn does not time out on its own.
- `control_cancel_request` withdraws a request the CLI no longer needs; drop any UI for that `request_id`.

An auto-denial that never reaches the host (a deny rule, `dontAsk` mode, the auto-mode classifier) is reported afterwards in the `result` event's `permission_denials`, which the CLI calls the authoritative record.

### Tools that always ask

`requires_user_interaction: true` marks a call that reaches the host **even when an allow rule matches**, so `--allowedTools` cannot route around it. `AskUserQuestion` and `ExitPlanMode` are both in this class.

### Answering an `AskUserQuestion`

The request's `input.questions` is the familiar array of `{question, header, multiSelect, options:[{label, description}]}`. Answer by allowing the call with an `answers` map added to `updatedInput`, keyed by **question text** and valued by the chosen **option label** (multi-select: comma-separated labels):

```json
{"behavior":"allow","updatedInput":{"questions":[…],"answers":{"Tabs or spaces?":"Tabs"}}}
```

Verified: the model received `Your questions have been answered: "Tabs or spaces?"="Tabs"` and acted on it. Allowing *without* an `answers` map returns the question unanswered — the model is told nothing was chosen, which is the natural encoding of "dismissed".

### Approving an `ExitPlanMode`

Same shape. `input` carries `plan` (markdown) and `planFilePath`. `allow` approves the plan and leaves plan mode; `deny` with a `message` rejects it and hands the model the reason.

### Approving a plan with feedback

There is no allow-with-message on this wire, and no plan-specific allow field. The documented allow surface is `updatedInput` and `updatedPermissions` and nothing else, and `ExitPlanMode` declares **no input fields at all** — it reads the plan from `planFilePath` — so an extra key on `updatedInput` is discarded with no diagnostic. Feedback therefore cannot ride the permission response.

Plume sends the approval unchanged and follows it with an ordinary user turn:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"<id>",
 "response":{"behavior":"allow","updatedInput":{ …the request's own input, unchanged… }}}}
{"type":"control_request","request_id":"<n>","request":{"subtype":"set_permission_mode","mode":"auto"}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<the typed feedback>"}]}}
```

The user turn is queued while the approved turn runs and is sent when that turn's `result` arrives, so the note steers the next plan instead of interrupting the one being approved. Blank feedback sends no third line.

## Interrupt

```json
{"type":"control_request","request_id":"int-1","request":{"subtype":"interrupt"}}
```

Answered with `{"still_queued":[…]}`, and the in-flight turn stops and emits its `result`. Verified mid-count: output truncated and the process stayed healthy for the next turn. **Prefer this to signals** — it keeps the process alive, where SIGTERM exits 143 and abandons the turn. Add `cancel_queued: true` to also drop queued messages.

## Other host-to-CLI control requests

Read from the CLI's own dispatcher; `interrupt`, `set_permission_mode` and `set_model` were exercised, the rest are listed as available:

| subtype | payload | effect |
|---|---|---|
| `set_permission_mode` | `mode` | Sets the mode outright — no Shift+Tab cycling |
| `set_model` | `model` | Switches model mid-session |
| `set_max_thinking_tokens` | | Thinking budget |
| `set_cwd` | | Moves the working directory |
| `get_settings` / `update_settings` | | Read and write session settings |
| `rewind_files` | `dry_run` | Undo file changes |
| `generate_session_title` | | Ask the CLI to title the session |
| `mcp_message` | `server_name`, `message` | Host-provided MCP servers |
| `hook_callback` | `callback_id`, `input` | In-process hooks, no shell scripts |

`set_permission_mode` and `set_model` replace what Plume does today by pasting `/model` or sending Shift+Tab.

## Output events

Observed in order, from a real run:

1. **`rate_limit_event`** — arrives **before** `system/init`, so quota can land before its session is known. `rate_limit_info` carries `unifiedWindows.five_hour` / `.seven_day`, each `{utilization, resetsAt}`, plus `overageStatus`, `overageResetsAt`, `isUsingOverage`. **`utilization` is 0–1**, where the statusline payload's `used_percentage` was 0–100.
2. **`system` / `init`** — `session_id`, `cwd`, `model`, `permissionMode`, `tools`, `slash_commands`, `agents`, `skills`, `mcp_servers` (each `{name, status}`), `memory_paths`, `plugins`, `output_style`, `claude_code_version`, `apiKeySource`.
3. **`system` / `status`** — coarse activity (`"requesting"`).
4. **`stream_event`** — raw Anthropic streaming events under `.event` (`message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`). Only with `--include-partial-messages`. This is the live token feed.
5. **`assistant`** / **`user`** — complete message envelopes, content blocks identical to the transcript's. `parent_tool_use_id` attributes a message to a subagent. Tool results arrive as `user` messages carrying `tool_result` blocks.
6. **`result`** — one per turn: `subtype` (`success` / error kinds), `is_error`, `result` (final text), `stop_reason`, `terminal_reason`, `num_turns`, `duration_ms`, `ttft_ms`, `total_cost_usd`, a full `usage` breakdown, `modelUsage` (per model: `costUSD`, `contextWindow`, `maxOutputTokens`, token counts — **including subagent models**), `permission_denials`, and `subagent_stats`.

Also defined in the schema: `attachment`, `prompt_suggestion`, and an auto-denial advisory event.

`total_cost_usd` is a **running total for the whole conversation**, re-sent on every `result` event — a session total must replace its tracked cost with each new value rather than accumulate. Replacing also keeps the figure correct across a `--resume`, since the first `result` after resuming already carries the true running total.

## What this buys over the TUI

Answering a running `AskUserQuestion`, approving a plan, approving or denying individual tool calls with a reason, setting permission mode and model directly, interrupting cleanly, live token streaming, and quota and cost as pushed events — replacing the statusline capture, which a headless run never fires at all.
