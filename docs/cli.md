# The `plume` command-line tool

`plume` is a small Swift tool that ships inside the app at `Contents/Helpers/plume`. It talks to the running app over a Unix socket, so it works from a plain terminal tab and from a headless agent tab, which has no terminal at all. The **Command line tool** switch in **Settings → Command line** links it into `~/.local/bin` as `plume` and as `plume-notify`, the name the tool had when it was a shell script. The switch reads on while any of those names links to a Plume tool, another copy's included, and an **Update** button appears when a Plume link points at an older or vanished tool. Turning it off removes every link Plume owns, `wt` included, plus any dangling link into a Plume bundle; a file or link the user made stays (`CommandLineHelper.uninstall`). The **`wt` command** and **Shell integration** rows show only while the switch is on. The `wt` row links `wt` the same way, but only when asked: neither the switch nor launch links it, and a `wt` that another tool owns, a dangling link outside any Plume bundle included, is never replaced (`CommandLineHelper.wtState`). A release build replaces a link into any Plume bundle, since the app may have moved. A debug build replaces and removes only links into its own bundle and shows a link into another Plume as taken (`CommandLineHelper.claimsOtherPlumeBundles`), so it never repoints the installed app's tool at itself. When another copy's links are the only ones, the switch reads on but is disabled, with a note naming the name that copy owns.

The code is split three ways:

| Where | What |
|---|---|
| `PlumeCLI/` | The tool's entry point: runs a parsed command. Target `PlumeCLI`, product `plume`. |
| `Shared/CLI/` | Compiled into both the app and the tool: the wire types, the line codec, socket path resolution, the socket client, `Presence`, argument parsing, and the zsh integration. PlumeTests reaches it through `@testable import Plume`. |
| `Plume/CLI/` | The app side: `CLIServer` (the socket) and `CLICommandHandler` (what each request does). |

**Settings → Command line → Shell integration** shows `eval "$(plume init zsh --aliases)"` with **Copy** and **Add to .zshrc** (`ZshrcSetup`). Add appends the line to `$ZDOTDIR/.zshrc`, else `~/.zshrc`, and creates the file if it is missing. It asks `zsh -c` for `ZDOTDIR`, because a GUI-launched app rarely inherits it from `~/.zshenv`. Any uncommented line containing `plume init zsh` counts as already added, so the row shows "Added" and appends nothing. Add appends through a file handle, so a `.zshrc` symlinked into a dotfiles repository stays a symlink. The line names `plume` rather than the bundled path, since the functions it defines call `command plume`. So the row shows only while the Command line tool switch is on.

## Commands

| Command | Needs the app | What it does |
|---|---|---|
| `plume notify <title> [body]` | No | Posts a desktop notification that routes back to the calling tab. Also takes `--title`, `--body` and `--message`, as the script did. Arguments apply in order and the last to name a field wins, again as the script did, so the first positional sets the title even after `--title`. `--` is skipped without ending the flags, and `-h` prints the usage to stderr and exits 2. |
| `plume presence [--json]` | No | Prints `awake`, `asleep` or `locked`. |
| `plume tab new [--cwd DIR] [--task ID] [--select]` | Yes | Opens a terminal tab in the calling task, or in `--task`, and prints its ID. Like every terminal tab, it reopens after a relaunch in the folder it last reported, unless that folder is gone. |
| `plume wt <command>` | Some | Manages git worktrees; `plume wt help` lists the commands. `docs/wt-port.md` maps it to the Python tool it replaces. |
| `plume init zsh [--aliases]` | No | Prints zsh completions and a `plume()` wrapper that turns `plume wt switch` into a `cd`; load with `eval "$(plume init zsh)"`. `--aliases` also defines a bare `wt()` that calls `plume wt`, with its own completion. |
| `plume help`, `plume --version` | No | `--version` reads the enclosing app's `Info.plist`. |

