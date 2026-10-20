# The headless `claude` wire protocol

Verified first-hand against Claude Code **2.1.258** (September 2026) by driving the real binary and by reading the protocol schemas embedded in it. Everything here was observed, not inferred. Re-verify against a new CLI version before trusting it — none of this is a published API.

`docs/agent-transport.md` argues *why* Plume moves off the TUI. This document is *how*.

## Invocation

```
claude -p --output-format stream-json --input-format stream-json \
       --include-partial-messages --verbose \
       --permission-mode <mode> --permission-prompt-tool stdio \
       --allow-dangerously-skip-permissions \
       [--resume <session-id>] [--model <model>] [--settings <path>] [--add-dir <dir>]
```

`--verbose` is required for `stream-json` output. Never pass `--bare`: it refuses the keychain and forces an API key.

**`CLAUDE_CODE_ARTIFACT=1` in the environment is what exposes the Artifact tools.** A `-p` run's entrypoint is `sdk-cli`, and the CLI withholds `Artifact`, `ArtifactComments` and `ArtifactData` from SDK entrypoints unless that variable is set. Measured against 2.1.293: without it `system/init` lists none of them. `HeadlessCommand.environment` sets it. A claude.ai subscription login and the org's artifact policy still gate the tools, and a user's `enableArtifact: false` still turns them off.

**`--permission-prompt-tool stdio` is the load-bearing flag.** Without it a headless run never asks — a tool needing approval is auto-denied with "no prompt available in headless mode", and the turn ends having done nothing. The flag's own help text says permission prompts reach the host over stdio. Its value is not validated at startup, so a wrong one fails only later, at the first tool call.

**`--allow-dangerously-skip-permissions` is what lets a session switch into bypass.** Measured against 2.1.280 in a trusted directory, with a Bash call that needs approval:

| launch | `--allow-…` | result |
|---|---|---|
| `--permission-mode bypassPermissions` | no | `init` reports `bypassPermissions`; no `can_use_tool`, the command runs |
| `--permission-mode default`, then `set_permission_mode` → `bypassPermissions` | no | the request fails: `Cannot set permission mode to bypassPermissions because the session was not launched with --dangerously-skip-permissions`. The next `init` still reports `default`, and the call still asks |
| same | yes | reply `{"mode":"bypassPermissions"}`, a `system/status` with the new mode, and no `can_use_tool` |
| `--permission-mode default` | yes | `init` reports `default` and the call still asks — the flag only unlocks the mode |
| `--permission-mode bypassPermissions`, then `set_permission_mode` → `default` | yes | the call asks again |

So launching in bypass works either way, but switching into it needs the flag, and without it the refusal arrives only as an error reply. `HeadlessSession` moves the picker before the reply, so on an error reply to the latest `set_permission_mode` it reverts to the last mode the CLI confirmed — the launch mode, `init`, or an accepted switch. A refusal of an older request is ignored, since a newer one has already superseded it. The error text names `--dangerously-skip-permissions`, but that flag *starts* the session in bypass; the `allow` variant is the one to pass. Plume passes it on every launch, and the picker's `showsBypassPermissions` setting stays the gate.

The TUI is different: there the flag shows the "Bypass Permissions mode" warning dialog at every launch, whatever the starting mode. A terminal tab therefore doesn't pass it. It never switches mode mid-session, and launching straight into bypass works there without the flag, behind that same dialog.

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

**The current Opus and Sonnet models are 1M at their bare ID, with no 200K form. Fable has no `[1m]` form at all. Haiku 4.5 is 200K bare, and this subscription can't use its `[1m]` form.** Measured against 2.1.280 by running `claude -p --output-format stream-json --verbose --model <id> 'hi'` and reading the `init` event's `model` and the `result` event's `modelUsage.<id>.contextWindow`:

| `--model` | `init` reports | `contextWindow` |
| --- | --- | --- |
| `opus` | `claude-opus-5-5` | 1,000,000 |
| `opus[1m]` | `claude-opus-5-5[1m]` | 1,000,000 |
| `claude-opus-5-5` | `claude-opus-5-5` | 1,000,000 |
| `claude-opus-5` | `claude-opus-5` | 1,000,000 |
| `sonnet` | `claude-sonnet-5` | 1,000,000 |
| `sonnet[1m]` | `claude-sonnet-5[1m]` | 1,000,000 |
| `fable` | `claude-fable-5-1` | 1,000,000 |
| `haiku` | `claude-haiku-4-5-20251001` | 200,000 |
| `claude-haiku-4-5-20251001` | `claude-haiku-4-5-20251001` | 200,000 |
| `haiku[1m]` | `claude-haiku-4-5-20251001[1m]` | 400 "long context beta is not yet available for this subscription" |
| `not-a-real-model` | `not-a-real-model` | |

