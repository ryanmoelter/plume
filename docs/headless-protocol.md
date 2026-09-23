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

## Model on resume

A bare `--resume` restores the model the conversation already used; it does **not** fall back to the CLI's default. Passing `--model` on a resume overrides it. Observed by driving the real binary — the three `init` events, verbatim:

```
# fresh, --model sonnet
{"subtype":"init","session_id":"b13e49d1-23dc-4604-a37e-d24fabe683e9","model":"claude-sonnet-5","permissionMode":"plan"}
# --resume b13e49d1-…, no --model
{"session_id":"b13e49d1-23dc-4604-a37e-d24fabe683e9","model":"claude-sonnet-5"}
# --resume b13e49d1-…, --model opus
{"session_id":"b13e49d1-23dc-4604-a37e-d24fabe683e9","model":"claude-opus-5"}
```

The default is a separate value again: a *fresh* run with no `--model` reported `claude-opus-5[1m]`, from `model` in `~/.claude/settings.json`. So the conversation's model, the CLI's default, and any flag are three distinct things, and only the flag overrides.

**What Plume does with this.** On a resume `--model` is omitted unless the user picked a model on that tab since the conversation last ran. The tab's snapshot is a record of what the conversation used, not a choice, so passing it back would be a no-op at best and would override a model the user changed inside the CLI at worst. `HeadlessCommand.arguments` takes `isModelExplicitlyChosen` for exactly this.

## Model aliases

**A bare alias resolves to the CLI's current 200K model; `alias[1m]` resolves to the current 1M model.** Measured against 2.1.280 by running `claude -p --output-format stream-json --verbose --model <id> 'hi'` and reading the `init` event's `model`:

| `--model` | `init` reports |
| --- | --- |
| `opus` | `claude-opus-5-5` |
| `opus[1m]` | `claude-opus-5-5[1m]` |
| `sonnet` | `claude-sonnet-5` |
| `sonnet[1m]` | `claude-sonnet-5[1m]` |
| `fable` | `claude-fable-5-1` |
| `haiku` | `claude-haiku-4-5-20251001` |
| `haiku[1m]` | `claude-haiku-4-5-20251001[1m]` |
| `not-a-real-model` | `not-a-real-model` |

Three things follow.

- **`alias[1m]` is what the top-level picker sends.** The CLI resolves it to its current 1M model, so Plume never has to track a version for the default path — `AgentModel.opus`/`.sonnet`/`.haiku` send `opus[1m]`/`sonnet[1m]`/`haiku[1m]` and show the bare family name until a session reports the resolved model. Fable has no 1M variant, so `AgentModel.fable` sends the plain `fable` alias. Specific versions (`claude-opus-5-5[1m]` and so on) live in the "More" submenu as explicit IDs; `recognizing(_:)` maps a resolved or reported alias onto the matching one so the composer can show a real label like "Opus 5.5" once the session confirms it.
- **Fable has no 1M variant.** It accepts the suffix and reports back plain, so `AgentModel.fable5dot1` is `claude-fable-5-1` and is labelled without a size — not because it's 1M by convention, but because it has no 200K form to distinguish from.
- **`init` echoes whatever ID it was handed**, including one the backend does not know, and it never lists the models on offer — `capabilities` names protocol features (`interrupt_receipt_v1` and friends). So there is no live model list to read, and `AgentModel.more` is maintained by hand. An ID with no preset round-trips as itself so the composer displays what the session actually runs on.

## Sending a turn

```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"…"}]}}
```

`content` is always an array of blocks, even for one line of text.

### Images in a turn

An image rides as a base64 block beside the text, in the same `source` shape the transcript records it in:

```json
{"type":"user","message":{"role":"user","content":[
  {"type":"text","text":"what's wrong with this?"},
  {"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0…"}}]}}
```

