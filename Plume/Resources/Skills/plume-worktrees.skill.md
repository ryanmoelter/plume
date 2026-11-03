---
name: plume-worktrees
description: Create, list, commit in, rename and remove git worktrees with Plume's `plume wt` command. Use whenever a task involves worktrees ("make a worktree", "do this in a new worktree", "clean up that worktree") and the `plume` command is available, as it is in a Plume tab ($PLUME is set) once Plume's command line tool is on.
---

# Worktrees with `plume wt`

`plume wt` manages git worktrees and opens them in Plume's tabs and tasks. Run `plume wt help` first. It lists the current commands and this repository's resolved settings: base branch, branch prefix and protected worktrees. Its output wins over anything here.

## Rules

- Pass `--no-tab` to `co`, `cob` and `bg` unless the user wants to see the worktree. Inside Plume these commands otherwise open a tab. Pass `--task` instead to open it as a new task. Don't run `plume wt open`: it only opens a tab.
- Pass bare branch names. `wt` adds the branch prefix from Plume's Settings ▸ Projects itself.
- `plume wt switch` can't change your shell's directory. Get the path with `plume wt path <name|branch>` and use it: `git -C "$(plume wt path <name>)" status`, or `cd` within a single command. If the user wants their own shell moved, tell them to run `wt switch <name>`, which needs Plume's shell integration.
- Never assume where a worktree lives. `plume wt list --paths` prints every worktree's directory.
- Once you work in a worktree, stay in it. Don't edit files outside it or operate on the main checkout's branches.
- Run `plume wt prune` only when the user asks. It deletes merged worktrees and then merged branches.

## Common commands

| Goal | Command |
| --- | --- |
| New branch in a new worktree | `plume wt cob <name> --no-tab` |
| Existing branch in a new worktree | `plume wt co <branch> --no-tab` |
| Move the current branch and its changes to a worktree | `plume wt bg [name] --no-tab` |
| List worktrees with their status | `plume wt list` (`--json` to parse) |
| Which worktree am I in | `plume wt current --json` |
| Commit all changes in another worktree | `plume wt cm <name> [git-args...]` |
| Rename a worktree's branch | `plume wt rename [name] <new>` (`-f` also renames the folder) |
| Remove a worktree, keeping its branch | `plume wt delete <name>` |
