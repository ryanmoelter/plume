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
| `mcpServer/elicitation/request` | not implemented |
| `item/tool/call` | run a Plume dynamic tool in the owning thread |

**`item/fileChange/requestApproval` does not carry the patch.** It carries
`{itemId, threadId, turnId, reason?}`, and the diff lives on the `fileChange`
item delivered earlier by `item/started`. Approvals must be joined against the
item table — unlike Claude's `can_use_tool`, which is self-contained.

Decisions are closed enums chosen by the server per request
(`availableDecisions`), and **none of them carries free text**. A Codex denial
is `decline` or `cancel`; there is no deny-with-a-reason.

MCP elicitation uses the same pending request queue, including requests from
child threads. An accepted form sends `{action: "accept", content: {...}}` with
typed values. Accepting a URL request sends only the action. Opening the link
requires a separate user action. Decline and cancel carry only their action.
The `openai/form` and `openaiForm` aliases accept the same supported field
schemas. Plume declines requests whose fields or constraints it cannot render.
Requests without a turn ID remain pending across turn completion.
The matching turn's completion cancels correlated requests. A server resolution
or disconnect removes the request, and closing the tab cancels its outstanding
elicitations. Form values stay in the active prompt and are not cached.

## Plume dynamic tools

Plume registers `plume_presence` in `thread/start.dynamicTools`. It accepts
an empty object and returns the same `awake`, `asleep`, or `locked` text as
`plume presence`, using the same CoreGraphics reader.

Plume also registers `plume_start_session`, `plume_dismiss_task` and
`plume_send_message` for Codex parents. Codex children register only
`plume_send_message` from this set and can address their own parent. See [Child sessions](child-sessions.md)
for launch settings, approvals, cards and reports.

Codex asks for each tool through `item/tool/call`. Plume checks the root
thread and active turn before dispatching. An unknown tool or invalid
arguments produce a failed tool result. Native subagent threads and
remote-control attachments do not run Plume's tool.

Codex stores the registration with its thread. Resuming a thread created
with the tool keeps it available. The 0.153.4 protocol only accepts dynamic
tool definitions on `thread/start`. A thread created without the tool cannot
gain it through `thread/resume`.

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

`model/list` returns the catalog live. The pre-launch picker reads it through a temporary app-server endpoint without creating a conversation.
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

## Offline subagent history and cmux import

Child descriptors and ordered conversation items are cached alongside the parent
history in a separate bounded, atomic cache. Each snapshot belongs to a specific
Plume tab and parent thread. Restoring it never recreates approvals, working
status, or Stay Awake holds; live notifications and authoritative server history
win over saved content. Archiving preserves the cache.

cmux import reads `~/.cmuxterm/codex-hook-sessions.json`. It requires an exact
surface and workspace match, selects a uniquely newest thread when a surface was
reused, and verifies the recorded rollout's `session_meta.id` and directory.
Ambiguous or unverifiable records remain terminal tabs. Imported Codex tabs keep
their provider and thread ID and resume through app-server, not the Claude JSONL
reader. Import does not stop or take over the source cmux process. Headless
resume preserves the conversation and unsent queue when Codex reports another
active writer; see "External conversation ownership" below.

## Work after a turn and Stay Awake

Codex's authoritative live inventory is `thread/backgroundTerminals/list`.
Plume reconciles every page into the shared background-task tracker for the
parent and discovered child threads. It refreshes at hydration, turn end,
and command item lifecycle events, then polls while confirmed work remains.
Historical command items alone never acquire a hold. Failed polls retain
only previously confirmed entries with their original 30-minute hard cap;
disconnecting clears the hold. A working child also keeps the machine awake
while its parent waits for an approval.

This inventory describes Codex-managed terminal sessions, not arbitrary shell
children. Use `exec_command` with a short `yield_time_ms` to keep a command such
as `sleep 60` in a managed session. A shell command such as `sleep 60 &` can
finish its command item immediately and leave an empty inventory; the shell’s
child may also fail to start or be terminated as the shell exits.

