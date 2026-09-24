# Codex support (Beta)

Plume supports Codex alongside Claude Code. Choose a Codex model in the composer
before starting a conversation. The model menu offers a download link when the
corresponding CLI is missing. Choose Dismiss to hide that section until the CLI
is detected. Missing-CLI download links remain available in Settings.

## Compatibility

- Requires macOS 26.2 or later and `codex` installed and logged in on your login
  shell’s PATH. Plume uses your local Codex installation and authentication.
- Tested with **Codex CLI 0.153.4** using ChatGPT authentication. This is the
  tested version, not a verified minimum; older and newer versions may differ.
- Codex’s app-server APIs include experimental features. Available models,
  permissions, skills, and remote access depend on the installed CLI and account.
- The default Headless transport provides Plume’s chat UI. Terminal mode runs
  the Codex TUI and has a different remote-access scope, described below.

## Remote control

All connected headless Codex chats share one server and remote-control setting.
The toggle applies to the host and its conversations and tools, rather than
only the selected chat. Stay Awake counts that host once. Closing one connected
chat keeps remote access available while another is connected; closing the last
one or quitting Plume ends the host. Reconnect after restarting Plume.

Chats opened or created remotely appear in Plume, with approvals and activity
tracking. Phone pairing and loading new chats from iOS have been verified.

Only one server for the same Codex installation can serve remote access at a
time. If the Codex desktop app is already serving it, turn that connection off
before enabling Plume’s. Plume does not stop another application’s host.
Terminal-mode Codex tabs run on separate servers and are not included in the
shared headless remote connection.

## Known limitations

- Cross-app resume protection is tracked in PLUME-153. Codex rejects a second
  server trying to resume a conversation with an active writer; Plume does not
  yet offer a friendly ownership/recovery flow. End the other application’s
  session before resuming it in Plume.
- MCP elicitation (`mcpServer/elicitation/request`) and dynamic tool calls
  (`item/tool/call`) are not implemented. Plume answers unsupported requests
  with an error rather than leaving them pending.
- Stay Awake tracks commands kept alive in Codex’s managed terminal sessions.
  Shell-detached commands such as `sleep 60 &` or `nohup … &` are not reliably
  reported by Codex and do not acquire a background-work hold. A printed PID
  or an agent’s “started” message is not proof that the process remains alive.
  Tracked in [PLUME-160](https://linear.app/plume-term/issue/PLUME-160/track-codex-shell-detached-background-work-for-stay-awake).
- Generated titles are best-effort and use a separate, tool-free Codex request.
  If it fails or the CLI is incompatible, the conversation preview remains.

## Manual verification

Remote checks 1–2 are deferred to [PLUME-159](https://linear.app/plume-term/issue/PLUME-159/verify-codex-remote-control-end-to-end) for a later pass.

Use a disposable task/folder for tool approvals. Keep the other desktop remote
host off for the remote checks. Report any failure with the transport, what you
clicked or sent, and the approximate time.

1. **Remote approvals:** in a headless Codex chat using a restrictive permission
   profile, request a harmless action that needs approval. Approve it from iOS;
   check that the prompt clears on the Mac and the turn continues. Repeat with
   denial; it must not run the denied action or stay stuck. If it runs without
   prompting, that does not exercise this check.
2. **Remote reconnect:** keep two Codex chats open. Quit and reopen Plume,
   reconnect remote control, and open both chats on iOS. Send a follow-up in each;
   history and replies should stay in the correct chat. Close one Mac tab and
   confirm the other remains reachable. Stay Awake should list one remote host.
3. **Codex terminal UI:** create a Codex Terminal-mode tab and send a simple
   prompt. Switch tasks and back while it works. Check the TUI survives and
   activity returns to idle after the turn. Exercise an approval in the TUI and
   check that waiting for approval is not reported as actively working.
4. **Background work / Stay Awake:** test both a headless Codex chat and a
   Terminal-mode tab with this specific prompt: “Run `sleep 60` using
   `exec_command` with `yield_time_ms: 1000`, then finish your turn while its
   returned session is still running. Do not use `&`, `nohup`, or wait for it.”
   Check that the tool returns a running session, rather than an exit code. With
   the relevant Stay Awake option enabled, the background reason should remain
   after the reply and disappear when the command exits. Closing the tab should
   clear its reasons too. Shell-detached work is a separate known limitation.
5. **Claude regression:** send a normal Claude chat message, approve a plan or
   tool request, and switch between Claude and Codex tabs. Claude’s controls,
   transcript, and remote-control behavior should remain independent.

Automated verification already covers shared initialization, chat/approval
isolation, reconnect state, remote thread adoption, and closing tabs during
startup. Live checks confirmed two Codex chats share a server and the surviving
chat can finish a new turn after its sibling closes. The broader test suite and
final branch review are still part of the merge pass.
