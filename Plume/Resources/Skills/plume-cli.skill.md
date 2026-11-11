---
name: plume-cli
description: Use Plume's `plume` command from inside a Plume tab ($PLUME is set) — post a desktop notification when long work finishes or you need the user, check whether the user is at their Mac, open a terminal tab in the current task, or link the Linear issue you are working on to the task. Use on "notify me when…", "let me know when it's done", "open a terminal tab", when you start work on a Linear issue, or any `plume notify`, `plume presence`, `plume tab new`, `plume issue` or `plume init`.
---

# The `plume` command

Plume's tabs export `PLUME=1`, plus `PLUME_SOCKET`, `PLUME_TAB_ID` and `PLUME_TASK_ID`, which the `plume` tool uses to reach the app and the calling tab. `plume help` lists every command.

If `plume` is not on PATH, run `"$PLUME_CLI"` instead.

## Commands

- `plume notify <title> [body]` posts a desktop notification that routes back to this tab. Plume skips it while the user is looking at the tab. It exits 0 once its arguments parse, so it is safe in hooks and scripts. Use it when a long build or test run finishes, or when you are blocked on the user.
- `plume presence` prints `awake`, `asleep` or `locked`; `--json` adds each display. Check it to decide whether a notification is worth sending.
- `plume tab new [--cwd DIR] [--select]` opens a terminal tab in the calling task and prints its ID. The tab opens behind the current one unless you pass `--select`. Open one only when the user wants a terminal to watch.
- `plume issue link <ID|URL>` links a Linear issue, such as `PLUME-287` or its URL, to the calling task, and prints the identifier. Run it once when you start work on an issue, so the task's sidebar row and info pane show it. `plume issue unlink <ID>` undoes a wrong link.
- `plume init zsh --aliases` prints zsh completions and the bare `wt` and `stack` shortcuts. It belongs in the user's `.zshrc` as `eval "$(plume init zsh --aliases)"`; don't run it yourself.
- `plume wt`, `plume stack` and `plume devices` have their own skills: `plume-worktrees`, `plume-stack` and `plume-devices`.

Exit codes: 0 success, 1 failure (for example, Plume isn't running), 2 bad arguments. `plume devices` has its own codes.