For zsh commands, Plume supplies a per-tab startup file that restores the
user’s startup configuration and opens a read-only file descriptor. Shell
children inherit it. Plume asks macOS which processes have that file open and
checks for processes reparented to launchd. Groups with a live, attached
leader still use managed-session tracking. Plume tracks confirmed detached
processes by PID and birth time until exit or tab closure. This covers commands run
by a Codex subagent that inherits the tab’s shell configuration.

A process that closes the descriptor before discovery cannot be identified.
Other shells, custom shell environment filters, and restrictive inheritance
policies skip this mechanism. Attaching to a conversation started remotely
preserves its existing shell configuration. Codex’s managed-session tracking
still works in those cases.

Local `!` commands also hold Stay Awake while their processes run. A completed
command waiting in the composer queue is no longer running work. Moving the tab
preserves its task ownership, and cancellation releases the reason.

## Plume CLI environment

Each headless thread gets its own Plume CLI environment through the thread's
`shell_environment_policy.set` configuration. To check a live tab, ask it to run
`env | grep -E '^PLUME_(SOCKET|TAB_ID|TASK_ID|BUNDLE_ID)='`.
On Codex 0.153.4 all four values matched the scratch Plume instance, including
the task and tab UUIDs in its store.

## Remote control

Codex CLI 0.153.4 exposes experimental `remoteControl/*` app-server methods.
Headless Codex tabs share one stdio app-server, which exposes a host/environment
rather than a single conversation. Plume reuses the antenna menu, `/rc`, sidebar
indicator and configurable Stay Awake reason. Codex's details panel provides
phone pairing QR codes and links, manual computer pairing codes with expiry,
paired-device listing and revocation. A pairing link connects a device to the
host; it is not a Claude-style conversation URL.

Enabling and disabling pass `ephemeral: true`, leaving user configuration
unchanged. All headless Codex tabs use the same remote controller. Closing one
tab detaches it; the server and remote connection remain while other headless
Codex tabs are attached. The last tab closes the server. Stay Awake counts the
host once, while actual working turns keep their individual Working reasons.
Terminal Codex tabs still use their separate private servers.

Sharing the process is necessary for remote access across chats: another server
can read a persisted transcript but cannot resume its active writer. A live
0.153.4 probe reproduced that rejection with both history formats. Virtual
clients share one initialization and request sequence; thread notifications and
approval requests still pass through each session's thread/ancestry checks.
Server-request responses are deduplicated at the shared host.

All servers using the same Codex installation report the same installation
identity. A live probe reached the backend but returned HTTP 409, "Remote app
server already online", while another app owned remote access. Plume must
report that failure and must not take over or stop the other app. Phone pairing succeeded once the desktop remote connection was turned off.
This conflict was reverified against CLI 0.153.4 on September 22, 2026; the
temporary probe exited and the configuration checksum was unchanged.

For the separate terminal transport, `app-server proxy`
sends raw JSON to its socket, whereas `app-server --listen unix://PATH`
expects WebSocket framing. A custom WebSocket probe confirmed that separate
clients can join a running thread, but even unsubscribed clients receive
global thread metadata. Foreign thread events therefore require ancestry
checks and must never be assumed to represent subagents.

For manual verification, open the Remote Control row's menu in a running Codex
chat's info pane and choose Connect Remote Control. If another application owns the host, expect a
connection error and stopped retries. With that application's remote access
turned off by its user, connect again and generate a pairing code. Scan the
QR code with a phone to open ChatGPT setup, then confirm the same account and
workspace and complete any requested authentication. Alternatively, on another
computer, open ChatGPT Settings > Connections > Control other devices, choose
Add, and enter the manual code. Check that a remote follow-up streams locally, an
approval answered remotely disappears locally, and disconnecting removes the
remote Stay Awake reason without ending the local conversation. Closing one of two headless tabs must keep the other reachable; closing the
last tab should end the host and remote connection.

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
not document third-party host setup. The generated QR and paired-device list were verified in a live Plume host.

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
Codex thread IDs before resume handshakes and checks live terminal ownership
before launching or resuming another tab. This is a guard on Plume's launch path:
commands entered directly into the TUI cannot be preflighted by its read-only
observer. Codex 0.153.4 rejects a second server resuming a live thread with an
“already has an active writer” error. Plume does not apply Claude's
process/transcript heuristics to Codex. Headless resume classifies the server’s
exact active-writer refusal and offers a retry after release. Terminal-mode
refusals remain in the real TUI; its observer never claims the thread.