- **Only `type: "base64"` sources are modeled.** A URL source would need a fetch, which neither the composer nor the transcript parser may do.
- `media_type` is one of `image/png`, `image/jpeg`, `image/gif`, `image/webp`. `ComposerImageAttachment` re-encodes anything else (a screenshot's TIFF, a HEIC) as PNG rather than refusing it.
- The wire form and the transcript form are the same form, so an image Plume sends parses back through `TranscriptBlock` as the block that rendered it. `UserContentBlockTests` locks that round trip.
- A block over `ChatImage.maxBase64Length` is dropped rather than sent — it would exhaust the turn's token budget, and it renders as a placeholder anyway.

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
| `remote_control` | `enabled`, `name` | Publishes the conversation to claude.ai/code — see below |
| `set_max_thinking_tokens` | | Thinking budget |
| `set_cwd` | | Moves the working directory |
| `get_settings` / `update_settings` | | Read and write session settings |
| `rewind_files` | `dry_run` | Undo file changes |
| `generate_session_title` | `description` | Ask the CLI to title the session — see below |
| `mcp_message` | `server_name`, `message` | Host-provided MCP servers |
| `hook_callback` | `callback_id`, `input` | In-process hooks, no shell scripts |

`set_permission_mode` and `set_model` replace what Plume does today by pasting `/model` or sending Shift+Tab.

## Session titles — `generate_session_title`

Verified first-hand against 2.1.276.

**Claude Code auto-titles only the interactive TUI.** A headless conversation never writes an `ai-title` line on its own, however long it runs, which is why `SessionJSONLReader` falls back to the first user message. This request is how a headless host gets a real title.

```json
{"type":"control_request","request_id":"plume-7","request":{
  "subtype":"generate_session_title",
  "description":"Help me add OAuth2 login with Google to my Flask app."}}
```

**`description` is required and must be a string.** Omitting it is refused outright:

```json
{"subtype":"error","request_id":"plume-7","error":"generate_session_title: description must be a string"}
```

The title is generated from `description`, *not* from the conversation — the CLI does not read the transcript to write it. So the caller chooses what the title describes. A success:

```json
{"subtype":"success","request_id":"plume-7","response":{"title":"OAuth2 login with Google in Flask"}}
```

**The CLI also appends the title to the transcript**, as the same line the TUI writes:

```json
{"type":"ai-title","aiTitle":"OAuth2 login with Google","sessionId":"dcf361e4-…"}
```

That side effect is what makes this cheap to adopt: `AgentTitleMonitor` already watches for `ai-title`, and `SessionJSONLReader.latestAITitle` already reads it, so a first title reaches `TitleStore` and the sidebar with no new delivery path.

**Only the first title of a session is written to the transcript, though.** Asking again returns a new title in the control response, and the transcript keeps the original — measured by titling one session twice and finding two identical `ai-title` lines against two different replies. So the control response is the authoritative delivery path, not a shortcut past the watcher's debounce: a re-title reaches the UI only because `HeadlessSession` applies the reply itself. It also means `latestAITitle` answers "has this session ever been titled", which is what `SessionTitleRequester` uses it for.

**An empty `description` is answered with `{"title": null}`**, not an error. So a decline and a failure are distinct — null means the CLI had nothing to work with, an `error` subtype means the request was malformed — and neither ever yields a bad title string. Plume treats both the same way: keep whatever the tab is already called.

`SessionTitleRequester` decides when to ask, since every request is a model call: once when the conversation has something to describe, again when a plan file names the work better than the opening message did, and every tenth turn after that. Never on the terminal transport, whose TUI titles itself.

## Remote Control — `remote_control`

Verified first-hand against 2.1.261.

**`/rc` is not reachable as a slash command here.** The CLI's `remote-control` command renders an interactive TUI component and ships no non-interactive variant, unlike `/usage`, `/advisor` and `/autocompact`, which each pair theirs with a `supportsNonInteractive` definition. An `initialize` handshake in this repo returns 76 commands and neither `rc` nor `remote-control` is among them. Sending the literal text does nothing. The control request is the only route, and Plume serves `/rc` itself (`PlumeSlashCommand`).

Enable:

```
{"type":"control_request","request_id":"<n>","request":{"subtype":"remote_control","enabled":true,"name":"laptop"}}
```

The reply carries the bridge:

```json
{"session_url":"https://claude.ai/code/session_01A…","connect_url":"https://claude.ai/code?environment=",
 "environment_id":"","bridge_epoch":1,"bridge_session_id":"cse_01A…"}
```

- **`session_url` is the link that works.** `connect_url` names an environment, which a session hosted on this Mac does not have — it arrives as a bare `https://claude.ai/code?environment=`. `bridge_session_id` is the same id as `session_url`'s with `cse_` in place of `session_`.
- `work_secret` and `reattach_session_id` select the worker-credential path, where a host that already owns a cloud session attaches this process to it as a worker. Omitting them authenticates the bridge as the user's own account, which is what the TUI's `/rc` does. Sending a secret with nothing to reattach to is refused.
- `bridge_epoch` increments per connect, so it tells a stale event from a live one.

Live state arrives on the **conversation** plane, not the control plane:

```
{"type":"system","subtype":"bridge_state","state":"ready","uuid":"…","session_id":"…"}
{"type":"system","subtype":"bridge_state","state":"connected","bridge_epoch":1,"uuid":"…","session_id":"…"}
```

Order on connect is `ready` (**carrying no `bridge_epoch`**), then the control response, then `connected`. Observed states are `ready`, `connected`, `reconnected`, `attach`, `failed` and `policy_disabled`; `failed` and `policy_disabled` carry a `detail`.

**Disconnecting emits no `bridge_state` at all** — `{"subtype":"remote_control","enabled":false}` is answered with a bare success carrying no `response` object, so the request itself is the only record of what happened. Re-enabling while already connected is idempotent and returns the live bridge.

`remote_control_work_secret` is a CLI-originated request for a fresher worker credential. It never fires when the host sends no `work_secret`; Plume answers it with a bare success regardless, since dropping a control request leaves the CLI waiting on its timeout.

## Error-shaped control responses

A refused request comes back with `subtype: "error"` and a bare `error` string beside `request_id` — there is no `response` object:

```json
{"type":"control_response","response":{"subtype":"error","request_id":"plume-2",
 "error":"Model \"not-a-real-model-xyz\" is not a recognized model id. Run /model to see available models."}}
```

Nothing times out a control request on either side, so a reply that is never decoded leaves its caller waiting forever. Remote Control's own failures read "Remote Control cannot be enabled from inside a remote session", "The conversation was cleared while Remote Control was being enabled; send the request again" and "Remote Control initialization failed".

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
