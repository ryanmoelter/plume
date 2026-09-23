# The Codex app-server protocol

How Plume talks to `codex`. The sibling of `docs/headless-protocol.md`, which
covers Claude Code's stream-json.

Verified against `codex-cli 0.153.4`, logged in with ChatGPT.

## Getting the schema

The CLI generates its own protocol schema:

```
codex app-server generate-json-schema --experimental --out <dir>
```

That writes `ClientRequest.json` (155 methods), `ServerRequest.json` (11),
`ServerNotification.json` (81) and a per-type file for each payload. Plume
reads a small corner of it, so **the Swift types are hand-written, not
generated** — see "Why no codegen" below.

## Transport

`codex app-server` speaks newline-delimited JSON over stdin/stdout, the same
framing `AgentProcess` already does for stream-json. `CodexCommand` builds the
argv; `AgentProcess` wraps it in a login shell, which is what puts `codex` on
PATH for a GUI-launched app.

Three things about the envelope, all confirmed by hand against a live server:

- **There is no `jsonrpc` field.** `JSONRPCRequest.json` requires only `id` and
  `method`, and every line the server writes omits `jsonrpc` entirely. Sending
  it is tolerated; Plume does not. Requiring it on the way in would drop the
  whole stream.
- **`id` is a string or an integer.** Plume only mints integers, but a server
  request may carry either.
- Route by shape: `method` + `id` is a request, `method` alone is a
  notification, anything else is a reply. `CodexRPC.decode` does exactly this.

## Handshake

1. `initialize` — `{clientInfo: {name, title, version}, capabilities: {experimentalApi: true}}`.
   The reply is `{userAgent, codexHome, platformFamily, platformOs}`.
2. `initialized` — a notification, the only one the client ever sends.
3. `thread/start` or `thread/resume`.

`InitializeCapabilities.experimentalApi` is required for the `permissions`
profile parameter Plume sends on thread start and resume. A bare `thread/start`
works without it, but is not Plume's actual launch request.
`optOutNotificationMethods` on the same
struct declines notifications the client never reads. It matches **exact
method names, not prefixes** — a pattern there suppresses nothing, silently.
`CodexCommand.ignoredNotifications` lists them.

## Threads and turns

`thread/start` needs only `cwd`. `ThreadStartParams` has no required fields,
and `permissions` and `sandbox` cannot be combined — pick one axis.

The reply carries `thread.id` (persisted to `TaskTab.agentSessionID`) and
thread history/status metadata. Resolved `model`, `reasoningEffort`, `cwd`,
and active permission profile are top-level response fields, beside `thread`.

A turn is `turn/start`, ended by a `turn/completed` notification.
`turn/interrupt` is a request, never a signal. `turn/steer` amends a turn
already in flight, which stream-json has no equivalent of.

## What the server asks the client

Server requests are the `can_use_tool` analogue, and every one of them **must
be answered** — an unanswered request stalls the turn exactly the way an
unanswered permission prompt does. `CodexAppServerClient` answers anything it
does not implement with a JSON-RPC error rather than silence.

| Request | Meaning |
| --- | --- |
| `item/commandExecution/requestApproval` | run a command |
| `item/fileChange/requestApproval` | apply a patch |
| `item/permissions/requestApproval` | widen the permission profile |
| `item/tool/requestUserInput` | ask the user a question |
| `mcpServer/elicitation/request`, `item/tool/call` | not implemented |

**`item/fileChange/requestApproval` does not carry the patch.** It carries
`{itemId, threadId, turnId, reason?}`, and the diff lives on the `fileChange`
item delivered earlier by `item/started`. Approvals must be joined against the
item table — unlike Claude's `can_use_tool`, which is self-contained.

Decisions are closed enums chosen by the server per request
(`availableDecisions`), and **none of them carries free text**. A Codex denial
is `decline` or `cancel`; there is no deny-with-a-reason.

## History

`ThreadItem` is one vocabulary for both live and historical items, so
`item/started`, `item/completed` and `thread/items/list` all decode the same
way. The history response wraps each item in `{item, turnId}`; unwrap the
entry before mapping it. Live text and reasoning deltas update that same
item by `(turnId, itemId)`, preserving its place among tool calls instead of adding a
second streaming copy at the end of the chat.
That is why Plume reads history through `thread/items/list` rather than
parsing the rollout JSONL at `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`:
the file format is not in the schema, is unversioned, and the API paginates.

Plume keeps a bounded local snapshot of opened Codex conversations under
`codex-history` in its application support directory. A saved copy can render
without an app-server; successful server hydration replaces its offline notice.
Live items win when loading a saved copy races streaming. Cached plans never
create approval controls, and cached history never asserts agent activity.
Writes are debounced and atomic, with explicit flushes after turns and session
stops. This is a best-effort cache, not an archive: it retains at most 10,000
items / 8 MiB per tab and 100 files / 128 MiB overall, and an abrupt exit can
lose the most recent streaming update. Child-thread history still requires
an app-server after restarting Plume.