Codex title generation follows the shared policy: once after the first completed
turn, then when a plan provides a better subject. User-named tasks and existing
server names suppress the initial request. Because app-server has no equivalent
of Claude's `generate_session_title`, Plume uses a separate ephemeral Luna request
with user configuration, rules, skill discovery, and tools disabled. A dedicated
model catalog removes patch/Code Mode tools that feature flags alone leave
available; strict configuration rejects incompatible CLI versions. The request
has a 45-second timeout and is canceled with its conversation. Successful short
structured titles are saved through `thread/name/set`; failure retains the
preview. Newer server names and user renames win over in-flight generation.
A live probe using the exact Swift-generated arguments verified structured title
output; a separate tool-inventory probe reported no tools.

### Terminal activity and Stay Awake

Plume's Codex terminal transport now starts a private `codex app-server --listen
unix://PATH` process and launches the actual TUI with `codex --remote unix://PATH`.
The socket sits inside a unique owner-only directory under `/private/tmp`. It is
not the user's shared desktop daemon and does not expose a TCP port.

A separate read-only WebSocket client initializes, then polls `thread/loaded/list`
and `thread/read` once a second. Idle servers provide no sleep hold. Active flags
separate approval/question waits from running work. Other active roots and child
threads continue to count if the selected root finishes. Background terminals
come from the same server's live inventory, and unloading a thread retires its
inventory. The observer never starts/resumes a thread or answers server requests;
the terminal remains the approval owner. Ephemeral title-helper threads never
replace the root conversation used for resume.

Closing the surface or quitting Plume stops its observer and owned server. A dead
surface is detected within two seconds. An unresponsive observer releases stale
activity after twenty seconds and retries its read-only connection up to three
times, without terminating the TUI's work. Exhausted retries leave an explicit
error until the tab is reopened; closing the tab still stops its owned server.
Unsupported CLI versions fail visibly rather than falling back to untracked work.

Verification: create a Codex terminal tab, send a short prompt, then leave it idle
and inspect Stay Awake. Run a command long enough to observe working status and
an approval-requiring command to check the wait state. Background a command and
finish the turn to check its independent hold, then let it exit. Close the tab;
its `codex app-server --listen unix://...` process and socket directory must go
away. `CodexUnixWebSocketTests` covers partial frames, fragmented text, interleaved
ping, handshake validation, and closing an unfinished handshake.