Three things follow.

- **The `[1m]` suffix is redundant for Opus and Sonnet, and unusable for Haiku on this subscription.** `init` echoes the ID it was handed, suffix included, but for Opus/Sonnet the window is the same either way, and for Haiku the `[1m]` form 400s outright. So "More" offers every preset bare — `claude-opus-5-5`, `claude-opus-5`, `claude-sonnet-5` and `claude-haiku-4-5-20251001` — with no `[1m]` sibling, and `recognizing(_:)` strips a `[1m]` suffix before matching so a suffixed ID from an older release, or a stored `haiku[1m]` from before this subscription's beta status was known, lands on the same bare entry. `nominalContextWindow` reads 200K for Haiku and 1M for every other preset.
- **The top-level picker sends `alias[1m]` for Opus and Sonnet** — `opus[1m]`/`sonnet[1m]` — and plain `fable`/`haiku`, and shows the bare family name until a session reports the resolved model. The CLI resolves the alias to its current model, so Plume never has to track a version for the default path.
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

### A message mid-turn

A `user` line written while a turn runs takes an optional `priority`, which says when the model sees it. The field sits in the CLI's own SDK user-message schema beside `uuid` and `shouldQuery`, as `priority: "now" | "next" | "later"`, and it is not marked `@internal`. Measured on **2.1.304** with Plume's flags, in a trusted directory. The probe turn ran `sleep 3` four times through Bash, and the second line arrived just after the first tool result:

```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Also, before you say DONE, reply with the word PINEAPPLE."}]},"parent_tool_use_id":null,"priority":"next"}
```

| `priority` | what happened |
|---|---|
| absent | Same as `next` on this build. The CLI picks the default behind a feature flag, so never rely on it. |
| `next` | Joined the running turn. The model answered `PINEAPPLE\nDONE` in the same turn, and only one `result` came. |
| `later` | Waited. The turn answered `DONE` and sent its `result`, then a fresh `system/init` began a second turn that answered `PINEAPPLE`. |
| `now` | Cut the turn at once: a `result` with `stop_reason: "tool_use"` 20 ms later, then a new turn that carried on with the message. This is an interrupt in all but name. |

What a `next` message looks like on each side:

- **stdout echoes nothing.** No `user` line, no `system` event. The only sign is the next `system/status` `requesting`, which is the API request that carries it.
- **The transcript records it as an attachment, not a `user` line**, written when that request goes out. In a probe that sent the message 1 s into a 12 s `sleep`, the row reached disk 12.7 s later. So for as long as a tool call runs, the message is in neither the chat nor Plume's queue. The row:

  ```json
  {"type":"attachment","parentUuid":"…","attachment":{"type":"queued_command","prompt":[{"type":"text","text":"Also, before you say DONE, …"}],"source_uuid":"9b9f9a6a-…","delivery_id":"a3422f20-…","commandMode":"prompt","timestamp":"…"},"uuid":"1ec22e07-…"}
  {"type":"queue-operation","operation":"remove","content":"Also, before you say DONE, …","reason":"absorbed_mid_turn","commandUuid":"…","deliveryId":"…"}
  ```

  The model reads it as a system reminder: "The user sent a new message while you were working: … Address the message above as you continue this turn."
- **A message that arrives after the turn's last request runs as its own turn.** In the probe it arrived while the final reply streamed. The first turn ended with its `result`, then 0.1 s later came `system/init`, `status` `requesting`, the reply and a second `result`. Here the transcript writes an ordinary `user` row.
- **`prompt` is a block array for a stream-json host and a plain string for the TUI.** A typed TUI message also carries `"origin":{"kind":"human"}`. Agent messages, harness reminders and task notifications ride the same attachment type. They carry `isMeta`, a non-human `origin`, or `commandMode: "task-notification"`.
- **`--replay-user-messages` echoes the line once the CLI takes it in**, with `isReplay: true` and a `uuid` equal to the attachment's `source_uuid`. The echo comes before the `result` when the message joins the turn, and after it when the message runs as its own turn. Plume does not pass the flag. The `requesting` signal already answers the same question.