`plume-notify` still works as a link for older scripts: invoked under that name (argv[0]'s basename), the tool runs `notify` with the rest of the arguments. Invoked as `wt`, it runs `plume wt` with all of them.

**`wt` uses the app only to open things.** Every command reads git and the Projects settings itself. Inside a Plume tab, `co`, `cob`, `bg`, `open` and `switch` send `tab.new` for the worktree, or `task.new` with `--task`. Outside Plume, or when the app refuses, they print `wt: (cd "<dir>")` instead, and `switch` fails naming the wrapper. `wt setup` sends `settings.open` for the `projects` section and, when that fails, prints where the settings live.

**`notify` never fails its caller**, which is often a hook. It tries, in order:

1. With `PLUME_TAB_ID` and `PLUME_SOCKET` set, the `notify` request over the socket. The app posts it the way it posts an OSC 777 notification from a terminal, through `TerminalAlerts.notify(tabID:title:body:)`, and skips it when the user is already looking at that tab.
2. If that fails, an OSC 777 escape written to `/dev/tty`. The tool attempts the open rather than testing for it, since a writable `/dev/tty` doesn't mean a controlling terminal exists.
3. If there is no terminal either, nothing, exit 0.

**`tab new` fails loudly**, because the user asked for an app action. It opens the tab in `--task` if given. Otherwise it sends `PLUME_TAB_ID`, and the app opens the tab in that tab's current task, which changes when the tab is moved to another task. It falls back to `PLUME_TASK_ID` only when no tab ID is set. With none of the three it fails with "not inside a Plume task", and with nothing listening on the socket it fails with "Plume isn't running". A relative `--cwd` resolves against the caller's directory; the app itself refuses a relative `directory`. The tab opens behind the current selection unless `--select` is passed, which also shows its task in the frontmost main window. Every main window registers with `CLICommandHandler` while it is open, and any of them can find the task. The directory seeds the tab's entry in `TabDirectoryStore`, so the new terminal, the info pane and a later ⌘T all read it before the shell reports its own.

**`presence` runs in the tool**, from CoreGraphics. The screen reads `locked` while `CGSessionCopyCurrentDictionary` carries `CGSSessionScreenIsLocked`, then `asleep` when every online display reports `CGDisplayIsAsleep` (including no online display at all), and `awake` otherwise. `Presence.classify` is the pure rule. `--json` prints `{"displays":[{"asleep":false,"id":1}],"locked":false,"state":"awake"}`.

A new subcommand adds its completion to `ShellIntegration.commands`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success. `notify` always exits 0 once its arguments parse. |
| 1 | The command failed: the app is unreachable, the task or directory doesn't exist, or the app refused. |
| 2 | Bad arguments. The usage goes to stderr. |

## Environment

The app exports these into every tab's process, terminal and agent alike, and into a `!` command a chat runs (`LoginShellCommand.plumeEnvironment(taskID:tabID:)`):

| Variable | Value |
|---|---|
| `PLUME` | `1` |
| `PLUME_SOCKET` | The socket this app serves (`CLIServer.shared.socketPath`), so a debug or worktree build's tabs reach that build. Omitted when the server failed to start. |
| `PLUME_TAB_ID` | The tab's UUID |
| `PLUME_TASK_ID` | The task's UUID |
| `PLUME_BUNDLE_ID` | The app's bundle ID, so `wt` reads this build's Projects settings from its defaults domain. Outside Plume the tool falls back to the release ID, `com.ryanmoelter.Plume`. |

**Headless Codex tabs get their IDs through their thread, not their process.** One `codex app-server` process serves every headless Codex tab, so the process carries only `PLUME`, `PLUME_SOCKET` and `PLUME_BUNDLE_ID`. `thread/start` and `thread/resume` add each tab's variables as per-thread `config` overrides, one `shell_environment_policy.set.<NAME>` key each (`CodexSession.threadConfig`). The dotted keys merge into the user's own `shell_environment_policy.set` instead of replacing it, and `set` applies after `inherit` and `exclude`, so the values reach commands even with `inherit = "none"`. Only a user `include_only` list that leaves them out drops them. A resume that attaches to a thread already running in the app-server ignores `config`, so that thread keeps the environment it started with.

A Claude Code terminal tab already carried `PLUME_TAB_ID` and `PLUME_TASK_ID` for hook instrumentation. The hook command keys off `PLUME_EVENTS_DIR`, which only that path sets, so exporting the IDs elsewhere writes no events.

At launch the app unsets any of these it inherited, along with `PLUME_EVENTS_DIR` (`LoginShellCommand.dropInheritedInstanceKeys`), so no child inherits them. A debug Plume launched from another Plume's tab would otherwise hand its own children that Plume's socket and IDs.

Outside any Plume tab, `PLUME_SOCKET` is unset and the tool uses the installed app's socket, `~/Library/Application Support/Plume/run/cli.sock`. With `PLUME_TAB_ID` or `PLUME_TASK_ID` set but no `PLUME_SOCKET`, the tab's app serves no socket, and the installed app's may belong to a different Plume. The tool then reaches no app: `notify` goes straight to OSC 777, and `tab new` fails.

## Socket

The app serves `<AppPaths.applicationSupport>/run/cli.sock`, so the installed app, a debug build and each worktree build each get their own (`AppPaths.cliSocketPath`). `sun_path` holds 103 bytes plus the terminator. A longer path, as from a deep `PLUME_APP_SUPPORT` override, falls back to `/tmp/plume-<uid>/cli-<hash>.sock`, where the hash is FNV-1a of the preferred path. Either way the socket's directory holds only the socket and its lock file. The app creates it mode 0700, and refuses to use it unless this user owns it and it is a real directory.

Only the user who runs Plume can connect. The socket is mode 0600 inside that 0700 directory, and the server checks every peer with `getpeereid`. It answers any other uid with `{"ok":false,"error":"permission denied"}`, then shuts down its side for writing and closes once the peer does (or the idle timeout passes), reading nothing the peer sends. Closing straight away would let the peer's own write fail with `EPIPE` before it read the reply. The tool also reads any reply that arrived when its write fails.

**Ownership of the path is an `flock` on `cli.sock.lock`**, held for the server's lifetime (`CLIServer.acquireLock`). Only the holder may unlink or bind the socket path, so a server that gets the lock removes whatever socket file is there, which is the leftover of a crash. A server that can't get the lock has another instance with the same data directory serving, so it logs and doesn't start. A connect probe can't make this call: Darwin refuses a connect to a live listener with a full backlog with the same `ECONNREFUSED` as a dead socket. `stop()` unlinks the path only if it is still the socket this server bound (same device and inode), then releases the lock. The lock file itself is never removed, since unlinking a lock file races a process about to lock it.

Because of that same refusal, the tool retries a refused connect a few times, about 0.4 s in all, while a socket file exists at the path (`CLISocket.Retry`). Only then does it report "Plume isn't running".

The app starts the server in `PlumeApp.init`, before any view exists, because a tab's environment names the socket when it is built and keeps it for life. A process with no bundle identifier never starts the server, and neither does the test host, so a debug app launched while tests run still gets the socket. Tests that need a server start their own.

## Wire protocol

Newline-delimited JSON over a stream socket: the tool writes one request line and reads one response line. The server reads on the main queue and answers requests on one connection one at a time, in order. A handler that needs a subprocess, as `task.new` needs `git`, awaits it off the main actor, and the reply goes out when it finishes. The server never blocks the main queue: a reply the client isn't reading waits in a buffer that a write source drains. A connection that holds more than 1 MiB of unread input gets an error reply and is closed. Complete requests waiting behind one still being answered count toward that 1 MiB, and at most 32 may wait; past either limit the connection gets `too many requests queued` after the queued replies and is closed. The same goes for one with more than 1 MiB of unsent output, or one idle for 30 seconds (`CLIServer.Limits`). When the process runs out of file descriptors, accepting pauses briefly instead of spinning. The tool bounds the connect and the write at three seconds (two for `notify`), so a wedged app can't hang a hook. The wait for the reply has its own thirty-second deadline, since the server answers on the main queue and a busy app answers late rather than never. It reads the reply once; only after a failed write does it read again, for a refusal the server sent first. A last request with no trailing newline is still answered when the client shuts down its writing side.

Requests name a `command` and carry its `params`:

```
{"command":"ping"}
{"command":"notify","params":{"tabID":"<uuid>","title":"Done","body":"All green"}}
{"command":"tab.new","params":{"taskID":"<uuid>","directory":"/abs/path","select":false}}
{"command":"tab.new","params":{"tabID":"<uuid>","select":false}}
{"command":"task.new","params":{"worktreePath":"/abs/worktree","tabID":"<uuid>","select":false}}
{"command":"settings.open","params":{"section":"projects"}}
```

`tab.new` names its task with `taskID`, or with `tabID`, a tab in that task; `taskID` wins when both are present. `directory` is absolute and optional.

`task.new` opens a task on the existing worktree at `worktreePath`, at the end of the caller's group, with the caller named the same two ways. An unknown caller, or none, puts the task outside any group. The app reads the repository and the branch from the worktree, and names the task after the worktree's folder. The repository is the parent of git's common dir, or in the bare layout the `.bare` repository itself, since its parent is no repository and git fails there (`ProjectRoot.repositoryDirectory(forRoot:)`). A worktree created from such a task still lands beside `.bare` in the project folder, where `plume wt` puts its own. The path must be absolute and the root of a checkout. A linked worktree becomes a worktree task; the main checkout becomes a directory task, so deleting the task never offers to remove it. A worktree that already has a task that isn't archived gets that task back instead of a second one, so a client that timed out and retried never duplicates it. `select` reveals the task in the frontmost main window. It answers `{"ok":true,"taskID":"<uuid>"}`.

`settings.open` brings Plume forward and shows the Settings window, on `section` when given. `section` is optional and names a `SettingsPane`, such as `projects`; an unknown one fails. Both commands need an open main window, and `wt` falls back on any refusal as it does for an unreachable app. Responses carry `ok`, plus `error` on failure and whatever the command returns:

```
{"ok":true,"version":"0.16.1"}
{"ok":true,"tabID":"<uuid>"}
{"ok":true,"taskID":"<uuid>"}
{"ok":false,"error":"no Plume task <uuid>"}
```

A line that doesn't decode, including an unknown command, gets an `ok: false` reply naming the problem; the connection stays open. To add a command, add a case to `CLIRequest` (`Shared/CLI/CLIProtocol.swift`) and handle it in `CLICommandHandler`.
