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

1. `initialize` — `{clientInfo: {name, title, version}, capabilities: {}}`.
   The reply is `{userAgent, codexHome, platformFamily, platformOs}`.
2. `initialized` — a notification, the only one the client ever sends.
3. `thread/start` or `thread/resume`.

`InitializeCapabilities` has an `experimentalApi` flag. **The `thread/*` surface
does not need it** — `thread/start` was verified to work with capabilities left
empty — so Plume does not opt in. `optOutNotificationMethods` on the same
struct declines notifications the client never reads. It matches **exact
method names, not prefixes** — a pattern there suppresses nothing, silently.
`CodexCommand.ignoredNotifications` lists them.

## Threads and turns

`thread/start` needs only `cwd`. `ThreadStartParams` has no required fields,
and `permissions` and `sandbox` cannot be combined — pick one axis.

The reply carries the whole thread: `id` (Plume persists it to
`TaskTab.agentSessionID`), `model`, `reasoningEffort`, `status`, `cwd`, and
`path` — the rollout file on disk.

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
way. That is why Plume reads history through `thread/items/list` rather than
parsing the rollout JSONL at `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`:
the file format is not in the schema, is unversioned, and the API paginates.

The cost is that a Codex tab's history needs a live app-server, where Claude's
transcript can be read cold.

## Models and effort

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