The alternative hook route requires users to review each hook definition in
`/hooks` ([official hook documentation](https://learn.chatgpt.com/docs/hooks)).
Plume does not disable that trust check to instrument terminals.

### Verification of the parity follow-up

The September 22 follow-up exercised offline child history, exact cmux identity
matching, local command holds, title generation, Unix WebSocket framing, and
remote-control races. The broad unit run passed 2,119 tests; the title path
escaping failure was fixed and the intermittent GUI shortcut test passed on its
focused rerun. All 32 follow-up tests passed. The three existing environmental
suites (real transcript corpus, real surface commands, checkout-specific session
path discovery) were excluded from that broad run.

A separate hidden Plume instance generated a title visible in its sidebar and
tab; Codex's persisted `name` matched while `preview` remained the original
prompt. The remote conflict notice was verified in an isolated UI instance.
Phone pairing succeeded after the desktop remote host was disabled. A later
multi-chat test exposed an ownership conflict: the remote server could list
threads owned by other per-tab servers, but could not resume them.

The terminal smoke test used the actual Codex TUI connected to Plume's private
server. Its command moved the tab from working to awaiting reply. A later sleep
process survived its parent turn: while the parent was idle, the live inventory
contained the process and `pmset` showed Plume's “1 background task” sleep
assertion. Once the process exited, the inventory and assertion both cleared.
The display was asleep, so this test attached the TUI through a separate PTY;
Ghostty's visible interaction still needs a manual check on an awake display.

### Shared remote host follow-up

The headless host is now shared across tabs. Remotely opened roots attach to an
exact persisted Codex thread ID, or create a new headless tab. Helpers and child
threads are excluded from task creation. Pending approvals replay after attachment,
including child requests whose parent was not attached yet. Session request-ID
deduplication prevents repeated rows. Remote attachment preserves server settings
and restores active turns and approval/input waits.

Verification: 81 focused tests passed. In an isolated Debug instance, two separate
chats completed through one app-server. Closing one tab preserved the server PID;
the remaining chat completed a follow-up. The Debug build and signature checks
passed. The prior remote-test instance was restarted with its saved data and this
build. The user subsequently confirmed that remote access works from iOS.
See [Codex beta compatibility](codex-beta.md) for the remaining manual checklist.

## Linked folders

Headless Codex tabs send user-selected folders as `runtimeWorkspaceRoots` on `thread/start`, `thread/resume`, and new `turn/start` requests. The complete replacement includes the working directory and normalized, unique additional folders. Removing the last folder sends only the working directory. A persisted removal also replaces roots when resuming. Folder edits during a turn wait for the next turn; they never restart the shared app-server or change another thread.

Named permission profiles stay unchanged. Roots materialize the profile’s `:workspace_roots`; they do not turn read-only into workspace-write or replace custom filesystem, network, or approval rules. There is no standalone add-directory request. `thread/settings/update` has no roots field.

Remote attachment sends no roots override and adopts the returned roots through the existing folder store, respecting previously removed folders. Ordinary chats without selected folders or persisted removals omit the field for compatibility. A server that does not report `runtimeWorkspaceRoots` in its start/resume response cannot verify linked-folder support. Folder-dependent turns stop with an update notice instead of silently proceeding without the folders.

Verified against installed CLI 0.153.4: ephemeral starts with two roots preserved `:read-only` and returned a read-only sandbox. `:workspace` returned the second root as writable, with network access still disabled.

## External conversation ownership

A headless resume treats the installed CLI’s exact `-32600` refusal, `thread <id> already has an active writer`, as authoritative ownership evidence for that requested thread. Plume keeps the cached history and unsent queue, explains that the conversation is open elsewhere, and retries the same thread only when the user asks. It never starts a replacement thread, interrupts the owner, or infers ownership from a directory or process name. Retry works after the owning app or terminal releases its writer. The protocol does not identify that application or supply a deep link, so Plume directs the user back to the app or terminal they were using.

A live probe used two independent CLI 0.153.4 app-servers and a persisted thread in an isolated Codex home. The second server received the exact active-writer refusal while the first remained alive. After the probe stopped its own first server, the same second server resumed the same thread successfully. Fresh threads without a turn have no rollout; a second resume then reports no rollout rather than proving ownership.

Terminal transport still lets the real TUI own resume and display the server refusal. Its read-only observer never claims a thread to test ownership. Plume’s local tab claim guards against duplicate tabs, but cannot identify an external owner before the TUI attempts resume.

## Linear evidence from Codex MCP calls

MCP name metadata remains separate from the generic MCP summary. Raw per-item evidence feeds the shared Linear scanner for root and child conversations, with child provenance retained when aggregating. Both content and structuredContent envelopes are supported. Failed calls never infer issue identifiers from results. History restoration and forgetting remain scoped to each tab.

### Side questions

In a headless Codex chat, `/btw <question>` reads up to twelve recent turns with `thread/turns/list`. Plume keeps text from completed turns and excludes the turn active when the question was asked. The snapshot can omit older messages, tool output, and attachments. The side chat shows the scope as “Completed turns.”

A separate ephemeral Luna process answers with the same tool-free configuration as title generation. The snapshot goes through stdin. Plume keeps the exchange in memory and cancels outstanding questions when the session closes. The main conversation continues independently.