User images and image-view, image-generation, MCP, and dynamic-tool results
render through the shared transcript image views. Data URIs and bounded local
files are supported; remote URLs are not fetched automatically, and unavailable
images retain a visible placeholder.

## Subagents

Child threads use the same app-server connection as their parent. Their item,
delta, turn and `thread/status/changed` notifications carry the child's
`threadId`; Plume routes those into a separate item table so child messages do
not appear in the root chat.

`subAgentActivity` is the current identity signal: `agentThreadId` is the
stable key and `agentPath` identifies the agent in the tree. Older and current
CLI runs can also expose `collabAgentToolCall`; its `receiverThreadIds`,
`prompt`, `model` and `agentsStates` provide discovery and lifecycle fallback.
Recovery scans the parent's paginated item history for both forms, reads child
metadata with `thread/read` and `includeTurns: false`, then loads the child via
paginated `thread/items/list`. It must never use `thread/resume`, which would
take ownership of the child conversation rather than inspect it.

## Models and effort

Account quota comes from `account/rateLimits/read` after initialization and
`account/rateLimits/updated` notifications afterward. Updates can be sparse;
retain window metadata when omitted; explicit null clears it. `usedPercent` is 0–100, durations
are minutes, and reset times are Unix seconds. The Codex status strip displays actual bucket names and durations, including
windows other than 5h/7d, instead of assuming primary/secondary order.
Accounts without a quota snapshot can still start conversations.

`model/list` returns the catalog live, which Claude Code has no equivalent of.
As of this writing it is `gpt-6-astra` (the default), `gpt-5.6-sol`,
`gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5.5` and `gpt-5.4-mini`. Entries carry
`hidden` and `isDefault`, and each lists its own `supportedReasoningEfforts`.

Effort runs `low, medium, high, xhigh, max, ultra` — a superset of Claude's, and
the schema types it as an open string. That is why `AgentEffort` cannot stay a
closed enum shared by both providers.

`permissionProfile/list` returns `:read-only`, `:workspace` and
`:danger-full-access`.

## Why no codegen

The schema is 2.1 MB and describes 155 client methods; Plume uses about twelve.
Generating it would emit thousands of unreachable types, require a new SwiftPM
package (which means hand-editing `project.pbxproj`), and produce exhaustive
enums that turn a Codex point release into a hard decode failure. The
hand-written subset decodes forgivingly instead — an unknown notification is
logged and dropped, not fatal.


## Planning and recovery

Codex Plan mode is `collaborationMode: {mode: "plan", settings: {model,
reasoning_effort, developer_instructions: null}}` on `turn/start`. Code mode
uses `mode: "default"`. These are independent of `permissions`; read-only
access is not Plan mode. The `plan` item is a streamed proposal, whereas
`turn/plan/updated` is a progress checklist. Neither is Claude's blocking
`ExitPlanMode` request. Plume docks the latest completed proposal as a plan
document. Implementing it switches to Code mode and starts a new turn asking
Codex to implement it; requesting changes stays in Plan mode and starts a new
turn with the user's feedback. These are ordinary `turn/start` requests, not
fictional approval or denial RPCs. During history recovery, a proposal is
pending only when no later user message exists, so an answered plan does not
reappear after reconnecting.

The session publishes the returned thread ID before loading history but does
not send queued turns until hydration completes. Live updates received during
hydration win over older history. Completed items replace partial content;
late start events and deltas cannot overwrite a completed item.

A failed handshake exposes Reconnect. Reconnecting retains the same thread ID
and only carries unsent queued inputs forward. A sent input whose reply was
lost is never automatically replayed. Stop requests made before a turn ID
arrives are retained and sent when the ID becomes known. Failed or interrupted
turns leave queued follow-ups unsent until the user acts.

Model and effort changes apply through the next `turn/start`, eliminating
races between independent settings requests and a submitted turn. Catalog
values remain open strings, including unfamiliar effort levels. A loaded
permission catalog with no allowed profiles never falls back to disallowed
static options.

## Skills and conversation discovery

The composer discovers enabled skills with `skills/list` for its working
directory, including before a conversation starts. `$` completion inserts
native `$name` references. Sending a discovered reference
includes both the text and an explicit `{type: "skill", name, path}` input;
paths come from discovery, never from arbitrary draft text. `skills/changed`
refreshes the catalog. Claude's slash commands retain their existing behavior.

The resume picker uses a short-lived, read-only app-server connection and
paginated `thread/list`, filtered to the task directory and repository
worktrees. Listing does not resume a conversation or take ownership of it.
Selecting a row restores its thread ID through the normal recovery path,
using the tab's current directory as the picker describes. Titles prefer thread names, fall back to the first
message preview, and follow `thread/name/updated` events.

## Work after a turn and Stay Awake

Codex's authoritative live inventory is `thread/backgroundTerminals/list`.
Plume reconciles every page into the shared background-task tracker for the
parent and discovered child threads. It refreshes at hydration, turn end,
and command item lifecycle events, then polls while confirmed work remains.
Historical command items alone never acquire a hold. Failed polls retain
only previously confirmed entries with their original 30-minute hard cap;
disconnecting clears the hold. A working child also keeps the machine awake
while its parent waits for an approval.