**Background subagents survive it.** A turn launched a background `Agent` (a `sleep` that then replied `BGDONE`) and went on with four `sleep 3` calls. A `next` message joined that turn. No `task_updated` reported `killed`. The subagent replied `BGDONE` and ended with `task_updated` `completed` and a `task_notification` `completed`, and its wake turn followed as usual. Written between turns while a subagent ran, the message started a turn of its own (`init`, reply, `result`), and the subagent completed about 22 s later in the same way.

**What Plume does with this.** Send-now (a queued row's Send now, or the Send Now menu command) writes every queued message, then the composer's text, as one `priority: "next"` line, and never sends an interrupt. With no turn running, it writes an ordinary turn. The "Deliver queued messages" setting (`QueuedMessageDelivery`) picks what an ordinary send does mid-turn: hold it until `result` (the default), or write it at once the way send-now does. Plan feedback always waits for the turn to end. `HeadlessSession.deliveringMessages` holds a sent message until the next `requesting`, so the chat can show it as sending and withdraw it (see below). A `result` that arrives while that list is not empty means the CLI is about to run the message as its own turn. The session holds that turn's end for `deliveryGrace` rather than announcing it, and the following `requesting` continues the turn. `TranscriptAttachment.userPrompt` renders a human `queued_command` as the user's message, between the replies it split.

### Withdrawing a mid-turn message — `cancel_async_message`

A `next` message can be withdrawn until the model takes it in. The user line has to carry a `uuid`, which the request then names:

```json
{"type":"user","uuid":"a383b9a3-…","message":{…},"priority":"next"}
{"type":"control_request","request_id":"c-1","request":{"subtype":"cancel_async_message","message_uuid":"a383b9a3-…"}}
```

Measured on **2.1.304** with Plume's flags, in a turn of `sleep 8` then `sleep 1`, with the message sent 1 s into the first sleep:

| withdrawn | reply | what happened |
|---|---|---|
| 1 s later, during the sleep | `{"cancelled": true}` | `command_lifecycle` `queued`, then `cancelled`. The model never saw the message, the turn answered `DONE` alone, and the transcript has no trace of it. |
| 0.5 s after the next `requesting` | `{"cancelled": false}` | `command_lifecycle` `started` had come with that `requesting`. The model answered `PINEAPPLE\nDONE`, and `completed` came just before the `result`. |

The reply is the race's answer: `true` means the message is gone, `false` means the model already has it. The binary describes `cancelled: false` as "not in the queue (already dequeued or never enqueued)". A message with a `uuid` also draws `command_lifecycle` events (`queued`, `started`, `completed`, `cancelled`) keyed by `command_uuid`. Plume does not read them yet.

**What Plume does with this.** Every delivering message carries a `uuid`, and its chip keeps Edit and Remove. Both send the request and show the chip as withdrawing. On `true`, Remove drops the message and Edit puts its text in the composer, as editing a queued message does. On `false` the chip says Claude already has it, until the `requesting` that carries it clears the chip. A withdrawal that empties the list while a `result` is held ends that turn at once. Never use `interrupt` with `cancel_queued` for this: it ends the turn and can stop background subagents.

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

Only the Stop button sends an interrupt. Send-now writes into the running turn instead — see "A message mid-turn" — because an interrupt can also stop background subagents.

Sent between turns while a background subagent runs, it kills that subagent instead: `task_updated` (`status: "killed"`), a `task_notification` with `status: "stopped"`, the reply, and the subagent's `[Request interrupted by user for tool use]` line. **No `result` follows**, because no turn was running. Verified on 2.1.280.

## Background subagents between turns

An `Agent` call with `run_in_background: true` returns at once, and the main turn ends with its `result` while the subagent works on. The subagent keeps streaming on the same stdout:

- `assistant` and `user` envelopes carrying `parent_tool_use_id` (the spawning call's id). No `stream_event` deltas and no `result` of their own.
- `system` events: `task_started`, `task_progress`, `background_tasks_changed` (the live list), `task_updated` and `task_notification`.

When the subagent finishes, its `task_notification` wakes the main agent: a fresh `system/init`, then a main-thread turn (envelopes with `parent_tool_use_id: null`) that ends in its own `result`. So only an envelope with no parent may mark a main turn as started. `HeadlessSession` reads it that way; a subagent's envelope opening one would never see a `result` close it. The woken turn's `system/status` `requesting` arrives about 0.1 s after the notification and seconds before its first envelope, and in the recorded runs only the main thread sent that event. `HeadlessSession` starts the turn there too.

## The live background-task list

`background_tasks_changed` carries the CLI's whole list of running background tasks, not only subagents. A backgrounded `Bash` and a `Monitor` both appear in it. Measured against **2.1.292** with the flags above, in a trusted directory: one turn started `sleep 40` with `run_in_background` and a `Monitor` on a `date` loop, then ended. The sleep finished between turns, and a later turn stopped the monitor with `TaskStop`.

```
{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b5b6p3ipm","run_id":"0muyhepps-9ba3eac4","task_type":"local_bash","description":"Sleep in background"}]}
{"type":"system","subtype":"task_started","task_id":"b5b6p3ipm","run_id":"0muyhepps-9ba3eac4","tool_use_id":"toolu_01F1…","description":"Sleep in background","is_backgrounded":true,"task_type":"local_bash"}
{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b5b6p3ipm",…},{"task_id":"bmzg7xfjs","run_id":"0muyheqxb-d628cb7a","task_type":"local_bash","description":"clock"}]}
… the turn ends with its `result`; 39 s later, between turns:
{"type":"system","subtype":"task_updated","task_id":"b5b6p3ipm","patch":{"status":"completed","end_time":1791400210755}}
{"type":"system","subtype":"task_notification","task_id":"b5b6p3ipm","tool_use_id":"toolu_01F1…","status":"completed","output_file":"…/tasks/b5b6p3ipm.output","summary":"Background command \"Sleep in background\" completed (exit code 0)"}
{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"bmzg7xfjs",…}]}
… TaskStop on the monitor:
{"type":"system","subtype":"task_updated","task_id":"bmzg7xfjs","patch":{"status":"killed","end_time":1791400236793}}
{"type":"system","subtype":"task_notification","task_id":"bmzg7xfjs","status":"stopped","summary":"clock"}
{"type":"system","subtype":"background_tasks_changed","tasks":[]}
```

Every event also carries `uuid` and `session_id`. What the run showed:

- **The list is the whole membership, sent on every change.** It arrives before `task_started` on a launch and after `task_notification` on an end, and fires between turns as readily as during one. An empty `tasks` array means nothing runs.
- **`task_id` is the id the tool's `tool_result` announces.** `Command running in background with ID: b5b6p3ipm.` and `Monitor started (task bmzg7xfjs, …` name the same ids `BackgroundTaskResult.parse` extracts, so a transcript entry and a list entry match by id.
- **A `Monitor` reports `task_type: "local_bash"`, the same as a backgrounded `Bash`.** The list cannot tell them apart; `task_started.tool_use_id` or the transcript can. The binary's other task types include `local_agent`, `remote_agent`, `in_process_teammate`, `local_workflow`, `monitor_mcp` and `dream`.
- **A Monitor event emits no `task_*` event.** Each event wakes a main-thread turn (`system/init`, then a `result`), and the list does not change.
- **The CLI exiting sends nothing.** A second run started `sleep 120` in the background, ended its turn, and then took a SIGKILL. Stdout closed with no further event. The `sleep` survived as an orphan of the dead CLI, so nothing on the wire can report it after that.

`HeadlessSession` therefore treats the list as the source of truth for its tab's background tasks, and clears them when its process exits.

A background `Agent` appears in the list as `local_agent`, before the `result` of the turn that launched it. Measured on **2.1.296** with Plume's flags: the list named the agent 1.0 s before the `result`, and the subagent's first envelope came 1.3 s *after* it. The transcript scan cannot be relied on to see the subagent by then, so `HeadlessSession` reports the list's subagents to `StatusEngine.setLiveSubagentActivity`, and a turn ending with one listed reads `waitingOnSubagents` rather than `awaitingReply`. When the subagent finishes, the list drops it 0.06 s before the woken turn's `status` `requesting`. The session holds that drop for a short grace between turns, so the gap never reads as a finished turn.

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
| `get_context_usage` | `detail` | What fills the context window, by category — see below |
| `mcp_message` | `server_name`, `message` | Host-provided MCP servers |
| `hook_callback` | `callback_id`, `input` | In-process hooks, no shell scripts |

`set_permission_mode` and `set_model` replace what Plume does today by pasting `/model` or sending Shift+Tab.

**Probe an untried request against the real binary before designing around it.** A short Python harness spawns `claude -p --output-format stream-json --input-format stream-json --verbose`, sends `initialize`, then the request under test. Probe the failure modes too, not only the happy path, and record what you find here with the CLI version. `generate_session_title` below came out of one such probe.

**Every message id sent to the CLI comes from the transcript.** The chat's optimistic first message carries Plume's own id, `plume.optimistic.first-message`, which the CLI has never seen. Sent as `last_seen_user_message_uuid`, it gets `rewind_conversation` refused as `stale_target`. Gate any id-taking action on `Transcript.messages` containing the id, and log the CLI's own refusal reason.

Two more were measured against 2.1.280 and are used by Plume: `side_question` and `rewind_conversation`.

## Side questions — `side_question`

Serves `/btw`. The CLI has no `btw` command in its `initialize` list — sending the literal text is a visible no-op, the same situation as `/rc` — so Plume supplies the command and intercepts it.

```json
{"type":"control_request","request_id":"sq-1",
 "request":{"subtype":"side_question","question":"what model are you?"}}
```

A `control_request_progress` line always arrives first, then the answer:

```json
{"type":"system","subtype":"control_request_progress","request_id":"sq-1","status":"started", ...}
{"type":"control_response","response":{"subtype":"success","request_id":"sq-1",
 "response":{"response":"…","synthetic":false}}}
```

Measured behaviour:

- It **reads** main context — it recalled a codeword set in an earlier main turn.
- It **writes nothing**. Transcript line count was unchanged across two side questions, so there is no branch to read one back from. This is why Plume holds them in memory on `HeadlessSession` and does not persist them.
- It **does not chain**: a second side question could not see the first.
- It works **mid-turn**. Fired during a live 3-tool-call turn, it answered in 1.3s and the main turn then completed normally and correctly.

## Rewinding — `rewind_conversation`

Cuts the conversation back to just before a message so it can be asked again. This is what Plume's "Roll back to here" uses, on a reply: it targets the user message that followed the reply.

```json
{"type":"control_request","request_id":"rw-1",
 "request":{"subtype":"rewind_conversation",
            "target_message_uuid":"…","last_seen_user_message_uuid":"…"}}
```

`last_seen_user_message_uuid` is required in practice: omit it and the CLI refuses with `stale_target`, since a target chosen against a conversation that has moved on would cut in the wrong place.

A success carries `prefillText` — the target's own text, for putting back in the composer — and `precedingAssistantUuid`. A refusal is **not** an error response: it is `{"rewound": false, "reason": "…"}`. Known reasons: `commands_queued`, `prompt_pending`, `turn_running`, `target_not_found`, `stale_target`, `unseen_later_turn`, `poll_tool_result_target`, `target_splits_tool_call`, `delivered_poll_events_in_range`, `persist_failed`, `state_changed`.

**It deletes nothing.** Measured twice, including once with a scrubbed environment: the file stayed the same length through the rewind, the prefix was byte-identical, no uuids were removed, and the abandoned prompt stayed on disk. Later turns append.

**The new tip has no row of its own.** A rewind appends one `{"type":"last-prompt","rewound":true,"leafUuid":…}` row and nothing else; in a measured run its `leafUuid` named the reply being rolled back to. The row has no `uuid`, so a tree walk from the file's last uuid'd row still lands on the cut-off branch until the next turn appends under the new tip. Plume applies the cut itself from the success response: `HeadlessSession.rewoundBeforeMessageID` and `Transcript.rolledBack(before:)`. Measured against 2.1.289.

**It cannot switch branches.** Rewinding onto a message on an already-abandoned branch answers `target_not_found` *even though that uuid is still in the file*: the file is append-only but the CLI's in-memory chain is not. Rewind is a one-way ratchet backward along the current path, not navigation.

## Forking — `--fork-session` and `--resume-session-at`

The second way to branch, and what Plume's "Fork to a new tab" uses. Unlike a rewind it leaves both conversations live.

```
claude -p --resume <old-id> --fork-session --session-id <new-id> --resume-session-at <message-uuid>
```

- `--fork-session` writes a **new `.jsonl` under a new session id**, copying history verbatim with uuids preserved. The original file is untouched.
- `--session-id` lets the host choose the fork's id up front, so a tab can record it before the process exists.
- `--resume-session-at` resumes only up to a given entry. Cut at the **parent** of the message being redone, not the message itself — cutting at the message keeps it, and the fork opens on two consecutive user turns.

**`--resume-session-at` is undocumented**: the CLI parses it but `claude --help` does not list it, so an upgrade can withdraw it without warning. That is why forking is the secondary path and `rewind_conversation` is the default. Companion hidden flags: `--resume-drops-turn`, `--rewind-files`, `--reply-on-resume`.

`--resume` accepts only a session id; passing a message uuid fails with `No conversation found with session ID`. `fork_conversation` on the control plane is a *cloud* mechanism — it needs a Remote Control sdkUrl and answers `{"forked":false,"reason":"unsupported"}` locally.

**The fork owns its transcript path, and reads a file already there as proof the id is taken.** Starting with a file at `<new-id>.jsonl` — even an empty one — exits immediately with `Error: Session ID <uuid> is already in use`. Plume's own `FileWatcher` created the file it watched and killed every fork this way, which is why a transcript watch passes `createsFile: false` and polls for the file instead.

**A forked session writes nothing until its first turn produces content.** Plume forks with an empty prompt, so the process sits idle and no `.jsonl` exists until the user sends something. A missing transcript straight after a fork is the expected state, not a failed launch — and a tab that waits for one before enabling its composer can never get one.

**Resuming a session whose process is still running does not disturb the original.** Both processes stay alive and independent; measured across a fork with a per-second process watch.

## Context usage — `get_context_usage`

Feeds the context breakdown in the statusline's usage popover. Probed against 2.1.296 after `initialize`:

```json
{"type":"control_request","request_id":"r2",
 "request":{"subtype":"get_context_usage","detail":"summary"}}
```

`detail` must be `summary` or `full`. Plume sends `summary`. The reply:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"r2","response":{
  "categories":[{"name":"System prompt","tokens":2145,"color":"promptBorder","kind":"used"},
                {"name":"System tools (deferred)","tokens":26459,"isDeferred":true,"kind":"deferred"},
                {"name":"Autocompact buffer","tokens":33000,"kind":"buffer"},
                {"name":"Free space","tokens":231330,"kind":"free"}, …],
  "totalTokens":35670,"maxTokens":300000,"rawMaxTokens":300000,
  "autocompactSource":"settings","percentage":12,"gridRows":[…]}}}
