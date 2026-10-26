# The `plume` command-line tool

`plume` is a small Swift tool that ships inside the app at `Contents/Helpers/plume`. It talks to the running app over a Unix socket, so it works from a plain terminal tab and from a headless agent tab, which has no terminal at all. **Settings → General → Command line tool** links it into `~/.local/bin` as `plume` and as `plume-notify`, the name the tool had when it was a shell script. A release build replaces a link into any Plume bundle, since the app may have moved. A debug build replaces only links into its own bundle and shows a link into another Plume as taken (`CommandLineHelper.claimsOtherPlumeBundles`), so it never repoints the installed app's tool at itself.

The code is split three ways:

| Where | What |
|---|---|
| `PlumeCLI/` | The tool's entry point: runs a parsed command. Target `PlumeCLI`, product `plume`. |
| `Shared/CLI/` | Compiled into both the app and the tool: the wire types, the line codec, socket path resolution, the socket client, `Presence`, argument parsing, and the zsh integration. PlumeTests reaches it through `@testable import Plume`. |
| `Plume/CLI/` | The app side: `CLIServer` (the socket) and `CLICommandHandler` (what each request does). |

## Commands

| Command | Needs the app | What it does |
|---|---|---|
| `plume notify <title> [body]` | No | Posts a desktop notification that routes back to the calling tab. Also takes `--title`, `--body` and `--message`, as the script did. |
| `plume presence [--json]` | No | Prints `awake`, `asleep` or `locked`. |
| `plume tab new [--cwd DIR] [--task ID] [--select]` | Yes | Opens a terminal tab in the calling task, or in `--task`, and prints its ID. |
| `plume init zsh` | No | Prints zsh completions; load with `eval "$(plume init zsh)"`. |
| `plume help`, `plume --version` | No | `--version` reads the enclosing app's `Info.plist`. |

Invoked as `plume-notify` (argv[0]'s basename), the tool runs `notify` with the rest of the arguments.

**`notify` never fails its caller**, which is often a hook. It tries, in order:

1. With `PLUME_TAB_ID` set, the `notify` request over the socket. The app posts it the way it posts an OSC 777 notification from a terminal, through `TerminalAlerts.notify(tabID:title:body:)`, and skips it when the user is already looking at that tab.
2. If that fails, an OSC 777 escape written to `/dev/tty`. The tool attempts the open rather than testing for it, since a writable `/dev/tty` doesn't mean a controlling terminal exists.
3. If there is no terminal either, nothing, exit 0.

**`tab new` fails loudly**, because the user asked for an app action. It opens the tab in `--task` if given. Otherwise it sends `PLUME_TAB_ID`, and the app opens the tab in that tab's current task, which changes when the tab is moved to another task. It falls back to `PLUME_TASK_ID` only when no tab ID is set. With none of the three it fails with "not inside a Plume task", and with nothing listening on the socket it fails with "Plume isn't running". A relative `--cwd` resolves against the caller's directory. The tab opens behind the current selection unless `--select` is passed, which also shows its task in the window. The directory is stored on the tab as `TaskTab.launchDirectoryPath` and read when its terminal surface is built.

**`presence` runs in the tool**, from CoreGraphics. The screen reads `locked` while `CGSessionCopyCurrentDictionary` carries `CGSSessionScreenIsLocked`, then `asleep` when every online display reports `CGDisplayIsAsleep` (including no online display at all), and `awake` otherwise. `Presence.classify` is the pure rule. `--json` prints `{"displays":[{"asleep":false,"id":1}],"locked":false,"state":"awake"}`.

A new subcommand adds its completion to `ShellIntegration.commands`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success. `notify` always exits 0 once its arguments parse. |
| 1 | The command failed: the app is unreachable, the task or directory doesn't exist, or the app refused. |
| 2 | Bad arguments. The usage goes to stderr. |

## Environment

The app exports these into every tab's process, terminal and agent alike (`LoginShellCommand.plumeEnvironment(taskID:tabID:)`):

| Variable | Value |
|---|---|
| `PLUME` | `1` |
| `PLUME_SOCKET` | This app's socket, so a debug or worktree build's tabs reach that build |
| `PLUME_TAB_ID` | The tab's UUID |
| `PLUME_TASK_ID` | The task's UUID |

**Headless Codex tabs get `PLUME_SOCKET` but no tab or task ID.** One `codex app-server` process serves every headless Codex tab, so its commands share one environment and there is no single tab to name. `plume notify` from one falls back to the terminal path, and `tab new` needs `--task`.

A Claude Code terminal tab already carried `PLUME_TAB_ID` and `PLUME_TASK_ID` for hook instrumentation. The hook command keys off `PLUME_EVENTS_DIR`, which only that path sets, so exporting the IDs elsewhere writes no events.

At launch the app unsets any of these it inherited, along with `PLUME_EVENTS_DIR`, and `LoginShellCommand.childEnvironment` strips them again when building a child's environment. A debug Plume launched from another Plume's tab would otherwise hand its own children that Plume's socket and IDs.

Outside any Plume tab, `PLUME_SOCKET` is unset and the tool uses the installed app's socket, `~/Library/Application Support/Plume/cli.sock`.

## Socket

The app serves `<AppPaths.applicationSupport>/cli.sock`, so the installed app, a debug build and each worktree build each get their own (`AppPaths.cliSocketPath`). `sun_path` holds 103 bytes plus the terminator. A longer path, as from a deep `PLUME_APP_SUPPORT` override, falls back to `/tmp/plume-<uid>/cli-<hash>.sock`, where the hash is FNV-1a of the preferred path. The app creates that directory mode 0700 and refuses to use it unless this user owns it and it is a real directory.

Only the user who runs Plume can connect. The socket is mode 0600, and the server checks every peer with `getpeereid`, answering any other uid with `{"ok":false,"error":"permission denied"}` before closing.

At launch the server removes a socket file that refuses connections, the leftover of a crash. It probes with a non-blocking connect, which a Unix socket answers at once. A socket that answers belongs to another running instance with the same data directory, so the server logs and doesn't start. The test host has no bundle identifier and never starts it.

## Wire protocol

Newline-delimited JSON over a stream socket: the tool writes one request line and reads one response line. The server reads on the main queue and answers requests on one connection in order. It never blocks there: a reply the client isn't reading waits in a buffer that a write source drains. A connection that holds more than 1 MiB of unread input gets an error reply and is closed, as is one with more than 1 MiB of unsent output, or one idle for 30 seconds (`CLIServer.Limits`). When the process runs out of file descriptors, accepting pauses briefly instead of spinning. The tool sets three-second send and receive timeouts (two for `notify`), so a wedged app can't hang a hook.

Requests name a `command` and carry its `params`:

```
{"command":"ping"}
{"command":"notify","params":{"tabID":"<uuid>","title":"Done","body":"All green"}}
{"command":"tab.new","params":{"taskID":"<uuid>","directory":"/abs/path","select":false}}
{"command":"tab.new","params":{"tabID":"<uuid>","select":false}}
```

`tab.new` names its task with `taskID`, or with `tabID`, a tab in that task; `taskID` wins when both are present. `directory` is absolute and optional. Responses carry `ok`, plus `error` on failure and whatever the command returns:

```
{"ok":true,"version":"0.16.1"}
{"ok":true,"tabID":"<uuid>"}
{"ok":false,"error":"no Plume task <uuid>"}
```

A line that doesn't decode, including an unknown command, gets an `ok: false` reply naming the problem; the connection stays open. To add a command, add a case to `CLIRequest` (`Shared/CLI/CLIProtocol.swift`) and handle it in `CLICommandHandler`.