## Remote control

Codex CLI 0.153.4 exposes experimental `remoteControl/*` app-server methods.
They work on the tab's existing stdio server, but expose a host/environment,
not just a single conversation. Plume reuses the antenna menu, `/rc`, sidebar
indicator and configurable Stay Awake reason. Codex's details panel provides
phone pairing QR codes and links, manual computer pairing codes with expiry,
paired-device listing and revocation. A pairing link connects a device to the
host; it is not a Claude-style conversation URL.

Only one Plume tab may serve the remote connection at once. Enabling and
disabling pass `ephemeral: true`, leaving user configuration unchanged; closing
the hosting tab terminates its server and remote connection. Other running
tabs remain on their own servers. The panel states this scope explicitly.
Every Codex composer's common Remote Control menu targets that same active
host, so its state and disconnect action agree across tabs. The sidebar marks
the hosting task only; sharing a host control does not make the other running
processes remotely reachable. Stay Awake counts the host once and does not
add a second Active reason for an idle remote connection. Actual working
turns still have their own Working reason.

All servers using the same Codex installation report the same installation
identity. A live probe reached the backend but returned HTTP 409, "Remote app
server already online", while another app owned remote access. Plume must
report that failure and must not take over or stop the other app. End-to-end
pairing on a phone remains unverified until that existing connection is off.

A shared backend is future work. In the installed CLI, `app-server proxy`
sends raw JSON to its socket, whereas `app-server --listen unix://PATH`
expects WebSocket framing. A custom WebSocket probe confirmed that separate
clients can join a running thread, but even unsubscribed clients receive
global thread metadata. Foreign thread events therefore require ancestry
checks and must never be assumed to represent subagents.

For manual verification, open a running Codex chat's antenna menu and choose
Connect Remote Control. If another application owns the host, expect a
connection error and stopped retries. With that application's remote access
turned off by its user, connect again and generate a pairing code. Scan the
QR code with a phone to open ChatGPT setup, then confirm the same account and
workspace and complete any requested authentication. Alternatively, on another
computer, open ChatGPT Settings > Connections > Control other devices, choose
Add, and enter the manual code. Check that a remote follow-up streams locally, an
approval answered remotely disappears locally, and disconnecting removes the
remote Stay Awake reason without ending the local conversation. Closing the
hosting tab should end both its conversation process and remote connection.

Pairing route evidence: the installed
`/Applications/ChatGPT.app/Contents/Resources/app.asar` constructs
`https://chatgpt.com/codex/pair?pairing_code=…` from the opaque `pairingCode`
returned by `remoteControl/pairing/start`. Its
`codexMobile.setupPage.waiting.computerPairingCode.caption` gives the computer
setup instructions above; `manualPairingCode` is a separate value. Plume uses
URLComponents to encode the opaque code and Core Image to render the QR
locally. Expired or claimed codes remove the QR/link and copy controls; no
pairing secrets are logged or persisted. The official
[Remote connections guide](https://learn.chatgpt.com/docs/remote-connections)
describes QR-based mobile setup and account/workspace authentication, but does
not document third-party host setup. Successful Plume pairing remains a live
verification requirement.

## Verification, September 2026

Live probes exercised command approval/cancellation, file approval/denial,
user questions, child-agent approval routing, and disconnect/resume while an
approval was pending. Recovery retained one user message without replaying
the command. A live shell command remained in the background inventory after
its parent turn completed and disappeared when its process exited.

Focused tests cover recovery ordering, stale approvals, skill inputs,
discovery pagination, subagents, background inventory reconciliation and
Stay Awake. The skill autocomplete and resume picker UI interactions still need a
manual visual check; protocol probes and unit tests do not verify their layout.


## Plume 0.11–0.12 integration

Composer messages keep text and images as `UserContentBlock` values through
queueing, editing, retries and steering. Codex receives images as `image`
inputs with data URLs. The shared local `!` runner supplies cancellation,
timeouts and live command chips; command/output text uses the shared shell
transcript renderer when Codex replays it. These explicitly entered shell
commands run locally through Plume, as they do in Claude tabs.

Codex account quotas are shared independently of Claude's account quota. Both
show time-based pacing and stale readings, and refresh countdowns without a
new message. Codex preserves the server's actual bucket/window durations and
omits unused windows. Full Access follows the same visibility preference as
Claude's Bypass Permissions; planning and permission profiles remain separate.

Both headless providers now use process-group shutdown. Moving a tab between
tasks retains its process and reparents status/background work. Plume reserves
Codex thread IDs before resume handshakes so two Plume tabs cannot both own
one thread. This is an in-app guard: the app-server protocol does not provide
an exclusive cross-application thread lease, and Plume does not apply Claude's
process/transcript heuristics to Codex.

Codex titles still use server thread names (including name-update events),
with a first-message preview fallback. The installed app-server exposes name
assignment, but no equivalent of Claude's `generate_session_title` request;
Plume does not introduce a hidden extra model call for this purpose.