```

- `kind` is `used`, `deferred`, `buffer` or `free`. The `used` categories sum to `totalTokens`.
- `ContextUsageBreakdown` reads `name`, `tokens`, `kind` and `isDeferred`, and ignores everything else, including `gridRows` and `color`.
- The popover lists every category except `free` and `deferred`. Free space restates the meter's remainder, and deferred tools are not loaded into context.
- `HeadlessSession.requestContextUsage()` sends the request each time the popover opens, never on a timer. The last reply stays cached in `contextBreakdown` meanwhile.
- An error reply, or a reply with no readable category, clears `contextBreakdown`, and the popover shows no breakdown.

## Session titles — `generate_session_title`

Verified first-hand against 2.1.276 and 2.1.280.

**Claude Code auto-titles the interactive TUI. A headless conversation may not get an `ai-title` line on its own** — a sample of 87 recent headless (`entrypoint: sdk-cli`) transcripts had one on only 26, with no guarantee it will appear on the rest — which is why `SessionJSONLReader` falls back to the first user message, and why Plume asks for a title explicitly rather than waiting for one to show up.

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

**The request is answered mid-turn without disturbing the turn.** `generate_session_title` rides the control plane, which is answered independently of whatever turn is running on the conversation plane. Against 2.1.280, a title request sent in the same breath as the first user turn was answered while that turn was still streaming, and the turn finished exactly as if it had not been asked at all.

**When the CLI does write an `ai-title` line for a session, only the first one lands in the transcript.** Asking again returns a new title in the control response, and the transcript keeps the original — measured by titling one session twice and finding two identical `ai-title` lines against two different replies. So the control response is the authoritative delivery path, not a shortcut past the watcher's debounce: a re-title reaches the UI only because `HeadlessSession` applies the reply itself.

`TitleStore` ranks each tab's title by `TitleSource` — `fallback` < `transcript` < `reply` — and only accepts a title whose source ranks at or above the one already recorded. This matters because `AgentTitleMonitor` gets re-watched (a relaunch, `EnterWorktree` relocating the transcript, an unarchive) and re-reads the transcript's `ai-title` fresh on every watch; since that line stays frozen at the first title, a re-watch after a reply has retitled the tab would otherwise clobber it right back to the stale first title. Ranking, not the watcher's own dedup, is what stops that.

**An empty `description` is answered with `{"title": null}`**, not an error. So a decline and a failure are distinct — null means the CLI had nothing to work with, an `error` subtype means the request was malformed — and neither ever yields a bad title string. Plume treats both the same way: keep whatever the tab is already called.

`SessionTitleRequester` decides when to ask, since every request is a model call: once as soon as the opening message reaches the agent, and again when a plan file names the work better than the opening message did. Never on the terminal transport, whose TUI titles itself.

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
